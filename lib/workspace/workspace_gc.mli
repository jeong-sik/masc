(** Workspace_gc — heartbeat and explicit garbage collection.

    Public surface for [workspace_gc.ml].  Extracted from [workspace.ml] for
    modularity (#4638).  See issue #10751 for the broader [workspace/]
    [.mli] coverage push.

    Side effects:
    - [heartbeat] touches [agents_dir config].
    - [gc] touches the explicit retention surfaces documented below.
      Callers must hold no other workspace lock when invoking either function.
    - Board artifact cleanup is wired via [Workspace_hooks] callbacks at
      startup; this module does not depend on the board layer
      directly. *)

(** What a heartbeat did. Only [Heartbeat_updated] means the agent's
    [last_seen] was written; the other two mean the call did nothing and are
    not evidence that the workspace is writable.

    This was a status string, and both readers got it wrong. The MCP handler
    tested the first three bytes for a warning sign no branch here ever
    emits — so every heartbeat reported success. The keeper's
    work-as-heartbeat refresher treated any call that did not raise as a live
    workspace, which a missing agent file satisfies. *)
type heartbeat_outcome =
  | Heartbeat_updated of string  (** resolved agent name *)
  | Agent_file_invalid of string  (** resolved agent name *)
  | Agent_not_found of string  (** requested agent name *)

(** The status string the outcome used to be, byte for byte. *)
val heartbeat_message : heartbeat_outcome -> string

(** Update the agent's [last_seen] timestamp on disk.

    [agent_name] is resolved through {!Workspace_identity.resolve_agent_name}
    so canonical/alias forms both work. The agent file is mutated under
    [with_file_lock]. *)
val heartbeat :
  Workspace_utils_backend_setup.config -> agent_name:string -> heartbeat_outcome

(** Run the explicit workspace garbage-collection pass. [days] has no default:
    the caller owns the retention decision rather than inheriting a fixed
    runtime heuristic.

    {ol
    {- archive backlog tasks in a terminal state ([Done]/[Cancelled]) older
       than [days] days.
       Non-terminal tasks — including [AwaitingVerification] obligations — are
       never archived; a completion authority must still be able to commit a
       verdict against the live task}
    {- self-heal: restore any non-terminal task a prior buggy pass stranded in
       [tasks-archive.json] back into the live backlog}}

    Archived tasks are appended to [tasks-archive.json] via
    {!Workspace_task_id.append_archive_tasks}; restored tasks are removed from
    it via {!Workspace_task_id.drop_archive_tasks}.  The backlog is rewritten
    with [version + 1] when anything changes.  Returns a multi-line summary
    string. *)
val gc :
  Workspace_utils_backend_setup.config -> days:int -> unit -> string
