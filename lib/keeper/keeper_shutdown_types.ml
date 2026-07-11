module Operation_id = struct
  type t = string

  let prefix = "shutdown-"
  (* NDT-OK: UUID entropy is an operation identity only. No lifecycle
     decision branches on the generated contents. *)
  let rng = Random.State.make_self_init () (* NDT-OK: identity entropy only *)
  let rng_mutex = Eio.Mutex.create ()

  let generate () =
    let uuid = Eio.Mutex.use_ro rng_mutex (fun () -> Uuidm.v4_gen rng ()) in
    prefix ^ Uuidm.to_string uuid
  ;;

  let of_string value =
    let prefix_length = String.length prefix in
    if
      String.length value = prefix_length + 36
      && String.equal (String.sub value 0 prefix_length) prefix
    then
      match Uuidm.of_string (String.sub value prefix_length 36) with
      | Some _ -> Ok value
      | None -> Error (Printf.sprintf "invalid Keeper shutdown operation id: %S" value)
    else Error (Printf.sprintf "invalid Keeper shutdown operation id: %S" value)
  ;;

  let to_string value = value
  let equal = String.equal
end

type cleanup_intent =
  { remove_meta : bool
  ; remove_session : bool
  }

type admission_lane =
  | Autonomous
  | Chat

type active_turn =
  { lane : admission_lane option
  ; admitted_at : float option
  ; observed_turn_id : int option
  ; observation_started_at : float option
  }

type turn_disposition =
  | No_inflight_turn
  | Inflight_effect_unknown of active_turn

type failure_stage =
  | Task_discovery
  | Record_persist
  | Turn_cancel
  | Lane_cancel
  | Turn_join
  | Lane_join
  | Record_update
  | Task_settlement
  | Pending_confirm_cleanup
  | Meta_update
  | Meta_remove
  | Session_remove
  | Registry_unregister

type failure =
  { stage : failure_stage
  ; detail : string
  }

type lane_outcome =
  | Lane_completed
  | Lane_shutdown_requested
  | Lane_cancelled_by_parent of string
  | Lane_failed of string

type terminal =
  | Terminal_stopped
  | Terminal_crashed of string

type join_evidence =
  { lane_outcome : lane_outcome
  ; terminal : terminal
  ; cleanup_error : string option
  }

type cleanup_evidence =
  { settled_task_ids : Keeper_id.Task_id.t list
  ; pending_confirms_removed : int
  }

type finalization_evidence =
  { cleanup : cleanup_evidence
  ; meta_removed : bool
  ; session_removed : bool
  ; registry_unregistered : bool
  }

type phase =
  | Prepared
  | Joined_idle
  | Finalizing_tasks of Keeper_id.Task_id.t list
  | Cleanup_ready of cleanup_evidence
  | Reconciliation_required of active_turn
  | Finalized of finalization_evidence
  | Blocked of failure

type t =
  { schema_version : int
  ; operation_id : Operation_id.t
  ; keeper_name : string
  ; lane_id : Keeper_lane.Id.t
  ; trace_id : Keeper_id.Trace_id.t
  ; generation : int
  ; actor : string
  ; cleanup_intent : cleanup_intent
  ; turn_disposition : turn_disposition
  ; owned_task_ids : Keeper_id.Task_id.t list
  ; join_evidence : join_evidence option
  ; phase : phase
  ; created_at : string
  ; updated_at : string
  }

let schema_version = 1

let admission_lane_to_string = function
  | Autonomous -> "autonomous"
  | Chat -> "chat"
;;

let admission_lane_of_string = function
  | "autonomous" -> Ok Autonomous
  | "chat" -> Ok Chat
  | value -> Error (Printf.sprintf "unknown Keeper shutdown admission lane: %S" value)
;;

let failure_stage_to_string = function
  | Task_discovery -> "task_discovery"
  | Record_persist -> "record_persist"
  | Turn_cancel -> "turn_cancel"
  | Lane_cancel -> "lane_cancel"
  | Turn_join -> "turn_join"
  | Lane_join -> "lane_join"
  | Record_update -> "record_update"
  | Task_settlement -> "task_settlement"
  | Pending_confirm_cleanup -> "pending_confirm_cleanup"
  | Meta_update -> "meta_update"
  | Meta_remove -> "meta_remove"
  | Session_remove -> "session_remove"
  | Registry_unregister -> "registry_unregister"
;;

let failure_stage_of_string = function
  | "task_discovery" -> Ok Task_discovery
  | "record_persist" -> Ok Record_persist
  | "turn_cancel" -> Ok Turn_cancel
  | "lane_cancel" -> Ok Lane_cancel
  | "turn_join" -> Ok Turn_join
  | "lane_join" -> Ok Lane_join
  | "record_update" -> Ok Record_update
  | "task_settlement" -> Ok Task_settlement
  | "pending_confirm_cleanup" -> Ok Pending_confirm_cleanup
  | "meta_update" -> Ok Meta_update
  | "meta_remove" -> Ok Meta_remove
  | "session_remove" -> Ok Session_remove
  | "registry_unregister" -> Ok Registry_unregister
  | value -> Error (Printf.sprintf "unknown Keeper shutdown failure stage: %S" value)
;;
