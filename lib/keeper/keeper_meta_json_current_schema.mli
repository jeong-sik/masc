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
(** Writer key set, derived from {!all_fields}. The writer emits every field. *)

val optional_field_names : string list
(** [usage_cursor] and [last_usage_resolution] are absent in exact v1
    snapshots and may be absent in v2; absence decodes like [null]. The
    decoder checks the version and rejects a v1 object carrying either key. *)

val required_field_names : string list
(** All current fields except {!optional_field_names}. *)

val find_duplicate : ('a * 'b) list -> 'a option
(** Return [Some key] for the first key that already occurred earlier in the
    association list, or [None] when every key is distinct. Callers decide how
    to report the duplicate. *)

val validate_current_object :
  Yojson.Safe.t -> ((string * Yojson.Safe.t) list, validation_error) result
(** Require every {!required_field_names} key and reject keys outside
    {!current_field_names}. Missing {!optional_field_names} keys are allowed;
    duplicates and unknown keys keep [Invalid_current] classification. *)
