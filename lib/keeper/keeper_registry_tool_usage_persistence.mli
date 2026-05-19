(** Disk persistence for per-keeper tool-usage counters. *)

(** Filesystem path under [<masc>/keepers/tool_usage/<name>.json]. *)
val tool_usage_path : base_path:string -> string -> string

(** Flush in-memory tool usage stats to disk for persistence across restarts.
    Reads the keeper entry via [Keeper_registry.get]; writes JSON atomically.
    Increments [metric_keeper_tool_usage_flush_failures] on I/O failure. *)
val flush : base_path:string -> string -> unit

(** Restore tool usage stats from disk after keeper re-registration.
    Reads JSON from [tool_usage_path]; replays each entry via
    [Keeper_registry.set_tool_usage_entry]. *)
val restore : base_path:string -> string -> unit
