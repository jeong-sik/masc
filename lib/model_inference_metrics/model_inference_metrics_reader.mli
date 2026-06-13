(** JSONL readers and coverage helpers for model inference metrics. *)

open Model_inference_metrics_entry

val read_all_decisions : base_path:string -> since_unix:float -> raw_entry list
val read_cost_entries : base_path:string -> since_unix:float -> raw_entry list
val read_all_entries : base_path:string -> since_unix:float -> raw_entry list
val usage_signal_present : raw_entry -> bool
val telemetry_signal_present : raw_entry -> bool
val usage_reported_effective : raw_entry -> bool
val telemetry_reported_effective : raw_entry -> bool
val coverage_reason_of_entry : raw_entry -> string option
val coverage_stage_of_entry : raw_entry -> string option

val coverage_reason_counts_of_entries :
  raw_entry list -> coverage_reason_count list

val most_common_stage_of_entries : raw_entry list -> string option
