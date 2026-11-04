(** JSONL readers and coverage helpers for model inference metrics. *)

open Model_inference_metrics_entry

(** What one physical row gives a reading over the window that starts at
    [since_unix]. A schema violation counts while its row is in the window;
    one with no readable time ([ts_unix = None]) counts wherever its file is
    read. *)
type row_reading =
  | Row_entry of raw_entry
  | Row_schema_violation of { ts_unix : float option; error : parse_error }
  | Row_ignored  (** Older than the window, or a row the reading does not count. *)

val decision_row_reading : since_unix:float -> Yojson.Safe.t -> row_reading
(** A [decisions.jsonl] row. *)

val cost_row_reading : since_unix:float -> Yojson.Safe.t -> row_reading
(** A cost ledger row. A raw provider observation is ignored. *)

val row_in_window : since_unix:float -> row_reading -> bool
(** Whether a reading kept from an earlier read still counts. *)

val decision_log_paths : base_path:string -> (string list, unit) result
(** Every Keeper's decision log, sorted; [Error ()] when the Keeper runtime
    directory cannot be listed (logged). *)

val merge_decision_and_cost_entries : raw_entry list -> raw_entry list -> raw_entry list * int
(** One entry per inference: a decision and a cost row with the same identity
    merge; an identity with more than one of either is excluded and counted. *)

type decision_read = (unit, decision_read_error) result

val read_all_entries :
  base_path:string -> since_unix:float -> raw_entry list * cost_read_result * decision_read
val read_complete_entries :
  base_path:string -> since_unix:float ->
  (raw_entry list * cost_read_result, read_error) result
(** Existing aggregate projections require a complete decision read. Cost read
    diagnostics stay separate so callers retain their cost coverage contract. *)

val usage_signal_present : raw_entry -> bool
(** Input, output, cache-read, cache-creation, and reasoning token counters are
    usage evidence. A billing-only [cost_usd] value is not. *)
val telemetry_signal_present : raw_entry -> bool
val coverage_reason_of_entry : raw_entry -> string option
val coverage_stage_of_entry : raw_entry -> string option

val coverage_reason_counts_of_entries :
  raw_entry list -> coverage_reason_count list

val most_common_stage_of_entries : raw_entry list -> string option
