(** Canonical filename grammar shared by atomic-temp writers and recovery.
    This module performs no filesystem operations. *)

val prefix : string
val suffix : string

(** [is_name name] recognizes the [.atomic_*.tmp] basename shape, including
    an empty middle component. It does not inspect the entry or establish
    ownership, age, or whether a writer is using it. *)
val is_name : string -> bool
