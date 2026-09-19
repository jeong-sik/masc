type handle =
  { subscription : Agent_core.Event_bus.subscription
  ; reported_dropped_total : int Atomic.t
  }

let subscribe ~capacity ~overflow ~purpose ?filter bus =
  match Agent_core.Event_bus.subscription_config ~capacity ~overflow with
  | Ok config ->
    { subscription = Agent_core.Event_bus.subscribe ~config ?filter ~purpose bus
    ; reported_dropped_total = Atomic.make 0
    }
  | Error (Agent_core.Event_bus.Non_positive_capacity capacity) ->
    invalid_arg
      (Printf.sprintf
         "Event_bus subscriber %S has non-positive capacity %d"
         purpose
         capacity)
;;

let drain handle =
  Eio.Fiber.yield ();
  Agent_core.Event_bus.drain handle.subscription
;;

type overflow_loss =
  | Nothing_dropped
  | Dropped of int

type batch =
  { events : Agent_core.Event_bus.event list
  ; overflow_loss : overflow_loss
  }

let drain_reporting_drops handle =
  let events = drain handle in
  let dropped_total = Agent_core.Event_bus.dropped_total handle.subscription in
  let reported = Atomic.exchange handle.reported_dropped_total dropped_total in
  let overflow_loss =
    if dropped_total > reported
    then Dropped (dropped_total - reported)
    else Nothing_dropped
  in
  { events; overflow_loss }
;;

let unsubscribe bus handle = Agent_core.Event_bus.unsubscribe bus handle.subscription
let publish = Agent_core.Event_bus.publish
