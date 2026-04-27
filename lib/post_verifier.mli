(** Post Verifier — 3-dimension output verification gate for agents.

    Deterministic heuristic checks across Relevance, Quality, Safety.
    Each dimension yields a verdict; overall verdict is the strongest
    negative across dimensions (Fail > Warn > Pass).

    @since 2.71.0 *)

(** {1 Types} *)

(** Single-dimension verdict. [Warn] and [Fail] carry a human-readable reason. *)
type verdict =
  | Pass
  | Warn of string
  | Fail of string

(** Verification dimension. *)
type dimension =
  | Relevance  (** Content has substance — minimum length, not filler. *)
  | Quality    (** Well-formed — no character/token repetition, coherent. *)
  | Safety     (** No shouting / spam indicators. *)

(** Per-dimension result pair (used by {!to_dimension_results}). *)
type dimension_result = {
  dimension : dimension;
  verdict : verdict;
}

(** Aggregate result across all three dimensions.
    [overall] is [Fail] if any dimension failed, else [Warn] if any warned,
    else [Pass]. *)
type verification_result = {
  relevance : verdict;
  quality : verdict;
  safety : verdict;
  overall : verdict;
}

(** {1 Verification} *)

(** Verify [content] across Relevance, Quality, Safety. *)
val verify : content:string -> verification_result

(** [true] when [overall] is [Pass] or [Warn], [false] on [Fail]. *)
val is_acceptable : verification_result -> bool

(** {1 Serialization / display} *)

(** Render a verdict as ["pass"], ["warn(reason)"], or ["fail(reason)"]. *)
val verdict_to_string : verdict -> string

(** Render a dimension as ["relevance"], ["quality"], or ["safety"]. *)
val dimension_to_string : dimension -> string

(** JSON shape for telemetry:
    {[
      { "relevance": "pass",
        "quality": "warn(reason)",
        "safety": "pass",
        "overall": "warn(reason)",
        "acceptable": true }
    ]} *)
val result_to_json : verification_result -> Yojson.Safe.t

(** Flatten a {!verification_result} into a list of three
    {!dimension_result} entries (Relevance, Quality, Safety). *)
val to_dimension_results : verification_result -> dimension_result list
