(** Pure prompt and output contract for LLM-owned current Memory OS selection.

    The Librarian receives the exact current facts plus a bounded slice of new
    conversation. It returns existing fact identities to retain and new facts
    to add. Omitting an existing identity removes that memory. No deterministic
    ranking, recency rule, byte budget, or migration path participates. *)

type input =
  { trace_id : string
  ; generation : int
  ; current_facts : Keeper_memory_os_types.fact list
  ; messages : Agent_sdk.Types.message list
  }

type selection =
  { summary : string
  ; retained_claim_ids : string list
  ; new_claims : Keeper_memory_os_types.fact list
  ; facts : Keeper_memory_os_types.fact list
  ; open_items : string list
  ; constraints : string list
  ; preserved_tool_refs : string list
  }

val wire_field_summary : string
val wire_field_retained_claim_ids : string
val wire_field_new_claims : string
val wire_field_open_items : string
val wire_field_constraints : string
val wire_field_preserved_tool_refs : string
val wire_field_claim : string
val wire_field_category : string
val wire_field_source_turn : string
val wire_field_source_tool_call_id : string
val wire_field_claim_id : string
val wire_field_claim_kind : string
val wire_field_valid_for_days : string
val wire_current_fields : string list
val wire_claim_fields : string list

val prompt_variables : input -> (string * string) list

type parse_error =
  | Empty_output
  | Invalid_json of string
  | Json_string_invalid_json of string
  | Top_level_not_object
  | Unexpected_field of string
  | Missing_required_fields
  | Claim_schema_mismatch
  | Unknown_retained_claim_id of string
  | Duplicate_retained_claim_id of string
  | Duplicate_selected_claim_id of string

val parse_error_to_string : parse_error -> string

val selection_of_json_result
  :  ?now:float
  -> input
  -> Yojson.Safe.t
  -> (selection, parse_error) result

val selection_of_output_result
  :  ?now:float
  -> input
  -> string
  -> (selection, parse_error) result
