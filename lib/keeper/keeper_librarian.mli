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

(** Prompt variables for [keeper.librarian.episode_extraction]. *)
val prompt_variables : input -> (string * string) list

(** Structured parse failure for raw librarian output. *)
type parse_error =
  | Empty_output
  | Invalid_json of string
  | Json_string_invalid_json of string
  | Top_level_not_object
  | Missing_required_fields
  | Claim_schema_mismatch

val parse_error_to_string : parse_error -> string

(** Parse a raw strict-JSON LLM response into an episode.

    Accepted wire forms are deliberately narrow:
    - exact JSON object;
    - exact JSON string whose contents are a JSON object.

    Markdown fences, prose before/after JSON, multiple JSON objects, and schema
    drift return a structured [parse_error]. [now] is optional so tests can keep
    timestamps deterministic. *)
val episode_of_output_result
  :  ?now:float
  -> generation:int
  -> input
  -> string
  -> (Keeper_memory_os_types.episode, parse_error) result

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
