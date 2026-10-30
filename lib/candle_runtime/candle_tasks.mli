(** Reading what a payout looks at: the Tasks a Goal linked, and the Keepers
    (RFC-goal-candle-ledger 3.4).

    Both reads are strict. A store that cannot be read, a row that does not
    decode, and a directory that cannot be listed are errors, never an empty
    answer, because a payout that read nothing would pay nobody. *)

val lookups :
  Workspace_utils_backend_setup.config
  -> goal_id:string
  -> string list
  -> ((string * Candle_event.task_lookup) list, string) result
(** What reading each Task id found, in the order given. A Task is found in the
    backlog, or else in [tasks-archive.json]. When neither has it and the Goal's
    links no longer name it, it was deleted, because deleting a Task removes
    its links too. No ids is an empty answer that reads nothing.

    The archive and the links are read only when the backlog leaves a Task
    unfound, and only the archive rows of the Tasks asked for are decoded.
    [Error] when the backlog cannot be read, when the archive or the links
    cannot be read while they are needed, when a wanted row of the archive does
    not decode or a row has no readable id, when a performer-bearing Task has
    a blank assignee, when a completion time is not in
    the ledger's form, and when a Task is in neither store while the Goal still
    links it. The last one is usually the collector between writing the backlog
    and appending to the archive, and the next read finds the Task. It stays an
    error when the collector stopped between those writes (#39963), when a
    Task's creation stopped between its link and its backlog entry, and when a
    deletion could not remove the links. The payout waits until every Task
    reads. *)

val is_keeper : Workspace_utils_backend_setup.config -> (string -> bool, string) result
(** Whether a name is a Keeper of this base path: a valid Keeper name with a
    [<name>.toml] in the Keepers directory. [Error] when the directory cannot be
    listed, which is not the same as a name having no file. *)
