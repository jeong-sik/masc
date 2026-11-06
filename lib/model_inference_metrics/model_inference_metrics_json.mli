(** JSON and prompt serializers for model inference metrics. *)

open Model_inference_metrics_entry

val to_json : aggregate -> Yojson.Safe.t
val render_keeper_prompt_feedback : aggregate -> string
(** Redacted planning feedback. Pricing and billing fields are excluded. *)
val compute_cost_latency_json :
  base_path:string -> window_minutes:int -> (Yojson.Safe.t, read_error) result
(** Decision read failures propagate to the cache. Token and cost totals are
    nullable: a field is a complete total only when every successful sample in
    its lane reports that field. Explicit reported zero remains zero. Global
    cost is null for no samples or any lane with incomplete cost evidence. *)

(** Operator-only runtime history of a reading; see
    {!Model_inference_metrics.runtime_metrics_json}. *)
val runtime_metrics_json :
  observed_at:float -> window_minutes:int -> Model_inference_metrics_kept.reading -> Yojson.Safe.t

(** {!runtime_metrics_json} of a reading from nothing kept. *)
val compute_runtime_metrics_json : base_path:string -> window_minutes:int -> Yojson.Safe.t
