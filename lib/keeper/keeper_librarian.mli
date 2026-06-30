(** Keeper_librarian — structured claim extraction for the Memory OS.

    This module stays on the MASC side of the OAS boundary. It does not call
    providers or persist files; callers choose the message slice, render the
    external prompt, call the LLM, and store accepted episodes via
    [Keeper_memory_os_io]. *)

(** Input bundle for one librarian extraction. *)
type input =
  { trace_id : string
  ; generation : int
  ; messages : Agent_sdk.Types.message list
  }

val wire_field_episode_summary : string
val wire_field_claims : string
val wire_field_open_items : string
val wire_field_constraints : string
val wire_field_preserved_tool_refs : string
val wire_field_claim : string
val wire_field_category : string
val wire_field_source_turn : string
val wire_field_source_tool_call_id : string
val wire_field_claim_id : string
val wire_field_claim_kind : string

val wire_episode_fields : string list
(** Canonical episode-object wire field names accepted by the parser and used by
    retry prompt rendering. *)

val wire_claim_fields : string list
(** Canonical claim-object wire field names accepted by the parser and used by
    retry prompt rendering. *)

(** Prompt variables for [keeper.librarian.episode_extraction]. *)
val prompt_variables : input -> (string * string) list

(** Structured parse failure for raw librarian output. *)
type parse_error =
  | Empty_output
  | Invalid_json of string
  | Json_string_invalid_json of string
  | Top_level_not_object
  | Unexpected_field of string
  | Missing_required_fields
  | Claim_schema_mismatch

val parse_error_to_string : parse_error -> string

(** Parse a raw strict-JSON LLM response into an episode.

    Accepted wire forms are deliberately narrow:
    - exact JSON object;
    - exact JSON string whose contents are a JSON object.

    Markdown fences, prose before/after JSON, multiple JSON objects, and schema
    drift return a structured [parse_error]. A provider-supplied
    [schema_version] field is ignored if present; persisted episodes always use
    {!Keeper_memory_os_types.schema_version}. [now] is optional so tests can
    keep timestamps deterministic. *)
val episode_of_output_result
  :  ?now:float
  -> generation:int
  -> input
  -> string
  -> (Keeper_memory_os_types.episode, parse_error) result

val episode_of_json_result
  :  ?now:float
  -> generation:int
  -> input
  -> Yojson.Safe.t
  -> (Keeper_memory_os_types.episode, parse_error) result
(** Parse an already extracted provider-native JSON response into an episode.
    This is the runtime path used after OAS structured response extraction. *)

(** Parse a raw strict-JSON LLM response into an episode.

    Compatibility wrapper over {!episode_of_output_result}; [None] means the
    response was not JSON or violated the extraction schema. *)
val episode_of_output
  :  ?now:float
  -> generation:int
  -> input
  -> string
  -> Keeper_memory_os_types.episode option

(** Scrub private runtime markers from messages before prompt rendering. *)
val scrub_messages_for_librarian
  :  Agent_sdk.Types.message list
  -> Agent_sdk.Types.message list
