(* Guards the deliberate backpressure-policy choice on the keeper-facing
   [oas_runtime] bus.

   [oas_runtime] MUST be [Drop_oldest], not [Block]: under [Block] a slow
   subscriber back-pressures publishers, so a full 256 buffer freezes every
   keeper fiber inside [Event_bus.publish] with no timeout (RCA 2026-06-10
   sustained fleet freeze). Every oas_runtime subscriber is observational and
   durable replay reads the JSONL surface, so no consumer needs completeness.

   [masc_domain] stays [Block] (workspace-invariant events).

   OAS [test_event_bus.ml] proves [Drop_oldest] evicts the queue head when full
   (non-blocking delivery); this test guards MASC's policy *assignment* so a
   revert of [oas_runtime] to [Block] fails CI. *)

open Masc

let test_oas_runtime_drop_oldest () =
  Alcotest.(check bool)
    "oas_runtime uses Drop_oldest so a slow subscriber cannot freeze keeper \
     publishers"
    true
    Masc_event_bus_policy.(oas_runtime.policy = Drop_oldest)

let test_oas_runtime_not_block () =
  Alcotest.(check bool)
    "oas_runtime is NOT Block (Block re-introduces the fleet-freeze coupling)"
    false
    Masc_event_bus_policy.(oas_runtime.policy = Block)

let test_masc_domain_stays_block () =
  Alcotest.(check bool)
    "masc_domain stays Block (workspace-invariant events; not the keeper \
     turn pipeline)"
    true
    Masc_event_bus_policy.(masc_domain.policy = Block)

let () =
  Alcotest.run
    "masc_event_bus_policy"
    [ ( "oas_runtime_backpressure"
      , [ Alcotest.test_case "oas_runtime = Drop_oldest" `Quick
            test_oas_runtime_drop_oldest
        ; Alcotest.test_case "oas_runtime <> Block" `Quick
            test_oas_runtime_not_block
        ; Alcotest.test_case "masc_domain = Block" `Quick
            test_masc_domain_stays_block
        ] )
    ]
;;
