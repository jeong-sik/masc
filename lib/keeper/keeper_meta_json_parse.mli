(** Exact current-schema Keeper meta JSON parser. *)

val meta_of_json :
  Yojson.Safe.t -> (Keeper_meta_contract.keeper_meta, string) result
(** Decode current v2 metadata and the exact pre-#32435 v1 shape. The v2
    writer emits every key. A v1 snapshot must omit [usage_cursor] and
    [last_usage_resolution]; v2 may omit them too. Absence decodes as [None],
    like [`Null], so the next resumed conversation re-baselines its cursor
    without charging the whole counter. Present malformed usage fields and
    missing required, duplicate, unknown, or malformed fields remain explicit
    reset-required errors. The writer still emits only v2. *)

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
    field is repairable (currently [last_proactive_outcome]); [repairs]
    describes every field that was reset. A recognized value repairs to its
    canonical spelling (the field parsers trim and lowercase, so ["SILENT"]
    becomes ["silent"]); only an unrecognized value falls back to the field's
    canonical default.
    [None] when nothing repairable is present — the caller must keep failing
    loud with the original decode error.  Repair detection uses the same
    canonicality predicates as the decoder, never the error text. *)
