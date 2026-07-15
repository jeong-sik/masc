(** Keeper_context_runtime — shared keeper context utilities: working context,
    checkpoint management, compaction, system prompts,
    text processing, proactive prompt helpers, and proactive generation.

    Working context types live in {!Keeper_types}.
    Pure context operations (previously in Keeper_working_context)
    are provided directly by this module. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(** {1 Working Context Types (re-exported from Keeper_types)} *)

type working_context = Keeper_types.working_context
type session_context = Keeper_types.session_context

(** {1 Working Context Operations} *)

val text_of_message : Agent_sdk.Types.message -> string
val max_tokens_of_context : working_context -> int
val message_count : working_context -> int
val serialized_bytes : working_context -> int
val checkpoint_of_context : working_context -> Agent_sdk.Checkpoint.t
val resume_checkpoint_of_context : working_context -> Agent_sdk.Checkpoint.t
val oas_context_of_context : working_context -> Agent_sdk.Context.t
val with_max_tokens : working_context -> int -> working_context
val system_prompt_of_context : working_context -> string
val messages_of_context : working_context -> Agent_sdk.Types.message list
val create : eio:bool -> system_prompt:string -> max_tokens:int -> working_context
val set_system_prompt : working_context -> system_prompt:string -> working_context
val append : working_context -> Agent_sdk.Types.message -> working_context
val append_many : working_context -> Agent_sdk.Types.message list -> working_context
val sync_oas_context : working_context -> working_context

val role_to_string : Agent_sdk.Types.role -> string

(** Strict variant — returns [None] for unrecognised role strings.
    Use this in checkpoint loaders / new code where silently
    misattributing a chat-history message would corrupt the
    LLM-visible conversation. *)
val role_of_string_opt : string -> Agent_sdk.Types.role option
val message_to_json : Agent_sdk.Types.message -> Yojson.Safe.t
val message_of_json : Yojson.Safe.t -> Agent_sdk.Types.message
val serialize_context : working_context -> string
val deserialize_context : eio:bool -> string -> max_tokens:int -> working_context
val context_to_json : working_context -> Yojson.Safe.t
val create_session : session_id:string -> base_dir:string -> session_context
val persist_message : ?source:string -> session_context -> Agent_sdk.Types.message -> unit

(** {1 Inference Utilities} *)

val timed : (unit -> 'a) -> 'a * int
val zero_usage : Agent_sdk.Types.api_usage
val usage_of_response : Agent_sdk.Types.api_response -> Agent_sdk.Types.api_usage
val total_tokens : Agent_sdk.Types.api_usage -> int

(** {1 Keeper Context Lifecycle} *)

val log_keeper_exn : label:string -> exn -> unit
val checkpoint_max_tokens : Agent_sdk.Checkpoint.t -> fallback:int -> int

val context_of_oas_checkpoint
  :  Agent_sdk.Checkpoint.t
  -> primary_model_max_tokens:int
  -> working_context

val save_oas_checkpoint
  :  multimodal_policy:Keeper_types_profile.multimodal_policy
  -> keeper_name:string
  -> session:session_context
  -> agent_name:string
  -> ctx:working_context
  -> generation:int
  -> (Agent_sdk.Checkpoint.t, string) result

type compaction_event =
  { attempted : bool
  ; applied : bool
  ; started_dispatched : bool
  ; failure_reason : string option
  ; trigger : Compaction_trigger.t option
  ; decision : Keeper_compact_policy.compaction_decision
  }

type post_turn_lifecycle =
  { updated_meta : keeper_meta
  ; checkpoint : Agent_sdk.Checkpoint.t option
  ; handoff_json : Yojson.Safe.t option
  ; handoff_attempted : bool
  ; handoff_failure_reason : string option
  ; compaction : compaction_event
  ; turn_generation : int
  ; checkpoint_bytes : int
  ; message_count : int
  }

type max_context_resolution =
  { requested_override : int option
  ; primary_budget : int
  ; runtime_budget : int
  ; requested_context_window : int
  ; effective_budget : int
  }

type context_budget_source =
  | Runtime_provider_cap
  | Requested_override
  | Requested_override_clamped_to_provider

type overflow_retry_recovery =
  { checkpoint : Agent_sdk.Checkpoint.t
  ; compaction : compaction_event
  ; evidence : Keeper_compact_policy.compaction_evidence
  ; operation_id : string
  ; turn_generation : int
  }

(** {1 Checkpoint Loading} *)

val load_context_from_checkpoint
  :  trace_id:string
  -> primary_model_max_tokens:int
  -> base_dir:string
  -> session_context * working_context option

(** {1 Compaction} *)

val compaction_policy_of_keeper : keeper_meta -> float * int * int

type compaction_decision = Keeper_compact_policy.compaction_decision =
  | Applied of Compaction_trigger.t
  | Prepared of Compaction_trigger.t
  | Rejected of Compaction_trigger.t * Keeper_compact_policy.compaction_rejection
  | Not_requested
  | Skipped_no_checkpoint

val compaction_decision_to_string : compaction_decision -> string
val compaction_decision_applied : compaction_decision -> bool
val compaction_decision_prepared : compaction_decision -> bool

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
  :  config:Workspace.config
  -> ?origin:Keeper_registry.lifecycle_event_origin
  -> keeper_name:string
  -> Keeper_state_machine.event
  -> unit

type lifecycle_dispatch_error =
  | Transition_rejected of Keeper_state_machine.transition_error
  | Compaction_invariant_violation of
      Keeper_registry_types.compaction_transition_spec_violation

val lifecycle_dispatch_error_to_string : lifecycle_dispatch_error -> string

val dispatch_keeper_phase_event_result
  :  config:Workspace.config
  -> ?origin:Keeper_registry.lifecycle_event_origin
  -> keeper_name:string
  -> Keeper_state_machine.event
  -> (unit, lifecycle_dispatch_error) result

(** Dispatch [Compaction_completed] only after the prepared checkpoint has
    been durably saved. *)
val dispatch_compaction_completed
  :  config:Workspace.config
  -> origin:Keeper_registry.lifecycle_event_origin
  -> keeper_name:string
  -> (unit, lifecycle_dispatch_error) result

val dispatch_post_turn_lifecycle_events
  :  config:Workspace.config
  -> keeper_name:string
  -> post_turn_lifecycle
  -> unit

val recover_latest_checkpoint_for_overflow_retry
  :  base_dir:string
  -> meta:keeper_meta
  -> trigger:Compaction_trigger.t
  -> primary_model_max_tokens:int
  -> (overflow_retry_recovery, Keeper_post_turn.compaction_recovery_error) result

(** {1 Trace and Board Utilities} *)

val generate_trace_id : ?now:float -> unit -> string
val keeper_board_write_tool_names : string list
val keeper_action_kind_of_tool_names : string list -> string

(** {1 Model and Workspace Utilities} *)

val effective_model_labels_for_turn : keeper_meta -> string list

val resolve_max_context_resolution
  :  requested_override:int option
  -> string list
  -> max_context_resolution

val resolve_max_context_resolution_of_meta : keeper_meta -> max_context_resolution

val context_budget_source_of_resolution
  :  max_context_resolution
  -> context_budget_source

val context_budget_source_to_string : context_budget_source -> string

val context_budget_json_of_resolution
  :  runtime_id:string
  -> max_context_resolution
  -> Yojson.Safe.t

(** {1 Mention Detection} *)
(** {1 Mention Detection} *)

val exact_direct_mention_present : targets:string list -> string -> bool

(** {1 Prompt Delegation} *)

val keeper_constitution : unit -> string

val build_keeper_system_prompt
  :  instructions:string
  -> ?persona_extended:string
  -> ?keeper_name:string
  -> ?home_ground:string
  -> ?active_goals:(string * string) list
  -> unit
  -> string

val append_trait_clause : base:string -> clause:string -> string

(** {1 Fragment Detection (used by dashboard)} *)

val looks_fragmentary_history_text : string -> bool

(** {1 Memory Check} *)

val memory_check_default_json : unit -> Yojson.Safe.t
