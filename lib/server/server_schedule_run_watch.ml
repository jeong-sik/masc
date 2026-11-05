module Watch = Schedule_run_watch

(* GitHub's REST limit is 5000 requests an hour per token. One run read every
   30 s is 120 an hour, so the reader account serves about forty runs at once
   before this loop alone spends its limit; a rate-limited answer stops the
   pass and {!pause_after} waits until the time GitHub gave. *)
let poll_interval_sec = 30.0

let pause_after ~now outcomes =
  let wait pause (outcome : Watch.outcome) =
    match outcome.verdict with
    | Watch.Waiting_to_read (Watch.Rate_limited { reset_at = Some at }) ->
      Float.max pause (at -. now)
    | Watch.Waiting_to_read
        ( Watch.Rate_limited { reset_at = None }
        | Watch.Not_visible
        | Watch.Token_rejected
        | Watch.Forbidden
        | Watch.Http_status _
        | Watch.Transport_failed _
        | Watch.Response_unreadable _
        | Watch.Reader_unavailable _
        | Watch.Reader_not_ready _ )
    | Watch.Woken _ | Watch.Waiting_for_run | Watch.Not_woken _ -> pause
  in
  List.fold_left wait poll_interval_sec outcomes
;;

let log_outcome (outcome : Watch.outcome) =
  let run =
    match outcome.target with
    | Some target -> Watch.describe_target target
    | None -> "a watch that cannot be read"
  in
  match outcome.verdict with
  | Watch.Woken (Watch.Run_completed (Some conclusion)) ->
    Log.Server.info
      "schedule_run_watch: woke %s, %s completed: %s"
      outcome.schedule_id
      run
      (Watch.conclusion_to_string conclusion)
  | Watch.Woken (Watch.Run_completed None) ->
    Log.Server.info
      "schedule_run_watch: woke %s, %s completed with no conclusion"
      outcome.schedule_id
      run
  | Watch.Woken (Watch.Run_unreadable failure) ->
    Log.Server.warn
      "schedule_run_watch: woke %s early, %s cannot be read: %s"
      outcome.schedule_id
      run
      (Watch.read_failure_to_string failure)
  | Watch.Waiting_to_read failure ->
    Log.Server.warn
      "schedule_run_watch: %s waits, %s cannot be read now: %s"
      outcome.schedule_id
      run
      (Watch.read_failure_to_string failure)
  | Watch.Not_woken detail ->
    Log.Server.warn "schedule_run_watch: %s not woken: %s" outcome.schedule_id detail
  | Watch.Waiting_for_run -> ()
;;

let pass ~now ~http_get ~config =
  let runner_tick_sec = Env_config_runtime_services.ScheduleRunner.interval_sec in
  match
    Watch.tick
      config
      ~now:(now ())
      ~runner_tick_sec
      ~read:(Server_github_run_reader.read ~now ~http_get ~config)
  with
  | Error detail ->
    Log.Server.warn "schedule_run_watch: the schedule store cannot be read: %s" detail;
    poll_interval_sec
  | Ok outcomes ->
    List.iter log_outcome outcomes;
    pause_after ~now:(now ()) outcomes
;;

let run ~clock ~config =
  let rec loop () =
    let pause =
      try
        pass
          ~now:Time_compat.now
          ~http_get:Server_repository_pulls.default_http_get
          ~config
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Server.warn "schedule_run_watch: a pass raised %s" (Printexc.to_string exn);
        poll_interval_sec
    in
    Eio.Time.sleep clock pause;
    loop ()
  in
  loop ()
;;
