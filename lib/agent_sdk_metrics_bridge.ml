type handle = Agent_sdk.Event_bus.subscription

let subscribe ~contract ?(filter = Agent_sdk.Event_bus.accept_all) bus =
  Agent_sdk.Event_bus.subscribe
    ~config:(Masc_event_bus_subscription.subscription_config contract)
    ~filter
    ~purpose:(Masc_event_bus_subscription.purpose contract)
    bus
;;

let drain handle =
  Eio.Fiber.yield ();
  Agent_sdk.Event_bus.drain handle
;;
let unsubscribe = Agent_sdk.Event_bus.unsubscribe
let publish = Agent_sdk.Event_bus.publish
