(* RFC-0020 Phase 1 PR-3: typed keeper cycle channel.

   The keeper cycle channel ("is this turn reactive or scheduled-
   autonomous") is now carried by the closed [keeper_cycle_channel]
   variant instead of a [string -> bool] classifier. These tests pin:
   - the canonical wire codec (Reactive serialises as "turn"),
   - the round-trip channel_of_string (channel_to_string c) = Some c,
   - STRICT parsing: the dropped legacy spellings ("reactive"/"proactive")
     and the non-interaction "heartbeat" marker all parse to None
     (owner decision 2026-06-15 — legacy channel vocabulary removed),
   - the typed is_autonomous predicate that replaces is_autonomous_channel. *)

open Alcotest

module KWO = Masc.Keeper_world_observation

let channel : KWO.keeper_cycle_channel testable =
  testable
    (fun fmt c -> Format.pp_print_string fmt (KWO.channel_to_string c))
    ( = )

let all = [ KWO.Reactive; KWO.Scheduled_autonomous ]

let test_to_string_canonical () =
  check string "Reactive -> turn" "turn" (KWO.channel_to_string KWO.Reactive);
  check string "Scheduled_autonomous -> scheduled_autonomous"
    "scheduled_autonomous"
    (KWO.channel_to_string KWO.Scheduled_autonomous)

let test_round_trip () =
  List.iter
    (fun c ->
      check (option channel) "channel_of_string (channel_to_string c) = Some c"
        (Some c)
        (KWO.channel_of_string (KWO.channel_to_string c)))
    all

let test_of_string_canonical () =
  check (option channel) "turn -> Reactive" (Some KWO.Reactive)
    (KWO.channel_of_string "turn");
  check (option channel) "scheduled_autonomous -> Scheduled_autonomous"
    (Some KWO.Scheduled_autonomous)
    (KWO.channel_of_string "scheduled_autonomous")

let test_of_string_strict_none () =
  List.iter
    (fun s -> check (option channel) s None (KWO.channel_of_string s))
    [ (* dropped legacy spellings *)
      "reactive";
      "proactive";
      (* non-interaction status-tick marker, outside the taxonomy *)
      "heartbeat";
      (* casing / whitespace / unknown are not coerced *)
      "Turn";
      "TURN";
      " turn";
      "scheduled-autonomous";
      "";
      "garbage"
    ]

let test_is_autonomous () =
  check bool "Reactive is not autonomous" false (KWO.is_autonomous KWO.Reactive);
  check bool "Scheduled_autonomous is autonomous" true
    (KWO.is_autonomous KWO.Scheduled_autonomous)

let () =
  run "keeper_cycle_channel"
    [
      ( "codec",
        [
          test_case "to_string canonical" `Quick test_to_string_canonical;
          test_case "round trip" `Quick test_round_trip;
          test_case "of_string canonical" `Quick test_of_string_canonical;
          test_case "of_string strict None" `Quick test_of_string_strict_none;
        ] );
      ("predicate", [ test_case "is_autonomous" `Quick test_is_autonomous ]);
    ]
