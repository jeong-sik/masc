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

module Count_map : Map.S with type key = string

val count_map_incr :
  int Count_map.t -> string -> int Count_map.t

val top_counts_map_json :
  ?limit:int ->
  name_key:string ->
  int Count_map.t ->
  Yojson.Safe.t list

(** {1 History summary (runtime-visible)} *)

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
