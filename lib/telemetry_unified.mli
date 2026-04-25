(** Telemetry_unified — Read-only aggregation of scattered telemetry stores.

    Provides a single, time-sorted view over independent telemetry stores.
    Paths under [.masc/] are resolved via the cluster-aware [masc_root]
    (use [Coord.masc_root_dir config]):
    - [<masc_root>/keepers/<name>/metrics/] — Per-keeper turn metrics
    - [<masc_root>/telemetry/]              — Agent lifecycle + tool call events
    - [<masc_root>/tool_calls/]             — Full I/O for keeper tool calls
    - [<masc_root>/trajectories/<keeper>/]  — Trajectory tool-call rows
    - [<masc_root>/tool_usage/]             — System_internal surface tool calls
    - [<masc_root>/oas-events/]             — Durable OAS native/custom bus events
    - [<masc_root>/keepers/<name>/execution-receipts/]
                                              — Keeper execution receipts
    - [<masc_root>/goal_events.jsonl]       — Goal FSM lifecycle events
    - [<base_path>/data/tool-metrics/]      — Tool duration/success metrics

    Each returned entry is tagged with a ["source"] field for discrimination.
    No write paths are modified; this module is purely a read-side fan-in.

    @since 2.251.0 *)

(** Telemetry source discriminator. *)
type source =
  | Keeper_metric  (** Per-keeper turn/heartbeat metrics *)
  | Agent_event    (** Agent lifecycle, task, handoff events *)
  | Tool_call_io   (** Keeper tool calls with full input/output *)
  | Trajectory_tool_call  (** Trajectory-backed keeper tool call rows *)
  | Tool_usage     (** System_internal surface tool invocations *)
  | Oas_event      (** Durable OAS native/custom event bus relays *)
  | Execution_receipt  (** Keeper execution receipt rows *)
  | Goal_event     (** Goal FSM lifecycle and verification events *)
  | Tool_metric    (** Tool duration and success metrics *)

val source_to_string : source -> string
val source_of_string : string -> source option
val all_sources : source list

type read_result = {
  entries : Yojson.Safe.t list;
  total_matching_entries : int;
  truncated : bool;
}

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
  ?n:int ->
  unit ->
  Yojson.Safe.t list
(** [read_unified ~base_path ~masc_root ?sources ?keeper_name ?session_id
      ?operation_id ?worker_run_id ?since_ts ?until_ts ?n ()]
    reads entries from [sources] (default: all sources), optionally filtered
    by [keeper_name], generic correlation keys, and an optional unix-second
    window. Returns at most [n] entries (default 100) sorted by timestamp
    descending (newest first).  When [n <= 0], no truncation is applied.

    [masc_root] is the cluster-aware .masc directory (use
    [Coord.masc_root_dir config] to obtain it).  [base_path] is the
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
  ?n:int ->
  unit ->
  read_result
(** Like {!read_unified}, but also returns the total number of matching
    entries before truncation plus whether truncation occurred. *)

val summary_json :
  base_path:string ->
  masc_root:string ->
  unit ->
  Yojson.Safe.t
(** [summary_json ~base_path ~masc_root ()] returns a JSON overview of
    each source: path, entry count, whether the store directory exists,
    and freshness metadata ([latest_ts_unix], [latest_ts_iso],
    [latest_age_s]).  [masc_root] is the cluster-aware .masc directory. *)
