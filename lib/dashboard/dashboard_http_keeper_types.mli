(** Dashboard_http_keeper_types — pure helpers extracted from
    Dashboard_http_keeper (2327 LoC godfile).

    Holds the health-scoring constants + compute_health_score +
    backoff-eta + small JSON builders. State-touching dashboard renderers
    remain in Dashboard_http_keeper. Re-included by that module so
    existing callers continue to use [Dashboard_http_keeper.<helper>]
    unchanged. *)

val health_ctx_critical : float
val health_ctx_warn : float
val health_penalty_critical : float
val health_penalty_warn : float
val runtime_warning_ctx_ratio : float
(** Dashboard health scoring thresholds, sourced from
    [Env_config_keeper.DashboardHealth]. *)

val live_keeper_cascade_name : string -> string
(** Resolve a raw cascade name to its live (post-rotation) identifier. *)

val compute_health_score :
  restart_count:int ->
  max_restarts:int ->
  recent_crash_count:int ->
  is_dead:bool ->
  context_ratio:float ->
  int
(** Pure 0-100 health score for a keeper. Dead returns 0; otherwise
    deducts budget / crash / context penalties from 100. *)

val estimate_dead_eta_sec :
  restart_count:int -> max_restarts:int -> float option
(** Sum of supervisor backoff delays from [restart_count] up to
    [max_restarts]. [None] when the budget is already exhausted. *)

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

val json_string_list_member : string -> Yojson.Safe.t -> string list
val json_string_member_opt : string -> Yojson.Safe.t -> string option
val terminal_reason_code_of_decision_json :
  Yojson.Safe.t -> string option

val execution_trust_source : string
val execution_trust_producer : string
val execution_trust_dashboard_surface : string
val execution_trust_freshness_slo_s : float

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
