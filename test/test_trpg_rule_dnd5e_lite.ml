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

let () =
  Alcotest.run "TRPG Rule DnD5e Lite"
    [
      ("math", [ Alcotest.test_case "stat bonus" `Quick test_stat_bonus ]);
      ("tier", [ Alcotest.test_case "classify roll" `Quick test_classify_roll ]);
      ("event", [ Alcotest.test_case "hp changed applies" `Quick test_hp_changed_event ]);
    ]
