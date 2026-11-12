module Watch = Schedule_run_watch
module Checks = Schedule_checks_watch

(* GitHub's REST limit is 5000 requests an hour per token. One run read every
   30 s is 120 an hour, so the reader account serves about forty runs at once
   before this loop alone spends its limit; a rate-limited answer stops the
   pass and {!pause_after} waits until the time GitHub gave. *)
let poll_interval_sec = 30.0

(* [Some reset_at] for a rate-limited read ([reset_at] is what GitHub gave, if
   it gave one), [None] for every other failure. *)
let rate_limit_of : Watch.read_failure -> float option option = function
  | Watch.Rate_limited { reset_at } -> Some reset_at
  | Watch.Not_visible
  | Watch.Token_rejected
  | Watch.Forbidden
  | Watch.Http_status _
  | Watch.Transport_failed _
  | Watch.Response_unreadable _
  | Watch.Reader_unavailable _
  | Watch.Reader_not_ready _ -> None
;;

let is_rate_limited failure = Option.is_some (rate_limit_of failure)

let pause_after_failures ~now failures =
  let wait pause failure =
    match rate_limit_of failure with
    | Some (Some at) -> Float.max pause (at -. now)
    | Some None | None -> pause
  in
  List.fold_left wait poll_interval_sec failures
;;

let waiting_failure_of_run (outcome : Watch.outcome) =
  match outcome.verdict with
  | Watch.Waiting_to_read failure -> Some failure
  | Watch.Woken _ | Watch.Waiting_for_run | Watch.Not_woken _ -> None
;;

let waiting_failure_of_checks (outcome : Checks.outcome) =
  match outcome.verdict with
  | Checks.Waiting_to_read failure -> Some failure
  | Checks.Woken _ | Checks.Waiting_for_checks | Checks.Not_woken _ -> None
;;

let pause_after ~now outcomes =
  pause_after_failures ~now (List.filter_map waiting_failure_of_run outcomes)
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

let log_checks_outcome (outcome : Checks.outcome) =
  let commit =
    match outcome.target with
    | Some target -> Checks.describe_target target
    | None -> "a watch that cannot be read"
  in
  match outcome.verdict with
  | Checks.Woken (Checks.Checks_completed runs) ->
    Log.Server.info
      "schedule_checks_watch: woke %s, %s: %d check runs completed"
      outcome.schedule_id
      commit
      (List.length runs)
  | Checks.Woken (Checks.Checks_unreadable failure) ->
    Log.Server.warn
      "schedule_checks_watch: woke %s early, the runs of %s cannot be read: %s"
      outcome.schedule_id
      commit
      (Watch.read_failure_to_string failure)
  | Checks.Waiting_to_read failure ->
    Log.Server.warn
      "schedule_checks_watch: %s waits, the runs of %s cannot be read now: %s"
      outcome.schedule_id
      commit
      (Watch.read_failure_to_string failure)
  | Checks.Not_woken detail ->
    Log.Server.warn "schedule_checks_watch: %s not woken: %s" outcome.schedule_id detail
  | Checks.Waiting_for_checks -> ()
;;

(* A pass reads with one account, so the two watches spend one limit. The reads
   a watch could not make are the failures it returns; [None] is a schedule
   store that cannot be read. *)
let run_pass ~now ~http_get ~config ~runner_tick_sec =
  match
    Watch.tick
      config
      ~now:(now ())
      ~runner_tick_sec
      ~read:(Server_github_run_reader.read ~now ~http_get ~config)
  with
  | Error detail ->
    Log.Server.warn "schedule_run_watch: the schedule store cannot be read: %s" detail;
    None
  | Ok outcomes ->
    List.iter log_outcome outcomes;
    Some (List.filter_map waiting_failure_of_run outcomes)
;;

let checks_pass ~now ~http_get ~config ~runner_tick_sec =
  match
    Checks.tick
      config
      ~now:(now ())
      ~runner_tick_sec
      ~read:(Server_github_run_reader.read_checks ~now ~http_get ~config)
  with
  | Error detail ->
    Log.Server.warn "schedule_checks_watch: the schedule store cannot be read: %s" detail;
    []
  | Ok outcomes ->
    List.iter log_checks_outcome outcomes;
    List.filter_map waiting_failure_of_checks outcomes
;;

let pass ~now ~http_get ~config =
  let runner_tick_sec = Env_config_runtime_services.ScheduleRunner.interval_sec in
  match run_pass ~now ~http_get ~config ~runner_tick_sec with
  | None -> poll_interval_sec
  | Some run_failures ->
    (* After a rate-limited answer the commit reads would be refused as well. *)
    let checks_failures =
      if List.exists is_rate_limited run_failures
      then []
      else checks_pass ~now ~http_get ~config ~runner_tick_sec
    in
    pause_after_failures ~now:(now ()) (run_failures @ checks_failures)
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
