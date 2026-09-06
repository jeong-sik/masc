(** MASC MCP core domain types. *)

include module type of struct
  include Ids
end

val now_iso : unit -> string
val parse_iso8601_opt : string -> float option

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
(** Presence ordering for operator surfaces: [Busy] 4, [Active] 3,
    [Listening] 2, [Inactive] 1. Descending-rank comparators sort a working
    agent above an idle one. *)
val agent_status_rank : agent_status -> int

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

(** Actions an *agent* may drive. A completion verdict is not among them; a
    trusted operator or judge caller constructs its authority provenance
    outside this surface. *)
type task_action =
  | Claim
  | Start
  | Done_action
  | Cancel
  | Release
  | Submit_for_verification
[@@deriving show]

(** Rejects ["approve"] / ["reject"] with an explanation naming
    [completion_authority], rather than reporting them as unknown actions. *)
val task_action_of_string : string -> (task_action, string) result

val task_action_to_string : task_action -> string
val all_task_actions : task_action list
val valid_task_action_strings : string list

(** Verdict provenance. Constructors do not authenticate their string payload;
    a trusted operator or the system LLM agent boundary must construct the
    value. The system LLM agent is not a Keeper and does not participate in
    the Keeper task-action or lifecycle surfaces. *)
type completion_authority =
  | Human_operator of { operator_id : string }
  | System_llm_agent of { agent_run_id : string }
[@@deriving show]

type completion_verdict =
  | Verdict_approved
  | Verdict_rejected of { reason : string }
[@@deriving show]

val completion_authority_actor : completion_authority -> string
val completion_authority_kind : completion_authority -> string
val completion_authority_has_identity : completion_authority -> bool
(** Whether the provenance carries a non-empty authenticated identity. *)

(** Which question a completion authority is being asked. A producer submits
    work it believes is finished, or a stop it believes is right; both wait in
    the same place and both end on one verdict, so the verdict needs to know
    which terminal state it is authorising. *)
type verification_intent =
  | Complete_task
  | Cancel_task
[@@deriving show]

(** What the producer places before the authority. [verification_intent] is
    the projection the task status carries; the request record the authority
    reads carries the claim itself. *)
type verification_claim =
  | Completion_evidence of { evidence_refs : string list }
  | Cancellation_reason of { reason : string }

type task_status =
  | Todo
  | Claimed of { assignee : string; claimed_at : string }
  | InProgress of { assignee : string; started_at : string }
  | AwaitingVerification of
      { assignee : string
      ; started_at : string
      ; submitted_at : string
      ; intent : verification_intent
      ; verification_id : string
      }
      (** No verifier binding. [started_at] preserves the producer's original
          work start across submission and rejection; [verification_id] joins
          to the evidence record the authority reads. *)
  | Done of { assignee : string; completed_at : string; notes : string option }
  | Cancelled of { cancelled_by : string; cancelled_at : string; reason : string option }
[@@deriving show]

val task_status_to_string : task_status -> string
val string_of_task_status : task_status -> string
val task_status_icon : task_status -> string
val task_display_assignee : task_status -> string
(* [task_actor] and [task_actor_of_status] stay inside this module. They exist
   so the three questions below cannot disagree about [Done] and [Cancelled] --
   each is a total match over the same sum -- and that job is done entirely
   here. Nothing outside ever named the type or its constructors, so exporting
   them offered a second vocabulary for "who acted on a Task" beside the three
   answers that are actually asked for. [task_actor_name] had no caller at all
   and is gone. *)

(** Who owes work now. [Done] and [Cancelled] owe nothing. *)
val task_assignee_of_status : task_status -> string option

(** Who did or is doing the work, including after completion. [Cancelled]
    answers [None]: its canceller ended the work rather than performing it. *)
val task_performer_of_status : task_status -> string option
val task_status_is_terminal : task_status -> bool
val task_status_is_done : task_status -> bool
val valid_task_status_strings : string list
val task_status_to_yojson : task_status -> Yojson.Safe.t
val task_status_of_yojson : Yojson.Safe.t -> (task_status, string) result

type task_execution_links =
  { operation_id : string option [@default None]
  ; session_id : string option [@default None]
  }
[@@deriving show, yojson { strict = true }]

(** No producer has been linked yet. A task starts here and stays here until a
    runtime records the operation or session that carried it out. *)
val no_execution_links : task_execution_links

type task_contract =
  { strict : bool [@default false]
  ; completion_contract : string list [@default []]
  ; required_evidence : string list [@default []]
  ; inspect_gate_evidence : string list [@default []]
  ; verify_gate_evidence : string list [@default []]
  }
[@@deriving show, yojson { strict = false }]

type task_reclaim_policy =
  | Allow_reclaim
  | Block_reclaim
[@@deriving show]

val task_reclaim_policy_to_string : task_reclaim_policy -> string
val task_reclaim_policy_of_string : string -> (task_reclaim_policy, string) result
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

(** The "why" behind a transition that stopped work, from whichever argument
    carried it. [transition_task_r] takes an explicit [reason];
    [release_task_r] takes none and forwards only a handoff context, which the
    production release tool requires for a strict release.
    [task_handoff_context.reason] is the same concept under a different
    argument, so it is read when the explicit one is blank, then
    [task_handoff_context.summary] — which a strict release is rejected
    without, while [reason] stays optional.

    Single definition on purpose: the committed broadcast and the author wake
    both answer "why did this stop", and resolving it separately let them
    disagree about the same cancellation. [None] when neither carries a
    non-blank reason. *)
val stated_reason :
  reason:string option -> handoff_context:task_handoff_context option -> string option

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
  ; execution_links : task_execution_links
        [@default no_execution_links]
        (** Runtime identifiers attached after creation by whichever execution
            picks the task up. Separate from [contract] so linking them never
            rewrites what counts as done. *)
  ; handoff_context : task_handoff_context option [@default None]
  ; cycle_count : int [@default 0]
  ; reclaim_policy : task_reclaim_policy option [@default None]
  ; do_not_reclaim_reason : string option [@default None]
  ; skills : Skill_reference.t list [@default []]
        (** Exact, immutable Skill references attached at Task creation.
            Source, package, canonical name, and content revision remain one
            durable fact throughout the Task lifecycle. Empty means the Task
            declares no Skill. *)
  }
[@@deriving show]

(** When the Task last changed state, from the timestamp its status carries.
    [Todo] falls back to creation. Defined once: two byte-identical copies
    lived in the execution and goals projections, one per surface. *)
val task_last_transition_at : task -> string

val task_to_yojson : task -> Yojson.Safe.t

(** Listing row without the task body: [id], [title], [priority], [created_at]
    and the status fields ([status], [assignee], timestamps). [task_to_yojson]
    is the full record. *)
val task_compact_to_yojson : task -> Yojson.Safe.t

val task_of_yojson : Yojson.Safe.t -> (task, string) result

type task_claim_readiness =
  | Claim_ready

(** RFC-0323 G-10: the typed reclaim claim gate is retired (#23661 removed
    the Todo producer, G-10 the Done producer). Claim blocks describe the
    task-status fact that prevents an agent claim; [reclaim_policy] survives
    as release/cancel data plumbing. *)
type task_claim_block =
  | Claim_block_pending_verdict of { verification_id : string }
  | Claim_block_not_todo of task_status

type task_claim_decision =
  | Claim_available of task_claim_readiness
  | Claim_unavailable of task_claim_block

val task_claim_decision_for_status :
  task_status -> task_claim_decision
(** Claim admission derived only from the persisted task status. This is the
    status-level SSOT used by both the full-task projection and lifecycle
    transitions. *)

val task_claim_decision :
  task -> task_claim_decision
(** Deterministic claim decision for queue/admission surfaces. An
    [AwaitingVerification] task is unavailable to agents until a completion
    authority commits its verdict. *)

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

type message_mention_delivery =
  | Mention_passive
  | Mention_pending
  | Mention_accepted
  | Mention_rejected
[@@deriving yojson, show]

val message_mention_delivery_to_string : message_mention_delivery -> string

type message =
  { request_id : string
  ; seq : int
  ; from_agent : string [@key "from"]
  ; msg_type : string [@key "type"] [@default "broadcast"]
  ; content : string
  ; mention : string option [@default None]
  ; mention_delivery : message_mention_delivery
  ; timestamp : string
  ; trace_context : string option [@default None]
  ; expires_at : float option [@default None]
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

(** Task backlog snapshot. [version] is the monotonic commit revision —
    stamped +1 per commit by [Workspace_backlog.write_backlog_result] (the
    single commit point; callers never hand-bump). It is the
    optimistic-concurrency token for task transitions. OCaml's 63-bit [int]
    serves as the monotonic integer. The field is required by the current
    contract; absent, malformed, or non-positive values fail the decode
    (fail-closed — corruption must not silently rewind the revision).
    [last_updated] is stamped at the same commit point; display only —
    never an ordering input. *)
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
      ; message : string
      ; scope_widened : bool
      }
  | Claim_next_no_unclaimed
  | Claim_next_no_eligible of
      { excluded_count : int
      ; scope_excluded_count : int
      ; explicit_excluded_count : int
      ; claim_pool_candidate_count : int
      }
  | Claim_next_error of string
