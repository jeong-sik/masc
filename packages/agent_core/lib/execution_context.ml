type child_scope_factory =
  agent_name:string -> (Execution_agent_scope.t, Execution_agent_scope.error) result

let child_scope_factory_key : child_scope_factory Eio.Fiber.key = Eio.Fiber.create_key ()
let agent_scope_key : Execution_agent_scope.t Eio.Fiber.key = Eio.Fiber.create_key ()

let provider_attempt_key : Execution_agent_scope.provider_attempt Eio.Fiber.key =
  Eio.Fiber.create_key ()
;;

let resume_once_key : bool ref Eio.Fiber.key = Eio.Fiber.create_key ()

let with_child_scope_factory factory run =
  Eio.Fiber.with_binding child_scope_factory_key factory run
;;

let child_scope_factory () = Eio.Fiber.get child_scope_factory_key
let with_agent_scope scope run = Eio.Fiber.with_binding agent_scope_key scope run
let agent_scope () = Eio.Fiber.get agent_scope_key

let with_provider_attempt provider run =
  Eio.Fiber.with_binding provider_attempt_key provider run
;;

let provider_attempt () = Eio.Fiber.get provider_attempt_key
let with_resume_once run = Eio.Fiber.with_binding resume_once_key (ref true) run

let take_resume_once () =
  match Eio.Fiber.get resume_once_key with
  | None -> false
  | Some pending ->
    let value = !pending in
    pending := false;
    value
;;

type bus_observer =
  { register:run_id:Execution_event.Run_id.t -> event_bus:Event_bus.t option -> unit
  ; settled_observers:Tool_contract.Occurrence.t -> unit
  ; flush:unit -> unit
  }
let bus_observer_key : bus_observer Eio.Fiber.key = Eio.Fiber.create_key ()
let with_bus_observer observer run = Eio.Fiber.with_binding bus_observer_key observer run
let bus_observer () = Eio.Fiber.get bus_observer_key
let flush_bus_observations () = match bus_observer () with None -> () | Some observer -> observer.flush ()

let settle_tool_observers invocation =
  match bus_observer (),Tool_contract.Invocation.occurrence invocation with
  | Some observer,Some occurrence -> observer.settled_observers occurrence
  | None,_ | Some _,None -> ()
