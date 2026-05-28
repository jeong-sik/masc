(** Disk persistence for per-keeper tool-usage counters. *)

(** Flush in-memory tool usage stats to disk for persistence across restarts.
    Reads the keeper entry via [Keeper_registry.get]; writes JSON atomically.
    Increments [metric_keeper_tool_usage_flush_failures] on I/O failure. *)
val flush : base_path:string -> string -> unit

(** Mark a keeper as needing a flush. Called on every tool use instead
    of [flush], avoiding disk I/O in the hot path. *)
val mark_dirty : base_path:string -> string -> unit

(** Flush all keepers in the dirty set. Called by the background fiber. *)
val flush_all_dirty : unit -> unit

(** Restore tool usage stats from disk after keeper re-registration.
    Reads JSON from [tool_usage_path]; replays each entry via
    [Keeper_registry.set_tool_usage_entry]. *)
val restore : base_path:string -> string -> unit
