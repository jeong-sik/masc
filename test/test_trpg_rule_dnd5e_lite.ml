open Masc_mcp
open Yojson.Safe.Util

let test_stat_bonus () =
  Alcotest.(check int) "0 -> 0" 0 (Trpg_rule_dnd5e_lite.stat_bonus 0);
  Alcotest.(check int) "2 -> 0" 0 (Trpg_rule_dnd5e_lite.stat_bonus 2);
  Alcotest.(check int) "3 -> 1" 1 (Trpg_rule_dnd5e_lite.stat_bonus 3);
  Alcotest.(check int) "8 -> 2" 2 (Trpg_rule_dnd5e_lite.stat_bonus 8)

let test_classify_roll () =
  let open Trpg_rule_dnd5e_lite in
  let c1 = classify_roll ~raw_d20:1 ~total:99 in
  Alcotest.(check string) "nat1 tier" "critical_fail" (roll_tier_to_string c1.tier);
  Alcotest.(check bool) "nat1 passed" false c1.passed;

  let c20 = classify_roll ~raw_d20:20 ~total:1 in
  Alcotest.(check string) "nat20 tier" "miracle" (roll_tier_to_string c20.tier);
  Alcotest.(check bool) "nat20 passed" true c20.passed;

  let c_fail = classify_roll ~raw_d20:7 ~total:5 in
  Alcotest.(check string) "fail tier" "fail" (roll_tier_to_string c_fail.tier);

  let c_partial = classify_roll ~raw_d20:7 ~total:6 in
  Alcotest.(check string) "partial tier" "partial" (roll_tier_to_string c_partial.tier);

  let c_success = classify_roll ~raw_d20:7 ~total:11 in
  Alcotest.(check string) "success tier" "success" (roll_tier_to_string c_success.tier);

  let c_great = classify_roll ~raw_d20:7 ~total:16 in
  Alcotest.(check string) "great tier" "great" (roll_tier_to_string c_great.tier)

let test_hp_changed_event () =
  let config =
    `Assoc
      [
        ( "party",
          `Assoc
            [
              ( "grimja",
                `Assoc
                  [
                    ("hp", `Int 30);
                    ("max_hp", `Int 30);
                    ("alive", `Bool true);
                    ("inventory", `List []);
                  ] );
            ] );
        ("world", `Assoc [ ("story_flags", `List []) ]);
      ]
  in
  let ev =
    Trpg_engine_event.make
      ~seq:1
      ~room_id:"room-1"
      ~ts:"2026-02-15T00:00:00Z"
      ~event_type:Trpg_engine_event.Hp_changed
      ~payload:(`Assoc [ ("actor_id", `String "grimja"); ("delta", `Int (-40)) ])
      ()
  in
  let state =
    Trpg_engine_replay.derive_state
      ~rule:(module Trpg_rule_dnd5e_lite)
      ~config
      ~events:[ ev ]
  in
  let hp = state |> member "party" |> member "grimja" |> member "hp" |> to_int in
  let alive = state |> member "party" |> member "grimja" |> member "alive" |> to_bool in
  Alcotest.(check int) "hp clamped to 0" 0 hp;
  Alcotest.(check bool) "alive false on zero hp" false alive

let test_turn_action_proposed_added_to_narration_log () =
  let config =
    `Assoc
      [
        ("party", `Assoc []);
        ("world", `Assoc [ ("story_flags", `List []) ]);
      ]
  in
  let ev =
    Trpg_engine_event.make
      ~seq:1
      ~room_id:"room-1"
      ~ts:"2026-02-15T00:00:00Z"
      ~event_type:Trpg_engine_event.Turn_action_proposed
      ~payload:
        (`Assoc
          [
            ("phase", `String "round");
            ("turn", `Int 3);
            ("actor_id", `String "p01");
            ("keeper", `String "pk-1");
            ("proposed_action", `String "엄폐하며 정찰한다.");
          ])
      ()
  in
  let state =
    Trpg_engine_replay.derive_state
      ~rule:(module Trpg_rule_dnd5e_lite)
      ~config
      ~events:[ ev ]
  in
  let narration_log = state |> member "narration_log" |> to_list in
  Alcotest.(check int) "narration entry count" 1 (List.length narration_log);
  let entry = List.hd narration_log in
  Alcotest.(check string) "role preserved as player"
    "player" (entry |> member "role" |> to_string);
  Alcotest.(check string) "reply uses proposed_action"
    "엄폐하며 정찰한다." (entry |> member "reply" |> to_string)

let test_room_restart_clears_previous_session_state () =
  let initial_config =
    `Assoc
      [
        ( "party",
          `Assoc
            [
              ( "p01",
                `Assoc
                  [
                    ("name", `String "Old Hero");
                    ("hp", `Int 10);
                    ("max_hp", `Int 10);
                    ("alive", `Bool true);
                  ] );
            ] );
        ("world", `Assoc [ ("story_flags", `List [ `String "old.flag" ]) ]);
      ]
  in
  let restarted_config =
    `Assoc
      [
        ( "party",
          `Assoc
            [
              ( "p02",
                `Assoc
                  [
                    ("name", `String "New Hero");
                    ("hp", `Int 12);
                    ("max_hp", `Int 12);
                    ("alive", `Bool true);
                  ] );
            ] );
        ("world", `Assoc [ ("story_flags", `List [ `String "new.flag" ]) ]);
      ]
  in
  let mk_event ~seq ~event_type ~payload =
    Trpg_engine_event.make
      ~seq
      ~room_id:"room-1"
      ~ts:"2026-02-20T00:00:00Z"
      ~event_type
      ~payload
      ()
  in
  let events =
    [
      mk_event
        ~seq:1
        ~event_type:Trpg_engine_event.Dice_rolled
        ~payload:(`Assoc [ ("actor_id", `String "p01"); ("total", `Int 14) ]);
      mk_event
        ~seq:2
        ~event_type:Trpg_engine_event.Narration_posted
        ~payload:
          (`Assoc
            [
              ("turn", `Int 1);
              ("phase", `String "round");
              ("actor_id", `String "p01");
              ("reply", `String "old narration");
            ]);
      mk_event
        ~seq:3
        ~event_type:Trpg_engine_event.Session_outcome
        ~payload:
          (`Assoc
            [
              ("outcome", `String "draw");
              ("reason", `String "max_turn_reached");
            ]);
      mk_event
        ~seq:4
        ~event_type:Trpg_engine_event.Room_created
        ~payload:(`Assoc [ ("config", restarted_config) ]);
      mk_event
        ~seq:5
        ~event_type:Trpg_engine_event.Room_started
        ~payload:(`Assoc []);
    ]
  in
  let state =
    Trpg_engine_replay.derive_state
      ~rule:(module Trpg_rule_dnd5e_lite)
      ~config:initial_config
      ~events
  in
  let status = state |> member "status" |> to_string in
  Alcotest.(check string) "room restarted as active" "active" status;
  Alcotest.(check bool) "session_outcome cleared"
    true
    (state |> member "session_outcome" = `Null);
  Alcotest.(check int) "dice_log cleared"
    0 (state |> member "dice_log" |> to_list |> List.length);
  Alcotest.(check int) "narration_log cleared"
    0 (state |> member "narration_log" |> to_list |> List.length);
  let party = state |> member "party" |> to_assoc in
  Alcotest.(check bool) "old actor removed" false (List.mem_assoc "p01" party);
  Alcotest.(check bool) "new actor present" true (List.mem_assoc "p02" party)

let () =
  Alcotest.run "TRPG Rule DnD5e Lite"
    [
      ("math", [ Alcotest.test_case "stat bonus" `Quick test_stat_bonus ]);
      ("tier", [ Alcotest.test_case "classify roll" `Quick test_classify_roll ]);
      ( "event",
        [
          Alcotest.test_case "hp changed applies" `Quick test_hp_changed_event;
          Alcotest.test_case "turn action proposed logs narration" `Quick
            test_turn_action_proposed_added_to_narration_log;
          Alcotest.test_case "room restart clears previous session state" `Quick
            test_room_restart_clears_previous_session_state;
        ] );
    ]
