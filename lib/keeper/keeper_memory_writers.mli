(** The Memory writers of the workspaces this process serves
    (RFC librarian-call-only-proposes §8.6, §9.5).

    The server starts one table for its workspace. A Keeper of that
    workspace has a writer while it is in the Keeper registry: nothing here
    starts or stops a writer by name.

    A process that starts no table (a CLI, the TUI) has no writer. {!find}
    says so, and the caller answers that Memory cannot be written here. *)

val start : sw:Eio.Switch.t -> config:Workspace.config -> unit
(** The table of [config]'s workspace. Its writers run on [sw], in the
    domain that calls this, and stamp their lines with the wall clock. A
    Keeper's snapshot and commit log are in the workspace's Keeper config
    directory, and its turn log in the Keeper runtime directory.

    The table is gone when [sw] ends. Starting a workspace again replaces
    its table. *)

val find : base_path:string -> Librarian_writers.t option
(** The table {!start} made for the workspace. [None]: this process started
    none for it. Can be called from any domain. *)
