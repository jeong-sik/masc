(** Autonomy Trace Analyzer — quantify whether agent behavior is
    autonomous, scripted, or random based on raw trace summaries.

    Layer 1 (pure OCaml, no LLM required): computes diversity,
    divergence, and relevance metrics from {!Raw_trace.run_summary}
    values produced by {!Raw_trace_query.summarize_run}.

    @stability Evolving
    @since 0.93.1 *)

(** {2 Metrics} *)

type worker_metric =
  { diversity : float (** unique_tools / total_calls.  Higher = more exploratory. *)
  ; unique_tool_count : int
  ; total_calls : int
  ; turn_count : int
  ; tool_set : string list (** sorted unique tool names *)
  }
[@@deriving yojson, show]

(** {2 Divergence between two workers} *)

type divergence =
  { jaccard_distance : float
    (** 1.0 - |A inter B| / |A union B|. 0 = identical, 1 = disjoint. *)
  ; shared_tools : string list
  ; exclusive_a : string list
  ; exclusive_b : string list
  }
[@@deriving yojson, show]

(** {2 Verdict} *)

type classification =
  | Autonomous
  | Scripted
  | Random
  | Insufficient_data
[@@deriving yojson, show]

type verdict =
  { classification : classification
  ; confidence : float (** 0.0 to 1.0 *)
  ; evidence : string list
  ; metrics : worker_metric list
  ; mean_diversity : float
  ; mean_divergence : float
  ; pairwise_divergences : divergence list
  }
[@@deriving yojson, show]

(** {2 Thresholds (configurable)} *)

type thresholds =
  { diversity_autonomous : float (** >= this is considered diverse (default 0.3) *)
  ; diversity_scripted : float (** < this is considered scripted (default 0.15) *)
  ; divergence_autonomous : float (** >= this is considered divergent (default 0.15) *)
  ; divergence_scripted : float (** < this is considered identical (default 0.05) *)
  ; min_unique_tools : int (** minimum unique tools for autonomous (default 3) *)
  ; random_divergence : float
    (** divergence above this with low diversity → Random (default 0.8) *)
  }

val default_thresholds : thresholds

(** {2 Core functions} *)

(** Extract a worker metric from a single run summary. *)
val metric_of_summary : Raw_trace.run_summary -> worker_metric

(** Compute Jaccard-based divergence between two workers' tool sets. *)
val divergence_of_pair : worker_metric -> worker_metric -> divergence

(** Analyze a list of run summaries and produce a verdict.
    Requires >= 2 summaries for meaningful divergence comparison.
    With 1 summary, only diversity is evaluated. *)
val analyze : ?thresholds:thresholds -> Raw_trace.run_summary list -> verdict

(** Serialize a verdict to JSON for CLI output. *)
val verdict_to_json : verdict -> Yojson.Safe.t
