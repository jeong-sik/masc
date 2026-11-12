(** Cache key, timeout, and projection diagnostics for dashboard HTTP core. *)

val dashboard_request_timeout_s : float
val standard_cache_ttl_s : float

val workspace_memory_inventory_cache_key : base_path:string -> string
(** The inventory's read and commit invalidation share this exact cache key. *)

val deep_surface_cache_ttl_s : float
val shell_surface_cache_ttl_s : float
val freshness_slo_s : float
val config_cache_ttl_s : float
val live_cache_ttl_s : float
val realtime_cache_ttl_s : float
val dashboard_projection_cache_ttl_s : float

val planning_cache_prefix : string
(** Every workspace's planning projection key starts with this. A task write
    drops them all: the task mutation hook does not name its workspace. *)

val planning_cache_key : base_path:string -> string

val invalidate_board_projections : unit -> unit
(** Drop every cached board projection. Called on each board write so the
    next read, including the one the [notifications/board] SSE event
    triggers in the dashboard, computes from the store. *)
val shell_warmed : bool Atomic.t
val shell_warming : bool Atomic.t
val last_good_shell : Yojson.Safe.t Atomic.t
val last_good_shell_light : Yojson.Safe.t Atomic.t

val with_dashboard_timeout :
  clock:_ Eio.Time.clock -> (unit -> Yojson.Safe.t) -> Yojson.Safe.t

val dashboard_cache_key : Workspace.config -> string -> string -> string
val dashboard_query_cache_key :
  Workspace.config -> string -> (string * string option) list -> string

val tool_metrics_series_cache_key :
  Workspace.config -> (string * string option) list -> string
val invalidate_tool_metrics_series : base_path:string -> unit
(** The series route and after-write/deadline consumers share this key
    family. Invalidation drops every filter/window for the owning workspace,
    including an in-flight old computation, before publishing a change. *)

val ide_file_activity_cache_key :
  base_path:string -> (string * string option) list -> string
val invalidate_ide_file_activity : base_path:string -> unit
(** The scoped IDE file reader and tool-ledger commit notifications share
    this cache family. No unrelated workspace or query family is dropped. *)

val scheduled_automation_cache_key : base_path:string -> string
(** The key the fleet schedule list ([GET /api/v1/dashboard/scheduled-automation]
    without a selector) is cached under, for the workspace at [base_path]. *)

val invalidate_scheduled_automation : base_path:string -> unit
(** Drop the cached fleet schedule list. The schedule runner loop calls it
    after every tick it records, so the list's runner status and holds are the
    newest tick's rather than up to {!live_cache_ttl_s} older. While no tick is
    recorded, a hung one included, the list can still trail the runner by that
    long. The schedule store's change observer calls it before it enqueues
    each write's invalidation, so a reader that answers
    [schedule_store_invalidated] reads the write. *)
val dashboard_briefing_timeout_s : float

val with_projection_diagnostics :
  surface:string ->
  started_at:float ->
  extra:(string * Yojson.Safe.t) list ->
  Yojson.Safe.t ->
  Yojson.Safe.t
(** Refresh generated timing/extra metadata while retaining the producer's
    existing diagnostic fields. [read_completeness] and [read_error] belong
    only to the original read: metadata [extra] cannot replace or invent
    them. Other metadata keys take precedence over an existing value. Emits
    one [projection_diagnostics] member with unique field names; does not
    infer an absent read outcome. *)
