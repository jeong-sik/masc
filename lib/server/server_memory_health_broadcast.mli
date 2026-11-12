(** Tells a workspace's readers which Keeper's memory health row moved
    (RFC-0487 L3).

    A write to a file the row reads arrives through
    {!Keeper_memory_health_input} or {!Keeper_memory_commit_notifications},
    named by its keepers directory. When the directory is this workspace's
    config or runtime keepers directory, the workspace's cached fleet answer
    ({!Server_dashboard_http_keeper_memory_health.fleet_cache_key}) is emptied
    first and then {!Workspace_dataset_event.Memory_health} is announced for
    the Keeper. A write under any other directory announces nothing: no reader
    of this workspace shows it.

    Writers only empty caches and enqueue typed notices. A switch-owned
    worker coalesces repeated notices and performs SSE fanout, which may
    suspend through a client disconnect hook. A change during publication
    remains owed after that publication. *)

val install :
  sw:Eio.Switch.t -> mono_clock:_ Eio.Time.Mono.t ->
  config:Workspace.config -> unit
(** Subscribe for [config]'s workspace until [sw] is released. The two
    directories are resolved through symlinks once, here. One that does not
    exist yet is named under its deepest existing ancestor, resolved, which is
    where its first write puts it. A directory that cannot be resolved for any
    other reason raises. *)
