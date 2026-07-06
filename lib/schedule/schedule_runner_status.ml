type tick_counts =
  { due_changed : int
  ; emitted : int
  ; rescheduled : int
  ; dispatch_succeeded : int
  ; dispatch_failed : int
  ; dispatch_unsupported : int
  ; dispatch_start_rejected : int
  ; wake_enqueued : int
  ; wake_skipped_no_keeper : int
  ; wake_skipped_missing_schedule : int
  ; wake_skipped_non_keeper_actor : int
  ; wake_skipped_unregistered_keeper : int
  ; wake_failed : int
  }

type wake_enqueue_counts =
  { wake_enqueued : int
  ; wake_skipped_no_keeper : int
  ; wake_skipped_missing_schedule : int
  ; wake_skipped_non_keeper_actor : int
  ; wake_skipped_unregistered_keeper : int
  ; wake_failed : int
  }

let empty_wake_enqueue_counts =
  { wake_enqueued = 0
  ; wake_skipped_no_keeper = 0
  ; wake_skipped_missing_schedule = 0
  ; wake_skipped_non_keeper_actor = 0
  ; wake_skipped_unregistered_keeper = 0
  ; wake_failed = 0
  }
;;

type snapshot =
  { tick_in_flight : bool
  ; tick_count : int
  ; success_count : int
  ; failure_count : int
  ; crash_count : int
  ; last_tick_started_at : float option
  ; last_tick_finished_at : float option
  ; last_success_at : float option
  ; last_error_at : float option
  ; last_error : string option
  ; last_duration_sec : float option
  ; last_counts : tick_counts option
  }

let empty =
  { tick_in_flight = false
  ; tick_count = 0
  ; success_count = 0
  ; failure_count = 0
  ; crash_count = 0
  ; last_tick_started_at = None
  ; last_tick_finished_at = None
  ; last_success_at = None
  ; last_error_at = None
  ; last_error = None
  ; last_duration_sec = None
  ; last_counts = None
  }
;;

let state = ref empty
let state_mu = Stdlib.Mutex.create ()

let with_lock f = Stdlib.Mutex.protect state_mu f

let reset_for_test () =
  with_lock (fun () -> state := empty)
;;

let record_tick_started ~now =
  with_lock (fun () ->
    state := { !state with tick_in_flight = true; last_tick_started_at = Some now })
;;

(* TEL-OK: this module is a pure process-local projection over
   [Schedule_runner.tick_result]. The server maintenance loop owns concrete Log
   and Otel_metric_store emission at the same tick record call sites, while
   [/health?full=1] reads this snapshot for the structured health surface. *)
let tick_counts_of_result
      ~(wake_enqueue_counts : wake_enqueue_counts)
      (result : Schedule_runner.tick_result)
  =
  let dispatch_succeeded, dispatch_failed, dispatch_unsupported, dispatch_start_rejected =
    List.fold_left
      (fun (succeeded, failed, unsupported, start_rejected)
        (dispatch : Schedule_runner.dispatch_result) ->
         match dispatch.status with
         | Dispatch_succeeded -> succeeded + 1, failed, unsupported, start_rejected
         | Dispatch_failed -> succeeded, failed + 1, unsupported, start_rejected
         | Dispatch_unsupported -> succeeded, failed, unsupported + 1, start_rejected
         | Dispatch_start_rejected -> succeeded, failed, unsupported, start_rejected + 1)
      (0, 0, 0, 0)
      result.dispatches
  in
  { due_changed = result.due_changed
  ; emitted = List.length result.emitted
  ; rescheduled = result.rescheduled
  ; dispatch_succeeded
  ; dispatch_failed
  ; dispatch_unsupported
  ; dispatch_start_rejected
  ; wake_enqueued = wake_enqueue_counts.wake_enqueued
  ; wake_skipped_no_keeper = wake_enqueue_counts.wake_skipped_no_keeper
  ; wake_skipped_missing_schedule =
      wake_enqueue_counts.wake_skipped_missing_schedule
  ; wake_skipped_non_keeper_actor =
      wake_enqueue_counts.wake_skipped_non_keeper_actor
  ; wake_skipped_unregistered_keeper =
      wake_enqueue_counts.wake_skipped_unregistered_keeper
  ; wake_failed = wake_enqueue_counts.wake_failed
  }
;;

let duration ~started_at ~finished_at = max 0.0 (finished_at -. started_at)

let record_tick_ok
      ?(wake_enqueue_counts = empty_wake_enqueue_counts)
      ~started_at
      ~finished_at
      result
  =
  let counts = tick_counts_of_result ~wake_enqueue_counts result in
  with_lock (fun () ->
    let current = !state in
    state :=
      { current with
        tick_in_flight = false
      ; tick_count = current.tick_count + 1
      ; success_count = current.success_count + 1
      ; last_tick_started_at = Some started_at
      ; last_tick_finished_at = Some finished_at
      ; last_success_at = Some finished_at
      ; last_duration_sec = Some (duration ~started_at ~finished_at)
      ; last_counts = Some counts
      })
;;

let record_failure ~crashed ~started_at ~finished_at error =
  with_lock (fun () ->
    let current = !state in
    state :=
      { current with
        tick_in_flight = false
      ; tick_count = current.tick_count + 1
      ; failure_count = current.failure_count + 1
      ; crash_count = current.crash_count + if crashed then 1 else 0
      ; last_tick_started_at = Some started_at
      ; last_tick_finished_at = Some finished_at
      ; last_error_at = Some finished_at
      ; last_error = Some error
      ; last_duration_sec = Some (duration ~started_at ~finished_at)
      })
;;

let record_tick_error ~started_at ~finished_at error =
  record_failure ~crashed:false ~started_at ~finished_at error
;;

let record_tick_crash ~started_at ~finished_at error =
  record_failure ~crashed:true ~started_at ~finished_at error
;;

let snapshot () = with_lock (fun () -> !state)

let option_float_json = function
  | None -> `Null
  | Some value -> `Float value
;;

let option_int_counts_json = function
  | None -> `Null
  | Some counts ->
    `Assoc
      [ "due_changed", `Int counts.due_changed
      ; "emitted", `Int counts.emitted
      ; "rescheduled", `Int counts.rescheduled
      ; "dispatch_succeeded", `Int counts.dispatch_succeeded
      ; "dispatch_failed", `Int counts.dispatch_failed
      ; "dispatch_unsupported", `Int counts.dispatch_unsupported
      ; "dispatch_start_rejected", `Int counts.dispatch_start_rejected
      ; "wake_enqueued", `Int counts.wake_enqueued
      ; "wake_skipped_no_keeper", `Int counts.wake_skipped_no_keeper
      ; "wake_skipped_missing_schedule", `Int counts.wake_skipped_missing_schedule
      ; "wake_skipped_non_keeper_actor", `Int counts.wake_skipped_non_keeper_actor
      ; "wake_skipped_unregistered_keeper", `Int counts.wake_skipped_unregistered_keeper
      ; "wake_failed", `Int counts.wake_failed
      ]
;;

let option_age ~now = function
  | None -> None
  | Some ts -> Some (max 0.0 (now -. ts))
;;

let latest_error_is_newer snapshot =
  match snapshot.last_error_at, snapshot.last_success_at with
  | Some _, None -> true
  | Some error_at, Some success_at -> error_at >= success_at
  | None, _ -> false
;;

let latest_tick_has_wake_failure snapshot =
  match snapshot.last_counts with
  | Some counts -> counts.wake_failed > 0
  | None -> false
;;

let latest_tick_has_dispatch_failure snapshot =
  match snapshot.last_counts with
  | Some counts ->
    counts.dispatch_failed > 0
    || counts.dispatch_unsupported > 0
    || counts.dispatch_start_rejected > 0
  | None -> false
;;

let status ?now ?stale_after_sec snapshot =
  let stale =
    match now, stale_after_sec, snapshot.last_tick_finished_at with
    | Some now, Some stale_after_sec, Some finished_at ->
      now -. finished_at > stale_after_sec
    | _ -> false
  in
  if snapshot.tick_in_flight
  then "running"
  else if snapshot.tick_count = 0
  then "not_started"
  else if stale
  then "stale"
  else if latest_error_is_newer snapshot
          || latest_tick_has_dispatch_failure snapshot
          || latest_tick_has_wake_failure snapshot
  then "degraded"
  else "ok"
;;

let snapshot_to_yojson ?now ?stale_after_sec snapshot =
  let age_field name timestamp =
    match now with
    | None -> name, `Null
    | Some now -> name, option_float_json (option_age ~now timestamp)
  in
  `Assoc
    [ "schema", `String "masc.schedule.runner_status.v1"
    ; "status", `String (status ?now ?stale_after_sec snapshot)
    ; "tick_in_flight", `Bool snapshot.tick_in_flight
    ; "tick_count", `Int snapshot.tick_count
    ; "success_count", `Int snapshot.success_count
    ; "failure_count", `Int snapshot.failure_count
    ; "crash_count", `Int snapshot.crash_count
    ; "last_tick_started_at", option_float_json snapshot.last_tick_started_at
    ; "last_tick_finished_at", option_float_json snapshot.last_tick_finished_at
    ; "last_success_at", option_float_json snapshot.last_success_at
    ; "last_error_at", option_float_json snapshot.last_error_at
    ; ( "last_error"
      , match snapshot.last_error with
        | None -> `Null
        | Some error -> `String error )
    ; "last_duration_sec", option_float_json snapshot.last_duration_sec
    ; "last_counts", option_int_counts_json snapshot.last_counts
    ; ( "stale_after_sec"
      , match stale_after_sec with
        | None -> `Null
        | Some value -> `Float value )
    ; age_field "last_tick_age_sec" snapshot.last_tick_finished_at
    ; age_field "last_success_age_sec" snapshot.last_success_at
    ; age_field "last_error_age_sec" snapshot.last_error_at
    ]
;;
