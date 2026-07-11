(** Durable types for one Keeper shutdown operation.  These records describe
    lifecycle coordination only; task ownership remains authoritative in the
    Workspace backlog. *)

module Operation_id : sig
  type t

  val generate : unit -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
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

type phase =
  | Prepared
  | Joined_idle
  | Reconciliation_required of active_turn
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

val schema_version : int
val admission_lane_to_string : admission_lane -> string
val admission_lane_of_string : string -> (admission_lane, string) result
val failure_stage_to_string : failure_stage -> string
val failure_stage_of_string : string -> (failure_stage, string) result
