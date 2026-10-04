(** JSONL readers and coverage helpers for model inference metrics. *)

open Model_inference_metrics_entry

type decision_read =
  | Decisions_read
  | Decision_directory_unavailable
  | Decision_files_unreadable of int
  | Decision_rows_invalid of { malformed_rows : int; schema_violation_rows : int }
(** A missing store is an empty readable inventory. A directory or file that
    cannot be read never confirms absence of runtime activity. *)

val read_all_entries :
  base_path:string -> since_unix:float -> raw_entry list * cost_read_result * decision_read
val usage_signal_present : raw_entry -> bool
(** Input, output, cache-read, cache-creation, and reasoning token counters are
    usage evidence. A billing-only [cost_usd] value is not. *)
val telemetry_signal_present : raw_entry -> bool
val coverage_reason_of_entry : raw_entry -> string option
val coverage_stage_of_entry : raw_entry -> string option

val coverage_reason_counts_of_entries :
  raw_entry list -> coverage_reason_count list

val most_common_stage_of_entries : raw_entry list -> string option
