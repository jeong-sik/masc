(** Telemetry_unified — Read-only aggregation of scattered telemetry stores.

    Provides a single, time-sorted view over independent telemetry stores.
    Paths under [.masc/] are resolved via the cluster-aware [masc_root]
    (use [Workspace.masc_root_dir config]):
    - [<masc_root>/keepers/<name>/metrics/] — Per-keeper turn metrics
    - [<masc_root>/telemetry/]              — Agent lifecycle + tool call events
    - [<masc_root>/tool_calls/]             — Full I/O for keeper tool calls
    - [<masc_root>/trajectories/<keeper>/]  — Trajectory tool-call rows
    - [<masc_root>/tool_usage/]             — Non-public registered tool calls
    - [<masc_root>/agent-core-events/]             — Durable AGENT_CORE native/custom bus events
    - [<masc_root>/keepers/<name>/execution-receipts/]
                                              — Keeper execution receipts
    - [<masc_root>/goal_events.jsonl]       — Goal FSM lifecycle events
    - [<masc_root>/tool-metrics.sqlite3]    — Tool duration/success metrics

    Each returned entry is tagged with a ["source"] field for discrimination.
    No write paths are modified; this module is purely a read-side fan-in.

    @since 2.251.0 *)

(** Telemetry source discriminator. *)
type source =
  | Keeper_metric  (** Per-keeper turn/heartbeat metrics *)
  | Agent_event    (** Agent lifecycle, task, handoff events *)
  | Tool_call_io   (** Keeper tool calls with full input/output *)
  | Trajectory_tool_call  (** Trajectory-backed keeper tool call rows *)
  | Tool_usage     (** Non-public registered tool invocations *)
  | Agent_core_event      (** Durable AGENT_CORE native/custom event bus relays *)
  | Execution_receipt  (** Keeper execution receipt rows *)
  | Goal_event     (** Goal FSM lifecycle and verification events *)
  | Tool_metric    (** Tool duration and success metrics *)

val source_to_string : source -> string
val source_of_string : string -> source option
val all_sources : source list
val source_freshness_slo_s : ?keeper_keepalive_interval_s:float -> source -> float

type read_result = {
  entries : Yojson.Safe.t list;
  total_matching_entries : int;
  truncated : bool;
}

(** How many entries one read may return.

    Abstract so that "no limit" cannot be constructed. Before RFC-0372 the
    limit was a plain [int] where [n <= 0] meant unbounded, and the scan cap
    that backed it applied per store rather than per request: with nine
    sources, three of which fan out per keeper, one request could materialise
    the whole store and the ceiling rose every time a keeper was added.

    Values are clamped into [1, max_read_entries] at construction, so every
    reader downstream holds a positive bound by type. A caller that wants
    "everything in the window" gets [max_read_entries] and a [truncated] flag,
    not an unbounded scan — the response contract is preserved, the unbounded
    read is not. *)
type read_limit

(** Ceiling a single read may return, whatever the store size. *)
val max_read_entries : int

(** Applied when a request omits the limit. *)
val default_read_entries : int

(** Clamp into [1, max_read_entries].

    Zero and negatives map to [default_read_entries], NOT to "unbounded":
    the old permissive reading of [n = 0] is the defect RFC-0372 closes, so it
    is mapped here once rather than re-checked at each reader. *)
val read_limit_of_int : int -> read_limit

val read_limit_to_int : read_limit -> int

val read_unified :
  base_path:string ->
  masc_root:string ->
  ?sources:source list ->
  ?keeper_name:string ->
  ?session_id:string ->
  ?operation_id:string ->
  ?worker_run_id:string ->
  ?since_ts:float ->
  ?until_ts:float ->
  ?limit:read_limit ->
  ?offset:int ->
  unit ->
  Yojson.Safe.t list
(** [read_unified ~base_path ~masc_root ?sources ?keeper_name ?session_id
      ?operation_id ?worker_run_id ?since_ts ?until_ts ?limit ()]
    reads entries from [sources] (default: all sources), optionally filtered
    by [keeper_name], generic correlation keys, and an optional unix-second
    window. Returns at most [read_limit_to_int limit] entries (default
    [default_read_limit]) sorted by timestamp descending (newest first).

    Truncation always applies. There is no "return everything" form: a limit
    is a positive bound by construction ({!read_limit}), and a caller asking
    for more than [max_read_entries] receives that ceiling with
    [truncated = true] rather than a full-store scan (RFC-0372).

    [masc_root] is the cluster-aware .masc directory (use
    [Workspace.masc_root_dir config] to obtain it).  [base_path] is the
    project root, used only for [data/] paths.

    Each entry is a JSON object with an added ["source"] field. *)

val read_unified_result :
  base_path:string ->
  masc_root:string ->
  ?sources:source list ->
  ?keeper_name:string ->
  ?session_id:string ->
  ?operation_id:string ->
  ?worker_run_id:string ->
  ?since_ts:float ->
  ?until_ts:float ->
  ?limit:read_limit ->
  ?offset:int ->
  unit ->
  read_result
(** Like {!read_unified}, but also returns the total number of matching
    entries before truncation plus whether truncation occurred. *)

val summary_json :
  ?keeper_keepalive_interval_s:float ->
  ?keeper_metric_producer_active:bool ->
  base_path:string ->
  masc_root:string ->
  unit ->
  Yojson.Safe.t
(** [summary_json ~base_path ~masc_root ()] returns a JSON overview of
    each source: path, entry count, whether the store directory exists,
    and freshness metadata ([latest_ts_unix], [latest_ts_iso],
    [latest_age_s]). A live Keeper metrics producer suppresses only
    age-derived staleness; missing, empty, read-error, and coverage-gap states
    remain fail-visible. [masc_root] is the cluster-aware .masc directory. *)

val replay_retention_json :
  ?keeper_keepalive_interval_s:float ->
  base_path:string ->
  masc_root:string ->
  sources:source list ->
  unit ->
  Yojson.Safe.t
(** [replay_retention_json ~base_path ~masc_root ~sources ()] returns the
    provenance block for the dashboard telemetry replay endpoint, including
    the selected source list and durable stores read for each source. *)

val save_trajectory_summary_cache : path:string -> (unit, string) result
(** Writes the per-file (path, boundary, tool_calls, latest_ts) trajectory
    cache to [path] via a temp-file rename. The cache is never an authority:
    every row is still validated against its file's current size when used,
    so a stale or absent file only costs the full read it costs today. *)

val load_trajectory_summary_cache : path:string -> (int, string) result
(** Loads a cache written by {!save_trajectory_summary_cache}, returning how
    many rows were read. Rows merge into the in-memory table and never
    overwrite an entry this process has already advanced further. A missing
    file is [Ok 0]. *)

module For_testing : sig
  val trajectory_tool_call_summary_stats :
    masc_root:string -> int * float option
  (** Exposes the per-trace-file incremental summary used by
      [summary_json] for the trajectory source: (tool-call entry count,
      latest tool-call ts). Production callers go through
      [summary_json]. *)

  val reset_trajectory_summary_cache_for_testing : unit -> unit
  (** Clear the per-file (boundary, count, latest_ts) cache so a test
      observes cold-start behavior. *)
end

val heap_root : (Obj.t -> 'a) -> 'a
(** Run [walk] on this module's retained state, under the lock that guards
    it, for [Heap_roots.measure] to size with [Obj.reachable_words].
    Diagnostics only: the walk stalls the process for its duration. *)
