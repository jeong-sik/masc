(** Restart-durable per-keeper memory execution lane. *)

type worker_token = unit ref
type wake_token = unit ref

type retryability =
  | Retryable
  | Terminal

type execution_error =
  { retryability : retryability
  ; kind : string
  ; message : string
  ; detail : Yojson.Safe.t
  }

type execute =
  base_path:string ->
  Keeper_memory_job_store.job ->
  (Yojson.Safe.t, execution_error) result

type worker_deferred_reason =
  | Executor_not_initialized
  | Executor_base_path_mismatch
  | Executor_switch_released
  | Hook_registration_failed
  | Fork_failed

type worker_state =
  | Started
  | Already_running
  | Not_needed
  | Deferred of worker_deferred_reason

type admission =
  | Admitted of
      { job_id : string
      ; activation : Keeper_memory_job_store.activation
      ; worker : worker_state
      }
  | Rejected of Keeper_memory_job_store.error

type staging =
  | Staged of
      { job_id : string
      ; durable : Keeper_memory_job_store.admission
      }
  | Stage_rejected of Keeper_memory_job_store.error

type init_report =
  { discovered_keepers : int
  ; workers_started : int
  ; workers_deferred : int
  ; discovery_error : Keeper_memory_job_store.error option
  ; keeper_discovery_errors : Keeper_memory_job_store.error list
  }

type entry =
  { state_mu : Stdlib.Mutex.t
  ; store_mu : Eio.Mutex.t
  ; mutable wake : wake_token
  ; mutable active_worker : worker_token option
  ; mutable reconciliation_active : bool
  }

type executor =
  { sw : Eio.Switch.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; base_path : string
  ; execute : execute
  }

let entries : (string, entry) Hashtbl.t = Hashtbl.create 16
let registry_mu = Stdlib.Mutex.create ()
let installed_executor : executor option ref = ref None

let worker_deferred_reason_to_string = function
  | Executor_not_initialized -> "executor_not_initialized"
  | Executor_base_path_mismatch -> "executor_base_path_mismatch"
  | Executor_switch_released -> "executor_switch_released"
  | Hook_registration_failed -> "hook_registration_failed"
  | Fork_failed -> "fork_failed"
;;

let metric_name metric = Keeper_metrics.(to_string metric)

let record_counter ~keeper_name metric =
  Otel_metric_store.inc_counter
    (metric_name metric)
    ~labels:[ "keeper", keeper_name ]
    ()
;;

let record_counter_delta ~keeper_name metric count =
  if count > 0
  then
    Otel_metric_store.inc_counter
      (metric_name metric)
      ~labels:[ "keeper", keeper_name ]
      ~delta:(float_of_int count)
      ()
;;

let set_pending ~keeper_name count =
  Otel_metric_store.set_gauge
    (metric_name MemoryLanePending)
    ~labels:[ "keeper", keeper_name ]
    (float_of_int count)
;;

let inc_in_flight ~keeper_name =
  Otel_metric_store.inc_gauge
    (metric_name MemoryLaneInFlight)
    ~labels:[ "keeper", keeper_name ]
    ()
;;

let dec_in_flight ~keeper_name =
  Otel_metric_store.dec_gauge
    (metric_name MemoryLaneInFlight)
    ~labels:[ "keeper", keeper_name ]
    ()
;;

let current_executor () =
  Stdlib.Mutex.protect registry_mu (fun () -> !installed_executor)
;;

let entry_for ~base_path ~keeper_name =
  let key = Keeper_registry_types.registry_key ~base_path keeper_name in
  Stdlib.Mutex.protect registry_mu (fun () ->
    match Hashtbl.find_opt entries key with
    | Some entry -> entry
    | None ->
      let entry =
        { state_mu = Stdlib.Mutex.create ()
        ; store_mu = Eio.Mutex.create ()
        ; wake = ref ()
        ; active_worker = None
        ; reconciliation_active = false
        }
      in
      Hashtbl.add entries key entry;
      entry)
;;

let with_store : type a. entry -> (unit -> a) -> a =
 fun entry f ->
  let guarded () =
    match f () with
    | value -> Ok value
    | exception exn -> Error (exn, Printexc.get_raw_backtrace ())
  in
  (* Filesystem operations may suspend the current fiber. [Eio.Mutex] is
     domain-safe and lets sibling fibers run while waiting; [use_ro] is the
     non-poisoning form because every store transition is crash-consistent and
     may be retried after an exception. It also permits the uncontended,
     pre-Eio staging path used before [init]. *)
  let outcome = Eio.Mutex.use_ro entry.store_mu guarded in
  match outcome with
  | Ok value -> value
  | Error (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
;;

let refresh_pending ~base_path ~keeper_name entry =
  match
    with_store entry (fun () ->
      Keeper_memory_job_store.backlog_count ~base_path ~keeper_name)
  with
  | Ok count -> set_pending ~keeper_name count
  | Error error ->
    record_counter ~keeper_name MemoryLaneUnitFailures;
    Log.Keeper.warn ~keeper_name
      "memory lane backlog observation failed: %s"
      (Keeper_memory_job_store.error_to_string error)
;;

let signal_worker entry =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    entry.wake <- ref ();
    match entry.active_worker with
    | Some _ -> `Running
    | None ->
      let worker = ref () in
      entry.active_worker <- Some worker;
      `Start worker)
;;

let clear_worker entry worker =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    match entry.active_worker with
    | Some active when active == worker -> entry.active_worker <- None
    | Some _ | None -> ())
;;

let wake_snapshot entry =
  Stdlib.Mutex.protect entry.state_mu (fun () -> entry.wake)
;;

let release_if_quiet entry ~worker ~observed_wake =
  Stdlib.Mutex.protect entry.state_mu (fun () ->
    match entry.active_worker with
    | Some active when active == worker && entry.wake == observed_wake ->
      entry.active_worker <- None;
      true
    | Some _ | None -> false)
;;

type worker_exit =
  | Released_quietly
  | Retry_required
;;

let next_retry_attempt attempt =
  if attempt = Int.max_int then Int.max_int else attempt + 1
;;

let execution_error_to_json error =
  `Assoc
    [ ( "retryability"
      , `String
          (match error.retryability with
           | Retryable -> "retryable"
           | Terminal -> "terminal") )
    ; "kind", `String error.kind
    ; "message", `String error.message
    ; "detail", error.detail
    ]
;;

let unexpected_execution_error exn =
  { retryability = Terminal
  ; kind = "uncaught_exception"
  ; message = Printexc.to_string exn
  ; detail = `Null
  }
;;

let log_cleanup_errors ~keeper_name ~job_id errors =
  List.iter
    (fun error ->
       record_counter ~keeper_name MemoryLaneUnitFailures;
       Log.Keeper.error ~keeper_name
         "memory lane cleanup debt job_id=%s: %s"
         job_id
         (Keeper_memory_job_store.error_to_string error))
    errors
;;

type worker_failure =
  | Store_failure of Keeper_memory_job_store.error
  | Retryable_execution of execution_error

let run_lease executor entry (lease : Keeper_memory_job_store.lease) =
  let keeper_name = lease.job.keeper_name in
  inc_in_flight ~keeper_name;
  let result =
    Fun.protect
      (* Do not perform filesystem/Eio work in cancellation cleanup. The
         inflight file intentionally remains and its pending gauge value does
         not change. *)
      ~finally:(fun () -> dec_in_flight ~keeper_name)
      (fun () ->
      let execution =
        try
          Eio_context.with_turn_switch executor.sw (fun () ->
            executor.execute ~base_path:executor.base_path lease.job)
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (unexpected_execution_error exn)
      in
      match execution with
      | Error ({ retryability = Retryable; _ } as error) ->
        record_counter ~keeper_name MemoryLaneUnitFailures;
        Log.Keeper.warn ~keeper_name
          "memory lane job will retry job_id=%s turn=%d kind=%s: %s"
          lease.job.id
          lease.job.turn
          error.kind
          error.message;
        Error (Retryable_execution error)
      | (Ok _ | Error { retryability = Terminal; _ }) as execution ->
        let outcome, detail =
          match execution with
          | Ok detail -> Keeper_memory_job_store.Succeeded, detail
          | Error error ->
            Keeper_memory_job_store.Failed, execution_error_to_json error
        in
        let receipt : Keeper_memory_job_store.terminal_receipt =
          { identity = Keeper_memory_job_store.receipt_identity_of_job lease.job
          ; started_at = lease.started_at
          ; ended_at = Time_compat.now ()
          ; outcome
          ; detail
          }
        in
        (match
           with_store entry (fun () ->
             Keeper_memory_job_store.finish
               ~base_path:executor.base_path
               receipt)
         with
         | Error error ->
           record_counter ~keeper_name MemoryLaneUnitFailures;
           Log.Keeper.error ~keeper_name
             "memory lane terminal receipt commit failed job_id=%s: %s"
             lease.job.id
             (Keeper_memory_job_store.error_to_string error);
           Error (Store_failure error)
         | Ok cleanup ->
           log_cleanup_errors
             ~keeper_name
             ~job_id:lease.job.id
             cleanup.cleanup_errors;
           (match execution with
            | Ok _ ->
              record_counter ~keeper_name MemoryLaneCompleted;
              Log.Keeper.info ~keeper_name
                "memory lane job completed job_id=%s turn=%d"
                lease.job.id
                lease.job.turn
            | Error error ->
              record_counter ~keeper_name MemoryLaneUnitFailures;
              record_counter ~keeper_name MemoryLaneFailed;
              Log.Keeper.warn ~keeper_name
                "memory lane job failed job_id=%s turn=%d kind=%s: %s"
                lease.job.id
                lease.job.turn
                error.kind
                error.message);
           Ok ()))
  in
  refresh_pending
    ~base_path:executor.base_path
    ~keeper_name
    entry;
  result
;;

let rec drain_keeper executor entry ~worker ~keeper_name =
  let observed_wake = wake_snapshot entry in
  match
    with_store entry (fun () ->
      Keeper_memory_job_store.claim_all
        ~base_path:executor.base_path
        ~keeper_name
        ~now:(Time_compat.now ()))
  with
  | Error error ->
    record_counter ~keeper_name MemoryLaneUnitFailures;
    Log.Keeper.error ~keeper_name
      "memory lane claim failed: %s"
      (Keeper_memory_job_store.error_to_string error);
    Retry_required
  | Ok { leases = []; cleanup_errors } ->
    log_cleanup_errors ~keeper_name ~job_id:"claim-sweep" cleanup_errors;
    if release_if_quiet entry ~worker ~observed_wake
    then (
      refresh_pending ~base_path:executor.base_path ~keeper_name entry;
      Released_quietly)
    else drain_keeper executor entry ~worker ~keeper_name
  | Ok { leases; cleanup_errors } ->
    log_cleanup_errors ~keeper_name ~job_id:"claim-sweep" cleanup_errors;
    let rec run_batch = function
      | [] -> drain_keeper executor entry ~worker ~keeper_name
      | lease :: rest ->
        (match run_lease executor entry lease with
         | Ok () -> run_batch rest
         | Error _ -> Retry_required)
    in
    run_batch leases
;;

let run_worker executor entry ~worker ~keeper_name =
  let observed_wake = wake_snapshot entry in
  match
    with_store entry (fun () ->
      Keeper_memory_job_store.recover_inflight
        ~base_path:executor.base_path
        ~keeper_name)
  with
  | Error error ->
    record_counter ~keeper_name MemoryLaneUnitFailures;
    Log.Keeper.error ~keeper_name
      "memory lane recovery failed: %s"
      (Keeper_memory_job_store.error_to_string error);
    Retry_required
  | Ok recovery ->
    log_cleanup_errors
      ~keeper_name
      ~job_id:"recovery-sweep"
      recovery.cleanup_errors;
    if recovery.replayed > 0
    then (
      record_counter_delta ~keeper_name MemoryLaneReplayed recovery.replayed;
      Log.Keeper.warn ~keeper_name
        "memory lane replaying durable inflight jobs count=%d"
        recovery.replayed);
    refresh_pending ~base_path:executor.base_path ~keeper_name entry;
    drain_keeper executor entry ~worker ~keeper_name
;;

let rec run_worker_until_quiet executor entry ~worker ~keeper_name ~retry_attempt =
  match run_worker executor entry ~worker ~keeper_name with
  | Released_quietly -> ()
  | Retry_required ->
    let retry_attempt = next_retry_attempt retry_attempt in
    let delay =
      Env_config_keeper.KeeperRetryBackoff.transient_backoff_sec retry_attempt
    in
    Log.Keeper.warn ~keeper_name
      "memory lane retry scheduled attempt=%d delay_sec=%.3f"
      retry_attempt
      delay;
    Eio.Time.sleep executor.clock delay;
    run_worker_until_quiet
      executor
      entry
      ~worker
      ~keeper_name
      ~retry_attempt
;;

let start_worker executor entry ~worker ~keeper_name =
  let release_worker () = clear_worker entry worker in
  match Eio.Switch.get_error executor.sw with
  | Some _ ->
    clear_worker entry worker;
    Deferred Executor_switch_released
  | None ->
    let hook =
      try
        Some
          (Eio.Switch.on_release_cancellable
             executor.sw
             release_worker)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        clear_worker entry worker;
        record_counter ~keeper_name MemoryLaneUnitFailures;
        Log.Keeper.error ~keeper_name
          "memory lane switch hook registration failed: %s"
          (Printexc.to_string exn);
        None
    in
    (match hook with
     | None -> Deferred Hook_registration_failed
     | Some hook ->
       (try
          Eio.Fiber.fork_daemon ~sw:executor.sw (fun () ->
            Fun.protect
              ~finally:(fun () ->
                ignore (Eio.Switch.try_remove_hook hook);
                clear_worker entry worker)
              (fun () ->
                Eio.Fiber.yield ();
                run_worker_until_quiet
                  executor
                  entry
                  ~worker
                  ~keeper_name
                  ~retry_attempt:0);
            `Stop_daemon);
          Started
        with
        | Eio.Cancel.Cancelled _ as exn ->
          ignore (Eio.Switch.try_remove_hook hook);
          clear_worker entry worker;
          raise exn
        | exn ->
          ignore (Eio.Switch.try_remove_hook hook);
          clear_worker entry worker;
          record_counter ~keeper_name MemoryLaneUnitFailures;
          Log.Keeper.error ~keeper_name
            "memory lane worker fork failed: %s"
            (Printexc.to_string exn);
          Deferred Fork_failed))
;;

let wake_or_start executor ~keeper_name =
  let entry =
    entry_for ~base_path:executor.base_path ~keeper_name
  in
  match signal_worker entry with
  | `Running -> Already_running
  | `Start worker -> start_worker executor entry ~worker ~keeper_name
;;

let stage ~base_path (job : Keeper_memory_job_store.job) =
  let entry = entry_for ~base_path ~keeper_name:job.keeper_name in
  match
    with_store entry (fun () ->
      Keeper_memory_job_store.stage_awaiting_turn_commit ~base_path job)
  with
  | Error error ->
    record_counter ~keeper_name:job.keeper_name MemoryLaneAdmissionRejected;
    Log.Keeper.error ~keeper_name:job.keeper_name
      "memory lane admission rejected job_id=%s: %s"
      job.id
      (Keeper_memory_job_store.error_to_string error);
    Stage_rejected error
  | Ok durable ->
    record_counter ~keeper_name:job.keeper_name MemoryLaneSubmitted;
    refresh_pending ~base_path ~keeper_name:job.keeper_name entry;
    Staged { job_id = job.id; durable }
;;

let abort ~base_path (job : Keeper_memory_job_store.job) =
  let entry = entry_for ~base_path ~keeper_name:job.keeper_name in
  match
    with_store entry (fun () ->
      Keeper_memory_job_store.abort_awaiting ~base_path job)
  with
  | Ok () ->
    refresh_pending ~base_path ~keeper_name:job.keeper_name entry;
    Ok ()
  | Error error ->
    record_counter ~keeper_name:job.keeper_name MemoryLaneUnitFailures;
    Log.Keeper.error ~keeper_name:job.keeper_name
      "memory lane awaiting-turn abort failed job_id=%s: %s"
      job.id
      (Keeper_memory_job_store.error_to_string error);
    Error error
;;

let install_executor ~sw ~clock ~base_path ~execute =
  Stdlib.Mutex.protect registry_mu (fun () ->
    match !installed_executor with
    | None ->
      let executor = { sw; clock; base_path; execute } in
      installed_executor := Some executor;
      executor
    | Some current
      when current.sw == sw
           && current.clock == clock
           && String.equal current.base_path base_path
           && current.execute == execute ->
      current
    | Some _ ->
      invalid_arg
        "Keeper_memory_lane.init: executor already initialized with different ownership")
;;

let compare_awaiting_jobs
      (left : Keeper_memory_job_store.job)
      (right : Keeper_memory_job_store.job)
  =
  let by_turn = Int.compare left.turn right.turn in
  if by_turn <> 0
  then by_turn
  else
    let by_generation = Int.compare left.generation right.generation in
    if by_generation <> 0
    then by_generation
    else Int.compare left.oas_turn_count right.oas_turn_count
;;

let reconcile_awaiting_jobs executor ~keeper_name =
  let entry =
    entry_for ~base_path:executor.base_path ~keeper_name
  in
  match
    with_store entry (fun () ->
      Keeper_memory_job_store.list_awaiting
        ~base_path:executor.base_path
        ~keeper_name)
  with
  | Error error -> [ error ]
  | Ok [] -> []
  | Ok jobs ->
    let jobs = List.sort compare_awaiting_jobs jobs in
    let candidate_ids = List.map (fun job -> job.Keeper_memory_job_store.id) jobs in
    let config = Workspace.default_config executor.base_path in
    (match
       Keeper_execution_receipt.committed_post_turn_memory_job_ids
         config
         ~keeper_name
         ~candidate_ids
     with
     | Error detail ->
       [ Keeper_memory_job_store.Turn_receipt_error
           { keeper_name; detail }
       ]
     | Ok committed_ids ->
       with_store entry (fun () ->
         let rec reconcile errors = function
           | [] -> List.rev errors
           | job :: rest ->
             if List.mem job.Keeper_memory_job_store.id committed_ids
             then
               (match
                  Keeper_memory_job_store.activate
                    ~base_path:executor.base_path
                    job
                with
                | Error error -> reconcile (error :: errors) rest
                | Ok (_, cleanup) ->
                  log_cleanup_errors
                    ~keeper_name
                    ~job_id:job.id
                    cleanup.cleanup_errors;
                  reconcile errors rest)
             else
               (match
                  Keeper_memory_job_store.abort_awaiting
                    ~base_path:executor.base_path
                    job
                with
                | Error error -> reconcile (error :: errors) rest
                | Ok () ->
                  Log.Keeper.warn ~keeper_name
                    "memory lane discarded uncommitted awaiting job job_id=%s turn=%d"
                    job.id
                    job.turn;
                  reconcile errors rest)
         in
         reconcile [] jobs))
;;

let start_reconciliation_retry executor ~keeper_name =
  let entry = entry_for ~base_path:executor.base_path ~keeper_name in
  let should_start =
    Stdlib.Mutex.protect entry.state_mu (fun () ->
      if entry.reconciliation_active
      then false
      else (
        entry.reconciliation_active <- true;
        true))
  in
  if should_start
  then
    try
      Eio.Fiber.fork_daemon ~sw:executor.sw (fun () ->
        Fun.protect
          ~finally:(fun () ->
            Stdlib.Mutex.protect entry.state_mu (fun () ->
              entry.reconciliation_active <- false))
          (fun () ->
             let rec retry attempt =
               let delay =
                 Env_config_keeper.KeeperRetryBackoff.transient_backoff_sec
                   attempt
               in
               Eio.Time.sleep executor.clock delay;
               match reconcile_awaiting_jobs executor ~keeper_name with
               | [] ->
                 ignore (wake_or_start executor ~keeper_name : worker_state)
               | errors ->
                 List.iter
                   (fun error ->
                      record_counter ~keeper_name MemoryLaneUnitFailures;
                      Log.Keeper.error ~keeper_name
                        "memory lane awaiting-turn reconciliation retry failed attempt=%d: %s"
                        attempt
                        (Keeper_memory_job_store.error_to_string error))
                   errors;
                 retry (next_retry_attempt attempt)
             in
             retry 1);
        `Stop_daemon)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Stdlib.Mutex.protect entry.state_mu (fun () ->
        entry.reconciliation_active <- false);
      record_counter ~keeper_name MemoryLaneUnitFailures;
      Log.Keeper.error ~keeper_name
        "memory lane awaiting-turn reconciliation retry fork failed: %s"
        (Printexc.to_string exn)
;;

let request_reconciliation ~base_path ~keeper_name =
  match current_executor () with
  | None ->
    Log.Keeper.warn ~keeper_name
      "memory lane awaiting-turn reconciliation deferred reason=%s"
      (worker_deferred_reason_to_string Executor_not_initialized)
  | Some executor when not (String.equal executor.base_path base_path) ->
    Log.Keeper.error ~keeper_name
      "memory lane awaiting-turn reconciliation deferred reason=%s expected_base_path=%s actual_base_path=%s"
      (worker_deferred_reason_to_string Executor_base_path_mismatch)
      base_path
      executor.base_path
  | Some executor -> start_reconciliation_retry executor ~keeper_name
;;

let activate ~base_path (job : Keeper_memory_job_store.job) =
  let entry = entry_for ~base_path ~keeper_name:job.keeper_name in
  match
    with_store entry (fun () ->
      Keeper_memory_job_store.activate ~base_path job)
  with
  | Error error ->
    record_counter ~keeper_name:job.keeper_name MemoryLaneAdmissionRejected;
    Log.Keeper.error ~keeper_name:job.keeper_name
      "memory lane activation rejected job_id=%s: %s"
      job.id
      (Keeper_memory_job_store.error_to_string error);
    (* The execution receipt is already durable at this boundary. Keep the
       awaiting envelope and reconcile it without requiring another turn,
       signal, or process restart. *)
    request_reconciliation ~base_path ~keeper_name:job.keeper_name;
    Rejected error
  | Ok (activation, cleanup) ->
    log_cleanup_errors
      ~keeper_name:job.keeper_name
      ~job_id:job.id
      cleanup.cleanup_errors;
    refresh_pending ~base_path ~keeper_name:job.keeper_name entry;
    let worker =
      match activation with
      | Keeper_memory_job_store.Activation_already_completed -> Not_needed
      | Keeper_memory_job_store.Activated
      | Keeper_memory_job_store.Activation_already_pending
      | Keeper_memory_job_store.Activation_already_inflight ->
        (match current_executor () with
         | None -> Deferred Executor_not_initialized
         | Some executor when not (String.equal executor.base_path base_path) ->
           Deferred Executor_base_path_mismatch
         | Some executor -> wake_or_start executor ~keeper_name:job.keeper_name)
    in
    (match worker with
     | Deferred reason ->
       Log.Keeper.warn ~keeper_name:job.keeper_name
         "memory lane job persisted without active worker job_id=%s reason=%s"
         job.id
         (worker_deferred_reason_to_string reason)
     | Started | Already_running | Not_needed -> ());
    Admitted { job_id = job.id; activation; worker }
;;

let init ~sw ~clock ~base_path ~execute =
  let executor = install_executor ~sw ~clock ~base_path ~execute in
  match Keeper_memory_job_store.discover_keeper_names ~base_path with
  | Error error ->
    Log.Keeper.error
      "memory lane durable backlog discovery failed: %s"
      (Keeper_memory_job_store.error_to_string error);
    { discovered_keepers = 0
    ; workers_started = 0
    ; workers_deferred = 0
    ; discovery_error = Some error
    ; keeper_discovery_errors = []
    }
  | Ok (keeper_names, keeper_discovery_errors) ->
    let reconciliation_errors =
      List.concat_map
        (fun keeper_name ->
           let errors = reconcile_awaiting_jobs executor ~keeper_name in
           if errors <> []
           then start_reconciliation_retry executor ~keeper_name;
           errors)
        keeper_names
    in
    let keeper_discovery_errors =
      keeper_discovery_errors @ reconciliation_errors
    in
    List.iter
      (fun error ->
         Log.Keeper.error
           "memory lane skipped one malformed keeper backlog during discovery: %s"
           (Keeper_memory_job_store.error_to_string error))
      keeper_discovery_errors;
    let started, deferred =
      List.fold_left
        (fun (started, deferred) keeper_name ->
           match wake_or_start executor ~keeper_name with
           | Started | Already_running -> started + 1, deferred
           | Deferred _ -> started, deferred + 1
           | Not_needed -> started, deferred)
        (0, 0)
        keeper_names
    in
    { discovered_keepers = List.length keeper_names
    ; workers_started = started
    ; workers_deferred = deferred
    ; discovery_error = None
    ; keeper_discovery_errors
    }
;;

module For_testing = struct
  let reset () =
    Stdlib.Mutex.protect registry_mu (fun () ->
      Hashtbl.reset entries;
      installed_executor := None)
  ;;

  let backlog_count ~base_path ~keeper_name =
    Keeper_memory_job_store.backlog_count ~base_path ~keeper_name
  ;;
end
