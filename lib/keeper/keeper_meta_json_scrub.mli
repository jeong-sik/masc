(** Keeper meta JSON legacy scrub helpers.

    Lives below the codec/parser facade so persisted runtime JSON can
    be migrated before strict [keeper_meta] decoding. *)

(** Drop the named keys from a top-level JSON object; passes through
    non-objects unchanged. *)
val drop_assoc_keys : string list -> Yojson.Safe.t -> Yojson.Safe.t

(** Returns [Error msg] if any [removed_keeper_meta_key_names] is
    present at the top level (these have been deleted from the schema
    and must not appear). *)
val reject_removed_keeper_meta_fields :
  Yojson.Safe.t -> (unit, string) result

(** Legacy tool-policy keys that are scrubbed via
    [scrub_legacy_tool_policy_meta_json]. *)
val legacy_keeper_meta_tool_policy_key_names : string list

(** Combined legacy key names (allowed_providers + tool-policy keys). *)
val legacy_keeper_meta_key_names : string list

(** Returns [Error msg] if any legacy key is present without going
    through [read_meta_file_path] (which scrubs them). *)
val reject_legacy_keeper_meta_fields :
  Yojson.Safe.t -> (unit, string) result

(** True if the top-level [tool_access.kind] is a legacy variant
    ("restricted" / "unrestricted") that needs migration. *)
val legacy_tool_access_kind_needs_scrub : Yojson.Safe.t -> bool

(** Scrub legacy tool-policy keys, returning the new JSON and the list
    of rewrite reasons (key names + tool_access(defaulted/legacy-kind)
    pseudo-keys). Empty rewrite list means no change was needed. *)
val scrub_legacy_tool_policy_meta_json :
  Yojson.Safe.t -> Yojson.Safe.t * string list

(** [scrub_persisted_keeper_meta_json ~path json] migrates persisted
    keeper meta to the current schema (drops removed keys, rewrites
    legacy tool-policy, migrates presence_keepalive=false→paused=true)
    and writes the scrubbed content back to [path] when changes were
    needed. Returns the scrubbed JSON and a [bool] indicating whether
    the file was rewritten. *)
val scrub_persisted_keeper_meta_json :
  path:string -> Yojson.Safe.t -> Yojson.Safe.t * bool
