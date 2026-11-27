(** JSONL row parsers for model inference metrics. *)

open Model_inference_metrics_entry

val parse_telemetry_entry :
  Yojson.Safe.t -> since_unix:float -> (raw_entry, parse_error) result

val parse_decoded_cost_entry :
  Yojson.Safe.t ->
  decoded:Cost_ledger.t ->
  since_unix:float ->
  (raw_entry, parse_error) result
(** Parse a cost row whose core fields were already decoded via
    [Cost_ledger.of_json json]. Callers must pass the [Ok] value from that
    exact [json] and handle [Cost_ledger.Raw_observation] filtering first. *)

val parse_cost_entry :
  Yojson.Safe.t -> since_unix:float -> (raw_entry, parse_error) result

val renderable_timestamp : float -> bool
(** A finite time [Unix.gmtime] can render. *)
