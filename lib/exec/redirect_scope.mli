(** Redirect_scope — closed variant for I/O redirection.

    heredoc, here-string, process substitution, and [&>] bash-isms are
    excluded from the subset and surface as [Parsed.Too_complex]. *)

type mode =
  | Read
  | Write
  | Append

type t =
  | File of
      { fd : int
      ; target : Path_scope.t
      ; mode : mode
      }
  | Fd_to_fd of
      { src : int
      ; dst : int
      }

val pp : Format.formatter -> t -> unit
