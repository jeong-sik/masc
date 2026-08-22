(** Dashboard_gate_metrics — aggregates tool rejection counts and
    approval queue depth/latency for operator visibility.

    Two data sources:
    1. In-memory ring of recent tool-skip events recorded via
       [record_tool_skipped], registered at module initialisation as the
       [Keeper_keepalive_signal.record_tool_skipped] callback so the ring
       carries the same (tool_name, reason_code) the SSE stream emits. The
       ring gives operators a "last N minutes" view without tailing JSONL.
    2. Live approval queue state returned by
       [Keeper_approval_queue.list_pending_entries_for_workspace]. Approval queue metrics
       are computed from the current pending set; this module does not parse
       the approval audit JSONL.

    Window for tool-rejection counts is configurable per-request via the
    HTTP [?window=<minutes>] query param.

    @since #6810 follow-up — observability gap #1 + #6 *)

(* ── Tool rejection ring ─────────────────────────────────── *)

(** Single recorded rejection event. *)
type rejection_event = {
  ts : float;
  tool_name : string;
  reason_code : string;
}
let max_ring_size = 43200
(** Bounded ring buffer to prevent unbounded memory growth.
    43200 events at ~1 skip/sec sustained covers 12 hours, matching
    the largest dashboard window (720m). *)

let ring_mu = Eio.Mutex.create ()

type rejection_ring = {
  events : rejection_event list;
  count : int;
}

let empty_ring = { events = []; count = 0 }

let ring : rejection_ring ref = ref empty_ring
(** [events] is most recent first; truncated to [max_ring_size].
    [count] is the linearized length so appends do not rescan the full ring. *)

let record_failure_callback_label =
  "dashboard_gate_tool_skipped_record"

let record_tool_skipped_failure exn =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string LifecycleCallbackFailures)
    ~labels:[ ("callback", record_failure_callback_label) ]
    ();
  Log.Dashboard.warn
    "dashboard Gate metrics failed to record tool skip: %s"
    (Printexc.to_string exn)

let append_rejection_event event =
  Eio.Mutex.use_rw ~protect:true ring_mu (fun () ->
    let current = !ring in
    if current.count < max_ring_size
    then ring := { events = event :: current.events; count = current.count + 1 }
    else
      ring :=
        { events = event :: List.take (max_ring_size - 1) current.events
        ; count = max_ring_size
        })

let record_tool_skipped_with_append ~append ~tool_name ~reason_code =
  (* NDT-OK: observation boundary. The ring stamps when the skip was seen; no
     branch reads [ts] back, only the window filter in the projection does. *)
  let event = { ts = Unix.gettimeofday (); tool_name; reason_code } in
  try
    append event
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> record_tool_skipped_failure exn

(** Record a tool-skip event. Installed as the
    [Keeper_keepalive_signal.record_tool_skipped] callback so the in-memory
    ring stays in sync with the SSE event stream. *)
let record_tool_skipped ~tool_name ~reason_code =
  record_tool_skipped_with_append ~append:append_rejection_event ~tool_name ~reason_code

(** Reset the ring. Test-only helper — exposed because the alcotest cases
    need to start from a clean state regardless of test order. *)
let reset_for_testing () =
  Eio.Mutex.use_rw ~protect:true ring_mu (fun () -> ring := empty_ring)

let snapshot_ring () =
  Safe_ops.protect ~default:[] (fun () ->
    Eio.Mutex.use_ro ring_mu (fun () -> (!ring).events))

let inject_for_testing ~tool_name ~reason_code ~ts =
  let event = { ts; tool_name; reason_code } in
  append_rejection_event event

let max_ring_size_for_testing = max_ring_size

let ring_size_for_testing () =
  Eio.Mutex.use_ro ring_mu (fun () -> (!ring).count)

let record_tool_skipped_with_append_for_testing ~append ~tool_name ~reason_code =
  record_tool_skipped_with_append
    ~append:(fun _event -> append ())
    ~tool_name
    ~reason_code

(** Aggregate [(tool_name, reason_code) -> count] over the supplied window.
    [now_ts] is injectable for testing.  Returns a deterministic ordering:
    count desc, then tool_name asc, then reason_code asc. *)
let tool_rejection_counts ~now_ts ~window_minutes () :
    (string * string * int) list =
  let since = now_ts -. (float_of_int window_minutes *. 60.0) in
  let module SMap = Map.Make (struct
    type t = string * string
    let compare = compare
  end) in
  let counts =
    List.fold_left
      (fun acc ev ->
        if ev.ts >= since
        then
          let key = (ev.tool_name, ev.reason_code) in
          let prior = Option.value (SMap.find_opt key acc) ~default:0 in
          SMap.add key (prior + 1) acc
        else acc)
      SMap.empty (snapshot_ring ())
  in
  SMap.bindings counts
  |> List.map (fun ((tool, reason), count) -> (tool, reason, count))
  |> List.sort (fun (t1, r1, c1) (t2, r2, c2) ->
      let by_count = Int.compare c2 c1 in
      if by_count <> 0 then by_count
      else
        let by_tool = String.compare t1 t2 in
        if by_tool <> 0 then by_tool
        else String.compare r1 r2)

(* ── Approval queue depth & latency ─────────────────────── *)

(** Compute percentile (linear interpolation) on a sorted ascending array.
    Returns [None] when the array is empty. *)
let percentile_sorted arr p =
  let n = Array.length arr in
  if n = 0 then None
  else if n = 1 then Some arr.(0)
  else
    let p = max 0.0 (min 1.0 p) in
    let rank = p *. float_of_int (n - 1) in
    let lo = int_of_float (Float.floor rank) in
    let hi = int_of_float (Float.ceil rank) in
    if lo = hi then Some arr.(lo)
    else
      let frac = rank -. float_of_int lo in
      Some (arr.(lo) +. ((arr.(hi) -. arr.(lo)) *. frac))

(** Approval queue snapshot: depth + wait-time percentiles. *)
type approval_summary = {
  depth : int;
  p50_wait_sec : float option;
  p95_wait_sec : float option;
  oldest_pending_sec : float option;
}

let approval_queue_summary_of_entries ~now_ts entries : approval_summary =
  let waits =
    List.map
      (fun (entry : Keeper_approval_queue_rules_types.pending_approval) ->
        Float.max 0.0 (now_ts -. entry.requested_at))
      entries
  in
  let depth = List.length waits in
  if depth = 0 then
    { depth = 0; p50_wait_sec = None; p95_wait_sec = None;
      oldest_pending_sec = None }
  else
    let arr = Array.of_list waits in
    Array.sort Float.compare arr;
    let oldest = arr.(Array.length arr - 1) in
    {
      depth;
      p50_wait_sec = percentile_sorted arr 0.50;
      p95_wait_sec = percentile_sorted arr 0.95;
      oldest_pending_sec = Some oldest;
    }

let approval_queue_summary ~now_ts ~base_path ()
  : (approval_summary, Keeper_approval_queue.storage_error) result
  =
  Keeper_approval_queue.list_pending_entries_for_workspace ~base_path
  |> Result.map (approval_queue_summary_of_entries ~now_ts)

(* ── JSON projection ─────────────────────────────────────── *)

let tool_rejections_json ?(top_n = 20)
    ~window_minutes ~now_ts () : Yojson.Safe.t list =
  tool_rejection_counts ~now_ts ~window_minutes ()
  |> (fun ls ->
       if List.length ls <= top_n then ls
       else List.filteri (fun i _ -> i < top_n) ls)
  |> List.map (fun (tool, reason, count) ->
      `Assoc [
        ("tool", `String tool);
        ("reason", `String reason);
        ("count", `Int count);
      ])

let approval_queue_json (summary : approval_summary) : Yojson.Safe.t =
  `Assoc [
    ("depth", `Int summary.depth);
    ("p50_wait_sec", Json_util.float_opt_to_json summary.p50_wait_sec);
    ("p95_wait_sec", Json_util.float_opt_to_json summary.p95_wait_sec);
    ("oldest_pending_sec", Json_util.float_opt_to_json summary.oldest_pending_sec);
  ]

let gate_tool_events_json_with_pending_result
      ~now_ts
      ~window_minutes
      pending_result
  =
  let rejections = tool_rejections_json ~window_minutes ~now_ts () in
  let approval_queue_state, approval_queue =
    match pending_result with
    | Ok entries ->
      ( Keeper_approval_queue.approval_queue_ready_state_json
      , approval_queue_summary_of_entries ~now_ts entries
        |> approval_queue_json )
    | Error error ->
      ( Keeper_approval_queue.approval_queue_unavailable_state_json error
      , `Null )
  in
  `Assoc [
    ("generated_at", `String (Masc_domain.iso8601_of_unix_seconds now_ts));
    ("window_minutes", `Int window_minutes);
    ("tool_rejections", `List rejections);
    ("approval_queue_state", approval_queue_state);
    ("approval_queue", approval_queue);
  ]

(** Top-level endpoint payload. *)
let gate_tool_events_json ~base_path ~window_minutes () : Yojson.Safe.t =
  (* NDT-OK: HTTP observation boundary; captured once for the pure projection. *)
  let now_ts = Unix.gettimeofday () in
  let pending_result =
    Keeper_approval_queue.list_pending_entries_for_workspace ~base_path
  in
  gate_tool_events_json_with_pending_result
    ~now_ts
    ~window_minutes
    pending_result

let gate_tool_events_json_with_pending_result_for_testing =
  gate_tool_events_json_with_pending_result

let () = Keeper_keepalive_signal.register_record_tool_skipped record_tool_skipped
