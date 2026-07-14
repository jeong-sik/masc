type handle = Agent_sdk.Event_bus.subscription

let subscribe ~purpose ?(filter = Agent_sdk.Event_bus.accept_all) bus =
  Agent_sdk.Event_bus.subscribe ~filter ~purpose bus
;;

let drain handle =
  Eio.Fiber.yield ();
  Agent_sdk.Event_bus.drain handle
;;
let unsubscribe = Agent_sdk.Event_bus.unsubscribe
let publish = Agent_sdk.Event_bus.publish
