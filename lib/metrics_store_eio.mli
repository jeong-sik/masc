open Base

(** Metrics_store_eio — agent performance metrics with async batched
    file I/O.

    Storage layout: \[.masc/metrics/\{agent\}/YYYY-MM.jsonl\] — one
    {!task_metric} per line, JSON-serialised via
    [\[@@deriving yojson\]].

    Concurrency model: writers serialise the JSON line and push to a
    bounded {!Eio.Stream}; a single background fiber
    ({!start_flush_fiber}) drains the queue every 500 ms and batches
    file appends.  This eliminates the global mutex + synchronous
    I/O pattern that previously blocked all writers.  When the
    flush fiber is not active (tests, pre-init), {!record} falls
    back to direct synchronous write. *)

(** {1 Types} *)

type task_metric = {
  id : string;
      (** Unique metric ID — see {!generate_id} for the format. *)
  agent_id : string;  (** Agent name (e.g. ["claude"]). *)
  task_id : string;
  started_at : float;  (** Unix timestamp. *)
  completed_at : float option; [@default None]
      (** [None] iff still in progress. *)
  success : bool;
  error_message : string option; [@default None]
  collaborators : string list;
      (** Other agents involved — for Hebbian collaboration learning. *)
  handoff_from : string option; [@default None]
      (** Previous agent if this metric is a handoff target. *)
  handoff_to : string option; [@default None]
      (** Next agent if this metric handed off out. *)
}
[@@deriving yojson, show]
(** Per-task metric.  PPX derives [task_metric_to_yojson],
    [task_metric_of_yojson], and [show_task_metric] (used by PBT
    test harness for diff diagnostics). *)

type agent_metrics = {
  agent_id : string;
  period_start : float;
  period_end : float;
  total_tasks : int;
  completed_tasks : int;
  failed_tasks : int;
  avg_completion_time_s : float;
  task_completion_rate : float;  (** Range [\[0.0, 1.0\]]. *)
  error_rate : float;  (** Range [\[0.0, 1.0\]]. *)
  handoff_success_rate : float;  (** Range [\[0.0, 1.0\]]. *)
  unique_collaborators : string list;
}
[@@deriving yojson, show]
(** Aggregated per-period metrics — output of
    {!calculate_agent_metrics}.  PPX derives
    [agent_metrics_to_yojson], [agent_metrics_of_yojson], and
    [show_agent_metrics]. *)

type config = Coord_utils.config
(** Transparent alias to {!Coord_utils.config} — the metrics store
    inherits the same base-path resolution. *)

(** {1 Path resolution} *)

val agent_metrics_dir : config -> string -> string
(** [agent_metrics_dir config agent_id] returns
    \[<masc_dir>/metrics/<agent_id>/\].  Pure path computation — does
    {b not} create the directory.  Use {!record} or call
    [Fs_compat.mkdir_p] explicitly if creation is needed. *)

(** {1 ID generation} *)

val generate_id : unit -> string
(** [generate_id ()] returns ["metric-<timestamp_ms>-<sequence>"]
    where [sequence] is a 6-digit zero-padded counter.  Atomic
    [fetch_and_add] guarantees that two fibers calling [generate_id]
    in the same millisecond receive distinct IDs. *)

(** {1 Recording} *)

val record : config -> task_metric -> unit
(** [record config metric] persists [metric] to
    \[<agent_metrics_dir>/<YYYY-MM>.jsonl\].

    Concurrency: when the flush fiber is active (post-
    {!start_flush_fiber}), the metric is serialised and pushed to
    the queue (lock-free).  Otherwise falls back to direct
    {!Fs_compat.append_file} (tests, pre-init).  Always ensures the
    target directory exists.

    Returns [()] regardless of queue state — backpressure is bounded
    by the 256-entry stream capacity; overflow drops are not
    surfaced to the caller. *)

val flush_pending : unit -> unit
(** [flush_pending ()] drains all pending entries from the write
    queue, batches them by file, and appends each batch with a
    single {!Fs_compat.append_file} call.

    Errors during append are logged to {!Log.Metrics.error} but do
    not raise.  [Eio.Cancel.Cancelled] is re-raised. *)

val start_flush_fiber :
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t -> unit
(** [start_flush_fiber ~clock] sets [queue_active <- true], then
    loops forever sleeping 0.5s between {!flush_pending} calls.
    Caller must run this on a dedicated fiber inside
    {!Eio_main.run}.  Does not return. *)

(** {1 Pure constructors / mutators} *)

val create_metric :
  agent_id:string ->
  task_id:string ->
  ?collaborators:string list ->
  ?handoff_from:string ->
  unit ->
  task_metric
(** [create_metric ~agent_id ~task_id ?collaborators ?handoff_from
      ()] returns an in-progress metric:
    [success = false], [completed_at = None],
    [started_at = Time_compat.now ()], [id = generate_id ()].
    Pure modulo the clock + atomic counter. *)

val complete_metric :
  task_metric ->
  success:bool ->
  ?error_message:string ->
  ?handoff_to:string ->
  unit ->
  task_metric
(** [complete_metric m ~success ?error_message ?handoff_to ()]
    returns [m] with [completed_at = Some (Time_compat.now ())] +
    [success] / [error_message] / [handoff_to] applied.  Pure
    modulo the clock. *)

(** {1 Month-key helpers (test-visible)} *)

val filter_recent_month_filenames :
  now:float -> days:int -> string list -> string list
(** [filter_recent_month_filenames ~now ~days filenames] keeps only
    the [YYYY-MM.jsonl] entries whose month is within
    [\[now - days, now\]] (inclusive).  Filenames that do not match
    the expected pattern are kept (defensive — caller still applies
    a per-metric timestamp filter via {!get_recent}). *)

(** {1 Reads / aggregates} *)

val get_recent :
  config -> agent_id:string -> days:int -> task_metric list
(** [get_recent config ~agent_id ~days] returns metrics with
    [started_at >= now -. days * 86400] from
    \[<agent_metrics_dir>/*.jsonl\].

    Two-stage filter: month-level (file selection) +
    metric-level ([started_at] cutoff).  Yields between files via
    {!Eio.Fiber.yield} so concurrent fibers are not starved on
    large month files.  Returns [\[\]] when the agent dir does not
    exist. *)

val calculate_agent_metrics :
  config -> agent_id:string -> days:int -> agent_metrics option
(** [calculate_agent_metrics config ~agent_id ~days] aggregates
    {!get_recent} into an {!agent_metrics} summary.  Contracts:

    - Returns [None] iff {!get_recent} returns [\[\]].
    - [period_start = now -. days * 86400], [period_end = now].
    - [completed_tasks] counts only [success = true] (note: not all
      [completed_at = Some _]).
    - [failed_tasks] counts [completed_at = Some _ && success = false].
    - [avg_completion_time_s] averages over metrics with
      [completed_at = Some _]; returns [0.0] when no completions.
    - [task_completion_rate = successful / total] when [total > 0],
      else [0.0].
    - [handoff_success_rate]: among metrics with
      [handoff_from] or [handoff_to] set, the success ratio.
      Returns [1.0] when there are no handoffs ("perfect rate"). *)

val get_all_agents : config -> string list
(** [get_all_agents config] lists each subdirectory of
    \[<masc_dir>/metrics/\].  Returns [\[\]] when the metrics
    directory does not exist.  Order: filesystem readdir order
    (not sorted). *)
