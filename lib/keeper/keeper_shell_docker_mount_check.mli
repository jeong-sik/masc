(** Docker bind-mount preflight validation.

    Deterministic filesystem checks before spawning a container:
    host_root must exist and be a directory; cwd must exist and be a
    directory.  Pure logic — no side effects. *)

type error =
  | Mount_source_not_found of string
  | Mount_source_not_directory of string
  | Cwd_not_found of string
  | Cwd_not_directory of string

val check : host_root:string -> cwd:string -> (unit, error) result
