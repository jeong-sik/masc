(** Keeper meta JSON codec facade.

    Included by [Keeper_types] so existing [Keeper_types.*] callers
    keep their public API while scrubbing, parsing, and serialization
    stay in smaller private modules. *)

include module type of Keeper_meta_json_scrub

include module type of Keeper_meta_json_parse

(** Serialize a [keeper_meta] record to JSON. Centralizes the write
    side of the personality-fields contract (Layer 2 PR-B,
    Keeper_personality_io.to_json) so that round-trip symmetry with
    [meta_of_json] is preserved (#10479 PR-A drift fix). *)
val meta_to_json : Keeper_meta_contract.keeper_meta -> Yojson.Safe.t

(** Canonical key list, used as fallback if dynamic seed-based key
    extraction fails. ~95 keys covering identity, intent, social
    state, runtime telemetry, proactive/work-discovery surfaces. *)
val fallback_canonical_keeper_meta_key_names : string list

(** Canonical key list, computed at startup by serializing a seed
    keeper_meta and extracting field names. Falls back to
    [fallback_canonical_keeper_meta_key_names] if serialization fails. *)
val canonical_keeper_meta_key_names : string list

(** Log a warning for any top-level keys in [json] that aren't in the
    canonical key list — catches schema drift early. *)
val warn_unknown_keeper_meta_keys :
  path:string -> Yojson.Safe.t -> unit
