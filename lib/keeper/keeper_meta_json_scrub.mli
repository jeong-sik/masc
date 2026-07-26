(** Keeper meta current-schema key contract.

    The historical module path is retained, but persisted JSON is never scrubbed,
    rewritten, imported, or migrated. *)

val current_field_names : string list
(** Exact top-level keys emitted by the current writer. *)

val toml_only_field_names : string list
(** Configuration keys that are valid only in keeper TOML. Their presence in
    persisted keeper JSON is a retired-schema error. *)

val retired_field_names : string list
(** Closed set of known retired persisted keys. *)

val validate_current_object :
  Yojson.Safe.t -> ((string * Yojson.Safe.t) list, string) result
(** Require exactly the current top-level key set. Duplicate, missing, retired,
    unknown, and non-object inputs are explicit reset-required errors. *)
