(** Optional workspace lane. Availability is installed into Candle_status by
    server startup; each grade/relation/weights request has its own exact run. *)
val available : unit -> (unit, string) result
val run : base_path:string -> Candle_appraisal.runner
module For_testing : sig
  val run_declared : base_path:string -> cli_runner:Keeper_lane_cli_oneshot.runner -> Candle_appraisal.runner
  val run : base_path:string
    -> execute:(request:Candle_appraisal.request -> prompt:string -> (Yojson.Safe.t * string, Candle_appraisal.error) result)
    -> Candle_appraisal.runner
end
