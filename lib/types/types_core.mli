(** MASC MCP core domain types. *)

include module type of struct
  include Ids
end

val now_iso : unit -> string
val parse_iso8601_opt : string -> float option
val parse_iso8601 : ?default_time:float -> string -> float

type agent_status =
  | Active
  | Busy
  | Listening
  | Inactive
[@@deriving show { with_path = false }]

val agent_status_to_string : agent_status -> string
val string_of_agent_status : agent_status -> string
val all_agent_statuses : agent_status list
val valid_agent_status_strings : string list
val agent_status_of_string_opt : string -> agent_status option
val agent_status_of_string_r : string -> (agent_status, string) result
val agent_status_to_yojson : agent_status -> Yojson.Safe.t
val agent_status_of_yojson : Yojson.Safe.t -> (agent_status, string) result

type agent_meta =
  { session_id : string
  ; agent_type : string
  ; pid : int option [@default None]
  ; hostname : string option [@default None]
  ; tty : string option [@default None]
  ; parent_task : string option [@default None]
  ; keeper_name : string option [@default None]
  ; keeper_id : string option [@default None]
  }
[@@deriving yojson { strict = false }, show]

type agent =
  { id : Agent_id.t option [@default None]
  ; name : string
  ; agent_type : string [@default "unknown"]
  ; status : agent_status
  ; capabilities : string list
  ; current_task : string option [@default None]
  ; session_bound_at : string
  ; last_seen : string
  ; meta : agent_meta option [@default None]
  }
[@@deriving show]

val agent_to_yojson : agent -> Yojson.Safe.t
val agent_of_yojson : Yojson.Safe.t -> (agent, string) result
val iso8601_of_unix_seconds : float -> string
val normalize_agent_last_seen : session_bound_at:Yojson.Safe.t option -> Yojson.Safe.t -> Yojson.Safe.t option
val short_json_repr : Yojson.Safe.t -> string

type task_action =
  | Claim
  | Start
  | Done_action
  | Cancel
  | Release
  | Submit_for_verification
  | Approve_verification
  | Reject_verification
[@@deriving show]

val task_action_of_string : string -> (task_action, string) result
val task_action_to_string : task_action -> string
val all_task_actions : task_action list
val valid_task_action_strings : string list

(** RFC-0262: who authorizes a transition that would otherwise require the
    task's assignee. Replaces the anonymous [~force:bool] (RFC-0262 §3.1). *)
type completion_authority =
  | Assignee
  | Operator
  | System
[@@deriving show]

val completion_authority_to_string : completion_authority -> string
(** Stable lowercase wire label ([assignee] / [operator] / [system]) for
    transition-log serialization. Distinct from {!show_completion_authority},
    whose output is a [@@deriving] detail not safe to persist. *)

(* RFC-0220: verification sub-state folded into [task_status] (was a separate
   request_status store) so the illegal Todo+Pending pair is unrepresentable. *)
type verification_phase =
  | Awaiting_verifier
  | Verifier_assigned of { verifier : string }
[@@deriving show]

type task_status =
  | Todo
  | Claimed of { assignee : string; claimed_at : string }
  | InProgress of { assignee : string; started_at : string }
  | AwaitingVerification of
      { assignee : string
      ; submitted_at : string
      ; verification_id : string
      ; phase : verification_phase
      }
  | Done of { assignee : string; completed_at : string; notes : string option }
  | Cancelled of { cancelled_by : string; cancelled_at : string; reason : string option }
[@@deriving show]

(** RFC-0220 §3.5: [task_status] of an [AwaitingVerification] obligation once
    [verifier] has claimed it as its satisfier — status preserved, verifier
    recorded in [phase]. Single construction authority shared by [decide] and
    both claim writers. Advisory binding: records who is verifying, not who is
    permitted to (any non-submitter may still approve/reject). *)
val bind_verifier
  :  verifier:string
  -> assignee:string
  -> submitted_at:string
  -> verification_id:string
  -> task_status

val task_status_to_string : task_status -> string
val string_of_task_status : task_status -> string
val task_status_icon : task_status -> string
val task_display_assignee : task_status -> string
val task_assignee_of_status : task_status -> string option
val task_status_is_terminal : task_status -> bool
val task_status_is_done : task_status -> bool
val all_task_status_names : string list
val valid_task_status_strings : string list
val task_status_to_yojson : task_status -> Yojson.Safe.t
val task_status_of_yojson : Yojson.Safe.t -> (task_status, string) result

type task_execution_links =
  { operation_id : string option [@default None]
  ; session_id : string option [@default None]
  }
[@@deriving show, yojson { strict = false }]

type task_contract =
  { strict : bool [@default false]
  ; completion_contract : string list [@default []]
  ; required_evidence : string list [@default []]
  ; inspect_gate_evidence : string list [@default []]
  ; verify_gate_evidence : string list [@default []]
  ; evidence_claims : Evidence_claim.t list [@default []]
        (* RFC-0199 Phase B: typed deterministic completion criteria the
           harness can check without verifier judgment. Declared by the task
           author (masc_add_task contract arg), evaluated by
           Deterministic_evidence_evaluator. Re-introduced with producer +
           consumer wired (unlike the fan-in-0 required_evidence_typed removed
           2026-06-03); legacy required_evidence strings are NOT auto-parsed
           into claims (that would be a substring classifier). *)
  ; stale_claim_timeout_sec : int [@default 0]
  ; links : task_execution_links
        [@default { operation_id = None; session_id = None }]
  }
[@@deriving show, yojson { strict = false }]

type task_reclaim_policy =
  | Allow_reclaim
  | Block_reclaim
[@@deriving show]

val task_reclaim_policy_to_string : task_reclaim_policy -> string
val task_reclaim_policy_of_string : string -> (task_reclaim_policy, string) result
val task_reclaim_policy_to_yojson : task_reclaim_policy -> Yojson.Safe.t
val task_reclaim_policy_of_yojson : Yojson.Safe.t -> (task_reclaim_policy, string) result

type task_handoff_context =
  { summary : string [@default ""]
  ; reason : string option [@default None]
  ; next_step : string option [@default None]
  ; failure_mode : string option [@default None]
  ; reclaim_policy : task_reclaim_policy option [@default None]
  ; evidence_refs : string list [@default []]
  ; updated_at : string option [@default None]
  ; updated_by : string option [@default None]
  }
[@@deriving show, yojson { strict = false }]

type task =
  { id : string
  ; title : string
  ; description : string
  ; task_status : task_status [@key "status"]
  ; priority : int [@default 3]
  ; files : string list [@default []]
  ; created_at : string
  ; created_by : string option [@default None]
  ; predecessor_task_id : string option [@default None]
        (** RFC-0323 W2: write-once lineage pointer to the terminal task this
            one re-runs. Set only at creation; transitions carry it through. *)
  ; contract : task_contract option [@default None]
  ; handoff_context : task_handoff_context option [@default None]
  ; cycle_count : int [@default 0]
  ; reclaim_policy : task_reclaim_policy option [@default None]
  ; do_not_reclaim_reason : string option [@default None]
  }
[@@deriving show]

val task_to_yojson : task -> Yojson.Safe.t
val task_of_yojson : Yojson.Safe.t -> (task, string) result

val task_requires_verification : task -> bool
(** RFC-0323 W1 Phase A (implements RFC-0308): true when the task's contract
    opts into strict verification — completion must route through
    submit -> approve instead of a direct done. Contract presence is not the
    trigger (creation auto-fills an advisory contract for every task);
    [strict] is the explicit persisted opt-in. *)

type task_reclaim_gate =
  | Reclaim_gate_open
  | Reclaim_gate_blocked_by_policy of string

val task_reclaim_gate : task -> task_reclaim_gate
(** Deterministic reclaim gate derived only from typed [reclaim_policy].
    Free-text [do_not_reclaim_reason] can explain a typed block, but cannot
    close the gate by itself. *)

val task_reclaim_gate_block_reason : task -> string option

type task_claim_readiness =
  | Claim_ready

type task_claim_block =
  | Claim_block_not_todo of task_status
  | Claim_block_reclaim_policy of string

type task_claim_decision =
  | Claim_available of task_claim_readiness
  | Claim_unavailable of task_claim_block

val task_claim_decision :
  task -> task_claim_decision
(** Deterministic claim decision for queue/admission surfaces. *)

val task_claim_decision_is_available :
  task -> bool

type task_claim_next_action =
  | Claim_now
  | Skip_claim of task_claim_block

val task_claim_next_action :
  task -> task_claim_next_action
(** Scheduler-facing claim action. *)

val task_claim_next_action_is_claimable :
  task -> bool

type message =
  { seq : int
  ; from_agent : string [@key "from"]
  ; msg_type : string [@key "type"] [@default "broadcast"]
  ; content : string
  ; mention : string option [@default None]
  ; timestamp : string
  ; trace_context : string option [@default None]
  ; expires_at : float option [@default None]
  ; relevance : string [@default "medium"]
  }
[@@deriving yojson { strict = false }, show]

type workspace_state =
  { protocol_version : string
  ; project : string
  ; started_at : string
  ; message_seq : int
  ; active_agents : string list
  ; paused : bool [@default false]
  ; pause_reason : string option [@default None]
  ; paused_by : string option [@default None]
  ; paused_at : string option [@default None]
  ; search_strategy_default : string option [@default None]
  ; speculation_enabled : bool [@default false]
  ; speculation_budget : int option [@default None]
  }
[@@deriving yojson { strict = false }, show]

type tempo_mode =
  | Normal
  | Slow
  | Fast
  | Paused
[@@deriving show { with_path = false }]

val tempo_mode_to_string : tempo_mode -> string
val string_of_tempo_mode : tempo_mode -> string
val tempo_mode_of_string : string -> (tempo_mode, string) result
val tempo_mode_to_yojson : tempo_mode -> Yojson.Safe.t
val tempo_mode_of_yojson : Yojson.Safe.t -> (tempo_mode, string) result

type tempo_config =
  { mode : tempo_mode
  ; delay_ms : int
  ; reason : string option
  ; set_by : string option
  ; set_at : string option
  }
[@@deriving show]

val default_tempo_config : tempo_config
val tempo_config_to_yojson : tempo_config -> Yojson.Safe.t
val tempo_config_of_yojson : Yojson.Safe.t -> (tempo_config, string) result

type backlog =
  { tasks : task list
  ; last_updated : string
  ; version : int
  }
[@@deriving show]

val backlog_to_yojson : backlog -> Yojson.Safe.t
val backlog_of_yojson : Yojson.Safe.t -> (backlog, string) result

type sse_session =
  { agent_name : string
  ; connected_at : string
  ; last_activity : float
  ; is_listening : bool
  }
[@@deriving show]

type tool_result =
  { success : bool
  ; message : string
  ; data : Yojson.Safe.t option [@default None]
  }
[@@deriving show]

val tool_result_to_yojson : tool_result -> Yojson.Safe.t

type tool_schema =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  }

type claim_next_result =
  | Claim_next_claimed of
      { task_id : string
      ; title : string
      ; priority : int
      ; released_task_id : string option
      ; message : string
      ; scope_widened : bool
      }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of
      { excluded_count : int
      ; blocked_count : int
      ; verification_blocked_count : int
      ; scope_excluded_count : int
      ; explicit_excluded_count : int
      ; claim_pool_candidate_count : int
      }
  | Claim_next_error of string
