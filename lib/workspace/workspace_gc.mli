(** Workspace_gc — heartbeat and explicit garbage collection.

    Public surface for {!Workspace_gc.ml}.  Extracted from [workspace.ml] for
    modularity (#4638).  See issue #10751 for the broader [workspace/]
    [.mli] coverage push.

    Side effects:
    - Both functions touch [agents_dir config] and the locks
      under it.  Callers must hold no other workspace lock when invoking.
    - Board artifact cleanup is wired via [Workspace_hooks] callbacks at
      startup; this module does not depend on the board layer
      directly. *)

(** Update the agent's [last_seen] timestamp on disk.

    [agent_name] is resolved through {!Workspace_utils.resolve_agent_name}
    so canonical/alias forms both work.  Returns a human-readable
    status string (heartbeat updated / agent missing / file invalid).
    The agent file is mutated under [with_file_lock]. *)
val heartbeat :
  Workspace_utils_backend_setup.config -> agent_name:string -> string

(** Run the explicit workspace garbage-collection pass. [days] has no default:
    the caller owns the retention decision rather than inheriting a fixed
    runtime heuristic.

    {ol
    {- archive backlog tasks in a terminal state ([Done]/[Cancelled]) older
       than [days] days.
       Non-terminal tasks — including [AwaitingVerification] obligations — are
       never archived (RFC-0220: an obligation must stay claimable by a
       verifier)}
    {- self-heal: restore any non-terminal task a prior buggy pass stranded in
       [tasks-archive.json] back into the live backlog}}

    Archived tasks are appended to [tasks-archive.json] via
    {!Workspace_task_id.append_archive_tasks}; restored tasks are removed from
    it via {!Workspace_task_id.drop_archive_tasks}.  The backlog is rewritten
    with [version + 1] when anything changes.  Returns a multi-line summary
    string. *)
val gc :
  Workspace_utils_backend_setup.config -> days:int -> unit -> string
