(** Exact Keeper meta current-schema contract. *)

type validation_error = Invalid_current of string

val validation_error_detail : validation_error -> string

type field =
  | Name
  | Agent_name
  | Persona
  | Instructions
  | Trace_id
  | Multimodal_policy
  | Trace_history
  | Generation
  | Last_handoff_ts
  | Created_at
  | Updated_at
  | Total_turns
  | Total_input_tokens
  | Total_output_tokens
  | Total_tokens
  | Total_cost_usd
  | Last_turn_ts
  | Last_input_tokens
  | Last_output_tokens
  | Last_total_tokens
  | Last_latency_ms
  | Compaction_count
  | Last_compaction_ts
  | Last_compaction_before_tokens
  | Last_compaction_after_tokens
  | Proactive_count_total
  | Last_proactive_ts
  | Proactive_visible_count_total
  | Last_visible_proactive_ts
  | Last_proactive_outcome
  | Last_proactive_reason
  | Last_proactive_preview
  | Consecutive_noop_count
  | Last_consumed_backlog_revision
  | Last_consumed_backlog_projection_sha256
  | Last_compaction_check_ts
  | Last_compaction_decision
  | Active_goal_ids
  | Last_autonomous_action_at
  | Autonomous_action_count
  | Autonomous_turn_count
  | Autonomous_text_turn_count
  | Autonomous_tool_turn_count
  | Board_reactive_turn_count
  | Mention_reactive_turn_count
  | Noop_turn_count
  | Message_scope_ack_id
  | Last_blocker
  | Last_runtime_attempt
  | Paused
  | Latched_reason
  | Current_task_id
  | Keeper_id
  | Oas_env
  | Meta_version

val all_fields : field list
val field_name : field -> string

val object_of_field_values :
  (field * Yojson.Safe.t) list -> Yojson.Safe.t
(** Construct one canonical current object. The supplied field sequence must be
    exactly {!all_fields}; a writer cannot silently add, omit, duplicate, or
    reorder a persisted field independently of the reader's key authority. *)

val current_field_names : string list
(** Derived from {!all_fields}; never maintained as a separate string list. *)

val validate_current_object :
  Yojson.Safe.t -> ((string * Yojson.Safe.t) list, validation_error) result
(** Require exactly the current top-level key set. Every field outside that set
    has the same [Invalid_current] classification. One exception: the
    RFC-0357 §3.3 genesis pair — [last_consumed_backlog_revision] and
    [last_consumed_backlog_projection_sha256] — may be ABSENT together (live
    metas predate it) and decodes as revision 0 with an empty projection
    digest; a PRESENT malformed value and half-genesis states still fail.
    Issue #26697 retires the exception once every live meta carries the
    pair. *)
