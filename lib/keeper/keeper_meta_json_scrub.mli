(** Keeper meta JSON removed-field guards.

    Lives below the codec/parser facade so persisted runtime JSON can
    be rejected before strict [keeper_meta] decoding. *)

(** Config field names owned by TOML only — never written to JSON.
    Defined here to avoid module cycles; re-exported by
    [Keeper_meta_json] via [include Keeper_meta_json_scrub]. *)
val config_field_names : string list

(** Returns [Error msg] if any [removed_keeper_meta_key_names] is
    present at the top level (these have been deleted from the schema
    and must not appear). *)
val reject_removed_keeper_meta_fields :
  Yojson.Safe.t -> (unit, string) result

(** Removed tool-policy keys that are no longer supported. *)
val rejected_keeper_meta_tool_policy_key_names : string list

(** Combined removed key names that remain rejected by strict runtime
    meta decoding. *)
val strict_rejected_keeper_meta_key_names : string list

(** Returns [Error msg] if any strictly rejected key is present. *)
val reject_strict_keeper_meta_fields :
  Yojson.Safe.t -> (unit, string) result

(** Returns [Error msg] if TOML-owned config fields are present in
    persisted runtime JSON. *)
val reject_config_keeper_meta_fields :
  Yojson.Safe.t -> (unit, string) result
