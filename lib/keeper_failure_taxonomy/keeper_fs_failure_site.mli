(** Filesystem runtime failure-site labels.

    Replaces hardcoded literals in the filesystem runtime.  Each value names
    a distinct failure path in keeper-side filesystem helpers. *)

type t =
  | Ensure_dir_cancelled (** mkdir-p path was cancelled mid-flight. *)
  | Ensure_dir_failed (** mkdir-p raised a non-cancellation exception. *)
  | Save_atomic_failed (** Atomic save returned Error (write/rename/fsync failed). *)
  | Save_atomic_raised (** Atomic save raised an unexpected exception. *)

val to_label : t -> string
