(* See .mli. *)

module Candidate = Keeper_board_attention_candidate

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
   concatenation is a lossless, order-preserving key. Mirrors the pre-existing
   [active_key] convention in the candidate module. *)
let dirty_key ~base_path ~keeper_name = String.concat "\031" [ base_path; keeper_name ]

let key_parts key =
  match String.split_on_char '\031' key with
  | [ base_path; keeper_name ] -> base_path, keeper_name
  | _ ->
    (* Keys are only ever produced by [dirty_key] above. *)
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

let notify ~base_path ~keeper_name =
  let key = dirty_key ~base_path ~keeper_name in
  atomic_add dirty_keepers key;
  atomic_add known_keepers key;
  Eio.Condition.broadcast condition
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

(* ── Dispatcher: bounded, boot-scanning, expiry-first eligibility scan ── *)

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

(* One (base_path, keeper_name) pass: expire stale backlog first (no worker
   slot spent), enqueue everything else eligible (oldest-recorded-first), and
   report the earliest still-pending [Deferred.not_before] so the dispatcher's
   idle wait does not overshoot it. *)
let scan_and_dispatch ~now ~policy ~stream ~base_path ~keeper_name =
  match Candidate.load_candidates ~base_path ~keeper_name with
  | Error detail ->
    Log.Keeper.warn
      "Board attention dispatcher could not load keeper=%s: %s"
      keeper_name
      detail;
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
    eligible
    |> List.sort (fun (a : Candidate.candidate) (b : Candidate.candidate) ->
      Float.compare a.recorded_at b.recorded_at)
    |> List.iter (Eio.Stream.add stream);
    List.fold_left
      (fun acc (candidate : Candidate.candidate) ->
         match candidate.status with
         | Candidate.Deferred { retry; _ } -> Float.min acc retry.not_before
         | Candidate.Pending _ | Candidate.Judged _ | Candidate.Consumed _
         | Candidate.Terminal_failed _ -> acc)
      infinity
      candidates
    |> Option.some
;;

let idle_poll_sec = 5.0

(* [fork_daemon]-shaped: loops forever until the owning switch cancels it
   (e.g. a test's bounded [Switch.run] scope closing, or process shutdown).
   A plain [Fiber.fork] loop never returns on its own, so [Switch.run] would
   wait for it forever even after its caller's work is done — [fork_daemon]
   instead ties its lifetime to "all non-daemon fibers are done". *)
(* One keeper's ledger becoming unreadable (workspace removed, permission
   error, transient FS fault) must never stop the dispatcher from scanning
   every *other* keeper — [Eio.Cancel.Cancelled] still propagates so a
   genuine switch cancellation is not swallowed here. *)
let scan_keeper_safely ~now ~policy ~stream ~base_path ~keeper_name =
  try scan_and_dispatch ~now ~policy ~stream ~base_path ~keeper_name with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.warn
      "Board attention dispatcher could not scan keeper=%s: %s"
      keeper_name
      (Printexc.to_string exn);
    None
;;

let run_dispatcher ~clock ~policy ~stream () : [ `Stop_daemon ] =
  let rec drain () =
    let fresh = swap_dirty () in
    Dirty_set.iter (atomic_add known_keepers) fresh;
    let now = Time_compat.now () in
    let policy = policy () in
    let next_due =
      Dirty_set.fold
        (fun key acc ->
           let base_path, keeper_name = key_parts key in
           match scan_keeper_safely ~now ~policy ~stream ~base_path ~keeper_name with
           | Some due -> Float.min acc due
           | None -> acc)
        (Atomic.get known_keepers)
        infinity
    in
    let sleep_for =
      if Float.is_finite next_due then Float.max 0.0 (next_due -. now) else idle_poll_sec
    in
    Eio.Fiber.first
      (fun () -> Eio.Mutex.use_ro wait_mutex (fun () -> Eio.Condition.await condition wait_mutex))
      (fun () -> Eio.Time.sleep clock (Float.min sleep_for idle_poll_sec));
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
       let result =
         Candidate.process_with_judge
           ~base_path
           ~now:Time_compat.now
           ~policy
           ~judge
           fresh
       in
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

let run_worker ~base_path ~policy ~judge ~stream () : [ `Stop_daemon ] =
  let rec loop () =
    let enqueued = Eio.Stream.take stream in
    let key =
      active_key ~base_path ~keeper_name:enqueued.Candidate.keeper_name
        ~candidate_id:enqueued.Candidate.candidate_id
    in
    if claim_active key
    then
      Fun.protect
        ~finally:(fun () -> release_active key)
        (fun () ->
           inc_in_flight ();
           Fun.protect ~finally:dec_in_flight (fun () ->
             process_one_safely ~base_path ~policy:(policy ()) ~judge enqueued));
    loop ()
  in
  try loop () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.error "Board attention judge worker crashed: %s" (Printexc.to_string exn);
    `Stop_daemon
;;

let start_dispatcher ~sw ~clock ~base_path ~max_concurrency ~judge () =
  boot_scan_keepers ~base_path;
  let stream : Candidate.candidate Eio.Stream.t = Eio.Stream.create (max 1 max_concurrency) in
  for _ = 1 to max 1 max_concurrency do
    Eio.Fiber.fork_daemon ~sw (run_worker ~base_path ~policy ~judge ~stream)
  done;
  Eio.Fiber.fork_daemon ~sw (run_dispatcher ~clock ~policy ~stream)
;;

let start ~sw ~clock ~base_path () =
  start_dispatcher
    ~sw
    ~clock
    ~base_path
    ~max_concurrency:(effective_max_concurrency ())
    ~judge:(Candidate.run_judge ~base_path)
    ()
;;

module For_testing = struct
  let effective_max_concurrency = clamp_to_runtime_limit
  let in_flight_count = in_flight_count

  let start_with_judge ~sw ~clock ~base_path ~max_concurrency ~judge () =
    start_dispatcher ~sw ~clock ~base_path ~max_concurrency ~judge ()
  ;;
end
