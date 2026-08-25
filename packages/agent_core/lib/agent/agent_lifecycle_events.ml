(** Typed run lifecycle events.

    Envelope identity joins the surrounding event stream:
    [correlation_id] is the raw-trace session id when present (same source
    as turn-level events, see [Pipeline_common.event_envelope]);
    [AgentStarted] opens a fresh run id; the outcome event reuses the
    lifecycle [current_run_id] (raw-trace run id) when one is active; and
    [caused_by] points at the started event's run id (#877).
    [task_id] carries the started run id so subscribers can group one run
    invocation. *)

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

type outcome =
  | Completed of Types.api_response
  | Yielded of { turn : int }
  | Input_required of Error.input_required
  | Failed of Error.t

let publish_finished ~event_bus ~agent_name ~started ~current_run_id ~outcome ~elapsed =
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
    (match outcome with
     | Completed response ->
       publish
         "AgentCompleted"
         (AgentCompleted
            { agent_name; task_id = started_run_id; response; elapsed })
     | Yielded { turn } ->
       publish
         "AgentYielded"
         (AgentYielded { agent_name; task_id = started_run_id; turn; elapsed })
     | Input_required request ->
       publish
         "AgentInputRequired"
         (AgentInputRequired { agent_name; task_id = started_run_id; request; elapsed })
     | Failed error ->
       publish
         "AgentFailed"
         (AgentFailed { agent_name; task_id = started_run_id; error; elapsed }))
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

let with_run_lifecycle_events
      ~event_bus
      ~agent_name
      ~raw_trace
      ~current_run_id
      ~classify
      f
  =
  let started_at = Unix.gettimeofday () in
  let started =
    publish_started
      ~event_bus
      ~agent_name
      ~correlation_id:(Option.bind raw_trace Raw_trace.session_id)
  in
  (* A raised call must still publish its typed failure before the original
     exception is re-raised with the captured backtrace. *)
  match f () with
  | result ->
    publish_finished
      ~event_bus
      ~agent_name
      ~started
      ~current_run_id:(current_run_id ())
      ~outcome:(classify result)
      ~elapsed:(Unix.gettimeofday () -. started_at);
    result
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    (* Classified rather than blanket-[Internal]: a timeout published as an
       invariant failure reads to an operator as a broken agent, and gives a
       downstream classifier free-form text instead of a variant. The re-raise
       below is unchanged, so this never absorbs a cancellation. *)
    let error = Error.of_raised_exn exn in
    publish_finished
      ~event_bus
      ~agent_name
      ~started
      ~current_run_id:(current_run_id ())
      ~outcome:(Failed error)
      ~elapsed:(Unix.gettimeofday () -. started_at);
    Printexc.raise_with_backtrace exn backtrace
;;
