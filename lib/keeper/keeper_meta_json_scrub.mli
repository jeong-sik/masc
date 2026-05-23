(** Keeper meta JSON removed-field scrub helpers.

    Lives below the codec/parser facade so persisted runtime JSON can
    be normalized before strict [keeper_meta] decoding. *)

(** Drop the named keys from a top-level JSON object; passes through
    non-objects unchanged. *)
val drop_assoc_keys : string list -> Yojson.Safe.t -> Yojson.Safe.t

(** Returns [Error msg] if any [removed_keeper_meta_key_names] is
    present at the top level (these have been deleted from the schema
    and must not appear). *)
val reject_removed_keeper_meta_fields :
  Yojson.Safe.t -> (unit, string) result

(** Legacy tool-policy keys that are no longer supported. *)
val legacy_keeper_meta_tool_policy_key_names : string list

(** Combined legacy key names (allowed_providers + tool-policy keys). *)
val legacy_keeper_meta_key_names : string list

(** Returns [Error msg] if any legacy key is present. *)
val reject_legacy_keeper_meta_fields :
  Yojson.Safe.t -> (unit, string) result

(** [scrub_persisted_keeper_meta_json ~path json] migrates persisted
    keeper meta to the current schema for removed non-tool fields
    (including presence_keepalive=false→paused=true) and writes the
    scrubbed content back to [path] when changes were needed. Legacy
    tool policy fields are intentionally not rewritten. Returns the
    scrubbed JSON and a [bool] indicating whether the file was
    rewritten. *)
val scrub_persisted_keeper_meta_json :
  path:string -> Yojson.Safe.t -> Yojson.Safe.t * bool
