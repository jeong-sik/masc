(** Optional workspace lane. Availability is installed into Candle_status by
    server startup; each grade/relation/weights request has its own exact run. *)
val available : unit -> (unit, string) result
val declaration_change_probe : unit -> (unit -> bool)
(** Seed before starting the payout worker. Reports changed usable Candle lane
    declarations only; missing/busy publication retains the previous declaration.
    Same-slot provider, credential and prompt changes are not observed. *)
val run : base_path:string -> Candle_appraisal.runner
module For_testing : sig
  val retryable_execution : Agent_core.Exact_output.execution_error_cause -> bool
  val terminal_error : rejected:bool -> retryable:bool
    -> string Agent_core.Exact_output.flow_execution_error -> Candle_appraisal.error
  val run_declared : base_path:string -> cli_runner:Keeper_lane_cli_oneshot.runner -> Candle_appraisal.runner
  val run : base_path:string
    -> execute:(request:Candle_appraisal.request -> prompt:string -> (Yojson.Safe.t * string, Candle_appraisal.error) result)
    -> Candle_appraisal.runner
end
