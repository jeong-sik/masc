(** JSON and prompt serializers for model inference metrics. *)

open Model_inference_metrics_entry

val to_json : aggregate -> Yojson.Safe.t
val render_keeper_prompt_feedback : aggregate -> string
(** Redacted planning feedback. Pricing and billing fields are excluded. *)
val compute_cost_latency_json :
  base_path:string -> window_minutes:int -> Yojson.Safe.t
