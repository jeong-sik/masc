(** Startup removal of retained continuations no semantic execution names.

    A retained continuation ([<session>/accepted-checkpoints/<sha256>.json],
    written by {!Keeper_checkpoint_store.retain_exact_snapshot}) is read only
    through an unsettled semantic execution that names it
    ({!Keeper_semantic_execution.checkpoint_references}). A settled execution
    names none, so a file that no unsettled execution names is never read
    again.

    The file is written before the execution naming it commits. The pass is
    therefore run only by the server process that holds the BasePath writer
    lease, before its scheduler starts and before any keeper runs, when no
    retention can be in flight. *)

type report =
  { live_references : int  (** distinct checkpoints named by unsettled executions *)
  ; removed : int
  ; removed_bytes : int
  ; failures : string list  (** files that could not be removed, with the cause *)
  }

type error =
  | Store_unreadable of { path : string; detail : string }
      (** A keeper's operation store could not be read, so the live set is
          unknown and nothing was removed. *)

val error_to_string : error -> string

(** [run ~runtime_root] reads every keeper's operation store under
    [<runtime_root>/keepers] and removes the retained files under
    [<runtime_root>/traces] that none of them names. *)
val run : runtime_root:string -> (report, error) result
