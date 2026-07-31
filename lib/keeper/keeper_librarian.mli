(** Pure prompt and output contract for LLM-owned current Memory OS selection.

    The Librarian receives the exact current selection plus a bounded slice of
    new conversation. It returns existing fact identities to retain and new
    facts to add. Omitting an existing identity removes that memory. No
    deterministic ranking, recency rule, byte budget, or migration path
    participates. *)

type current_selection =
  { facts : Keeper_memory_os_types.fact list }

type input =
  { turn_ref : Ids.Turn_ref.t
  ; generation : int
  ; persona : string
    (** The same resolved persona text the keeper's own system prompt
        carries ([Keeper_types_profile.load_resolved_persona_extended]).
        The librarian curates on the keeper's behalf, so it judges
        importance through this identity; [""] renders as an explicit
        [no persona] marker. *)
  ; current : current_selection option
  ; messages : Agent_sdk.Types.message list
  }

type selection =
  { retained_memory_ids : string list
  ; new_claims : Keeper_memory_os_types.fact list
  ; facts : Keeper_memory_os_types.fact list
  }

val wire_field_retained_memory_ids : string
val wire_field_new_claims : string
val wire_field_claim : string
val wire_field_category : string
val wire_current_fields : string list
val wire_claim_fields : string list

val prompt_variables : input -> (string * string) list

type parse_error =
  | Top_level_not_object
  | Unexpected_field of string
  | Duplicate_field of string
  | Missing_required_fields
  | Claim_schema_mismatch
  | Unknown_retained_memory_id of string
  | Duplicate_retained_memory_id of string
  | Duplicate_selected_memory_id of string

val parse_error_to_string : parse_error -> string

val selection_of_json_result
  :  ?now:float
  -> input
  -> Yojson.Safe.t
  -> (selection, parse_error) result
