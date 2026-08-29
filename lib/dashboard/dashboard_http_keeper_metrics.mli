(** Dashboard_http_keeper_metrics — keeper-metrics aggregation
    helpers for the dashboard HTTP endpoint.

    Standalone module (no upward [include]).
    {!Dashboard_http_keeper_detail} does
    [include Dashboard_http_keeper_metrics] to make the
    runtime-visible entries available in the keeper-detail JSON
    builder.

    [truncate_text] stays private — it is used only by the
    history-summary preview builder. *)

(** {1 Model name normalization (runtime-visible)} *)

(** {1 Per-keeper window statistics (runtime-visible)} *)

type keeper_gen_window_stats = {
  turns : int;
  usage_points : int;
  input_tokens : int;
  output_tokens : int;
  total_tokens : int;
  handoffs : int;
  first_ts : float;
  last_ts : float;
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

val keeper_history_summary_json :
  all_keeper_names:string list ->
  keeper_name:string ->
  history_path:string ->
  filter_fragments:bool ->
  Yojson.Safe.t * Yojson.Safe.t * Yojson.Safe.t * int * int * int
(** [keeper_history_summary_json ~all_keeper_names ~keeper_name
      ~history_path ~filter_fragments] reads the keeper's history
    file and returns
    [(turns_json, models_json, tools_json, raw_count,
       fragment_count, filtered_count)]. The 6-tuple shape is
    operator-visible in the dashboard and pinned at the contract
    seam. *)

(** {1 Test-visible helpers}
    Pinned for behaviour-tests under {!test/test_dashboard_keeper_metrics_10286}. *)

val contains_ci : string -> string -> bool
(** [contains_ci haystack needle] is a case-insensitive substring
    check.  Returns [false] when [needle] is empty or longer than
    [haystack]. *)
