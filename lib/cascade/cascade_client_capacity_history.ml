(** See cascade_client_capacity_history.mli for documentation. *)

type event_kind = Acquired | Released | Rejected_full

type event = {
  ts : float;
  key : string;
  kind : event_kind;
  active_after : int;
}

(* ── Classifier (copy of Dashboard_cascade.classify_capacity_key) ─

   We copy-paste instead of extracting into a shared helper because:
   - Both copies are ~12 lines and unlikely to drift meaningfully
     (the classifier is anchored to two literal substrings).
   - The dashboard module would otherwise need to depend on this
     module (for classify_key in JSON projections) or vice versa,
     and neither direction feels natural.
   Any drift here will be caught by the [test_snapshot_kind_filter]
   coverage below + existing Dashboard_cascade tests. *)
let classify_key url =
  if String.length url > 4 && String.sub url 0 4 = "cli:" then "cli"
  else
    let len = String.length url in
    let needle = ":11434" in
    let nlen = String.length needle in
    let rec scan i =
      if i + nlen > len then false
      else if String.sub url i nlen = needle then true
      else scan (i + 1)
    in
    if scan 0 then "ollama" else "other"

(* ── Ring buffer configuration ─────────────────────────────── *)

let min_capacity = 16
let max_capacity = 65_536
let default_capacity = 1024

let resolve_capacity () =
  let from_env =
    match Sys.getenv_opt "MASC_CAPACITY_HISTORY_SIZE" with
    | None | Some "" -> default_capacity
    | Some s ->
      (match int_of_string_opt (String.trim s) with
       | Some n -> n
       | None -> default_capacity)
  in
  max min_capacity (min max_capacity from_env)

(* ── Ring buffer state ──────────────────────────────────────

   Invariants (established once, maintained by [record]):
   - [Array.length !buf = !cap]
   - [0 <= !head < !cap]
   - [0 <= !count <= !cap]
   - The [!count] most recent entries live at indices
     [ (head - count + cap) mod cap ], …, [ (head - 1 + cap) mod cap ]
     — that is, [head] points to the *next write slot*, so the most
     recent entry is at [(head - 1 + cap) mod cap].
   - Slots [0 .. cap-1] always hold [Some _] once written; we
     overwrite in place, never resize. *)

let cap_ref = ref 0
let buf : event option array ref = ref [||]
let head = ref 0
let count = ref 0
let mu = Mutex.create ()

(* Lazy init: resolve capacity + allocate buffer on first use.  We
   do this outside [record] so [clear] / [capacity] can be called
   from tests before any event is recorded.  Guarded by [mu]. *)
let ensure_initialised_locked () =
  if !cap_ref = 0 then begin
    let cap = resolve_capacity () in
    cap_ref := cap;
    buf := Array.make cap None;
    head := 0;
    count := 0
  end

let string_of_kind = function
  | Acquired -> "acquired"
  | Released -> "released"
  | Rejected_full -> "rejected_full"

(* Prometheus counter increment happens *outside* the ring mutex so a slow
   metrics hashtable mutex never blocks cascade acquire paths.  The counter
   name + labels match the dashboard projection (classify_key) so Grafana
   queries can join on the same {kind, key_type} tuple. *)
let bump_prometheus_counter (ev : event) =
  Prometheus.inc_counter "masc_cascade_capacity_events_total"
    ~labels:[
      "kind", string_of_kind ev.kind;
      "key_type", classify_key ev.key;
    ] ()

let record ev =
  Mutex.protect mu (fun () ->
      ensure_initialised_locked ();
      let cap = !cap_ref in
      (!buf).(!head) <- Some ev;
      head := (!head + 1) mod cap;
      if !count < cap then incr count);
  bump_prometheus_counter ev

let clear () =
  Mutex.protect mu (fun () ->
      ensure_initialised_locked ();
      let cap = !cap_ref in
      for i = 0 to cap - 1 do (!buf).(i) <- None done;
      head := 0;
      count := 0)

let size () = Mutex.protect mu (fun () -> !count)

let capacity () =
  Mutex.protect mu (fun () ->
      ensure_initialised_locked ();
      !cap_ref)

(* ── Snapshot ───────────────────────────────────────────────

   Hot path: copy the live events out under the mutex, then run the
   (pure) filter / limit pipeline with the lock released.  This keeps
   the critical section O(count) allocation-light (one intermediate
   list) and avoids holding the mutex across [List.filter] work. *)

let collect_newest_first_locked () =
  (* Walk from (head-1) backwards for [count] steps.  Invariant:
     [0 <= head < cap] and [0 <= i < count <= cap], therefore
     [head - 1 - i + cap] is in [0, 2*cap - 2], so a single
     [mod cap] normalises it.  We pattern-match on [Some _] so
     slots that somehow contain [None] (shouldn't happen once
     we've written [count] entries, but keeps [collect] safe
     during the first few acquires) are silently skipped. *)
  let cap = !cap_ref in
  let n = !count in
  let acc = ref [] in
  (* Walk oldest→newest (i goes from n-1 down to 0) and prepend,
     so the final list is newest-first without a [List.rev]. *)
  for i = n - 1 downto 0 do
    let idx = (!head - 1 - i + cap) mod cap in
    match (!buf).(idx) with
    | Some e -> acc := e :: !acc
    | None -> ()
  done;
  !acc

let snapshot ?(limit = 100) ?kind ?since_ts () =
  let events =
    Mutex.protect mu (fun () ->
        ensure_initialised_locked ();
        collect_newest_first_locked ())
  in
  let kind_match =
    match kind with
    | None -> fun _ -> true
    | Some k when k = "cli" || k = "ollama" || k = "other" ->
      fun e -> classify_key e.key = k
    | Some _ ->
      (* Unknown kind filter: return nothing rather than silently
         matching everything.  Spec-required behaviour per the .mli. *)
      fun _ -> false
  in
  let ts_match =
    match since_ts with
    | None -> fun _ -> true
    | Some t -> fun e -> e.ts >= t
  in
  let filtered =
    List.filter (fun e -> kind_match e && ts_match e) events
  in
  let n = max 0 limit in
  if n = 0 then []
  else
    (* [List.filteri] keeps the first [n] elements without building
       an intermediate list length. *)
    let rec take k = function
      | [] -> []
      | _ when k = 0 -> []
      | x :: rest -> x :: take (k - 1) rest
    in
    take n filtered
