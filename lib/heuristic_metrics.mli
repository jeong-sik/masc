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

val record : event -> unit
(** Append a metric event.  Thread-safe.  No-op if storage is not initialized. *)

val init : base_path:string -> unit
(** Initialize the JSONL store under [base_path/.masc/heuristic_metrics.jsonl].
    Idempotent; second call is a no-op. *)

val flush : unit -> unit
(** Force flush pending writes (useful in tests). *)

val recent : int -> Yojson.Safe.t list
(** Read the N most recent events as JSON objects. *)

val event_to_json : event -> Yojson.Safe.t
(** Serialize an event for external consumption (dashboard, tests). *)
