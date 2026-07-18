(** Dashboard_http_keeper_metrics — keeper-metrics aggregation
    helpers for the dashboard HTTP endpoint.

    Standalone module (no upward [include]).
    {!Dashboard_http_keeper_detail} does
    [include Dashboard_http_keeper_metrics] to make the 7
    runtime-visible entries available in the keeper-detail JSON
    builder.

    Internal parsing and aggregation helpers stay private. The public
    boundaries below expose typed summaries, not text-quality classifiers. *)

(** {1 Model name normalization (runtime-visible)} *)

val normalize_model_name : string -> string
(** [normalize_model_name s] trims whitespace and strips the
    [":latest"] suffix when present.  Used by the keeper-detail
    aggregator to dedupe model labels (e.g. ["claude-sonnet"] vs
    ["claude-sonnet:latest"]). *)

(** {1 Per-keeper window statistics (runtime-visible)} *)

type keeper_gen_window_stats = {
  mutable turns : int;
  mutable input_tokens : int;
  mutable output_tokens : int;
  mutable total_tokens : int;
  mutable handoffs : int;
  mutable compactions : int;
  mutable memory_compactions : int;
  mutable memory_trimmed : int;
  mutable memory_checks : int;
  mutable memory_passed : int;
  mutable memory_notes : int;
  mutable first_ts : float;
  mutable last_ts : float;
  models : (string, int) Hashtbl.t;
  tools : (string, int) Hashtbl.t;
}
(** Per-keeper rolling-window statistics record.  All counters
    are mutable for in-place increment as the aggregator scans
    keeper events.  Concrete record because runtime consumer
    ({!Dashboard_http_keeper_detail}) reads / writes fields
    directly. *)

val create_keeper_gen_window_stats : unit -> keeper_gen_window_stats
(** [create_keeper_gen_window_stats ()] returns a fresh
    zero-initialised stats record with empty Hashtbls for
    [models] / [tools]. *)

val count_table_incr :
  (string, int) Hashtbl.t -> string -> unit
(** [count_table_incr tbl key] increments [tbl.(key)] by 1
    (initialising to 1 when missing).  Trims [key] before lookup
    to avoid whitespace-driven duplicates.  Used to update the
    [models] / [tools] counters inside
    {!keeper_gen_window_stats}. *)

(** {1 Top-count rendering (runtime-visible)} *)

val top_counts_json :
  ?limit:int ->
  name_key:string ->
  (string, int) Hashtbl.t ->
  Yojson.Safe.t list
(** [top_counts_json ?limit ~name_key tbl] returns the top
    [limit] (default 5) entries from [tbl] as JSON objects with
    fields [name_key -> entry name] and ["count" -> count].
    Sorted by count descending.  Used to render top-models /
    top-tools sections of keeper-detail JSON. *)

val top_count_name_and_count :
  (string, int) Hashtbl.t -> (string * int) option
(** [top_count_name_and_count tbl] returns [Some (name, count)]
    for the highest-count entry, [None] when [tbl] is empty.
    Convenience for the "primary model / tool" badge. *)

(** {1 Metrics-row classification (runtime-visible)} *)

val metrics_row_has_context_snapshot : Yojson.Safe.t -> bool
(** [metrics_row_has_context_snapshot row] is true when [row] carries
    turn/heartbeat context fields used by context health panels. Sparse
    [tool_event] rows intentionally do not qualify. *)

(** {1 24h-window aggregation (runtime-visible)} *)

val keeper_metrics_24h_json :
  metrics_lines:string list ->
  now_ts:float ->
  Yojson.Safe.t * Yojson.Safe.t
(** [keeper_metrics_24h_json ~metrics_lines ~now_ts] aggregates
    metrics from the past 24 hours (window = [now_ts - 86400] to
    [now_ts]) into a 2-tuple of JSON payloads (per-keeper +
    fleet-wide).  Used by the keeper-detail dashboard endpoint. *)

val keeper_history_summary_json :
  all_keeper_names:string list ->
  keeper_name:string ->
  history_path:string ->
  Yojson.Safe.t * Yojson.Safe.t * Yojson.Safe.t * int * int
(** [keeper_history_summary_json ~all_keeper_names ~keeper_name
      ~history_path] reads the keeper's typed history and returns
    [(conversation_json, k2k_recent_json, k2k_mentions_json, raw_count,
      decode_error_count)]. *)
