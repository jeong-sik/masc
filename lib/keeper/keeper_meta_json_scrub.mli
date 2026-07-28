(** Keeper meta JSON scrub helpers.

    Lives below the codec/parser facade so persisted runtime JSON cleanup code
    can share the same TOML-owned field names without introducing a module
    cycle. *)

(** Config field names owned by TOML only — never written to JSON.
    Defined here to avoid module cycles; re-exported by
    [Keeper_meta_json] via [include Keeper_meta_json_scrub]. *)

(** Drop the named keys from a top-level JSON object; passes through
    non-objects unchanged. *)
