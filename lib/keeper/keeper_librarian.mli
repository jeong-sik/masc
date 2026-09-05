(** Pure prompt and output contract for LLM-owned current Memory OS selection.

    The Librarian receives the exact current selection plus a bounded slice of
    new conversation. It returns existing fact identities to retain and new
    facts to add. Every existing identity must be retained or explicitly
    dropped. The LLM owns selection within the rendered-fact byte budget; no
    deterministic ranking, recency rule, or migration path participates.

    Wire identities are short surrogate tokens ([m1], [m2], ... in
    current-fact order), not the cryptographic [memory_id]: a 64-hex digest
    cannot be echoed verbatim reliably, and stale digests linger in
    conversation-history recall renderings. The parser maps surrogates back to
    real identities before validation, so [selection] always carries real
    identities and unknown tokens stay fail-closed. *)

type current_selection =
  { facts : Keeper_memory_os_types.fact list }

type tool_observation_outcome =
  | Succeeded
  | Failed
  | Unknown

type tool_observation =
  { tool_name : string
  ; outcome : tool_observation_outcome
  }
(** Host-authored current-turn tool evidence. Tool payloads stay excluded from
    the Librarian prompt; this says only which tool completed and its typed
    execution outcome. [Unknown] remains explicit rather than being treated as
    evidence of either success or failure. *)

type input =
  { turn_ref : Ids.Turn_ref.t
  ; keeper_instructions : string
    (** The same instructions the keeper's own system prompt carries.
        The librarian curates on the keeper's behalf, so it judges
        importance through this identity; [""] renders as an explicit
        [no keeper instructions] marker. *)
  ; current : current_selection option
  ; messages : Agent_core.Types.message list
  ; tool_observations : tool_observation list
  ; counterpart_observations : Keeper_counterpart_observation.t list
    (** Host-authored speaker provenance plus untrusted current-turn content.
        This covers connector attention outside the AGENT_CORE checkpoint and
        direct turns on runtimes that return no AGENT_CORE checkpoint. *)
  }

(** A new claim that continues a dropped memory, both by exact memory id.
    The librarian named the old one with [supersedes]; the parser checked
    that it exists and is in [dropped]. Recorded as a [Revised] event on the
    old id after the snapshot commits (RFC-0418). *)
type revision =
  { superseded : string
  ; superseded_by : string
  }

type selection =
  { retained_memory_ids : string list
  ; new_claims : Keeper_memory_os_types.fact list
  ; dropped : Keeper_memory_os_types.dropped_statement list
    (** One statement per dropped current memory. Totality is enforced:
        every current identity appears in [retained_memory_ids] or here,
        so [Missing_disposition] replaces silent forgetting. *)
  ; facts : Keeper_memory_os_types.fact list
  ; revisions : revision list
  }

val wire_field_retained_memory_ids : string
val wire_field_new_claims : string
val wire_field_dropped : string
val wire_field_claim : string
val wire_field_category : string
val wire_field_memory_id : string
val wire_field_reason : string
val wire_field_supersedes : string
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
  | Supersedes_unknown_memory_id of string
      (** [supersedes] named a short id the answer's current set does not have. *)
  | Supersedes_not_dropped of string
      (** [supersedes] named a memory that is retained in the same answer; a
          revision drops what it continues. *)

val parse_error_to_string : parse_error -> string

val selection_of_json_result
  :  ?now:float
  -> input
  -> Yojson.Safe.t
  -> (selection, parse_error) result
