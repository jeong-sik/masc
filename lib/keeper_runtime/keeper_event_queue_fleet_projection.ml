(** Pure fleet summaries after durable acquisition at the persistence boundary. *)
module State = Keeper_event_queue_state

let queue_oldest_source_arrived_at queue =
  queue
  |> Keeper_event_queue.to_list
  |> List.fold_left
       (fun oldest (stimulus : Keeper_event_queue.stimulus) ->
          match oldest with
          | None -> Some stimulus.arrived_at
          | Some value -> Some (Float.min value stimulus.arrived_at))
       None
;;

let min_float_opt left right =
  match left, right with
  | None, None -> None
  | Some value, None | None, Some value -> Some value
  | Some left, Some right -> Some (Float.min left right)
;;


let age_seconds_json ~now = function
  | None -> `Null
  | Some timestamp -> `Float (Float.max 0.0 (now -. timestamp))
;;

type queue_residence_unknown_reason =
  | First_admission_not_recorded
  | Queue_observation_incomplete

type queue_residence = Unknown of queue_residence_unknown_reason

let queue_residence_to_yojson (Unknown reason) =
  let reason = match reason with
    | First_admission_not_recorded -> "first_admission_not_recorded"
    | Queue_observation_incomplete -> "queue_observation_incomplete"
  in
  `Assoc
    [ "status", `String "unknown"
    ; "oldest_age_seconds", `Null
    ; "reason", `String reason
    ]
;;

type owner_lifecycle =
  | Runnable
  | Recoverable
  | Retained_disabled
  | Paused_dead
  | Shutdown_fenced
  | Lifecycle_unknown of string

type keeper_summary =
  { keeper_name : string
  ; owner_lifecycle : owner_lifecycle
  ; pending_count : int
  ; pending_oldest_source : float option
  ; outbox_count : int
  ; counts_complete : bool
  ; read_errors : string list
  }

let keeper_summary_of_state ~keeper_name ~owner_lifecycle state =
  let pending = State.pending state in
  { keeper_name
  ; owner_lifecycle
  ; pending_count = Keeper_event_queue.length pending
  ; pending_oldest_source = queue_oldest_source_arrived_at pending
  ; outbox_count = List.length (State.transition_outbox state)
  ; counts_complete = true
  ; read_errors = []
  }
;;

let keeper_summary_unavailable ~keeper_name ~owner_lifecycle ~read_errors =
  { keeper_name
  ; owner_lifecycle
  ; pending_count = 0
  ; pending_oldest_source = None
  ; outbox_count = 0
  ; counts_complete = false
  ; read_errors
  }
;;

let owner_lifecycle_wire = function
  | Runnable -> "runnable"
  | Recoverable -> "recoverable"
  | Retained_disabled -> "retained_disabled"
  | Paused_dead -> "paused_dead"
  | Shutdown_fenced -> "shutdown_fenced"
  | Lifecycle_unknown _ -> "unclassified"
;;

let owner_lifecycle_detail_json = function
  | Lifecycle_unknown detail -> `String detail
  | Runnable | Recoverable | Retained_disabled | Paused_dead | Shutdown_fenced -> `Null
;;

let keeper_summary_json ~now (summary : keeper_summary) =
  `Assoc
    [ "keeper_name", `String summary.keeper_name
    ; "owner_lifecycle", `String (owner_lifecycle_wire summary.owner_lifecycle)
    ; "owner_lifecycle_detail", owner_lifecycle_detail_json summary.owner_lifecycle
    ; "pending_count", `Int summary.pending_count
    ; "total_count", `Int summary.pending_count
    ; "oldest_source_arrived_at_unix", Json_util.float_opt_to_json summary.pending_oldest_source
    ; "oldest_source_age_seconds", age_seconds_json ~now summary.pending_oldest_source
    ; "queue_residence", queue_residence_to_yojson
        (Unknown (if summary.counts_complete then First_admission_not_recorded
                  else Queue_observation_incomplete))
    ; "pending_oldest_source_arrived_at_unix", Json_util.float_opt_to_json summary.pending_oldest_source
    ; "pending_oldest_source_age_seconds", age_seconds_json ~now summary.pending_oldest_source
    ; "transition_outbox_count", `Int summary.outbox_count
    ; "counts_complete", `Bool summary.counts_complete
    ; "read_errors", `List (List.map (fun message -> `String message) summary.read_errors)
    ]
;;

let compact_pending_count_json ~now (summary : keeper_summary) =
  `Assoc
    [ "keeper_name", `String summary.keeper_name
    ; "pending_count", `Int summary.pending_count
    ; "oldest_source_age_seconds", age_seconds_json ~now summary.pending_oldest_source
    ; "queue_residence", queue_residence_to_yojson
        (Unknown (if summary.counts_complete then First_admission_not_recorded
                  else Queue_observation_incomplete))
    ]
;;

let compact_backlog_count_json ~now (summary : keeper_summary) =
  `Assoc
    [ "keeper_name", `String summary.keeper_name
    ; "owner_lifecycle_detail", owner_lifecycle_detail_json summary.owner_lifecycle
    ; "pending_count", `Int summary.pending_count
    ; "total_count", `Int summary.pending_count
    ; "oldest_source_age_seconds", age_seconds_json ~now summary.pending_oldest_source
    ; "queue_residence", queue_residence_to_yojson
        (Unknown (if summary.counts_complete then First_admission_not_recorded
                  else Queue_observation_incomplete))
    ]
;;

type backlog_summary =
  { pending_count : int
  ; oldest : float option
  ; keepers : keeper_summary list
  }

let backlog_summary ~matches summaries =
  let keepers = List.filter (fun (summary : keeper_summary) -> matches summary.owner_lifecycle) summaries in
  let pending_count =
    List.fold_left
      (fun total (summary : keeper_summary) -> total + summary.pending_count)
      0
      keepers
  in
  let oldest =
    List.fold_left
      (fun oldest (summary : keeper_summary) ->
         min_float_opt oldest summary.pending_oldest_source)
      None
      keepers
  in
  { pending_count; oldest; keepers }
;;

let fleet_summary_json ~now ~base_path ~discovery_error summaries =
  let keeper_names = List.map (fun (summary : keeper_summary) -> summary.keeper_name) summaries in
  let pending_count =
    List.fold_left
      (fun total (summary : keeper_summary) -> total + summary.pending_count)
      0
      summaries
  in
  let outbox_count =
    List.fold_left
      (fun total (summary : keeper_summary) -> total + summary.outbox_count)
      0
      summaries
  in
  let oldest =
    List.fold_left
      (fun oldest (summary : keeper_summary) ->
         min_float_opt oldest summary.pending_oldest_source)
      None
      summaries
  in
  let runnable =
    backlog_summary
      ~matches:(function
        | Runnable -> true
        | Recoverable
        | Retained_disabled
        | Paused_dead
        | Shutdown_fenced
        | Lifecycle_unknown _ -> false)
      summaries
  in
  let recoverable =
    backlog_summary
      ~matches:(function
        | Recoverable -> true
        | Runnable
        | Retained_disabled
        | Paused_dead
        | Shutdown_fenced
        | Lifecycle_unknown _ -> false)
      summaries
  in
  let retained_disabled =
    backlog_summary
      ~matches:(function
        | Retained_disabled -> true
        | Runnable
        | Recoverable
        | Paused_dead
        | Shutdown_fenced
        | Lifecycle_unknown _ -> false)
      summaries
  in
  let paused_dead =
    backlog_summary
      ~matches:(function
        | Paused_dead -> true
        | Runnable
        | Recoverable
        | Retained_disabled
        | Shutdown_fenced
        | Lifecycle_unknown _ -> false)
      summaries
  in
  let shutdown_fenced =
    backlog_summary
      ~matches:(function
        | Shutdown_fenced -> true
        | Runnable
        | Recoverable
        | Retained_disabled
        | Paused_dead
        | Lifecycle_unknown _ -> false)
      summaries
  in
  let unclassified =
    backlog_summary
      ~matches:(function
        | Lifecycle_unknown _ -> true
        | Runnable
        | Recoverable
        | Retained_disabled
        | Paused_dead
        | Shutdown_fenced -> false)
      summaries
  in
  let read_errors =
    (match discovery_error with None -> [] | Some error -> [ `String error ])
    @ List.concat_map
        (fun (summary : keeper_summary) ->
           List.map (fun error -> `String error) summary.read_errors)
        summaries
  in
  let counts_complete =
    discovery_error = None
    && List.for_all (fun (summary : keeper_summary) -> summary.counts_complete) summaries
  in
  (* This summary counts the durable queue; it does not judge it. The health
     surface holds the only verdict, because it is the only place that knows
     which parts of the backlog an operator can act on: a retained-disabled or
     paused-dead entry is the operator's own standing decision, not a prompt.
     Emitting a verdict here too produced two answers for one question, and the
     surface then read this one back and cancelled its own policy. *)
  `Assoc
    [ "schema", `String Keeper_event_queue_schema.fleet_summary
    ; "base_path", `String base_path
    ; ( "keepers_runtime_dir"
      , `String (Common.keepers_runtime_dir_of_base ~base_path:base_path) )
    ; "keeper_count", `Int (List.length keeper_names)
    ; "keeper_names", `List (List.map (fun name -> `String name) keeper_names)
    ; "pending_count", `Int pending_count
    ; "total_count", `Int pending_count
    ; "transition_outbox_count", `Int outbox_count
    ; "counts_complete", `Bool counts_complete
    ; "oldest_source_arrived_at_unix", Json_util.float_opt_to_json oldest
    ; "oldest_source_age_seconds", age_seconds_json ~now oldest
    ; "queue_residence", queue_residence_to_yojson
        (Unknown (if counts_complete then First_admission_not_recorded
                  else Queue_observation_incomplete))
    ; "runnable_backlog_count", `Int runnable.pending_count
    ; "runnable_oldest_source_arrived_at_unix", Json_util.float_opt_to_json runnable.oldest
    ; "runnable_oldest_source_age_seconds", age_seconds_json ~now runnable.oldest
    ; ( "runnable_by_keeper"
      , `List
          (runnable.keepers
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; "recoverable_backlog_count", `Int recoverable.pending_count
    ; "recoverable_oldest_source_arrived_at_unix", Json_util.float_opt_to_json recoverable.oldest
    ; "recoverable_oldest_source_age_seconds", age_seconds_json ~now recoverable.oldest
    ; ( "recoverable_by_keeper"
      , `List
          (recoverable.keepers
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; "retained_disabled_backlog_count", `Int retained_disabled.pending_count
    ; ( "retained_disabled_oldest_source_arrived_at_unix"
      , Json_util.float_opt_to_json retained_disabled.oldest )
    ; ( "retained_disabled_oldest_source_age_seconds"
      , age_seconds_json ~now retained_disabled.oldest )
    ; ( "retained_disabled_by_keeper"
      , `List
          (retained_disabled.keepers
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; "paused_dead_backlog_count", `Int paused_dead.pending_count
    ; "paused_dead_oldest_source_arrived_at_unix", Json_util.float_opt_to_json paused_dead.oldest
    ; "paused_dead_oldest_source_age_seconds", age_seconds_json ~now paused_dead.oldest
    ; ( "paused_dead_by_keeper"
      , `List
          (paused_dead.keepers
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; "shutdown_fenced_backlog_count", `Int shutdown_fenced.pending_count
    ; ( "shutdown_fenced_oldest_source_arrived_at_unix"
      , Json_util.float_opt_to_json shutdown_fenced.oldest )
    ; ( "shutdown_fenced_oldest_source_age_seconds"
      , age_seconds_json ~now shutdown_fenced.oldest )
    ; ( "shutdown_fenced_by_keeper"
      , `List
          (shutdown_fenced.keepers
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; "unclassified_count", `Int unclassified.pending_count
    ; "unclassified_oldest_source_arrived_at_unix", Json_util.float_opt_to_json unclassified.oldest
    ; "unclassified_oldest_source_age_seconds", age_seconds_json ~now unclassified.oldest
    ; ( "unclassified_by_keeper"
      , `List
          (unclassified.keepers
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_backlog_count_json ~now)) )
    ; ( "pending_by_keeper"
      , `List
          (summaries
           |> List.filter (fun (summary : keeper_summary) -> summary.pending_count > 0)
           |> List.map (compact_pending_count_json ~now)) )
    ; "read_error_count", `Int (List.length read_errors)
    ; "read_errors", `List read_errors
    ; "keepers", `List (List.map (keeper_summary_json ~now) summaries)
    ]
;;
