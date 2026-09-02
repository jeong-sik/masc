(** Exact Keeper meta current-schema contract. *)

type validation_error = Invalid_current of string

val validation_error_detail : validation_error -> string

type field =
  | Schema
  | Name
  | Instructions
  | Trace_id
  | Trace_history
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
  | Usage_cursor
  | Last_usage_resolution
  | Last_latency_ms
  | Proactive_count_total
  | Last_proactive_ts
  | Proactive_visible_count_total
  | Last_visible_proactive_ts
  | Last_proactive_outcome
  | Last_proactive_reason
  | Last_proactive_preview
  | Message_scope_ack_id
  | Last_runtime_attempt
  | Paused
  | Latched_reason
  | Current_task_id
  | Keeper_id
  | Agent_core_env

val all_fields : field list
val field_name : field -> string

val object_of_field_values :
  (field * Yojson.Safe.t) list -> Yojson.Safe.t
(** Construct one canonical current object. The supplied field sequence must be
    exactly {!all_fields}; a writer cannot silently add, omit, duplicate, or
    reorder a persisted field independently of the reader's key authority. *)

val current_field_names : string list
(** Derived from {!all_fields}; never maintained as a separate string list. *)

val find_duplicate : ('a * 'b) list -> 'a option
(** Return [Some key] for the first key that already occurred earlier in the
    association list, or [None] when every key is distinct. Callers decide how
    to report the duplicate. *)

val validate_current_object :
  Yojson.Safe.t -> ((string * Yojson.Safe.t) list, validation_error) result
(** Require exactly the current top-level key set. Every field outside that set
    has the same [Invalid_current] classification. *)
