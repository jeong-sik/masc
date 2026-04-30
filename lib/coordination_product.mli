(** Advisory orthogonal product for Goal x Task x Board x Reward.

    This module is intentionally pure. Runtime code projects existing stores
    into these axes and consumes the returned advisory violations; it does not
    enforce transitions or mutate balances/tasks/goals. *)

type task_phase =
  | No_task
  | Todo
  | Claimed
  | In_progress
  | Awaiting_verification
  | Done
  | Cancelled
  | Mixed

val task_phase_of_status : Types.task_status -> task_phase
val task_phase_to_string : task_phase -> string

type board_phase =
  | Quiet
  | Signal_pending
  | Signal_acknowledged
  | Signal_expired
  | Degraded

val board_phase_to_string : board_phase -> string

type reward_phase =
  | Disabled
  | Neutral
  | Credit_pending
  | Rewarded
  | Spent
  | Penalized

val reward_phase_to_string : reward_phase -> string

type axis =
  | Goal
  | Task
  | Board
  | Reward
  | Product

val axis_to_string : axis -> string

type severity =
  | Info
  | Warn
  | Error

val severity_to_string : severity -> string

type observation_principle =
  | Observable_updates
  | Deterministic_convergence
  | Monotonic_progress

val observation_principle_to_string : observation_principle -> string
val observation_driven_principles : observation_principle list

type ids =
  { goal_id : string option
  ; task_ids : string list
  ; post_ids : string list
  ; agent_name : string option
  }

module Ref_key : sig
  val goal_id : string
  val task_id : string
  val task_ids : string
  val post_id : string
  val post_ids : string
  val agent_name : string
end

val empty_ids : ids

type task_counts =
  { total : int
  ; open_count : int
  ; done_count : int
  ; cancelled_count : int
  ; awaiting_verification_count : int
  }

val empty_task_counts : task_counts
val task_counts_of_statuses : Types.task_status list -> task_counts
val task_phase_of_counts : Types.task_status list -> task_phase
val task_counts_to_yojson : task_counts -> Yojson.Safe.t

type claim_observation =
  { task_id : string
  ; owner : string
  ; phase : task_phase
  }

type duplicate_active_claim =
  { task_id : string
  ; owners : string list
  }

type turn_queue_entry =
  { task_id : string
  ; priority : int
  ; created_at : string
  }

val active_claim_observation : Types.task -> claim_observation option
val active_claims : Types.task list -> claim_observation list
val duplicate_active_claims : Types.task list -> duplicate_active_claim list
val visible_claim_queue : Types.task list -> turn_queue_entry list

type facts =
  { economy_enabled : bool
  ; has_reward_earning : bool
  ; has_spend : bool
  ; has_penalty : bool
  ; board_signal_count : int
  ; board_persist_error_count : int
  ; active_goal_verification : bool
  }

val default_facts : facts

type evidence_source =
  | Source_goal_store
  | Source_task_store
  | Source_board
  | Source_economy
  | Source_telemetry

val evidence_source_to_string : evidence_source -> string

type evidence_kind =
  | Evidence_goal_phase
  | Evidence_task_status
  | Evidence_board_post
  | Evidence_economy_earn_task_done
  | Evidence_economy_earn_board_post
  | Evidence_economy_earn_upvote
  | Evidence_economy_earn_mention_response
  | Evidence_economy_spend_model_call
  | Evidence_economy_spend_deliberation
  | Evidence_economy_adjustment
  | Evidence_telemetry_task_started
  | Evidence_telemetry_task_completed
  | Evidence_telemetry_tool_called

val evidence_kind_to_string : evidence_kind -> string

type evidence =
  { source : evidence_source
  ; kind : evidence_kind
  ; id : string option
  ; label : string
  ; detail : string
  ; timestamp : float option
  ; refs : ids
  }

type product =
  { ids : ids
  ; goal : Goal_phase.t option
  ; task : task_phase
  ; board : board_phase
  ; reward : reward_phase
  ; task_counts : task_counts
  ; facts : facts
  ; evidence : evidence list
  }

type violation =
  { axis : axis
  ; code : string
  ; severity : severity
  ; message : string
  ; ids : ids
  }

val observation_driven_violations : Types.task list -> violation list

val reward_phase_of_facts
  :  economy_enabled:bool
  -> task_counts:task_counts
  -> board:board_phase
  -> has_reward_earning:bool
  -> has_spend:bool
  -> has_penalty:bool
  -> reward_phase

val check_invariants : product -> violation list
val ids_to_yojson : ids -> Yojson.Safe.t
val facts_to_yojson : facts -> Yojson.Safe.t
val evidence_to_yojson : evidence -> Yojson.Safe.t
val violation_to_yojson : ?evidence:evidence list -> violation -> Yojson.Safe.t
val product_to_yojson : product -> Yojson.Safe.t

type snapshot =
  { products : product list
  ; violations : violation list
  }

val schema_version_current : int

type snapshot_mode = Advisory

val snapshot_mode_to_string : snapshot_mode -> string
val snapshot : product list -> snapshot
val snapshot_to_yojson : ?projection_error:string -> snapshot -> Yojson.Safe.t
