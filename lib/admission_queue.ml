(** Admission_queue — MASC-layer priority admission queue for inference calls.

    Mirrors OAS Slot_scheduler design (priority sorted waiter list,
    Eio.Promise blocking, Atomic cancel flag) at the MASC layer with
    MASC-visible waiter metadata for observability.

    {1 Status — 2026-05-05}

    [with_permit] is intentionally passthrough. Provider-level throttling
    moved to OAS runtime per RFC-0026 (PR-E-1.6 + 1.7); MASC-layer
    gating couples request classification with local resource estimates
    and cannot express per-provider capacity. The
    [insert_sorted] / [waiter] / [global.waiters] machinery below is
    observability scaffolding for the future runtime-layer admission
    router and is not consumed by the current call path; do not delete.
    See docs/audit-responses/2026-05-05-dashboard-heuristic.md §3 for the
    full classification.

    @since 3.0.0 *)

(* ── Types ─────────────────────────────────────────────── *)

type waiter_info =
  { keeper_name : string
  ; runtime_id : string
  ; enqueue_ts : float
  ; priority : Llm_provider.Request_priority.t
  }

type snapshot =
  { max_concurrent : int
  ; active : int
  ; available : int
  ; queue_depth : int
  ; waiters : waiter_info list
  }

type waiter =
  { rank : int
  ; info : waiter_info
  ; resolver : unit Eio.Promise.u
  ; cancelled : bool Atomic.t
  }

type counters =
  { active : int
  ; max_slots : int
  }

type t =
  { mutable counters : counters
  ; mutable waiters : waiter list
  ; mutex : Eio.Mutex.t
  }

(* ── Sorted Insertion ──────────────────────────────────── *)

(* RFC-0026 observability scaffolding: defined for future runtime-layer
   admission router consumption; not invoked from the current passthrough
   [with_permit] path. Audit response 2026-05-05 §3.2. Do not delete. *)

(** Insert waiter in priority order (lower rank = higher priority = front).
    Stable: equal-rank waiters maintain FIFO order. *)
let insert_sorted entry ws =
  let rec go acc = function
    | [] -> List.rev (entry :: acc)
    | w :: rest as tail ->
      if entry.rank <= w.rank
      then List.rev_append acc (entry :: tail)
      else go (w :: acc) rest
  in
  go [] ws
;;

(* ── Core Queue ────────────────────────────────────────── *)

let initial_max_concurrent_of_env getenv =
  let parse_int raw =
    Option.bind (getenv raw) (fun value -> int_of_string_opt (String.trim value))
  in
  match parse_int "MASC_ADMISSION_MAX_CONCURRENT" with
  | Some n -> max 1 n
  | None ->
    (* Default 3: with_permit is now passthrough (provider throttle
         belongs in OAS runtime, not MASC).  This value is only used
         for snapshot reporting; it does not gate anything. *)
    3
;;

let global : t =
  { counters = { max_slots = initial_max_concurrent_of_env Sys.getenv_opt; active = 0 }
  ; waiters = []
  ; mutex = Eio.Mutex.create ()
  }
;;

let () = Admission_queue_metrics.set_max_concurrent global.counters.max_slots
let now_ts () = Unix.gettimeofday ()
let wait_ms_since enqueue_ts = int_of_float ((now_ts () -. enqueue_ts) *. 1000.0)

let apply_active_delta counters ~delta =
  let new_active = counters.active + delta in
  if new_active < 0
  then Error (`Counter_underflow new_active)
  else Ok { counters with active = new_active }
;;

let bump_active ?(loc = "unknown") delta =
  Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
    match apply_active_delta global.counters ~delta with
    | Ok counters ->
      global.counters <- counters;
      Ok ()
    | Error (`Counter_underflow raw) as e ->
      (* A mismatch between acquire and release paths previously silently
         clamped the counter to zero.  Surface the drift so operators can
         detect accounting bugs instead of masking them.  The counter is left
         unchanged; callers must decide whether to abort or continue.
         FIXME: type-level pair acquire/release would make underflow
         impossible; defer that larger refactor. *)
      Log.Misc.warn
        "admission_queue active counter underflow: raw=%d loc=%s; leaving counter unchanged"
        raw loc;
      e)
;;

let with_inflight_observation ~keeper_name ~runtime_id f =
  let raise_underflow loc raw =
    failwith
      (Printf.sprintf
         "admission_queue counter underflow in %s for keeper=%s runtime_id=%s: raw=%d"
         loc
         keeper_name
         runtime_id
         raw)
  in
  (match bump_active ~loc:"acquire" 1 with
   | Ok () -> ()
   | Error (`Counter_underflow raw) -> raise_underflow "acquire" raw);
  (match Admission_queue_metrics.on_acquire ~keeper_name ~runtime_id ~wait_ms:0 with
   | () -> ()
   | exception exn ->
     (match bump_active ~loc:"on_acquire_exn" (-1) with
      | Ok () -> ()
      | Error (`Counter_underflow raw) ->
        Log.Misc.warn
          "admission_queue counter underflow in on_acquire_exn for keeper=%s runtime_id=%s: \
           raw=%d; leaving counter unchanged"
          keeper_name
          runtime_id
          raw);
     raise exn);
  let release_underflow = ref None in
  let result =
    Eio_guard.protect
      ~finally:(fun () ->
        (match Admission_queue_metrics.on_release ~keeper_name ~runtime_id with
         | () -> ()
         | exception exn ->
           (match bump_active ~loc:"on_release_exn" (-1) with
            | Ok () -> ()
            | Error (`Counter_underflow raw) ->
              Log.Misc.warn
                "admission_queue counter underflow in on_release_exn for keeper=%s runtime_id=%s: \
                 raw=%d; leaving counter unchanged"
                keeper_name
                runtime_id
                raw);
           raise exn);
        match bump_active ~loc:"release" (-1) with
        | Ok () -> ()
        | Error (`Counter_underflow raw) -> release_underflow := Some raw)
      f
  in
  match !release_underflow with
  | Some raw -> raise_underflow "release" raw
  | None -> result
;;

(* ── Public API ────────────────────────────────────────── *)

(* #10745: track previous rejection per keeper so successive rejection
   logs carry the fd-growth rate inline.  Issue evidence: fd count
   3110 → 3157 → 3215 (+47 fd/min steady) over 22 rejections / 24h,
   100% on [oas-governance_judge].  Without the rate, operators have
   to scrub timestamps to confirm a leak vs. a transient burst.  Hash
   keyed by [keeper_name]; protected by [rejection_history_mu]. *)
let rejection_history : (string, float * int) Hashtbl.t = Hashtbl.create 16
let rejection_history_mu = Eio.Mutex.create ()

let format_fd_growth_hint ~keeper_name ~fd_count ~now =
  Eio.Mutex.use_rw ~protect:true rejection_history_mu (fun () ->
    let prev = Hashtbl.find_opt rejection_history keeper_name in
    Hashtbl.replace rejection_history keeper_name (now, fd_count);
    match prev with
    | None -> ""
    | Some (prev_ts, prev_fd) ->
      let dt = now -. prev_ts in
      let dfd = fd_count - prev_fd in
      if dt <= 0.0
      then ""
      else (
        let rate_per_min = float_of_int dfd /. dt *. 60.0 in
        let trend =
          if dfd > 0 then "growing" else if dfd < 0 then "shrinking" else "steady"
        in
        Printf.sprintf
          " [Δ%+d fd in %.0fs = %+.1f fd/min, %s; previous fd=%d at %.0fs ago]"
          dfd
          dt
          rate_per_min
          trend
          prev_fd
          dt))
;;

let observe_rejection ~surface ~reason =
  Safe_ops.protect ~default:() (fun () ->
    Admission_queue_metrics.on_reject ~surface ~reason)
;;

let check_host_resources_with ~surface ~keeper_name ~fd_count ~threshold =
  if fd_count >= threshold * 9 / 10
  then (
    (* #10745: include fd-growth rate inline so the leak signal does
       not require log scrubbing.  Monotonic positive trend across
       successive rejections of the same keeper points at fd leak
       (see issue #10745 root-cause discussion: subprocess close miss,
       sandbox docker exec residue, WS standalone handler write-after-
       close).  The hint is empty on the first rejection and on
       reset (clock skew). *)
    let now = now_ts () in
    let hint = format_fd_growth_hint ~keeper_name ~fd_count ~now in
    let msg =
      Printf.sprintf "fd count %d >= 90%% of threshold %d%s" fd_count threshold hint
    in
    Log.Misc.warn "admission rejected for %s: %s" keeper_name msg;
    observe_rejection ~surface ~reason:Admission_queue_metrics.Host_resource_saturated;
    Error (`Host_resource_saturated msg))
  else Ok ()
;;

(* Resolve the gate from the configured threshold.  [fd_count] is a thunk so
   the [/dev/fd] scan in [Otel_metric_process.approximate_open_fd_count] runs
   only when a finite threshold is configured.  When gating is disabled
   ([None]) the scan is skipped entirely and the call is admitted.

   Behaviour-preserving against the former [max_int] sentinel: that sentinel
   admitted every call (no real fd count reaches [max_int * 9 / 10]) yet paid
   the directory scan on every admission.  The admit decision is unchanged;
   only the dead scan is dropped.  The MASC-side concurrency gate
   (RFC-0124 admission denial boundary, RFC-0153 backpressure) is unrelated
   and untouched; host-level fd pressure is handled out-of-process by the
   RFC-0137 keeper_fd_pressure poller. *)
let check_host_resources_for_threshold ~surface ~keeper_name ~threshold ~fd_count =
  match threshold with
  | None -> Ok ()
  | Some threshold ->
    check_host_resources_with ~surface ~keeper_name ~fd_count:(fd_count ()) ~threshold
;;

let check_host_resources ~surface ~keeper_name =
  check_host_resources_for_threshold ~surface ~keeper_name
    ~threshold:Otel_metric_process.fd_warn_threshold
    ~fd_count:Otel_metric_process.approximate_open_fd_count
;;

let with_permit ?wait_timeout_sec:_ ~priority:_ ~keeper_name ~runtime_id f =
  Otel_spans.with_span
    ~name:"admission_queue"
    ~attrs:[
      "keeper.name", `String keeper_name;
      "masc.runtime_id", `String runtime_id;
    ]
    (fun _trace_id ->
      match
        check_host_resources ~surface:Admission_queue_metrics.With_permit ~keeper_name
      with
      | Error _ as e -> e
      | Ok () ->
        (* Passthrough: provider-level throttling belongs in OAS (runtime),
             not in MASC.  The runtime distributes requests across providers
             and handles 429/timeout by falling to the next provider.
             Gating here starves cloud-routed keepers behind a serial local
             decode and cannot express per-provider capacity.
             Metric and snapshot observation track real inflight even though
             gating is off.
             RFC-0026 PR-E-1.6/1.7; audit response 2026-05-05 §3.1. *)
        Ok (with_inflight_observation ~keeper_name ~runtime_id f))
;;

let try_with_permit_result_with_check ~keeper_name ~runtime_id ~check_host_resources f =
  match check_host_resources () with
  | Error _ as e -> e
  | Ok () -> Ok (with_inflight_observation ~keeper_name ~runtime_id f)
;;

let try_with_permit_result ~priority:_ ~keeper_name ~runtime_id f =
  try_with_permit_result_with_check ~keeper_name ~runtime_id
    ~check_host_resources:(fun () ->
      check_host_resources ~surface:Admission_queue_metrics.Try_with_permit ~keeper_name)
    f
;;

let try_with_permit ~priority ~keeper_name ~runtime_id f =
  match try_with_permit_result ~priority ~keeper_name ~runtime_id f with
  | Ok value -> Some value
  | Error (`Host_resource_saturated _) -> None
;;

let snapshot () =
  Eio.Mutex.use_ro global.mutex (fun () ->
    let { active; max_slots } = global.counters in
    { max_concurrent = max_slots
    ; active
    ; available = max 0 (max_slots - active)
    ; queue_depth = List.length global.waiters
    ; waiters = List.map (fun (w : waiter) -> w.info) global.waiters
    })
;;

let snapshot_json () =
  let s = snapshot () in
  let now = now_ts () in
  `Assoc
    [ "throttle_owner", `String "oas_runtime"
    ; "local_tool_resource_gates", Tool_resource_gate.snapshot_json ()
    ; "max_concurrent", `Int s.max_concurrent
    ; "active", `Int s.active
    ; "available", `Int s.available
    ; "queue_depth", `Int s.queue_depth
    ; ( "waiters"
      , `List
          (List.map
             (fun (w : waiter_info) ->
                `Assoc
                  [ "keeper_name", `String w.keeper_name
                  ; ( "runtime_id"
                    , `String
                        (w.runtime_id) )
                  ; ( "priority"
                    , `String (Llm_provider.Request_priority.to_string w.priority) )
                  ; "wait_seconds", `Float (now -. w.enqueue_ts)
                  ])
             s.waiters) )
    ]
;;

let set_max_concurrent n =
  if n < 1
  then
    invalid_arg
      (Printf.sprintf "Admission_queue.set_max_concurrent: must be >= 1, got %d" n);
  Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
    global.counters <- { global.counters with max_slots = n });
  Admission_queue_metrics.set_max_concurrent n
;;

let max_concurrent () = global.counters.max_slots

(* For test access — reset queue state between tests. *)
let reset_for_test ~max_slots =
  Eio.Mutex.use_rw ~protect:true global.mutex (fun () ->
    global.counters <- { max_slots; active = 0 };
    global.waiters <- []);
  Admission_queue_metrics.set_max_concurrent max_slots
;;

module For_testing = struct
  let check_host_resources ~surface ~keeper_name ~fd_count ~threshold =
    check_host_resources_with ~surface ~keeper_name ~fd_count ~threshold
  ;;

  let check_host_resources_for_threshold = check_host_resources_for_threshold

  let try_with_permit_result_for_threshold ~keeper_name ~runtime_id ~threshold
      ~fd_count f =
    try_with_permit_result_with_check ~keeper_name ~runtime_id
      ~check_host_resources:(fun () ->
        check_host_resources_for_threshold
          ~surface:Admission_queue_metrics.Try_with_permit
          ~keeper_name
          ~threshold
          ~fd_count)
      f
  ;;

  let apply_active_delta ~active ~delta =
    match apply_active_delta { active; max_slots = 0 } ~delta with
    | Ok counters -> Ok counters.active
    | Error _ as e -> e
  ;;

  let bump_active = bump_active

  let get_active () = Eio.Mutex.use_ro global.mutex (fun () -> global.counters.active)
end
