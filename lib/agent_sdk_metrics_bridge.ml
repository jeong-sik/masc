type handle = Agent_sdk.Event_bus.subscription

let subscribe ~capacity ~overflow ~purpose ?filter bus =
  match Agent_sdk.Event_bus.subscription_config ~capacity ~overflow with
  | Ok config -> Agent_sdk.Event_bus.subscribe ~config ?filter ~purpose bus
  | Error (Agent_sdk.Event_bus.Non_positive_capacity capacity) ->
    invalid_arg
      (Printf.sprintf
         "Event_bus subscriber %S has non-positive capacity %d"
         purpose
         capacity)
;;

let drain handle =
  Eio.Fiber.yield ();
  Agent_sdk.Event_bus.drain handle
;;
let unsubscribe = Agent_sdk.Event_bus.unsubscribe
let publish = Agent_sdk.Event_bus.publish
