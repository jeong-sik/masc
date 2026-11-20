(** One serialized in-process Workspace Memory Curator owner per physical
    workspace.

    Drains pending Keeper ordinary and source-bound facts through
    {!Librarian_memory_lane} via {!Agent_core.Exact_output.execute_flow_once}
    (with declared CLI fallback), writes two-phase {!Workspace_memory_log}
    commits, updates {!Workspace_memory_ledger} and
    {!Workspace_memory_briefing}, and notifies subscribed MCP clients via
    {!Mcp_server_eio_resource.notify_world_memory_updated}. *)

val start : sw:Eio.Switch.t -> config:Workspace.config -> unit
(** Start one serialized daemon owner for the resolved physical workspace
    under [sw], recover any incomplete {!Workspace_memory_log} batches, and
    subscribe to Keeper memory commits and {!Librarian_memory_lane} registry
    updates. No-op when an owner for that physical workspace already runs. *)

val retry_pending_observations : base_path:string -> unit
(** Wake an existing owner only when its prior pass failed transiently or a
    log/ledger read failed. Shutdown owners stay stopped. *)

type refresh = Queued | No_owner | Unavailable of string

val request : base_path:string -> refresh
(** Resolve the physical workspace off-domain and queue one drain cycle on its
    existing owner without running model or storage work in the caller. *)

module For_testing : sig
  type idle_checkpoint
  type idle_result = Owner_idle of idle_checkpoint | Owner_stopped | Owner_missing
  type snapshot =
    { pending : bool
    ; in_flight : bool
    ; observation_retry : bool
    ; stopped : bool
    ; idle_waiters : int
    }

  val snapshot : base_path:string -> snapshot option
  (** [None] means there is no owner for this physical workspace. *)

  val await_idle : ?after:idle_checkpoint -> base_path:string -> unit -> idle_result
  (** Atomically check idle and subscribe under the owner's mutex. *)

  val is_idle : base_path:string -> bool
  val stop : base_path:string -> unit
end
