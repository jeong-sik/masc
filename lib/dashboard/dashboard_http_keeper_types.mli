(** Dashboard_http_keeper_types — pure helpers extracted from
    Dashboard_http_keeper (2327 LoC godfile).

    Holds small JSON builders. State-touching dashboard renderers
    remain in Dashboard_http_keeper. Re-included by that module so
    existing callers continue to use [Dashboard_http_keeper.<helper>]
    unchanged. *)

val runtime_warning_ctx_ratio : float

val live_keeper_runtime_id_result :
  string -> (string, [ `Unresolved of string ]) result
(** [Ok] carries the trimmed runtime id; a blank input is
    [Error (`Unresolved raw)], which the caller surfaces as JSON [null]
    on the canonical field. *)

val prompt_block_json : string -> Yojson.Safe.t
(** Pure: resolve a prompt key and emit the dashboard JSON record. *)

val tokens_per_sec_json :
  tokens:int -> latency_ms:int -> Yojson.Safe.t
(** Pure: tokens-per-second JSON value; [`Null] when inputs are
    non-positive. *)

val last_latency_ms_json : int -> Yojson.Safe.t
(** Pure: latency JSON value; [`Null] when input is non-positive. *)

(** {1 Internal Yojson / freshness helpers}

    Used by dashboard renderers and execution-trust health computations. *)

val terminal_reason_code_of_decision_json :
  Yojson.Safe.t -> string option
(** The code of the decision row's typed [terminal_reason] object
    ({!Keeper_turn_terminal.of_json}); [None] when the row has no such
    object or it does not decode. *)

val execution_trust_source : string
val execution_trust_producer : string
val execution_trust_dashboard_surface : string
val execution_trust_freshness_slo_s : float
val execution_trust_refresh_interval_s : float

val max_ts_opt : float option -> float -> float option

val latest_receipt_ts_of_keeper_rows :
  Yojson.Safe.t list -> float option

val freshness_fields :
  now:float -> float option -> (string * Yojson.Safe.t) list

val source_health_fields :
  now:float ->
  exists:bool ->
  entry_count:int ->
  latest_ts:float option ->
  ?coverage_gap:Yojson.Safe.t ->
  unit ->
  (string * Yojson.Safe.t) list

(** {1 Internal metric / list / decision helpers} *)

val nonempty_string_opt : string -> string option
val percentile_sorted_float : float array -> float -> float
val keeper_decisions_dashboard_surface : string

(** {1 K2 decisions feed helpers} *)

val k2_feed_limit : int -> int
(** Pure: clamp the feed limit to [1, 200]. *)

val keeper_decisions_retention_json : keeper_count:int -> Yojson.Safe.t
(** Pure: retention metadata JSON for the keeper-decisions feed. *)
