(** Keeper meta JSON codec facade. *)

include module type of Keeper_meta_json_current_schema

include module type of Keeper_meta_json_parse

(** Serialize a [keeper_meta] record to JSON. Centralizes the write
    side of the personality-fields contract (Layer 2 PR-B,
    Keeper_personality_io.to_json) so that round-trip symmetry with
    [meta_of_json] is preserved (#10479 PR-A drift fix). *)
val meta_to_json : Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

(** Canonical key list shared by the exact current reader and writer. *)
val canonical_keeper_meta_key_names : string list
