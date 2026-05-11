(** Keeper_exec_context — shared keeper context utilities: working context,
    checkpoint management, compaction, room presence, system prompts,
    text processing, proactive prompt helpers, and proactive generation.

    Working context types live in {!Keeper_types}.
    Pure context operations (previously in Keeper_working_context)
    are provided directly by this module. *)

open Keeper_types

(** {1 Working Context Types (re-exported from Keeper_types)} *)

type working_context = Keeper_types.working_context
type checkpoint = Keeper_types.checkpoint
type session_context = Keeper_types.session_context

(** {1 Working Context Operations} *)

val text_of_message : Agent_sdk.Types.message -> string
val msg_tokens : Agent_sdk.Types.message -> int
val count_tokens : string -> Agent_sdk.Types.message list -> int
val max_tokens_of_context : working_context -> int
val token_count : working_context -> int
val message_count : working_context -> int
val context_ratio : working_context -> float
val checkpoint_of_context : working_context -> Agent_sdk.Checkpoint.t
val oas_context_of_context : working_context -> Agent_sdk.Context.t
val with_max_tokens : working_context -> int -> working_context
val system_prompt_of_context : working_context -> string
val messages_of_context : working_context -> Agent_sdk.Types.message list
val create : system_prompt:string -> max_tokens:int -> working_context
val set_system_prompt : working_context -> system_prompt:string -> working_context
val append : working_context -> Agent_sdk.Types.message -> working_context
val append_many : working_context -> Agent_sdk.Types.message list -> working_context
val sync_oas_context : working_context -> working_context

(** Backwards-compatible: unknown -> [Tool] (safest fallback) + warn log.
    See {!role_of_string_opt} for the strict version. Issue #8623. *)
val role_to_string : Agent_sdk.Types.role -> string

(** Strict variant — returns [None] for unrecognised role strings.
    Use this in checkpoint loaders / new code where silently
    misattributing a chat-history message would corrupt the
    LLM-visible conversation. *)
val role_of_string : string -> Agent_sdk.Types.role

val role_of_string_opt : string -> Agent_sdk.Types.role option
val message_to_json : Agent_sdk.Types.message -> Yojson.Safe.t
val message_of_json : Yojson.Safe.t -> Agent_sdk.Types.message
val serialize_context : working_context -> string
val deserialize_context : string -> max_tokens:int -> working_context
val context_to_json : working_context -> Yojson.Safe.t
val create_checkpoint : working_context -> generation:int -> checkpoint
val create_session : session_id:string -> base_dir:string -> session_context
val persist_message : ?source:string -> session_context -> Agent_sdk.Types.message -> unit

(** {1 Inference Utilities} *)

val timed : (unit -> 'a) -> 'a * int
val zero_usage : Agent_sdk.Types.api_usage
val usage_of_response : Agent_sdk.Types.api_response -> Agent_sdk.Types.api_usage
val total_tokens : Agent_sdk.Types.api_usage -> int

(** {1 Checkpoint Store Delegation} *)

val save_session_checkpoint : session_context -> checkpoint -> unit

(** {1 Keeper Context Lifecycle} *)

val log_keeper_exn : label:string -> exn -> unit
val checkpoint_max_tokens : Agent_sdk.Checkpoint.t -> fallback:int -> int

val context_of_oas_checkpoint
  :  ?repair_orphans:bool
  -> max_checkpoint_messages:int
  -> Agent_sdk.Checkpoint.t
  -> primary_model_max_tokens:int
  -> working_context

val checkpoint_model_of_meta : keeper_meta -> string

val save_oas_checkpoint
  :  max_checkpoint_messages:int
  -> session:session_context
  -> agent_name:string
  -> model:string
  -> ctx:working_context
  -> generation:int
  -> (Agent_sdk.Checkpoint.t, string) result

(** {1 Handoff Rollover} *)

type handoff_rollover =
  { updated_meta : keeper_meta
  ; handoff_json : Yojson.Safe.t option
  ; attempted : bool
  ; failure_reason : string option
  ; context_ratio : float
  ; context_tokens : int
  ; context_max : int
  ; message_count : int
  }

type compaction_event =
  { attempted : bool
  ; applied : bool
  ; failure_reason : string option
  ; trigger : Compaction_trigger.t option
  ; decision : Keeper_compact_policy.compaction_decision
  ; before_tokens : int
  ; after_tokens : int
  ; saved_tokens : int
  }

type post_turn_lifecycle =
  { updated_meta : keeper_meta
  ; checkpoint : Agent_sdk.Checkpoint.t option
  ; handoff_json : Yojson.Safe.t option
  ; handoff_attempted : bool
  ; handoff_failure_reason : string option
  ; compaction : compaction_event
  ; turn_generation : int
  ; context_ratio : float
  ; context_tokens : int
  ; context_max : int
  ; message_count : int
  }

type max_context_resolution =
  { requested_override : int option
  ; primary_budget : int
  ; cascade_budget : int
  ; turn_budget : int
  ; effective_budget : int
  }

type overflow_retry_recovery =
  { checkpoint : Agent_sdk.Checkpoint.t
  ; compaction : compaction_event
  ; turn_generation : int
  }

val maybe_rollover_oas_handoff
  :  on_started:(unit -> unit)
  -> base_dir:string
  -> meta:keeper_meta
  -> model:string
  -> primary_model_max_tokens:int
  -> current_turn_blocker_info:blocker_info option
  -> checkpoint:Agent_sdk.Checkpoint.t option
  -> handoff_rollover

(** {2 Pure gate helpers (for testing)} *)

type rollover_gate_decision =
  | Skip of string
  | Go of string

(** [blocker_class_indicates_overflow klass] returns true when [klass] is
    the typed equivalent of a provider context-overflow signal.  Pure —
    keeper layer reasons over [blocker_class], never substring-matching
    error phrasing. *)
val blocker_class_indicates_overflow : blocker_class -> bool

(** [classify_rollover_gate] is the pure decision function used by
    [maybe_rollover_oas_handoff]. Exposed for unit tests.

    Returns [Go reason] when a handoff should be attempted; [Skip reason]
    otherwise. The [reason] string is surfaced in logs and [handoff_json]. *)
val classify_rollover_gate
  :  auto_handoff:bool
  -> cooldown_elapsed:bool
  -> ratio:float
  -> handoff_threshold:float
  -> last_outcome:proactive_cycle_outcome
  -> last_blocker_info:blocker_info option
  -> ?current_turn_blocker_info:blocker_info option
  -> unit
  -> rollover_gate_decision

(** {1 Checkpoint Loading and Saving} *)

val load_context_from_checkpoint
  :  max_checkpoint_messages:int
  -> trace_id:string
  -> primary_model_max_tokens:int
  -> base_dir:string
  -> session_context * working_context option

val save_checkpoint : session_context -> working_context -> generation:int -> checkpoint

(** {1 Compaction} *)

val compaction_policy_of_keeper : keeper_meta -> float * int * int

type compaction_decision = Keeper_compact_policy.compaction_decision =
  | Applied of Compaction_trigger.t
  | Blocked_below_thresholds
  | Skipped_no_checkpoint
  | Skipped_continuity_reflection of
      { hold_s : float
      ; cooldown_sec : int
      }

val compaction_decision_to_string : compaction_decision -> string
val compaction_decision_applied : compaction_decision -> bool

val apply_post_turn_lifecycle
  :  on_compaction_started:(unit -> unit)
  -> on_handoff_started:(unit -> unit)
  -> base_dir:string
  -> meta:keeper_meta
  -> model:string
  -> primary_model_max_tokens:int
  -> current_turn_blocker_info:blocker_info option
  -> checkpoint:Agent_sdk.Checkpoint.t option
  -> post_turn_lifecycle

val apply_post_turn_lifecycle_with_resilience_handles
  :  resilience_audit_store:Shared_audit.Store.t option
  -> resilience_strategy_executor:Resilience.Recovery.strategy_executor option
  -> on_compaction_started:(unit -> unit)
  -> on_handoff_started:(unit -> unit)
  -> base_dir:string
  -> meta:keeper_meta
  -> model:string
  -> primary_model_max_tokens:int
  -> current_turn_blocker_info:blocker_info option
  -> checkpoint:Agent_sdk.Checkpoint.t option
  -> post_turn_lifecycle

val dispatch_keeper_phase_event
  :  config:Coord.config
  -> keeper_name:string
  -> Keeper_state_machine.event
  -> unit

(** Canonical metric name for the compaction outcome counter.

    Labels: [("keeper", <name>); ("outcome", "ok" | "noop")].
    Exported so tests can pin the name without hard-coding a string
    literal.  #9988. *)
val compaction_outcome_metric : string

(** [record_compaction_outcome ~keeper_name ~before_tokens ~after_tokens]
    emits the outcome counter and (for [saved_tokens <= 0]) a warn log,
    without dispatching an FSM event.  Exposed for unit tests and for
    callers that need the observability signal before/after a dispatch.  *)
val record_compaction_outcome
  :  keeper_name:string
  -> before_tokens:int
  -> after_tokens:int
  -> unit

(** [dispatch_compaction_completed ~config ~keeper_name ~before_tokens
    ~after_tokens] dispatches a [Compaction_completed] phase event and
    updates observability in one place.

    Emits [compaction_outcome_metric] labelled with [outcome=ok] when
    [after_tokens < before_tokens] and [outcome=noop] otherwise.  A
    [noop] outcome also logs a warning — the FSM (#9988) keeps
    [context_overflow] set in this case, so operators need the signal
    to escalate profile / alert.

    Two emit paths exist ([tool_keeper] manual compact recovery and
    [dispatch_post_turn_lifecycle_events] automatic compact); both
    funnel through this helper to keep observability coherent. *)
val dispatch_compaction_completed
  :  config:Coord.config
  -> keeper_name:string
  -> before_tokens:int
  -> after_tokens:int
  -> unit

val dispatch_post_turn_lifecycle_events
  :  config:Coord.config
  -> keeper_name:string
  -> post_turn_lifecycle
  -> unit

val recover_latest_checkpoint_for_overflow_retry
  :  base_dir:string
  -> meta:keeper_meta
  -> model:string
  -> primary_model_max_tokens:int
  -> overflow_retry_recovery option

(** {1 Trace and Board Utilities} *)

val generate_trace_id : ?now:float -> unit -> string
val keeper_board_write_tool_names : string list
val keeper_write_done : string list -> bool
val keeper_action_kind_of_tool_names : string list -> string

(** {1 Model and Coord Utilities} *)

val effective_model_labels_for_turn : keeper_meta -> string list

val resolve_max_context_resolution
  :  requested_override:int option
  -> string list
  -> max_context_resolution

val resolve_max_context_resolution_of_meta : keeper_meta -> max_context_resolution
val room_cursor_for : keeper_meta -> string -> int
val set_room_cursor : keeper_meta -> string -> int -> keeper_meta
val room_ids_for_meta : Coord.config -> keeper_meta -> string list
val ensure_keeper_room_presence : Coord.config -> keeper_meta -> keeper_meta

(** {1 Mention Detection} *)

val exact_direct_mention_present : targets:string list -> string -> bool

(** {1 Prompt Delegation} *)

val keeper_constitution : unit -> string

val build_keeper_system_prompt
  :  goal:string
  -> short_goal:string
  -> mid_goal:string
  -> long_goal:string
  -> will:string
  -> needs:string
  -> desires:string
  -> instructions:string
  -> ?persona_extended:string
  -> ?keeper_name:string
  -> ?allowed_orgs:string list
  -> ?denied_repos:string list
  -> ?git_clone_policy_loaded:bool
  -> ?active_goals:(string * string * string) list
  -> unit
  -> string

val append_trait_clause : base:string -> clause:string -> string

(** {1 Text Processing} *)

val strip_state_blocks_text : string -> string
val trim_to_option : string -> string option
val user_visible_reply_text : ?fallback:string -> string -> string

(** {1 Fragment Detection (used by dashboard)} *)

val looks_fragmentary_history_text : string -> bool

(** {1 Memory Check} *)

val memory_check_default_json : unit -> Yojson.Safe.t
