(** Coord_gc — heartbeat, zombie cleanup, garbage collection.

    Public surface for {!Coord_gc.ml}.  Extracted from [room.ml] for
    modularity (#4638).  See issue #10751 for the broader [coord/]
    [.mli] coverage push.

    Side effects:
    - All three functions touch [agents_dir config] and the locks
      under it.  Callers must hold no other coord lock when invoking.
    - Board artifact cleanup is wired via [Coord_hooks] callbacks at
      startup; this module does not depend on the board layer
      directly. *)

(** Update the agent's [last_seen] timestamp on disk.

    [agent_name] is resolved through {!Coord_utils.resolve_agent_name}
    so canonical/alias forms both work.  Returns a human-readable
    status string (heartbeat updated / agent missing / file invalid).
    The agent file is mutated under [with_file_lock]. *)
val heartbeat :
  Coord_utils_backend_setup.config -> agent_name:string -> string

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
  Coord_utils_backend_setup.config -> cleanup_zombie_result

(** Run the full coord garbage-collection pass:
    {ol
    {- {!cleanup_zombies} (default thresholds)}
    {- archive backlog tasks older than [days] days that are not
       already in a terminal state (default [days = 7], clamped to
       at least 1)}}

    Stale tasks are appended to [tasks-archive.json] via
    {!Coord_task_id.append_archive_tasks} and the backlog is rewritten
    with [version + 1].  Returns a multi-line summary string. *)
val gc :
  Coord_utils_backend_setup.config -> ?days:int -> unit -> string
