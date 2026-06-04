(** JSON and prompt serializers for model inference metrics. *)

open Model_inference_metrics_entry

val model_stats_to_json : ?model_label:string -> model_stats -> Yojson.Safe.t
val to_json : aggregate -> Yojson.Safe.t
val render_keeper_prompt_feedback : aggregate -> string
val provider_stats_to_json : provider_stats -> Yojson.Safe.t

val compute_cost_latency_json :
  base_path:string -> window_minutes:int -> Yojson.Safe.t
