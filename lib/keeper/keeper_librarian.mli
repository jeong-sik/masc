(** Pure prompt and output contract for LLM-owned current Memory OS selection.

    The Librarian receives the exact current selection plus a bounded slice of
    new conversation. It answers with what changes: the identities to retire,
    with a reason each, and the new facts to add. A current identity it does
    not name stays. The LLM owns selection; no deterministic ranking, recency
    rule, or migration path participates.

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

type goal_context =
  | No_task
  | Task_goals of
      { task_id : string
      ; criteria : ((string * Goal_phase.t * Goal_store.criterion) list, string) result
      }

type input =
  { turn_ref : Ids.Turn_ref.t
  ; goal_context : goal_context
  ; keeper_instructions : string
    (** The same instructions the keeper's own system prompt carries.
        The librarian curates on the keeper's behalf, so it judges
        importance through this identity; [""] renders as an explicit
        [no keeper instructions] marker. *)
  ; current : current_selection option
  ; working_context : Keeper_librarian_context.input
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
  { new_claims : Keeper_memory_os_types.fact list
    (** The memories the answer adds. A claim that writes a current memory
        again as it stands adds nothing and is not here; two claims with the
        same text are one. *)
  ; dropped : Keeper_memory_os_types.dropped_statement list
    (** One statement per retired memory. The librarian names only what
        changes; a current memory it does not name here stays, which is what
        the apply step has always done. The whole-set roll call this answer
        used to carry was checked and then discarded, and one slip in it threw
        away the pass (RFC-0456). *)
  ; absorbed : Keeper_memory_os_types.absorbed_statement list
    (** One statement per current memory a new claim names in [absorbs]
        (RFC-0456 §4.2). Each is current, in no [dropped] statement, and
        absorbed by one claim only; [into] is that claim's identity, which is
        the current memory itself when the claim restated one. *)
  ; facts : Keeper_memory_os_types.fact list
  ; revisions : revision list
  ; working_state : string option
  ; working_contexts : Keeper_librarian_context.pocket list
  }

val wire_field_new_claims : string
val wire_field_dropped : string
val wire_field_claim : string
val wire_field_category : string
val wire_field_memory_id : string
val wire_field_reason : string
val wire_field_supersedes : string
val wire_field_absorbs : string
val wire_current_fields : string list
val wire_claim_fields : string list
val wire_dropped_fields : string list

val goal_context_to_json : goal_context -> Yojson.Safe.t

val prompt_variables : input -> (string * string) list

type parse_error =
  | Top_level_not_object
  | Working_context_invalid of string
  | Working_state_invalid of string
  | Unexpected_field of string
  | Duplicate_field of string
  | Missing_required_fields
  | Claim_schema_mismatch
  | Dropped_schema_mismatch
  | Dropped_memory_id_recreated of string
      (** A claim's text is a memory the same answer drops, directly or as the
          target of its own [supersedes]: the answer says both "gone" and
          "kept". A claim that writes a kept current memory again as it stands
          is that memory unchanged, not this error. *)
  | Absorbed_memory_id_restated of string
      (** A claim's text is a memory another claim of the same answer absorbs. *)
  | Unknown_dropped_memory_id of string
  | Duplicate_dropped_memory_id of string
  | Supersedes_unknown_memory_id of string
      (** [supersedes] named a short id the answer's current set does not have. *)
  | Supersedes_not_dropped of string
      (** [supersedes] named a memory that is retained in the same answer; a
          revision drops what it continues. *)
  | Absorbs_unknown_memory_id of string
      (** [absorbs] named a short id the answer's current set does not have. *)
  | Absorbs_dropped_memory_id of string
      (** [absorbs] named a memory the same answer drops: a dropped memory is
          gone, not said by the new claim. *)
  | Absorbs_memory_id_twice of string
      (** Two [absorbs] lists, or one list twice, named the same memory. *)

val parse_error_to_string : parse_error -> string

val selection_of_json_result
  :  ?now:float
  -> input
  -> Yojson.Safe.t
  -> (selection, parse_error) result
