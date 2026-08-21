(** Exact current-schema Keeper meta JSON parser. *)

val meta_of_json :
  Yojson.Safe.t -> (Keeper_meta_contract.keeper_meta, string) result
(** Decode the exact top-level shape emitted by
    [Keeper_meta_json.meta_to_json]. The immediately preceding
    ["active_goal_ids"] field is accepted and discarded as a read-only
    migration tombstone; it never reaches the runtime record or writer.
    Missing, wrong-typed, other retired, duplicate, unknown, or malformed
    fields are explicit reset-required errors. Nullable domain fields still
    accept their current [`Null] representation. *)

(** One enumerated-field repair: [field] held [previous_value], which is not a
    canonical spelling of any variant, and is reset to [repaired_value]. *)
type enum_field_repair =
  { field : string
  ; previous_value : string
  ; repaired_value : string
  }

val repair_non_canonical_enum_fields :
  Yojson.Safe.t -> (Yojson.Safe.t * enum_field_repair list) option
(** [Some (repaired, repairs)] when [json] is an object carrying at least one
    enumerated field whose value fails the canonical round-trip and whose
    field is repairable (currently [last_proactive_outcome] and
    [multimodal_policy]); [repairs] describes every field that was reset.
    A recognized value repairs to its canonical spelling (the field parsers
    trim and lowercase, so ["DELEGATE"] becomes ["delegate"]); only an
    unrecognized value falls back to the field's canonical default.
    [None] when nothing repairable is present — the caller must keep failing
    loud with the original decode error.  Repair detection uses the same
    canonicality predicates as the decoder, never the error text. *)
