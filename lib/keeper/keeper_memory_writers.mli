(** The Memory writers of the workspaces this process serves
    (RFC librarian-call-only-proposes §8.6, §9.5).

    The server starts one table for its workspace. A Keeper of that
    workspace has a writer while it is in the Keeper registry: nothing here
    starts or stops a writer by name.

    A process that starts no table (a CLI, the TUI) has no writer. {!find}
    says so, and the caller answers that Memory cannot be written here. *)

val start
  :  sw:Eio.Switch.t
  -> ask:(Librarian_ask.input -> Librarian_read_result.t)
  -> start_turn_log:(string -> (unit, string) result)
  -> config:Workspace.config
  -> Librarian_writers.t
(** The table of [config]'s workspace. Its writers run on [sw], in the
    domain that calls this, and stamp their lines with the wall clock. A
    Keeper's snapshot and commit log are in the workspace's Keeper config
    directory, its turn log in the Keeper runtime directory, and the
    content of its turns in its session directories and the workspace's
    chat and external stores. [ask] asks one question: the server passes
    {!Librarian_ask.run} with its own network and clock. [start_turn_log]
    is a Keeper's store start first step, run before every boot of its
    writer: the server passes {!Keeper_turn_log_store_start.run}. The turn
    log's own modules call this one, so the step comes in from the caller.

    The table holds no declaration until {!follow_declaration} sends one,
    so its writers do not ask before then. The table is gone when [sw]
    ends. Starting a workspace again replaces its table. *)

val find : base_path:string -> Librarian_writers.t option
(** The table {!start} made for the workspace. [None]: this process started
    none for it. Can be called from any domain. *)

val follow_declaration
  :  sw:Eio.Switch.t
  -> prompt:string
  -> answer_schema:Yojson.Safe.t
  -> Librarian_writers.t
  -> unit
(** Sends the table the [librarian_memory] lane value now, and again after
    every publication of the runtime table or of the lane in the
    Exact-output registry (§9.5). One fiber on [sw] waits for both signals:
    each sees a change the other does not.

    - The value is {!Librarian_memory_lane.resolve} with [prompt] and
      [answer_schema], under the registry published at the signal.
    - A registry that is being replaced ([Publication_busy]) sends nothing:
      the lane's signal comes when the replacement ends.
    - No registry, or a lane with no value, sends [None], and the reason
      goes to the log. *)
