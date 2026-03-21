(** Proactive_refresh -- Reusable refresh loop with circuit breaker.

    Runs a [compute] function periodically in a background fiber, storing
    the result via [on_result].  On repeated failures the interval doubles
    (exponential backoff, capped at [max_backoff_s]).  On recovery the
    interval resets and a log message is emitted. *)

type config = {
  label : string;
  interval_s : float;
  max_backoff_s : float;
  failure_threshold : int;
  timeout_s : float;
}

let default_config ~label ~interval_s =
  {
    label;
    interval_s;
    max_backoff_s = 600.0;
    failure_threshold = 3;
    timeout_s = 10.0;
  }

let start ~sw ~clock ~config ~compute ~on_result =
  (* --- Warm cache: run [compute] once synchronously with a timeout
     so the server has data before the first async tick.  If it takes
     longer than [timeout_s] the async loop will populate it. *)
  (let t0 = Time_compat.now () in
   try
     match
       Eio.Time.with_timeout clock config.timeout_s (fun () -> Ok (compute ()))
     with
     | Ok v ->
       on_result v;
       Log.Dashboard.info "%s warm cache done (%.1fs)" config.label
         (Time_compat.now () -. t0)
     | Error `Timeout ->
       Log.Dashboard.warn "%s warm cache skipped (%.1fs timeout)" config.label
         (Time_compat.now () -. t0)
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Dashboard.warn "%s warm cache failed (%.1fs): %s" config.label
       (Time_compat.now () -. t0) (Printexc.to_string exn));
  (* --- Background refresh loop with circuit breaker. *)
  Eio.Fiber.fork ~sw (fun () ->
    Log.Dashboard.info "starting %s refresh loop" config.label;
    let consecutive_failures = ref 0 in
    let current_interval = ref config.interval_s in
    let rec loop () =
      let t0 = Time_compat.now () in
      (try
         let v = compute () in
         on_result v;
         let dt = Time_compat.now () -. t0 in
         if !consecutive_failures > 0 then
           Log.Dashboard.info "%s refresh recovered after %d failures"
             config.label !consecutive_failures;
         consecutive_failures := 0;
         current_interval := config.interval_s;
         Log.Dashboard.info "%s refreshed (%.1fs)" config.label dt
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         let dt = Time_compat.now () -. t0 in
         consecutive_failures := !consecutive_failures + 1;
         if !consecutive_failures >= config.failure_threshold then
           current_interval :=
             min config.max_backoff_s (!current_interval *. 2.0);
         Log.Dashboard.warn
           "%s refresh failed (%d consecutive, next in %.0fs, %.1fs): %s"
           config.label !consecutive_failures !current_interval dt
           (Printexc.to_string exn));
      Eio.Time.sleep clock !current_interval;
      loop ()
    in
    loop ())
