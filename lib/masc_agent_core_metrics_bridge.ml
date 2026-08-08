type handle = Masc_agent_core.Event_bus.subscription

let subscribe ~capacity ~overflow ~purpose ?filter bus =
  match Masc_agent_core.Event_bus.subscription_config ~capacity ~overflow with
  | Ok config -> Masc_agent_core.Event_bus.subscribe ~config ?filter ~purpose bus
  | Error (Masc_agent_core.Event_bus.Non_positive_capacity capacity) ->
    invalid_arg
      (Printf.sprintf
         "Event_bus subscriber %S has non-positive capacity %d"
         purpose
         capacity)
;;

let drain handle =
  Eio.Fiber.yield ();
  Masc_agent_core.Event_bus.drain handle
;;
let unsubscribe = Masc_agent_core.Event_bus.unsubscribe
let publish = Masc_agent_core.Event_bus.publish
