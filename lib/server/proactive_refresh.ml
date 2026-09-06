(** Proactive_refresh -- Reusable refresh loop with circuit breaker.

    Runs a [compute] function periodically in a background fiber, storing
    the result via [on_result].  On repeated failures the interval doubles
    (exponential backoff, capped at [max_backoff_s]).  On recovery the
    interval resets and a log message is emitted. *)

type phase =
  | Warm_cache
  | Refresh

type timeout =
  { label : string
  ; phase : phase
  ; timeout_s : float
  ; elapsed_s : float
  }

type failure =
  | Timed_out of timeout
  | Raised of exn

let phase_to_string = function
  | Warm_cache -> "warm_cache"
  | Refresh -> "refresh"
;;

let timeout_detail timeout =
  Printf.sprintf
    "refresh_timeout label=%s phase=%s timeout_s=%.1f elapsed_s=%.1f"
    timeout.label
    (phase_to_string timeout.phase)
    timeout.timeout_s
    timeout.elapsed_s
;;

let failure_message = function
  | Timed_out timeout -> Printf.sprintf "Failure(%S)" (timeout_detail timeout)
  | Raised exn -> Printexc.to_string exn
;;

type config = {
  label : string;
  interval_s : float;
  max_backoff_s : float;
  failure_threshold : int;
  timeout_s : float;
  on_failure : (failure -> unit) option;
  wakeup : unit Eio.Stream.t option;
  wakeup_coalesce_s : float;
  warm_delay_s : float;
  warn_first_failure : bool;
}

let default_config ~label ~interval_s =
  {
    label;
    interval_s;
    max_backoff_s = 60.0;
    failure_threshold = 3;
    timeout_s = 10.0;
    on_failure = None;
    wakeup = None;
    wakeup_coalesce_s = 0.0;
    warm_delay_s = 0.0;
    warn_first_failure = true;
  }

let should_reraise_cancel exn =
  match exn with
  | Eio.Cancel.Cancelled _ -> not (Cancel_safe.is_internal_race_cancel exn)
  | _ -> false

let timeout_failure ~config ~phase ~elapsed_s =
  Timed_out
    { label = config.label
    ; phase
    ; timeout_s = config.timeout_s
    ; elapsed_s
    }

let is_power_of_two n = n > 0 && n land (n - 1) = 0

let should_warn_refresh_failure ?(warn_first_failure = true) ~failure_threshold
    consecutive_failures =
  (warn_first_failure && consecutive_failures = 1)
  || consecutive_failures = failure_threshold
  || (consecutive_failures > failure_threshold
      && is_power_of_two consecutive_failures)

let log_dashboard_refresh_failure ~warn message =
  if warn then Log.Dashboard.warn "%s" message
  else Log.Dashboard.debug "%s" message

let log_refresh_failure ~config ~consecutive_failures ~current_interval ~dt failure =
  incr consecutive_failures;
  if !consecutive_failures >= config.failure_threshold then
    current_interval :=
      min config.max_backoff_s (!current_interval *. 2.0);
  let message =
    Printf.sprintf
      "%s refresh failed (%d consecutive, next in %.0fs, %.1fs): %s"
      config.label !consecutive_failures !current_interval dt
      (failure_message failure)
  in
  log_dashboard_refresh_failure message
    ~warn:
      (should_warn_refresh_failure
         ~failure_threshold:config.failure_threshold
         ~warn_first_failure:config.warn_first_failure
         !consecutive_failures)

let notify_failure config failure =
  match config.on_failure with
  | Some f -> Safe_ops.protect ~default:() (fun () -> f failure)
  | None -> ()

let start ~sw ~clock ~config:raw_config ~compute ~on_result =
  (* Clamp timeout below interval to prevent overlapping refreshes.
     When timeout >= interval, a timed-out compute runs past the next
     scheduled refresh, causing cascading failures (#7164). *)
  let config =
    if raw_config.timeout_s >= raw_config.interval_s then begin
      let clamped = raw_config.interval_s *. 0.8 in
      Log.Dashboard.warn
        "%s: timeout_s (%.0f) >= interval_s (%.0f), clamping to %.0fs"
        raw_config.label raw_config.timeout_s raw_config.interval_s clamped;
      { raw_config with timeout_s = clamped }
    end else
      raw_config
  in
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run ~name:(config.label ^ " warm") @@ fun _ ->
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
         let dt = Time_compat.now () -. t0 in
         let failure = timeout_failure ~config ~phase:Warm_cache ~elapsed_s:dt in
         notify_failure config failure;
         Log.Dashboard.warn "%s warm cache skipped (%.1fs timeout=%.1fs): %s"
           config.label dt config.timeout_s (failure_message failure)
     with
     | exn ->
       if should_reraise_cancel exn then
         raise exn
       else begin
         let failure = Raised exn in
         notify_failure config failure;
         Log.Dashboard.warn "%s warm cache failed (%.1fs): %s" config.label
           (Time_compat.now () -. t0) (failure_message failure)
       end));
  Eio.Fiber.fork ~sw (fun () ->
    Eio.Switch.run ~name:(config.label ^ " refresh") @@ fun _ ->
    Log.Dashboard.info "starting %s refresh loop" config.label;
    let consecutive_failures = ref 0 in
    let current_interval = ref config.interval_s in
    let wait_for_interval_or_wakeup seconds =
      match config.wakeup with
      | None -> Eio.Time.sleep clock seconds
      | Some stream ->
        let reason =
          Eio.Fiber.first
            (fun () ->
               Eio.Time.sleep clock seconds;
               `Interval)
            (fun () ->
               Eio.Stream.take stream;
               `Wakeup)
        in
        (match reason with
         | `Interval -> ()
         | `Wakeup ->
           let coalesce_s = max 0.0 config.wakeup_coalesce_s in
           if coalesce_s > 0.0 then Eio.Time.sleep clock coalesce_s;
           let siblings = ref 0 in
           while Option.is_some (Eio.Stream.take_nonblocking stream) do
             incr siblings
           done;
           if !siblings > 0
           then
             Log.Dashboard.debug
               "%s coalesced %d sibling wakeup signal(s) over %.3fs"
               config.label
               !siblings
               coalesce_s)
    in
    let rec loop () =
      let jitter = Random.float (!current_interval *. 0.25) in
      wait_for_interval_or_wakeup (!current_interval +. jitter);
      let t0 = Time_compat.now () in
      (try
         match
           Eio.Time.with_timeout clock config.timeout_s (fun () ->
             (* Named per refresh so a tracer attached later still sees it. *)
             Ok (Eio.Switch.run ~name:(config.label ^ " refresh") (fun _ -> compute ())))
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
             let failure = timeout_failure ~config ~phase:Refresh ~elapsed_s:dt in
             notify_failure config failure;
             log_refresh_failure ~config ~consecutive_failures ~current_interval
               ~dt failure
       with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
         if should_reraise_cancel exn then raise exn;
         let dt = Time_compat.now () -. t0 in
         let failure = Raised exn in
         notify_failure config failure;
         log_refresh_failure ~config ~consecutive_failures ~current_interval
           ~dt failure);
      loop ()
    in
    loop ())

module For_testing = struct
  let should_warn_refresh_failure = should_warn_refresh_failure
end
