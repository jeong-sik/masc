(** Redirect_scope — closed variant for I/O redirection.

    heredoc, here-string, process substitution, and [&>] bash-isms are
    excluded from the subset and surface as [Parsed.Too_complex]. *)

type mode = Read | Write | Append

(** Which filesystem a redirect target names.

    A command inside a container writes paths as the container sees them, and
    this process cannot open those. Only a layer that knows the sandbox's
    mounts can turn one into a path here, so the result of that translation is
    a different value rather than the same value with a promise attached. *)
type target =
  | In_command_namespace of Path_scope.t
      (** the path as the command sees it. Running on this host that is this
          filesystem; running in a container it is not. *)
  | On_this_host of {
      path : string;
      as_written : Path_scope.t;
    }
      (** already resolved to this process's filesystem. [as_written] is kept
          so rendering still shows what the caller asked for. *)

type t =
  | File of { fd : int; target : target; mode : mode }
  | Fd_to_fd of { src : int; dst : int }

val on_this_host : Path_scope.t -> string -> target
(** [on_this_host as_written path] marks [path] as openable here. *)

val target_as_written : target -> Path_scope.t
(** The path the caller wrote, whichever namespace it names. *)

val pp : Format.formatter -> t -> unit
