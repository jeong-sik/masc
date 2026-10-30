(** Dashboard_http_keeper_metrics — keeper-metrics aggregation
    helpers for the dashboard HTTP endpoint.

    Standalone module (no upward [include]).
    {!Dashboard_http_keeper_detail} does
    [include Dashboard_http_keeper_metrics] to make the
    runtime-visible entries available in the keeper-detail JSON
    builder.

    [truncate_text] stays private — it is used only by the
    history-summary preview builder. *)

(** {1 Window counters (runtime-visible)} *)

val count_table_incr :
  (string, int) Hashtbl.t -> string -> unit
(** [count_table_incr tbl key] increments [tbl.(key)] by 1
    (initialising to 1 when missing).  Trims [key] before lookup
    to avoid whitespace-driven duplicates.  Used to update the
    work-kind / tool counters of the keeper metrics window. *)

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

val keeper_history_summary_json :
  all_keeper_names:string list ->
  keeper_name:string ->
  history_path:string ->
  Yojson.Safe.t * Yojson.Safe.t * Yojson.Safe.t * int
(** [keeper_history_summary_json ~all_keeper_names ~keeper_name
      ~history_path] reads the keeper's history
    file and returns
    [(conversation, recent_mentions, mention_counts, raw_count)].
    Internal sources are excluded by their recorded provenance. Message length,
    punctuation and language do not decide whether a conversation is visible.
    Mention activity uses the canonical Keeper address grammar and identities;
    it is not a delivery receipt. *)
