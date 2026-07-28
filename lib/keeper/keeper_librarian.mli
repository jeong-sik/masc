(** Keeper_librarian — store-aware recognition extraction for the Memory OS.

    This module stays on the MASC side of the OAS boundary. It does not call
    providers or persist files; callers choose the message slice, read the
    fact-store snapshot, render the external prompt, call the LLM, and apply
    accepted operations via [Keeper_librarian_runtime].

    masc#26122: storage is recognition. The input carries the keeper's current
    fact store; the output is typed operations
    ({!Keeper_librarian_recognition.operation}), so whether something is
    already known is the model's judgment — never a programmable identity
    comparison. *)

(** Input bundle for one librarian recognition pass. *)
type input =
  { trace_id : string
  ; generation : int
  ; messages : Agent_sdk.Types.message list
  ; store : Keeper_memory_os_types.fact list
    (** The keeper's current facts, exactly as read before the LLM call.
        The prompt renders them 0-indexed; output operation indices refer to
        this snapshot. *)
  }

val wire_field_episode_summary : string
val wire_field_operations : string
val wire_field_op : string
val wire_field_fact : string
val wire_field_index : string
val wire_field_member_indices : string
val wire_field_reason : string
val wire_field_open_items : string
val wire_field_constraints : string
val wire_field_preserved_tool_refs : string
val wire_field_claim : string
val wire_field_category : string
val wire_field_source_turn : string
val wire_field_source_tool_call_id : string
val wire_field_claim_id : string
val wire_field_claim_kind : string
val wire_field_claim_kind_update : string

val wire_field_valid_for_days : string
(** Producer-declared lifetime in whole days (1..
    {!Keeper_memory_os_types.max_valid_for_days}); absent = durable. The
    extracting model's own judgment — categories never infer a validity
    horizon (RFC-0351 S2). *)

val wire_episode_fields : string list
(** Canonical output-object wire field names accepted by the parser and used
    by retry prompt rendering. *)

val wire_claim_fields : string list
(** Canonical claim-object wire field names (the [fact] payload of an [add]
    operation) accepted by the parser and used by retry prompt rendering. *)

val wire_operation_fields : string list
(** Canonical operation-object wire field names accepted by the parser. *)

(** Prompt variables for [keeper.librarian.episode_extraction]:
    [conversation_history] and [current_store]. *)
val prompt_variables : input -> (string * string) list

val visible_store_indices : input -> int list
(** Original snapshot indices included in this generation's bounded fact page.
    Output operations may reference only these indices. *)

(** Structured parse failure for raw librarian output. *)
type parse_error =
  | Empty_output
  | Invalid_json of string
  | Json_string_invalid_json of string
  | Top_level_not_object
  | Unexpected_field of string
  | Missing_required_fields
  | Claim_schema_mismatch
  | Operation_schema_mismatch of string

val parse_error_to_string : parse_error -> string

(** The librarian's full recognition output: the episode narrative plus the
    typed store operations. *)
type recognition_output =
  { episode_summary : string
  ; operations : Keeper_librarian_recognition.operation list
  ; open_items : string list
  ; constraints : string list
  ; preserved_tool_refs : string list
  }

val recognition_output_of_json_result
  :  ?now:float
  -> input
  -> Yojson.Safe.t
  -> (recognition_output, parse_error) result
(** Parse an already extracted provider-native JSON response. Accepted wire
    forms are deliberately narrow: exact JSON object with exactly the
    documented fields; any schema drift (unknown field, non-null foreign
    field on an operation, malformed op payload) is a structured
    [parse_error]. A provider-supplied [schema_version] field is ignored if
    present. [now] is optional so tests can keep timestamps deterministic. *)

val recognition_output_of_output_result
  :  ?now:float
  -> input
  -> string
  -> (recognition_output, parse_error) result
(** Like {!recognition_output_of_json_result} for a raw string response
    (exact JSON object, or exact JSON string wrapping one). *)

(** The persisted episode for one applied recognition pass: the librarian's
    narrative with the recognized (created/rewritten) rows as its claims. *)
val episode_of_recognition
  :  now:float
  -> generation:int
  -> input
  -> recognition_output
  -> recognized_facts:Keeper_memory_os_types.fact list
  -> source_turns:int list
  -> Keeper_memory_os_types.episode
