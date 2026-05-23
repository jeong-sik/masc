(** Docker bind-mount preflight validation.

    Deterministic filesystem checks before spawning a container:
    host_root must exist and be a directory; cwd must exist and be a
    directory.  Pure logic — no side effects. *)

type error =
  | Mount_source_not_found of string
  | Mount_source_not_directory of string
  | Cwd_not_found of string
  | Cwd_not_directory of string

let check ~host_root ~cwd =
  if not (path_exists host_root)
  then Error (Mount_source_not_found host_root)
  else if not (path_is_directory host_root)
  then Error (Mount_source_not_directory host_root)
  else if not (path_exists cwd)
  then Error (Cwd_not_found cwd)
  else if not (path_is_directory cwd)
  then Error (Cwd_not_directory cwd)
  else Ok ()
;;
