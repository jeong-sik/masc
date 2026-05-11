(** Atomic_orphan_size_class — closed sum for the [size_class] label on
    [metric_fs_atomic_orphans_cleaned].

    Replaces 2 hardcoded literals (`"empty"` / `"with_data"`) in
    [server_runtime_bootstrap.ml].  The two values disambiguate
    save_file_atomic orphan cleanups by whether the orphan contained
    recoverable data (#10130 recovery). *)

type t =
  | Empty (** Orphaned atomic save file with no content (safe to delete). *)
  | With_data (** Orphaned file held content; preserved under .recovered/. *)

val to_label : t -> string
