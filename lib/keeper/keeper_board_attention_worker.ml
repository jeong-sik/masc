(* See .mli. *)

module Candidate = Keeper_board_attention_candidate

(* One item queued for a judge/delivery worker. Carries [base_path] alongside
   the candidate because the shared worker pool's dispatcher scans every
   known [(base_path, keeper_name)] pair, not just the one this process was
   booted with — a worker must never assume its own boot [base_path]. *)
type enqueued_work =
  { base_path : string
  ; candidate : Candidate.candidate
  }

(* ── Policy from config ────────────────────────────────────────── *)

let policy () : Candidate.retry_policy =
  { retry_base_sec = Keeper_config.board_attention_retry_base_sec ()
  ; retry_max_sec = Keeper_config.board_attention_retry_max_sec ()
  ; max_attempts = Keeper_config.board_attention_max_attempts ()
  ; max_pending_age_sec = Keeper_config.board_attention_max_pending_age_sec ()
  }
;;

let clamp_to_runtime_limit ~configured ~runtime_limit =
  match runtime_limit with
  | Some limit -> Int.min configured limit
  | None -> configured
;;

let effective_max_concurrency () =
  let configured = Keeper_config.board_attention_max_concurrency () in
  let runtime_limit =
    match Runtime.get_runtime_by_id (Runtime.runtime_id_for_structured_judge ()) with
    | Some runtime -> runtime.Runtime.binding.max_concurrent
    | None -> None
  in
  clamp_to_runtime_limit ~configured ~runtime_limit
;;

let per_keeper_max () = Keeper_config.board_attention_per_keeper_max_concurrency ()

(* ── Metrics ────────────────────────────────────────────────────── *)

let () =
  Otel_metric_store.register_counter
    ~name:Keeper_metrics.(to_string BoardAttentionWorkerOutcomes)
    ~help:
      "Total Board attention judge/delivery worker outcomes classified by \
       [outcome]. Labels: [outcome] (consumed_relevant | consumed_not_relevant | \
       deferred_retry | terminal_judge_rejected | terminal_budget_exhausted | \
       terminal_expired_backlog | load_error | crashed)."
    ()
;;

let record_outcome outcome =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string BoardAttentionWorkerOutcomes)
    ~labels:[ "outcome", outcome ]
    ()
;;

let in_flight_metric_name = Keeper_metrics.(to_string BoardAttentionWorkerInFlight)
let inc_in_flight () = Otel_metric_store.inc_gauge in_flight_metric_name ()
let dec_in_flight () = Otel_metric_store.dec_gauge in_flight_metric_name ()
let in_flight_count () = int_of_float (Otel_metric_store.metric_value_or_zero in_flight_metric_name ())

let outcome_label (result : (Candidate.candidate, string) result) =
  match result with
  | Error _ -> "storage_error"
  (* Unreachable in practice: [process_with_judge]'s Pending/Judged branches
     always resolve into Deferred/Consumed/Terminal_failed before returning.
     Listed only so this match stays exhaustive against [status]. *)
  | Ok { status = Candidate.Pending _; _ } -> "unexpected_pending"
  | Ok { status = Candidate.Judged _; _ } -> "unexpected_judged"
  | Ok { status = Candidate.Deferred _; _ } -> "deferred_retry"
  | Ok { status = Candidate.Consumed { delivery = Candidate.Enqueued_to_keeper_lane; _ }; _ } ->
    "consumed_relevant"
  | Ok { status = Candidate.Consumed { delivery = Candidate.Not_relevant; _ }; _ } ->
    "consumed_not_relevant"
  | Ok { status = Candidate.Terminal_failed { reason = Candidate.Judge_rejected _; _ }; _ } ->
    "terminal_judge_rejected"
  | Ok { status = Candidate.Terminal_failed { reason = Candidate.Retry_budget_exhausted _; _ }; _ } ->
    "terminal_budget_exhausted"
  | Ok { status = Candidate.Terminal_failed { reason = Candidate.Expired_backlog _; _ }; _ } ->
    "terminal_expired_backlog"
;;

(* ── Dirty-set notification (domain-safe: no Switch, no fork) ────── *)

module Dirty_set = Set.Make (String)

(* '\031' (unit separator) cannot appear in a base_path or keeper name, so the
   concatenation is a lossless, order-preserving key. *)
let lane_key ~base_path ~keeper_name = String.concat "\031" [ base_path; keeper_name ]

let key_parts key =
  match String.split_on_char '\031' key with
  | [ base_path; keeper_name ] -> base_path, keeper_name
  | _ ->
    (* Keys are only ever produced by [lane_key] above. *)
    failwith (Printf.sprintf "Board attention dirty key %S is malformed" key)
;;

let dirty_keepers = Atomic.make Dirty_set.empty

(* Union of every [(base_path, keeper_name)] this dispatcher has ever been
   asked about (via boot scan or [notify]), never cleared. Every idle-poll
   tick rescans this whole set (not just the freshly-dirty subset) so a
   [Deferred] retry timer or a missed broadcast is caught within one poll
   interval instead of being lost — the dirty set only controls *latency*
   (immediate wake via broadcast), never *correctness* (the ledger is SSOT
   and gets rechecked regardless). *)
let known_keepers = Atomic.make Dirty_set.empty

let rec atomic_add set_ref key =
  let current = Atomic.get set_ref in
  if Dirty_set.mem key current
  then ()
  else if Atomic.compare_and_set set_ref current (Dirty_set.add key current)
  then ()
  else atomic_add set_ref key
;;

let rec swap_dirty () =
  let current = Atomic.get dirty_keepers in
  if Atomic.compare_and_set dirty_keepers current Dirty_set.empty
  then current
  else swap_dirty ()
;;

let condition = Eio.Condition.create ()
let wait_mutex = Eio.Mutex.create ()

(* [notify]'s mutation must happen under [wait_mutex], matching the
   dispatcher's check-then-await critical section in [run_dispatcher]:
   see the comment there for why (lost-wakeup otherwise — broadcast is a
   documented no-op when nobody is registered as a waiter yet). *)
let notify ~base_path ~keeper_name =
  let key = lane_key ~base_path ~keeper_name in
  Eio.Mutex.use_ro wait_mutex (fun () ->
    atomic_add dirty_keepers key;
    atomic_add known_keepers key;
    Eio.Condition.broadcast condition)
;;

let record_and_notify ~base_path candidate =
  match Candidate.record ~base_path candidate with
  | Candidate.Record_error detail -> Error detail
  | Candidate.Recorded persisted | Candidate.Duplicate persisted ->
    notify ~base_path ~keeper_name:persisted.keeper_name;
    Ok persisted
;;

(* ── Per-candidate mutual exclusion (moved from the candidate module) ── *)

module Active_set = Set.Make (String)

let active_candidates = Atomic.make Active_set.empty

let active_key ~base_path ~keeper_name ~candidate_id =
  String.concat "\031" [ base_path; keeper_name; candidate_id ]
;;

let rec claim_active key =
  let current = Atomic.get active_candidates in
  if Active_set.mem key current
  then false
  else if Atomic.compare_and_set active_candidates current (Active_set.add key current)
  then true
  else claim_active key
;;

let rec release_active key =
  let current = Atomic.get active_candidates in
  if not (Active_set.mem key current)
  then ()
  else if Atomic.compare_and_set active_candidates current (Active_set.remove key current)
  then ()
  else release_active key
;;

(* ── Per-keeper in-flight reservation (lane fairness) ─────────────── *)

(* Reserved at dispatch time (before the item is even pushed to the shared
   stream), not at worker-take time: a queued-but-not-yet-started item still
   occupies its keeper's lane budget. Reserving only at worker-take time would
   let the dispatcher queue more than [per_keeper_max_concurrency] items for
   one keeper across two passes before any of them is claimed. *)
module Count_map = Map.Make (String)

let per_keeper_in_flight = Atomic.make Count_map.empty

let per_keeper_in_flight_count ~base_path ~keeper_name =
  Count_map.find_opt (lane_key ~base_path ~keeper_name) (Atomic.get per_keeper_in_flight)
  |> Option.value ~default:0
;;

let rec adjust_per_keeper_in_flight ~base_path ~keeper_name delta =
  let key = lane_key ~base_path ~keeper_name in
  let current = Atomic.get per_keeper_in_flight in
  let current_count = Count_map.find_opt key current |> Option.value ~default:0 in
  let updated_count = current_count + delta in
  let updated =
    if updated_count <= 0 then Count_map.remove key current else Count_map.add key updated_count current
  in
  if Atomic.compare_and_set per_keeper_in_flight current updated
  then ()
  else adjust_per_keeper_in_flight ~base_path ~keeper_name delta
;;

let reserve_per_keeper_slot ~base_path ~keeper_name = adjust_per_keeper_in_flight ~base_path ~keeper_name 1
let release_per_keeper_slot ~base_path ~keeper_name = adjust_per_keeper_in_flight ~base_path ~keeper_name (-1)

(* ── Dispatcher: bounded, boot-scanning, expiry-first, round-robin ── *)

let board_attention_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "board_attention_candidates"
;;

let boot_scan_keepers ~base_path =
  let dir = board_attention_dir ~base_path in
  match Sys.file_exists dir && Sys.is_directory dir with
  | false -> ()
  | true ->
    Sys.readdir dir
    |> Array.iter (fun name ->
      if Filename.check_suffix name ".jsonl"
      then (
        let keeper_name = Filename.chop_suffix name ".jsonl" in
        notify ~base_path ~keeper_name))
;;

type keeper_queue =
  { base_path : string
  ; keeper_name : string
  ; queue : Candidate.candidate list (* oldest-recorded-first, already filtered eligible *)
  ; next_due : float (* earliest not-yet-due Deferred.not_before in this keeper's ledger, or infinity *)
  }

(* Expire stale backlog first (no worker slot spent on it), then compute the
   eligible-and-due queue for one keeper. Exceptions here (e.g. a workspace
   removed from underneath a stale keeper reference) must not propagate: one
   keeper's ledger becoming unreadable must never stop the dispatcher from
   scanning every *other* keeper. [Eio.Cancel.Cancelled] still propagates so a
   genuine switch cancellation is not swallowed. *)
let load_keeper_queue_safely ~now ~policy ~base_path ~keeper_name : keeper_queue option =
  try
    match Candidate.load_candidates ~base_path ~keeper_name with
    | Error detail ->
      Log.Keeper.warn "Board attention dispatcher could not load keeper=%s: %s" keeper_name detail;
      None
    | Ok candidates ->
      let expired_count = ref 0 in
      let eligible =
        List.filter_map
          (fun candidate ->
             match Candidate.terminalize_expired ~base_path ~now ~policy candidate with
             | Error detail ->
               Log.Keeper.warn
                 "Board attention expiry check failed keeper=%s candidate=%s: %s"
                 keeper_name
                 candidate.Candidate.candidate_id
                 detail;
               None
             | Ok { Candidate.status = Candidate.Terminal_failed { reason = Candidate.Expired_backlog _; _ }; _ } ->
               incr expired_count;
               None
             | Ok unchanged ->
               if Candidate.is_eligible_for_dispatch ~now unchanged then Some unchanged else None)
          candidates
      in
      if !expired_count > 0
      then
        Log.Keeper.warn
          "Board attention dispatcher expired %d stale candidate(s) keeper=%s"
          !expired_count
          keeper_name;
      let queue =
        List.sort
          (fun (a : Candidate.candidate) (b : Candidate.candidate) -> Float.compare a.recorded_at b.recorded_at)
          eligible
      in
      let next_due =
        List.fold_left
          (fun acc (candidate : Candidate.candidate) ->
             match candidate.status with
             | Candidate.Deferred { retry; _ } -> Float.min acc retry.not_before
             | Candidate.Pending _ | Candidate.Judged _ | Candidate.Consumed _ | Candidate.Terminal_failed _ ->
               acc)
          infinity
          candidates
      in
      Some { base_path; keeper_name; queue; next_due }
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.warn "Board attention dispatcher could not scan keeper=%s: %s" keeper_name (Printexc.to_string exn);
    None
;;

(* Rotation cursor: the lane key most recently dispatched from, so a pass
   that stops partway (stream full, or ran out of eligible work) resumes
   fairly next time instead of always favoring the same starting keeper. *)
let rotation_cursor : string option Atomic.t = Atomic.make None

let rotate_from_cursor cursor (queues : keeper_queue list) =
  match cursor with
  | None -> queues
  | Some last_key ->
    let rec split acc = function
      | [] -> None
      | (q : keeper_queue) :: rest
        when String.equal (lane_key ~base_path:q.base_path ~keeper_name:q.keeper_name) last_key ->
        Some (List.rev acc, q, rest)
      | q :: rest -> split (q :: acc) rest
    in
    (match split [] queues with
     | None ->
       (* The keeper we last dispatched from has no entry this pass (e.g. its
          queue drained, or it's no longer known); nothing to rotate around. *)
       queues
     | Some (before, matched, after) ->
       (* Move the previously-served keeper to the back of the wheel rather
          than dropping it: everyone else gets first crack this pass, but
          [matched] still gets a turn if the pass has budget left over. With
          exactly one known keeper, dropping it (the old bug) left [ordered]
          permanently empty from the second pass onward — the single
          keeper's own queue was rotated straight out of existence and
          [round_robin_dispatch] never dispatched from it again. *)
       after @ before @ [ matched ])
;;

(* Round-robin: take one item from the front of each keeper's queue in turn
   (reserving that keeper's lane budget at the moment of dispatch, not at
   worker-take time), moving a keeper to the back of the wheel after each
   item it contributes and dropping it once its per-pass budget or its queue
   is exhausted. This bounds any single keeper to at most
   [per_keeper_max] items queued-or-in-flight at once, and guarantees every
   other eligible keeper gets a turn before a large-backlog keeper gets a
   second item in the same pass. Returns the last keeper dispatched from, for
   the next pass's rotation cursor. *)
let round_robin_dispatch ~stream ~per_keeper_max (queues : keeper_queue list) =
  let last_dispatched = ref None in
  let initial =
    List.filter_map
      (fun (q : keeper_queue) ->
         let budget = per_keeper_max - per_keeper_in_flight_count ~base_path:q.base_path ~keeper_name:q.keeper_name in
         if budget <= 0 || q.queue = [] then None else Some (q.base_path, q.keeper_name, q.queue, budget))
      queues
  in
  let rec loop = function
    | [] -> ()
    | (_, _, [], _) :: rest -> loop rest
    | (_, _, _, budget) :: rest when budget <= 0 -> loop rest
    | (base_path, keeper_name, candidate :: remaining_queue, budget) :: rest ->
      reserve_per_keeper_slot ~base_path ~keeper_name;
      last_dispatched := Some (lane_key ~base_path ~keeper_name);
      Eio.Stream.add stream { base_path; candidate };
      let next_budget = budget - 1 in
      if next_budget > 0 && remaining_queue <> []
      then loop (rest @ [ base_path, keeper_name, remaining_queue, next_budget ])
      else loop rest
  in
  loop initial;
  !last_dispatched
;;

let idle_poll_sec = 5.0

let run_dispatcher ~clock ~policy ~stream ~per_keeper_max () : [ `Stop_daemon ] =
  let rec drain () =
    let now = Time_compat.now () in
    let policy = policy () in
    let known = Dirty_set.elements (Atomic.get known_keepers) in
    let queues =
      List.filter_map
        (fun key ->
           let base_path, keeper_name = key_parts key in
           load_keeper_queue_safely ~now ~policy ~base_path ~keeper_name)
        known
    in
    let ordered = rotate_from_cursor (Atomic.get rotation_cursor) queues in
    (match round_robin_dispatch ~stream ~per_keeper_max:(per_keeper_max ()) ordered with
     | Some last -> Atomic.set rotation_cursor (Some last)
     | None -> ());
    let next_due = List.fold_left (fun acc (q : keeper_queue) -> Float.min acc q.next_due) infinity queues in
    let sleep_for = if Float.is_finite next_due then Float.max 0.0 (next_due -. now) else idle_poll_sec in
    (* The dirty-set check and the decision to await must run under the same
       [wait_mutex] critical section as [notify]'s mutation+broadcast.
       Otherwise there is a window — a worker calls [notify] after we last
       drained [dirty_keepers] but before we register as a waiter inside
       [Condition.await] — in which the broadcast lands on nobody and is
       silently dropped ([condition.mli]: "If no fibers are waiting, nothing
       happens"). We then sleep for the full [idle_poll_sec] even though
       there is already more eligible work sitting in a keeper's queue,
       waiting only for a freed per-keeper slot. This didn't surface before
       the per-keeper fairness pass split single-keeper backlogs across
       multiple dispatch passes (previously one pass + the bounded stream's
       own backpressure was enough to drain everything eligible in one go).
       Consuming [dirty_keepers] here, atomically with the await decision,
       closes the window: any signal recorded since our last check is
       observed before we decide to sleep at all. *)
    Eio.Mutex.use_ro wait_mutex (fun () ->
      let fresh = swap_dirty () in
      Dirty_set.iter (atomic_add known_keepers) fresh;
      if Dirty_set.is_empty fresh
      then
        Eio.Fiber.first
          (fun () -> Eio.Condition.await condition wait_mutex)
          (fun () -> Eio.Time.sleep clock (Float.min sleep_for idle_poll_sec)));
    drain ()
  in
  try drain () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.error "Board attention dispatcher crashed: %s" (Printexc.to_string exn);
    `Stop_daemon
;;

(* ── Judge/delivery worker fiber ──────────────────────────────────── *)

let process_one ~base_path ~policy ~judge (enqueued : Candidate.candidate) =
  (* The row may have changed (or been compacted away) since it was
     enqueued; re-load fresh rather than acting on a stale in-memory copy. *)
  match Candidate.load_candidates ~base_path ~keeper_name:enqueued.keeper_name with
  | Error detail ->
    record_outcome "load_error";
    Log.Keeper.warn
      "Board attention worker could not reload keeper=%s candidate=%s: %s"
      enqueued.keeper_name
      enqueued.candidate_id
      detail
  | Ok candidates ->
    (match
       List.find_opt
         (fun (c : Candidate.candidate) -> String.equal c.candidate_id enqueued.candidate_id)
         candidates
     with
     | None -> ()
     | Some fresh ->
       let result = Candidate.process_with_judge ~base_path ~now:Time_compat.now ~policy ~judge fresh in
       record_outcome (outcome_label result);
       (match result with
        | Ok _ -> ()
        | Error detail ->
          Log.Keeper.warn
            "Board attention worker transition failed keeper=%s candidate=%s: %s"
            enqueued.keeper_name
            enqueued.candidate_id
            detail))
;;

(* One candidate raising instead of returning a typed error (e.g. its
   workspace vanished underneath it) must not permanently kill this worker
   fiber and shrink the pool's effective concurrency; log and move on. *)
let process_one_safely ~base_path ~policy ~judge enqueued =
  try process_one ~base_path ~policy ~judge enqueued with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    record_outcome "crashed";
    Log.Keeper.warn
      "Board attention worker candidate crashed keeper=%s candidate=%s: %s"
      enqueued.Candidate.keeper_name
      enqueued.Candidate.candidate_id
      (Printexc.to_string exn)
;;

let run_worker ~policy ~judge ~stream () : [ `Stop_daemon ] =
  let rec loop () =
    let { base_path; candidate = enqueued } = Eio.Stream.take stream in
    let keeper_name = enqueued.Candidate.keeper_name in
    let key = active_key ~base_path ~keeper_name ~candidate_id:enqueued.Candidate.candidate_id in
    if claim_active key
    then
      Fun.protect
        ~finally:(fun () ->
          release_active key;
          release_per_keeper_slot ~base_path ~keeper_name;
          (* Freeing this lane's budget may let waiting work in the same
             keeper proceed; nudge the dispatcher rather than waiting for the
             next idle poll. *)
          notify ~base_path ~keeper_name)
        (fun () ->
           inc_in_flight ();
           Fun.protect ~finally:dec_in_flight (fun () ->
             process_one_safely ~base_path ~policy:(policy ()) ~judge enqueued))
    else release_per_keeper_slot ~base_path ~keeper_name;
    loop ()
  in
  try loop () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.error "Board attention judge worker crashed: %s" (Printexc.to_string exn);
    `Stop_daemon
;;

let start_dispatcher ~sw ~clock ~base_path ~max_concurrency ~per_keeper_max ~judge () =
  boot_scan_keepers ~base_path;
  let stream : enqueued_work Eio.Stream.t = Eio.Stream.create (max 1 max_concurrency) in
  for _ = 1 to max 1 max_concurrency do
    Eio.Fiber.fork_daemon ~sw (run_worker ~policy ~judge ~stream)
  done;
  Eio.Fiber.fork_daemon ~sw (run_dispatcher ~clock ~policy ~stream ~per_keeper_max)
;;

let start ~sw ~clock ~base_path () =
  start_dispatcher
    ~sw
    ~clock
    ~base_path
    ~max_concurrency:(effective_max_concurrency ())
    ~per_keeper_max
    ~judge:(Candidate.run_judge ~base_path)
    ()
;;

module For_testing = struct
  let effective_max_concurrency = clamp_to_runtime_limit
  let in_flight_count = in_flight_count
  let per_keeper_in_flight_count = per_keeper_in_flight_count
  let is_dirty ~base_path ~keeper_name = Dirty_set.mem (lane_key ~base_path ~keeper_name) (Atomic.get dirty_keepers)

  let start_with_judge ~sw ~clock ~base_path ~max_concurrency ~per_keeper_max_concurrency ~judge () =
    start_dispatcher
      ~sw
      ~clock
      ~base_path
      ~max_concurrency
      ~per_keeper_max:(fun () -> per_keeper_max_concurrency)
      ~judge
      ()
  ;;
end
