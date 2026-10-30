open Agent_types

let persist agent ~pending_input state =
  Agent_checkpoint_sink.persist_for_state
    agent After_input_wait_changed ~pending_input state
;;

let install agent pending =
  Eio.Mutex.use_rw ~protect:true agent.mu (fun () ->
    match persist agent ~pending_input:(Some pending) agent.state with
    | Error _ as error -> error
    | Ok () -> agent.pending_input <- Some pending; Ok ())
;;

let consume agent expected =
  match expected with
  | None -> Ok ()
  | Some expected ->
    Eio.Mutex.use_rw ~protect:true agent.mu (fun () ->
      match Agent_input_request.settle ~current:agent.pending_input expected with
      | Error (Agent_input_request.No_pending_request | Request_not_current) -> Ok ()
      | Ok _ ->
        (match persist agent ~pending_input:None agent.state with
         | Error _ as error -> error
         | Ok () -> agent.pending_input <- None; Ok ()))
;;

let respond agent supplied ~message =
  Eio.Mutex.use_rw ~protect:true agent.mu (fun () ->
    match Agent_input_request.settle ~current:agent.pending_input supplied with
    | Error error -> Error (Input_not_current error)
    | Ok owned ->
      let state = {agent.state with messages=Util.snoc agent.state.messages (message owned)} in
      match persist agent ~pending_input:None state with
      | Error error -> Error (Input_checkpoint_failed error)
      | Ok () -> agent.state <- state; agent.pending_input <- None; Ok ())
;;
