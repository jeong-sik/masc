module Scope = Execution_agent_scope
module Run_map = Map.Make(Execution_event.Run_id)
module Occurrence_set = Set.Make(Tool_contract.Occurrence)

let log = Log.create ~module_name:"agent_tool_observer" ()
let report detail =
  try Log.warn log "committed tool observation delivery failed" [Log.S ("detail",detail)] with
  | exn -> Llm_provider.Reserved_exn.reraise_if_reserved exn

let create ~publish scope =
  let mutex=Eio.Mutex.create () in
  let audiences=ref Run_map.empty in
  let settled=ref Occurrence_set.empty in
  let settled_observers occurrence = Eio.Mutex.use_rw ~protect:true mutex (fun () ->
    settled:=Occurrence_set.add occurrence !settled) in
  let ready (event:Event_bus.event) = match event.payload with
    | ToolCompleted {invocation;_} ->
      Option.fold ~none:false ~some:(fun occurrence->Occurrence_set.mem occurrence !settled)
        (Tool_contract.Invocation.occurrence invocation)
    | ToolCalled _ -> true
    | AgentStarted _ | AgentCompleted _ | AgentYielded _ | AgentInputRequired _ | AgentFailed _
    | TurnStarted _ | TurnReady _ | TurnCompleted _ | HandoffRequested _ | HandoffCompleted _
    | ElicitationCompleted _ | ToolApprovalCompleted _ | InferenceTelemetry _ | Custom _ -> false in
  (* One start cursor for this live subscription, never reset by child entry.
     Explicit durable catch-up belongs to the public projection reader. *)
  let cursor=ref (Scope.tool_observation_cursor scope) in
  let register ~run_id ~event_bus =
    Eio.Mutex.use_rw ~protect:true mutex (fun () ->
      audiences:=Run_map.add run_id event_bus !audiences) in
  let flush () =
    let outcome=Eio.Mutex.use_rw ~protect:false mutex (fun () ->
      (* Capture every exception inside the lock so cancellation cannot poison
         coordination. Reserved exceptions are re-raised after normal unlock. *)
      try
        match !cursor with
        | Error error -> `Failed (Scope.error_to_string error)
        | Ok after ->
          match Scope.read_tool_observations scope ~after ~limit:max_int with
          | Error error -> `Failed (Scope.error_to_string error)
          | Ok page ->
            let rec deliver = function
              | [] -> cursor:=Ok page.next_cursor;`Done
              | (observation:Scope.tool_observation)::rest ->
                (match Run_map.find_opt observation.run_id !audiences with
                 | None -> `Failed ("unregistered tool observation audience for run " ^
                                   Execution_event.Run_id.to_string observation.run_id)
                 | Some None -> cursor:=Ok observation.through;deliver rest
                 | Some (Some bus) ->
                   if not (ready observation.event) then `Held
                   else (
                     publish bus observation.event;
                     cursor:=Ok observation.through;
                     deliver rest)) in
            deliver page.observations
      with exn -> `Raised (exn,Printexc.get_raw_backtrace ())) in
    match outcome with
    | `Done | `Held -> ()
    | `Failed detail -> report detail
    | `Raised (exn,backtrace) ->
      (match Llm_provider.Reserved_exn.reraise_if_reserved exn with
       | () -> report (Printexc.to_string exn)
       | exception reserved -> Printexc.raise_with_backtrace reserved backtrace) in
  {Execution_context.register;settled_observers;flush}
