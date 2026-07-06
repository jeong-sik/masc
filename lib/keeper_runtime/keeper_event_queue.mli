(** Event Layer queue for the keeper heartbeat loop.

    Models the contract verified in
    [specs/keeper-state-machine/KeeperEventQueue.tla]: enqueue is a
    side-effect-free Event Layer operation, the Policy Layer drains
    pending stimuli once it gets a turn, and dedup/urgency are
    bookkeeping concerns that never delay an [enqueue]. *)

type urgency =
  | Immediate  (** operator commands and other latency-critical signals *)
  | Normal     (** board posts, mentions *)
  | Low        (** background polling, telemetry-driven nudges *)

type post_id = string
(** Identifier used by [dedup_by_post_id] to collapse repeat events. *)

type board_stimulus_kind =
  | Post_created
  | Comment_added
  | Reaction_changed of board_reaction_change

and board_reaction_target_type =
  | Reaction_post
  | Reaction_comment

and board_reaction_change =
  { target_type : board_reaction_target_type
  ; target_id : string
  ; user_id : string
  ; emoji : string
  ; reacted : bool
  }

type board_stimulus =
  { kind : board_stimulus_kind
  ; author : string
  ; title : string
  ; content : string
  ; mention_ids : string list
  ; hearth : string option
  ; updated_at : float option
  }
(** Typed board-signal payload carried end-to-end (RFC-0020). *)

type stimulus_payload =
  | Board_signal of board_stimulus
  | Bootstrap
  | No_progress_recovery
  | Fusion_completed of fusion_completion
  | Bg_completed of bg_job_completion
  | Schedule_signal of schedule_signal
      (** A schedule runner signal for a keeper-owned schedule. This carries the
          durable schedule signal identity and schedule id, not the payload
          body, so the keeper turn can re-read current schedule state instead
          of acting on a duplicated snapshot. *)
  | Schedule_due of scheduled_wake
      (** A scheduled automation request has reached its due time and directly
          targeted this keeper. The scheduler owns timing/approval; the keeper
          receives only a typed wake with the operator-authored message. *)
  | Connector_attention of connector_attention
      (** Ambient connector message pointer into [Keeper_external_attention]. *)
  | Hitl_resolved of hitl_resolution
      (** A HITL approval this keeper was waiting on has been resolved. *)
  | Goal_verification_failed of goal_verification_failure
      (** A goal completion verification was rejected for a goal assigned to
          this keeper. *)
(** Closed set of stimulus kinds. *)

and fusion_completion =
  { run_id : string
  ; ok : bool
  ; resolved_answer : string
  ; board_post_id : string
  }

and bg_job_completion =
  { bg_run_id : string
  ; bg_kind : bg_job_kind
  ; bg_outcome : bg_job_outcome
  ; bg_board_post_id : string
  }

and bg_job_kind = Subprocess

and bg_job_outcome =
  | Bg_ok of string
  | Bg_failed of string

and schedule_signal_kind =
  | Schedule_due_candidate
  | Schedule_due_blocked_approval

and schedule_signal =
  { schedule_signal_id : string
  ; schedule_signal_kind : schedule_signal_kind
  ; schedule_id : string
  ; due_at : float
  ; payload_digest : string
  }

and scheduled_wake =
  { schedule_id : string
  ; due_at : float
  ; payload_digest : string
  ; title : string option
  ; message : string
  }

and hitl_resolution_decision =
  | Hitl_approved
  | Hitl_rejected
  | Hitl_edited

and hitl_resolution =
  { approval_id : string
  ; decision : hitl_resolution_decision
  }

and connector_attention = { event_id : string }

and goal_verification_failure =
  { goal_id : string
  ; request_id : string
  ; goal_title : string
  ; phase : string
  ; metric : string option
  ; target_value : string option
  ; rejected_by : string
  ; note : string option
  ; evidence_refs : string list
  }

val fusion_completion_post_id : fusion_completion -> post_id
val bg_job_completion_post_id : bg_job_completion -> post_id
val schedule_signal_post_id : schedule_signal -> post_id
val schedule_due_post_id : scheduled_wake -> post_id
val hitl_resolution_post_id : hitl_resolution -> post_id
val goal_verification_failure_post_id : goal_verification_failure -> post_id

val schedule_signal_kind_to_string : schedule_signal_kind -> string
val hitl_resolution_decision_to_string : hitl_resolution_decision -> string
val bg_job_kind_to_string : bg_job_kind -> string

type stimulus =
  { post_id : post_id
  ; urgency : urgency
  ; arrived_at : float
  ; payload : stimulus_payload
  }

type t

val empty : t
val length : t -> int
val is_empty : t -> bool
val enqueue : t -> stimulus -> t
val stimulus_identity_equal : stimulus -> stimulus -> bool
val to_list : t -> stimulus list
val dequeue : t -> (stimulus * t) option
val prepend_list : stimulus list -> t -> t
val remove_by_post_id : post_id -> t -> stimulus list * t
val uniq_stimuli : stimulus list -> stimulus list
val dedup_by_identity : t -> t
val remove_by_post_id_pair : post_id -> t -> t -> stimulus list * t * t
val dedup_by_post_id : ?window_seconds:float -> t -> t
val sort_by_urgency : t -> t
val summary : t -> string
val payload_kind_label : stimulus_payload -> string
val urgency_to_string : urgency -> string
val urgency_of_string : string -> (urgency, string) result
val is_board_signal : stimulus_payload -> bool
val drain_board_window : ?window_sec:float -> t -> stimulus list * t
val stimulus_to_yojson : stimulus -> Yojson.Safe.t
val stimulus_of_yojson : Yojson.Safe.t -> (stimulus, string) result
val queue_to_yojson : t -> Yojson.Safe.t
val queue_of_yojson : Yojson.Safe.t -> (t, string) result
