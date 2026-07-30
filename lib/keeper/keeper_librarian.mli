(** Keeper_librarian — structured claim extraction for the Memory OS.

    This module stays on the MASC side of the OAS boundary. It does not call
    providers or persist files; callers choose the message slice, render the
    external prompt, call the LLM, and store accepted episodes via
    [Keeper_memory_os_io]. *)

(** Input bundle for one librarian extraction. *)
type input =
  { trace_id : string
  ; messages : Agent_sdk.Types.message list
  }

val wire_field_episode_summary : string
val wire_field_claims : string
val wire_field_claim : string
val wire_field_category : string
val wire_field_source_turn : string
val wire_field_source_tool_call_id : string
val wire_field_claim_id : string

val wire_episode_fields : string list
(** Canonical episode-object wire field names accepted by the parser and used by
    retry prompt rendering. *)

val wire_claim_fields : string list
(** Canonical claim-object wire field names accepted by the parser and used by
    retry prompt rendering. *)

(** Prompt variables for [keeper.librarian.episode_extraction]. *)
val prompt_variables : input -> (string * string) list

(** Structured parse failure for provider-native librarian JSON. *)
type parse_error =
  | Top_level_not_object
  | Unexpected_field of string
  | Missing_required_fields
  | Claim_schema_mismatch

val parse_error_to_string : parse_error -> string

val episode_of_json_result
  :  ?now:float
  -> generation:int
  -> input
  -> Yojson.Safe.t
  -> (Keeper_memory_os_types.episode, parse_error) result
(** Parse an already extracted provider-native JSON response into an episode.
    This is the sole runtime boundary after OAS structured response extraction.
    The object and every claim are current-only closed shapes; schema drift,
    missing fields, and invalid provenance return a structured [parse_error].
    [now] is optional so tests can keep timestamps deterministic. *)
