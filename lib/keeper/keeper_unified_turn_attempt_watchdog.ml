let dispatch
      ~clock
      ~attempt_watchdog_s
      ~oas_timeout_s
      ~on_cancelled
      ~run
  =
  try Eio.Time.with_timeout_exn clock attempt_watchdog_s run with
  | Eio.Cancel.Cancelled _ as e ->
    on_cancelled ();
    raise e
  | Eio.Time.Timeout ->
    Error
      (Agent_sdk.Error.Api
         (Timeout
            { message =
                Printf.sprintf
                  "Turn wall-clock budget exhausted during cascade attempt \
                   (budget=%.1fs, watchdog=%.1fs)"
                  oas_timeout_s
                  attempt_watchdog_s
            }))
;;
