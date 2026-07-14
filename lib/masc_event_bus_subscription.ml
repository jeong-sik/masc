type subscriber =
  | Sse_bridge
  | Telemetry_consumer
  | Keeper_turn
  | Keeper_lifecycle_listener

type t =
  { purpose : string
  ; capacity : int
  ; overflow : Agent_sdk.Event_bus.overflow
  ; subscription_config : Agent_sdk.Event_bus.subscription_config
  }

let overflow_label = function
  | Agent_sdk.Event_bus.Drop_oldest -> "drop_oldest"
  | Agent_sdk.Event_bus.Drop_newest -> "drop_newest"
;;

(* This is the exact per-subscriber allocation used before OAS moved resource
   ownership from the bus to subscriptions. Keeping one source value avoids a
   behavioural capacity change during the ownership migration. A future change
   must change this resource contract and its pressure telemetry together. *)
let live_projection_capacity = 256

let make ~purpose ~overflow =
  let capacity = live_projection_capacity in
  match Agent_sdk.Event_bus.subscription_config ~capacity ~overflow with
  | Ok subscription_config ->
    { purpose; capacity; overflow; subscription_config }
  | Error (Agent_sdk.Event_bus.Non_positive_capacity rejected_capacity) ->
    invalid_arg
      (Printf.sprintf
         "invalid MASC event-bus subscription capacity for %s: %d"
         purpose
         rejected_capacity)
;;

let sse_bridge =
  make ~purpose:"sse_bridge" ~overflow:Agent_sdk.Event_bus.Drop_oldest
;;

let telemetry_consumer =
  make ~purpose:"telemetry_consumer" ~overflow:Agent_sdk.Event_bus.Drop_oldest
;;

let keeper_turn =
  make ~purpose:"keeper_turn" ~overflow:Agent_sdk.Event_bus.Drop_oldest
;;

let keeper_lifecycle_listener =
  make
    ~purpose:"lifecycle_listener"
    ~overflow:Agent_sdk.Event_bus.Drop_oldest
;;

let for_subscriber = function
  | Sse_bridge -> sse_bridge
  | Telemetry_consumer -> telemetry_consumer
  | Keeper_turn -> keeper_turn
  | Keeper_lifecycle_listener -> keeper_lifecycle_listener
;;

let purpose t = t.purpose
let capacity t = t.capacity
let overflow t = t.overflow
let subscription_config t = t.subscription_config
