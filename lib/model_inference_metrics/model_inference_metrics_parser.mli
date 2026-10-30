(** JSONL row parsers for model inference metrics. *)

open Model_inference_metrics_entry

val parse_telemetry_entry :
  Yojson.Safe.t -> since_unix:float -> (raw_entry, parse_error) result

val parse_cost_entry :
  Yojson.Safe.t -> since_unix:float -> (raw_entry, parse_error) result
