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

let start_sampler ~sw:_ ~clock:_ ?interval_s:_ ?warn_threshold:_ () = ()

module For_testing = struct
  type transition =
    [ `Warn of string * int
    | `Recovered of string * int
    ]

  let current_depth ~purpose:_ = 0
  let sample_threshold_transitions ~warn_threshold:_ = []
  let reset () = ()
end
