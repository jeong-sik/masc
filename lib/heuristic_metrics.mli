(** Heuristic_metrics -- RFC-0001 Phase 0.1 instrumentation.

    Records raw values, thresholds, and trigger outcomes at every heuristic
    decision site.  Pure observation -- no behavioral change.  Data accumulates
    in [.masc/heuristic_metrics.jsonl] for later analysis (Gate B, Phase 1).

    Thread-safe via {!Eio.Mutex}.

    @since RFC-0001 Gate A *)

(** Provenance tag describing which subsystem produced this metric. *)
type provenance =
  | Post_verifier of string   (** dimension name, e.g. "relevance" *)
  | Thompson of string        (** signal kind, e.g. "quality_update" *)
  | Drift_guard of string     (** drift type, e.g. "factual" *)
  | Anti_rationalization of string  (** gate name, e.g. "length" / "excuse" / "llm" / "fallback" *)
  | Agent_reputation of string      (** metric name, e.g. "overall_score" *)
  | Relay of string                 (** relay decision site, e.g. "estimate_context" / "should_relay" *)
  | Alert_scoring of string         (** alert keyword/signal, e.g. "keyword_match" / "signal_bonus" *)
  | Pipeline_stage of string        (** stage inference, e.g. "recency_threshold" *)
  | Board_classify of string        (** board classification, e.g. "author_heuristic" *)
  | Reversibility of string         (** Karpathy reversibility, e.g. "estimate" *)

(** A single heuristic observation.  All fields are informational. *)
type event = {
  module_name : string;
  site : string;
  raw_value : float;
  threshold : float;
  triggered : bool;
  provenance : provenance;
  timestamp : float;
}

type coverage_site = {
  module_name : string;
  site : string;
  count : int;
  triggered_count : int;
}

type coverage_report = {
  total_events : int;
  sites : coverage_site list;
  unique_decision_tuples : int;
}

val record : event -> unit
(** Append a metric event.  Thread-safe.  No-op if storage is not initialized. *)

val init : base_path:string -> unit
(** Initialize the JSONL store under [base_path/.masc/heuristic_metrics.jsonl].
    Idempotent; second call is a no-op.  Also runs a one-time
    {!scrub_legacy_degenerate_rows} against the existing file to clear
    the #9919 legacy degenerate signature. *)

val scrub_legacy_degenerate_rows : string -> int
(** Filter out rows matching the #9919 legacy degenerate signature
    (site=post_tool_use_failure, raw_value=1.0, threshold=0.0,
    triggered=true) from the JSONL file at [path] in-place.  Returns
    the number of rows dropped.  Returns [0] without writing the file
    when no rows match, preserving mtime.  Exposed for test coverage
    and for operators who want to run a manual scrub. *)

val flush : unit -> unit
(** Force flush pending writes (useful in tests). *)

val recent : int -> Yojson.Safe.t list
(** Read the N most recent events as JSON objects. *)

val coverage_report_of_events : Yojson.Safe.t list -> coverage_report
(** Summarize event coverage by module/site and count distinct
    raw/threshold/triggered tuples. *)

val recent_coverage : int -> coverage_report
(** Read recent events and summarize their coverage. *)

val coverage_report_to_json : coverage_report -> Yojson.Safe.t
(** Serialize a coverage report for diagnostics. *)

val event_to_json : event -> Yojson.Safe.t
(** Serialize an event for external consumption (dashboard, tests). *)
