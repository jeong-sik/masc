open Masc

let subscribers =
  Masc_event_bus_subscription.
    [ Sse_bridge
    ; Telemetry_consumer
    ; Keeper_turn
    ; Keeper_lifecycle_listener
    ]
;;

let test_every_subscriber_has_validated_nonblocking_contract () =
  List.iter
    (fun subscriber ->
       let contract = Masc_event_bus_subscription.for_subscriber subscriber in
       Alcotest.(check int)
         "capacity remains the declared per-subscriber allocation"
         256
         (Masc_event_bus_subscription.capacity contract);
       Alcotest.(check bool)
         "subscriber never blocks a publisher"
         true
         (Masc_event_bus_subscription.overflow contract
          = Agent_sdk.Event_bus.Drop_oldest))
    subscribers
;;

let test_purposes_are_bounded_and_unique () =
  let purposes =
    List.map
      (fun subscriber ->
         subscriber
         |> Masc_event_bus_subscription.for_subscriber
         |> Masc_event_bus_subscription.purpose)
      subscribers
  in
  Alcotest.(check int)
    "one purpose per closed subscriber kind"
    (List.length purposes)
    (List.length (List.sort_uniq String.compare purposes))
;;

let () =
  Alcotest.run
    "masc_event_bus_subscription"
    [ ( "contract"
      , [ Alcotest.test_case
            "every subscriber owns a validated nonblocking contract"
            `Quick
            test_every_subscriber_has_validated_nonblocking_contract
        ; Alcotest.test_case
            "purposes are bounded and unique"
            `Quick
            test_purposes_are_bounded_and_unique
        ] )
    ]
;;
