(** Workspace_gc — heartbeat, zombie cleanup, garbage collection.

    Public surface for {!Workspace_gc.ml}.  Extracted from [workspace.ml] for
    modularity (#4638).  See issue #10751 for the broader [workspace/]
    [.mli] coverage push.

    Side effects:
    - All three functions touch [agents_dir config] and the locks
      under it.  Callers must hold no other workspace lock when invoking.
    - Board artifact cleanup is wired via [Workspace_hooks] callbacks at
      startup; this module does not depend on the board layer
      directly. *)

type heartbeat_result =
  | Heartbeat_updated of { agent_name : string }
  | Heartbeat_agent_not_found of { agent_name : string }
  | Heartbeat_invalid_agent_file of { agent_name : string; detail : string }

(** Update the agent's [last_seen] timestamp on disk with a closed, typed
    outcome.

    [agent_name] is resolved through {!Workspace_utils.resolve_agent_name}
    so canonical/alias forms both work. The agent file is mutated under
    [with_file_lock]. *)
val heartbeat_r :
  Workspace_utils_backend_setup.config -> agent_name:string -> heartbeat_result

type cleanup_zombie_result =
  | No_agents_dir
  | No_zombies
  | Cleaned of { count : int; names : string list; released_tasks : int; skipped : int }
(** Structured result of zombie cleanup to eliminate string-based parsing at call sites. *)

(** Sweep [.masc/agents/] and remove agents that have not heartbeated
    within the threshold.

    [keeper_threshold_sec] applies to keeper agents and defaults to
    {!Env_config.Zombie.keeper_threshold_seconds}; [agent_threshold_sec]
    applies to all other agents and defaults to
    {!Env_config.Zombie.threshold_seconds}. *)
val cleanup_zombies :
  ?keeper_threshold_sec:float ->
  ?agent_threshold_sec:float ->
  Workspace_utils_backend_setup.config -> cleanup_zombie_result

(** Run the full workspace garbage-collection pass:
    {ol
    {- {!cleanup_zombies} (default thresholds)}
    {- archive backlog tasks in a terminal state ([Done]/[Cancelled]) older
       than [days] days (default [days = 7], clamped to at least 1).
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
  Workspace_utils_backend_setup.config -> ?days:int -> unit -> string
