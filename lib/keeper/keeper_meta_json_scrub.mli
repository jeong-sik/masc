(** Keeper meta JSON scrub helpers.

    Lives below the codec/parser facade so persisted runtime JSON cleanup code
    can share the same TOML-owned field names without introducing a module
    cycle. *)

(** Config field names owned by TOML only — never written to JSON.
    Defined here to avoid module cycles; re-exported by
    [Keeper_meta_json] via [include Keeper_meta_json_scrub]. *)
val config_field_names : string list

(** Drop the named keys from a top-level JSON object; passes through
    non-objects unchanged. *)
val drop_assoc_keys : string list -> Yojson.Safe.t -> Yojson.Safe.t

(** [scrub_persisted_keeper_meta_json ~path json] removes TOML-owned
    config fields from persisted keeper meta and writes the scrubbed
    content back to [path] when changes were needed. Returns the scrubbed
    JSON and a [bool] indicating whether the file was rewritten. *)
val scrub_persisted_keeper_meta_json :
  path:string -> Yojson.Safe.t -> Yojson.Safe.t * bool
