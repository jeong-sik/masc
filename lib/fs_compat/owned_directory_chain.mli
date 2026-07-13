(** No-follow inspection of a directory path below a canonical ownership root.

    The caller owns the inspected subtree for the duration of the operation.
    OCaml 5.4 does not expose portable dirfd-relative traversal, so this module
    centralizes the lexical containment and [lstat] checks used by durable
    writes and recovery sweeps. *)

type rejection =
  | Owned_path_outside_root of
      { ownership_root : string
      ; path : string
      }
  | Owned_path_non_directory of
      { path : string
      ; kind : Unix.file_kind
      }

type observation =
  | Owned_directory_missing
  | Owned_directory of Unix.stats

val rejection_to_string : rejection -> string

val paths
  :  ownership_root:string
  -> string
  -> (string list, rejection) result
(** Return the ordered descendant paths from [ownership_root] to the target,
    excluding the root itself. This is lexical only and performs no I/O. *)

val inspect
  :  ownership_root:string
  -> string
  -> (observation, rejection) result
(** [inspect ~ownership_root path] walks from [ownership_root] through [path]
    without following symbolic links. Both arguments must be absolute and
    [path] must be lexically contained by [ownership_root]. A missing component
    returns [Owned_directory_missing]; non-[ENOENT] filesystem failures are
    raised. *)
