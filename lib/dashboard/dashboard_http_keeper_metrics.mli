(** Dashboard_http_keeper_metrics — keeper-metrics aggregation
    helpers for the dashboard HTTP endpoint.

    Standalone module (no upward [include]).
    {!Dashboard_http_keeper_detail} does
    [include Dashboard_http_keeper_metrics] to make the 7
    cascade-visible entries available in the keeper-detail JSON
    builder.

    Internal: 14 helpers stay private — token / similarity / text
    helpers ([utf8_safe_prefix_bytes], [truncate_text],
    [contains_ci], 2 normalize regexes,
    [normalize_similarity_text], [token_set_of_text],
    [jaccard_similarity_text], [take_last]),
    [type keeper_24h_bucket_stats] + builder, the 24h JSON
    helpers ([keeper_metrics_24h_json],
    [keeper_history_summary_json]), and [get_agent_identity]. *)

(** {1 Model name normalization (cascade-visible)} *)

val normalize_model_name : string -> string
(** [normalize_model_name s] trims whitespace and strips the
    [":latest"] suffix when present.  Used by the keeper-detail
    aggregator to dedupe model labels (e.g. ["claude-sonnet"] vs
    ["claude-sonnet:latest"]). *)

(** {1 Per-keeper window statistics (cascade-visible)} *)

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
    keeper events.  Concrete record because cascade consumer
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

(** {1 Preview similarity (cascade-visible)} *)

val proactive_preview_similarity_stats :
  ?window:int ->
  ?warn_threshold:float ->
  string list ->
  int * int * float * float * bool
(** [proactive_preview_similarity_stats ?window ?warn_threshold
      previews] computes the rolling Jaccard similarity stats
    over the last [window] previews (default 8) and returns
    [(samples, comparisons, mean_similarity,
       max_similarity, exceeded_warn_threshold)].

    [exceeded_warn_threshold] is [max_similarity >= warn_threshold]
    (default 0.90).  Used to detect "keeper repeats itself" loops
    in proactive output. *)

(** {1 Top-count rendering (cascade-visible)} *)

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

(** {1 24h-window aggregation (cascade-visible)} *)

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
  filter_fragments:bool ->
  Yojson.Safe.t * Yojson.Safe.t * Yojson.Safe.t * int * int * int
(** [keeper_history_summary_json ~all_keeper_names ~keeper_name
      ~history_path ~filter_fragments] reads the keeper's history
    file and returns
    [(turns_json, models_json, tools_json, turn_count,
       compaction_count, handoff_count)].  The 6-tuple shape is
    operator-visible in the dashboard and pinned at the contract
    seam. *)

val get_agent_identity : string -> string * string
(** [get_agent_identity name] is a thin re-export of
    {!Dashboard_execution_helpers.get_agent_identity}.  Returns
    [(emoji, label)] for the named agent — used by the
    keeper-detail builder to attach an emoji + display label to
    each row.  Kept here so the cascade consumer can call it
    bare via include without opening
    [Dashboard_execution_helpers] separately. *)

(** {1 Test-visible helpers}
    Pinned for behaviour-tests under {!test/test_dashboard_keeper_metrics_10286}. *)

val contains_ci : string -> string -> bool
(** [contains_ci haystack needle] is a case-insensitive substring
    check.  Returns [false] when [needle] is empty or longer than
    [haystack]. *)

val normalize_similarity_text : string -> string
(** [normalize_similarity_text s] lowercases ASCII, replaces
    non-word characters with spaces, collapses whitespace and
    trims.  Used as the input normaliser for Jaccard similarity. *)

val jaccard_similarity_text : string -> string -> float
(** [jaccard_similarity_text a b] is the Jaccard index over the
    token sets of {!normalize_similarity_text} [a] / [b].  Returns
    [0.0] when either side has no tokens. *)
