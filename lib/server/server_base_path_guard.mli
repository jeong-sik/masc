(** Shared startup guard for server runtime base paths. *)

type canonicalization_error =
  { base_path : string
  ; cause : exn
  ; backtrace : Printexc.raw_backtrace
  }

val startup_root :
  cli_base_path:string option -> (Workspace_root.t, Workspace_root.error) result
(** The workspace a server runtime owns, in {!Workspace_root}'s order. A
    current directory is accepted only when it holds [.masc/config]; with no
    flag, variable, workspace cwd or usable record the answer is
    [No_workspace]. *)

val exit_on_no_workspace :
  (Workspace_root.t, Workspace_root.error) result -> Workspace_root.t
(** Print {!Workspace_root.error_message} and exit 1 on [No_workspace]. *)

val canonicalize_existing :
  string -> (string, canonicalization_error) result
(** Resolve an already-created workspace root to the immutable owner identity
    used by locks, configuration, backends, and runtime state. Cancellation is
    never converted to an error. *)

val format_canonicalization_error : canonicalization_error -> string
