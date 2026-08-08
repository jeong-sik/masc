(** Run lifecycle events (AgentStarted/AgentCompleted/AgentFailed).

    The run-level lifecycle triple lost its only producer when the legacy
    orchestrator was removed (#1755); the variants and downstream subscribers
    stayed behind.  Envelope identity follows the removed producer's
    derivation so the triple joins the surrounding event stream:
    [correlation_id] is the raw-trace session id when present (same source
    as turn-level events, see [Pipeline_common.event_envelope]);
    [AgentStarted] opens a fresh run id; the terminal events reuse the
    lifecycle [current_run_id] (raw-trace run id) when one is active; and
    terminal [caused_by] points at the started event's run id (#877).
    [task_id] carries the started run id — the only run-scoped identifier
    available without an orchestrator task — so subscribers can group the
    triple of one run invocation. *)

let _log = Log.create ~module_name:"agent_lifecycle_events" ()

let publish_started ~event_bus ~agent_name ~correlation_id =
  match event_bus with
  | None -> None
  | Some bus ->
    let correlation_id =
      match correlation_id with
      | Some session_id -> session_id
      | None -> Event_bus.fresh_id ()
    in
    let run_id = Event_bus.fresh_id () in
    (try
       Event_bus.publish
         bus
         (Event_bus.mk_event
            ~correlation_id
            ~run_id
            (AgentStarted { agent_name; task_id = run_id }))
     with
     | exn ->
       Llm_provider.Reserved_exn.reraise_if_reserved exn;
       Log.warn
         _log
         "Event_bus.publish failed (AgentStarted)"
         [ Log.S ("error", Printexc.to_string exn) ]);
    Some (correlation_id, run_id)
;;

let publish_finished ~event_bus ~agent_name ~started ~current_run_id ~result ~elapsed =
  match event_bus, started with
  | Some bus, Some (correlation_id, started_run_id) ->
    let run_id =
      match current_run_id with
      | Some run_id -> run_id
      | None -> Event_bus.fresh_id ()
    in
    let publish label (payload : Event_bus.payload) =
      try
        Event_bus.publish
          bus
          (Event_bus.mk_event ~correlation_id ~run_id ~caused_by:started_run_id payload)
      with
      | exn ->
        Llm_provider.Reserved_exn.reraise_if_reserved exn;
        Log.warn
          _log
          (Printf.sprintf "Event_bus.publish failed (%s)" label)
          [ Log.S ("error", Printexc.to_string exn) ]
    in
    publish
      "AgentCompleted"
      (AgentCompleted { agent_name; task_id = started_run_id; result; elapsed });
    (* [AgentFailed] is a companion emitted in addition to [AgentCompleted]
       so failure-only subscribers match the variant directly instead of
       destructuring [result]. *)
    (match result with
     | Error error ->
       publish
         "AgentFailed"
         (AgentFailed { agent_name; task_id = started_run_id; error; elapsed })
     | Ok _ -> ())
  | None, _ | Some _, None -> ()
;;

let validate_run_callbacks ~on_yield ~on_resume =
  match on_yield, on_resume with
  | Some _, None | None, Some _ ->
    Error
      (Error.Config
         (Error.InvalidConfig
            { field = "on_yield/on_resume"
            ; detail = "callbacks must be supplied together or both omitted"
            }))
  | Some _, Some _ | None, None -> Ok ()
;;

let with_run_lifecycle_events ~event_bus ~agent_name ~raw_trace ~current_run_id ~project f
  =
  let started_at = Unix.gettimeofday () in
  let started =
    publish_started
      ~event_bus
      ~agent_name
      ~correlation_id:(Option.bind raw_trace Raw_trace.session_id)
  in
  (* Mirror the [with_raw_trace_run_classified_result] exception arm in
     [Agent_trace]: the terminal lifecycle transition must not be skipped
     even when [f] raises (e.g. [Eio.Cancel.Cancelled] on switch failure
     or any synchronous exn from the pipeline).  Subscribers always see
     [AgentStarted] closed by [AgentCompleted]/[AgentFailed]; the original
     exception is then re-raised with its backtrace so callers still
     observe the failure. *)
  match f () with
  | result ->
    publish_finished
      ~event_bus
      ~agent_name
      ~started
      ~current_run_id:(current_run_id ())
      ~result:(Result.map_error project result)
      ~elapsed:(Unix.gettimeofday () -. started_at);
    result
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    let error =
      Error.Internal (Printf.sprintf "Unhandled exception: %s" (Printexc.to_string exn))
    in
    publish_finished
      ~event_bus
      ~agent_name
      ~started
      ~current_run_id:(current_run_id ())
      ~result:(Error error)
      ~elapsed:(Unix.gettimeofday () -. started_at);
    Printexc.raise_with_backtrace exn backtrace
;;
