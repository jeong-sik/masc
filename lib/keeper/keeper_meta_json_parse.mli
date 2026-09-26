(** Exact current-schema Keeper meta JSON parser. *)

(** A decoded current meta together with the retired keys
    ({!Keeper_meta_json_current_schema.retired_field}) the file carried and the
    decoder dropped. *)
type decoded_current_meta =
  { decoded_meta : Keeper_meta_contract.keeper_meta
  ; retired_fields : Keeper_meta_json_current_schema.retired_field list
  }

val decode_current_meta_json :
  Yojson.Safe.t -> (decoded_current_meta, string) result
(** Decode the exact top-level shape emitted by
    [Keeper_meta_json.meta_to_json]. The retired keys are dropped and reported
    in [retired_fields] for this one release (#39200); missing, wrong-typed,
    duplicate, unknown, or malformed fields are explicit reset-required errors.
    Nullable domain fields still accept their current [`Null] representation.
    A reader that knows the file path reports the dropped keys. *)

val meta_of_json :
  Yojson.Safe.t -> (Keeper_meta_contract.keeper_meta, string) result
(** {!decode_current_meta_json} without the dropped-key report, for readers of
    JSON this binary serialized itself. *)

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
