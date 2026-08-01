(** Pure prompt and output contract for LLM-owned current Memory OS selection.

    The Librarian receives the exact current selection plus a bounded slice of
    new conversation. It returns existing fact identities to retain and new
    facts to add. Every existing identity must be retained or explicitly
    dropped. The LLM owns selection within the rendered-fact byte budget; no
    deterministic ranking, recency rule, or migration path participates. *)

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
  ; max_recall_fact_bytes : int
    (** Maximum UTF-8 bytes for the exact rendered fact lines. The prompt states
        this capacity and the parser rejects an oversized selection. *)
  ; messages : Agent_sdk.Types.message list
  }

type selection =
  { retained_memory_ids : string list
  ; new_claims : Keeper_memory_os_types.fact list
  ; dropped : Keeper_memory_os_types.dropped_statement list
    (** One statement per dropped current memory. Totality is enforced:
        every current identity appears in [retained_memory_ids] or here,
        so [Missing_disposition] replaces silent forgetting. *)
  ; facts : Keeper_memory_os_types.fact list
  }

val wire_field_retained_memory_ids : string
val wire_field_new_claims : string
val wire_field_dropped : string
val wire_field_claim : string
val wire_field_category : string
val wire_field_memory_id : string
val wire_field_reason : string
val wire_current_fields : string list
val wire_claim_fields : string list
val wire_dropped_fields : string list

val prompt_variables : input -> (string * string) list

type parse_error =
  | Top_level_not_object
  | Unexpected_field of string
  | Duplicate_field of string
  | Missing_required_fields
  | Claim_schema_mismatch
  | Dropped_schema_mismatch
  | Unknown_retained_memory_id of string
  | Duplicate_retained_memory_id of string
  | Duplicate_selected_memory_id of string
  | Unknown_dropped_memory_id of string
  | Duplicate_dropped_memory_id of string
  | Dropped_memory_id_also_retained of string
  | Missing_disposition of string
  | Recall_fact_budget_exceeded of
      { actual_bytes : int
      ; max_bytes : int
      }

val parse_error_to_string : parse_error -> string

val selection_of_json_result
  :  ?now:float
  -> input
  -> Yojson.Safe.t
  -> (selection, parse_error) result
