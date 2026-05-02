(** SafeAuto effect handler to prevent backtrace loss on discontinue.
    Ensures source path is attached to the effect payload before discontinuation. *)

type source_path = string

(** Exception raised when SafeAuto halts execution, including the source path for backtrace. *)
exception Safe_autonomy_halt of source_path * string

(** Runs a function within the SafeAuto effect handler, attaching the source path. *)
val with_safe_auto : source_path -> (unit -> 'a) -> 'a

(** Performs a Halt effect with the given source path and message. *)
val halt : source_path -> string -> unit

(** Invariant check for non-null source path. *)
val invariant_source_path_non_null : source_path -> unit
