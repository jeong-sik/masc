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
  on_error : (exn -> unit) option;
  health_check : (unit -> bool) option;
  warm_delay_s : float;
}

let default_config ~label ~interval_s =
  {
    label;
    interval_s;
    max_backoff_s = 120.0;
    failure_threshold = 5;
    timeout_s = 10.0;
    on_error = None;
    health_check = None;
    warm_delay_s = 0.0;
  }

let is_internal_race_cancel exn =
  match exn with
  | Eio.Cancel.Cancelled _ ->
      let msg = Printexc.to_string exn in
      String.equal msg "Cancelled: Eio__core__Fiber.Not_first"
      || String.ends_with ~suffix:"Eio__core__Fiber.Not_first" msg
  | _ -> false

let should_reraise_cancel exn =
  match exn with
  | Eio.Cancel.Cancelled _ -> not (is_internal_race_cancel exn)
  | _ -> false

let log_refresh_failure ~config ~consecutive_failures ~current_interval ~dt exn =
  incr consecutive_failures;
  if !consecutive_failures >= config.failure_threshold then
    current_interval :=
      min config.max_backoff_s (!current_interval *. 2.0);
  Log.Dashboard.warn
    "%s refresh failed (%d consecutive, next in %.0fs, %.1fs): %s"
    config.label !consecutive_failures !current_interval dt
    (Printexc.to_string exn)

let notify_error config exn =
  match config.on_error with
  | Some f -> Safe_ops.protect ~default:() (fun () -> f exn)
  | None -> ()

let start ~sw ~clock ~config ~compute ~on_result =
  Eio.Fiber.fork ~sw (fun () ->
    if config.warm_delay_s > 0.0 then begin
      Log.Dashboard.debug "%s warm cache delayed %.0fs" config.label config.warm_delay_s;
      Eio.Time.sleep clock config.warm_delay_s
    end;
    let t0 = Time_compat.now () in
    (try
       match
         Eio.Time.with_timeout clock config.timeout_s (fun () -> Ok (compute ()))
       with
       | Ok v ->
         on_result v;
         Log.Dashboard.info "%s warm cache done (%.1fs)" config.label
           (Time_compat.now () -. t0)
       | Error `Timeout ->
         notify_error config (Failure "timeout");
         Log.Dashboard.warn "%s warm cache skipped (%.1fs timeout)" config.label
           (Time_compat.now () -. t0)
     with
     | exn ->
       if should_reraise_cancel exn then
         raise exn
       else begin
         notify_error config exn;
         Log.Dashboard.warn "%s warm cache failed (%.1fs): %s" config.label
           (Time_compat.now () -. t0) (Printexc.to_string exn)
       end));
  Eio.Fiber.fork ~sw (fun () ->
    Log.Dashboard.info "starting %s refresh loop" config.label;
    let consecutive_failures = ref 0 in
    let current_interval = ref config.interval_s in
    let rec loop () =
      let jitter = Random.float (!current_interval *. 0.25) in
      Eio.Time.sleep clock (!current_interval +. jitter);
      let health_ok = match config.health_check with
        | None -> true
        | Some check -> Safe_ops.protect ~default:false check
      in
      if not health_ok then begin
        incr consecutive_failures;
        if !consecutive_failures >= config.failure_threshold then
          current_interval :=
            min config.max_backoff_s (!current_interval *. 2.0);
        Log.Dashboard.warn
          "%s skipped: health gate failed (%d consecutive, next in %.0fs)"
          config.label !consecutive_failures !current_interval
      end else
      let t0 = Time_compat.now () in
      (try
         match
           Eio.Time.with_timeout clock config.timeout_s (fun () -> Ok (compute ()))
         with
         | Ok v ->
         on_result v;
         let dt = Time_compat.now () -. t0 in
         if !consecutive_failures > 0 then
           Log.Dashboard.info "%s refresh recovered after %d failures"
             config.label !consecutive_failures;
         consecutive_failures := 0;
         current_interval := config.interval_s;
         (* Adaptive: if compute took >50% of base interval, double next interval
            to reduce overlap probability when compute is slow *)
         if dt > config.interval_s *. 0.5 then begin
           current_interval :=
             min config.max_backoff_s (config.interval_s *. 2.0);
           Log.Dashboard.info
             "%s: compute %.1fs > 50%% of %.0fs, next interval %.0fs"
             config.label dt config.interval_s !current_interval
         end;
         (* Sub-second refreshes are cache hits — log at debug to reduce noise *)
         if dt >= 1.0 then
           Log.Dashboard.info "%s refreshed (%.1fs)" config.label dt
         else
           Log.Dashboard.debug "%s refreshed (%.1fs)" config.label dt
         | Error `Timeout ->
             let dt = Time_compat.now () -. t0 in
             let timeout_exn = Failure "timeout" in
             notify_error config timeout_exn;
             log_refresh_failure ~config ~consecutive_failures ~current_interval
               ~dt timeout_exn
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         if should_reraise_cancel exn then raise exn;
         let dt = Time_compat.now () -. t0 in
         notify_error config exn;
         log_refresh_failure ~config ~consecutive_failures ~current_interval
           ~dt exn);
      loop ()
    in
    loop ())
