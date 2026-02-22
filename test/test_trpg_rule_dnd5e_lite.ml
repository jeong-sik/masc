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

let combat_party_config =
  `Assoc
    [
      ( "party",
        `Assoc
          [
            ( "warrior",
              `Assoc
                [
                  ("name", `String "Warrior");
                  ("hp", `Int 20);
                  ("max_hp", `Int 20);
                  ("alive", `Bool true);
                  ("atk", `Int 12);
                  ("def", `Int 8);
                  ("inventory", `List []);
                ] );
            ( "goblin",
              `Assoc
                [
                  ("name", `String "Goblin");
                  ("hp", `Int 15);
                  ("max_hp", `Int 15);
                  ("alive", `Bool true);
                  ("atk", `Int 6);
                  ("def", `Int 6);
                  ("inventory", `List []);
                ] );
          ] );
      ("world", `Assoc [ ("story_flags", `List []) ]);
    ]

let test_combat_attack_damages_target () =
  let ev =
    Trpg_engine_event.make ~seq:1 ~room_id:"room-1"
      ~ts:"2026-02-21T00:00:00Z"
      ~event_type:Trpg_engine_event.Combat_attack
      ~payload:
        (`Assoc
          [
            ("actor_id", `String "warrior");
            ("target_id", `String "goblin");
            ("raw_d20", `Int 15);
            ("base_damage", `Int 6);
          ])
      ()
  in
  let state =
    Trpg_engine_replay.derive_state
      ~rule:(module Trpg_rule_dnd5e_lite)
      ~config:combat_party_config ~events:[ ev ]
  in
  (* warrior ATK=12, bonus=12/3=4. raw_d20=15, total=15+4=19 => Great tier *)
  (* damage = round((6+4) * 1.5) = round(15.0) = 15 *)
  (* goblin HP: 15 - 15 = 0 *)
  let goblin_hp =
    state |> member "party" |> member "goblin" |> member "hp" |> to_int
  in
  let goblin_alive =
    state |> member "party" |> member "goblin" |> member "alive" |> to_bool
  in
  Alcotest.(check int) "goblin hp is 0" 0 goblin_hp;
  Alcotest.(check bool) "goblin is dead" false goblin_alive;
  let narration_log = state |> member "narration_log" |> to_list in
  Alcotest.(check bool) "narration has attack entry" true
    (List.length narration_log > 0);
  let entry = List.hd narration_log in
  Alcotest.(check string) "narration type is combat_attack" "combat_attack"
    (entry |> member "type" |> to_string);
  Alcotest.(check string) "tier is great" "great"
    (entry |> member "tier" |> to_string);
  Alcotest.(check int) "damage recorded" 15 (entry |> member "damage" |> to_int)

let test_combat_attack_critical_fail_misses () =
  let ev =
    Trpg_engine_event.make ~seq:1 ~room_id:"room-1"
      ~ts:"2026-02-21T00:00:00Z"
      ~event_type:Trpg_engine_event.Combat_attack
      ~payload:
        (`Assoc
          [
            ("actor_id", `String "warrior");
            ("target_id", `String "goblin");
            ("raw_d20", `Int 1);
            ("base_damage", `Int 6);
          ])
      ()
  in
  let state =
    Trpg_engine_replay.derive_state
      ~rule:(module Trpg_rule_dnd5e_lite)
      ~config:combat_party_config ~events:[ ev ]
  in
  (* nat 1 = Critical_fail, damage multiplier 0.0 => damage = 0 *)
  let goblin_hp =
    state |> member "party" |> member "goblin" |> member "hp" |> to_int
  in
  Alcotest.(check int) "goblin hp unchanged on miss" 15 goblin_hp;
  let entry =
    state |> member "narration_log" |> to_list |> List.hd
  in
  Alcotest.(check string) "tier is critical_fail" "critical_fail"
    (entry |> member "tier" |> to_string);
  Alcotest.(check int) "damage is 0" 0 (entry |> member "damage" |> to_int)

let test_combat_defense_reduces_damage () =
  let ev =
    Trpg_engine_event.make ~seq:1 ~room_id:"room-1"
      ~ts:"2026-02-21T00:00:00Z"
      ~event_type:Trpg_engine_event.Combat_defense
      ~payload:
        (`Assoc
          [
            ("actor_id", `String "warrior");
            ("raw_d20", `Int 15);
            ("incoming_damage", `Int 10);
          ])
      ()
  in
  let state =
    Trpg_engine_replay.derive_state
      ~rule:(module Trpg_rule_dnd5e_lite)
      ~config:combat_party_config ~events:[ ev ]
  in
  (* warrior DEF=8, bonus=8/3=2. raw_d20=15, total=15+2=17 => Great tier *)
  (* mitigation=0.75, mitigated=round(10*0.75)=round(7.5)=8 *)
  (* actual_damage = 10 - 8 = 2 *)
  (* warrior HP: 20 - 2 = 18 *)
  let warrior_hp =
    state |> member "party" |> member "warrior" |> member "hp" |> to_int
  in
  Alcotest.(check int) "warrior hp after defense" 18 warrior_hp;
  let entry =
    state |> member "narration_log" |> to_list |> List.hd
  in
  Alcotest.(check string) "narration type is combat_defense" "combat_defense"
    (entry |> member "type" |> to_string);
  Alcotest.(check int) "mitigated damage" 8
    (entry |> member "mitigated" |> to_int);
  Alcotest.(check int) "actual damage" 2
    (entry |> member "actual_damage" |> to_int)

let test_turn_timeout_advances_turn () =
  let config =
    `Assoc
      [
        ("party", `Assoc []);
        ("world", `Assoc [ ("story_flags", `List []) ]);
      ]
  in
  let ev =
    Trpg_engine_event.make ~seq:1 ~room_id:"room-1"
      ~ts:"2026-02-21T00:00:00Z"
      ~event_type:Trpg_engine_event.Turn_timeout
      ~payload:(`Assoc [ ("actor_id", `String "p01") ])
      ()
  in
  let state =
    Trpg_engine_replay.derive_state
      ~rule:(module Trpg_rule_dnd5e_lite)
      ~config ~events:[ ev ]
  in
  let narration_log = state |> member "narration_log" |> to_list in
  Alcotest.(check bool) "narration has timeout entry" true
    (List.length narration_log > 0);
  let entry = List.hd narration_log in
  Alcotest.(check string) "type is turn_timeout" "turn_timeout"
    (entry |> member "type" |> to_string);
  let turn = state |> member "turn" |> to_int in
  Alcotest.(check int) "turn advanced from 1 to 2" 2 turn

let test_keeper_unavailable_sets_auto_pilot () =
  let config =
    `Assoc
      [
        ( "party",
          `Assoc
            [
              ( "p01",
                `Assoc
                  [
                    ("hp", `Int 10);
                    ("max_hp", `Int 10);
                    ("alive", `Bool true);
                    ("inventory", `List []);
                  ] );
            ] );
        ("world", `Assoc [ ("story_flags", `List []) ]);
      ]
  in
  let ev =
    Trpg_engine_event.make ~seq:1 ~room_id:"room-1"
      ~ts:"2026-02-21T00:00:00Z"
      ~event_type:Trpg_engine_event.Keeper_unavailable
      ~payload:(`Assoc [ ("actor_id", `String "p01") ])
      ()
  in
  let state =
    Trpg_engine_replay.derive_state
      ~rule:(module Trpg_rule_dnd5e_lite)
      ~config ~events:[ ev ]
  in
  let control =
    state |> member "actor_control" |> member "p01" |> to_string
  in
  Alcotest.(check string) "actor set to auto-pilot" "auto-pilot" control;
  let narration_log = state |> member "narration_log" |> to_list in
  Alcotest.(check bool) "narration has keeper_unavailable entry" true
    (List.length narration_log > 0)

let test_world_event_damages_all_alive () =
  let config =
    `Assoc
      [
        ( "party",
          `Assoc
            [
              ( "p1",
                `Assoc
                  [
                    ("hp", `Int 20);
                    ("max_hp", `Int 20);
                    ("alive", `Bool true);
                    ("inventory", `List []);
                  ] );
              ( "p2",
                `Assoc
                  [
                    ("hp", `Int 10);
                    ("max_hp", `Int 10);
                    ("alive", `Bool true);
                    ("inventory", `List []);
                  ] );
              ( "dead_one",
                `Assoc
                  [
                    ("hp", `Int 0);
                    ("max_hp", `Int 10);
                    ("alive", `Bool false);
                    ("inventory", `List []);
                  ] );
            ] );
        ("world", `Assoc [ ("story_flags", `List []) ]);
      ]
  in
  let ev =
    Trpg_engine_event.make ~seq:1 ~room_id:"room-1"
      ~ts:"2026-02-21T00:00:00Z"
      ~event_type:Trpg_engine_event.World_event
      ~payload:
        (`Assoc
          [ ("effect_type", `String "earthquake"); ("damage", `Int 5) ])
      ()
  in
  let state =
    Trpg_engine_replay.derive_state
      ~rule:(module Trpg_rule_dnd5e_lite)
      ~config ~events:[ ev ]
  in
  let p1_hp = state |> member "party" |> member "p1" |> member "hp" |> to_int in
  let p2_hp = state |> member "party" |> member "p2" |> member "hp" |> to_int in
  let dead_hp =
    state |> member "party" |> member "dead_one" |> member "hp" |> to_int
  in
  Alcotest.(check int) "p1 hp reduced by 5" 15 p1_hp;
  Alcotest.(check int) "p2 hp reduced by 5" 5 p2_hp;
  Alcotest.(check int) "dead actor hp unchanged" 0 dead_hp;
  let narration_log = state |> member "narration_log" |> to_list in
  Alcotest.(check bool) "narration has world_event entry" true
    (List.length narration_log > 0)

let test_session_started_sets_timestamp () =
  let config =
    `Assoc
      [
        ("party", `Assoc []);
        ("world", `Assoc [ ("story_flags", `List []) ]);
      ]
  in
  let ev =
    Trpg_engine_event.make ~seq:1 ~room_id:"room-1"
      ~ts:"2026-02-21T12:00:00Z"
      ~event_type:Trpg_engine_event.Session_started
      ~payload:(`Assoc [])
      ()
  in
  let state =
    Trpg_engine_replay.derive_state
      ~rule:(module Trpg_rule_dnd5e_lite)
      ~config ~events:[ ev ]
  in
  let session_started_at =
    state |> member "session_started_at" |> to_string
  in
  Alcotest.(check string) "session_started_at set" "2026-02-21T12:00:00Z"
    session_started_at

let test_advantage_takes_higher_roll () =
  let open Trpg_rule_dnd5e_lite in
  (* Advantage: max(5, 18) = 18. total = 18 + 10/3 + 0 = 18 + 3 = 21. Great. *)
  let result =
    roll_with_advantage ~d20_1:5 ~d20_2:18 ~stat:10 ~modifier:0
  in
  Alcotest.(check string) "advantage uses higher" "great"
    (roll_tier_to_string result.tier);
  (* Disadvantage: min(5, 18) = 5. total = 5 + 3 = 8. Partial. *)
  let result2 =
    roll_with_disadvantage ~d20_1:5 ~d20_2:18 ~stat:10 ~modifier:0
  in
  Alcotest.(check string) "disadvantage uses lower" "partial"
    (roll_tier_to_string result2.tier)

let test_roll_with_modifier () =
  let open Trpg_rule_dnd5e_lite in
  (* raw_d20=10, stat=9 (bonus=3), modifier=2 => total = 10+3+2 = 15. Success. *)
  let r = roll_with_modifier ~raw_d20:10 ~stat:9 ~modifier:2 in
  Alcotest.(check string) "total 15 is success" "success"
    (roll_tier_to_string r.tier);
  Alcotest.(check bool) "success passed" true r.passed;
  (* nat 20 with modifier still miracle *)
  let r2 = roll_with_modifier ~raw_d20:20 ~stat:0 ~modifier:0 in
  Alcotest.(check string) "nat20 is miracle" "miracle"
    (roll_tier_to_string r2.tier)

let test_combat_attack_with_advantage () =
  let ev =
    Trpg_engine_event.make ~seq:1 ~room_id:"room-1"
      ~ts:"2026-02-21T00:00:00Z"
      ~event_type:Trpg_engine_event.Combat_attack
      ~payload:
        (`Assoc
          [
            ("actor_id", `String "warrior");
            ("target_id", `String "goblin");
            ("raw_d20", `Int 3);
            ("d20_2", `Int 18);
            ("advantage", `Bool true);
            ("base_damage", `Int 6);
          ])
      ()
  in
  let state =
    Trpg_engine_replay.derive_state
      ~rule:(module Trpg_rule_dnd5e_lite)
      ~config:combat_party_config ~events:[ ev ]
  in
  (* Advantage: max(3,18)=18. ATK=12, bonus=4. total=18+4=22 => Great *)
  (* damage = round((6+4)*1.5) = 15. goblin HP: 15-15=0 *)
  let goblin_hp =
    state |> member "party" |> member "goblin" |> member "hp" |> to_int
  in
  Alcotest.(check int) "advantage gives great roll, goblin dead" 0 goblin_hp

let () =
  Alcotest.run "TRPG Rule DnD5e Lite"
    [
      ( "math",
        [
          Alcotest.test_case "stat bonus" `Quick test_stat_bonus;
          Alcotest.test_case "roll_with_modifier" `Quick test_roll_with_modifier;
          Alcotest.test_case "advantage/disadvantage" `Quick
            test_advantage_takes_higher_roll;
        ] );
      ("tier", [ Alcotest.test_case "classify roll" `Quick test_classify_roll ]);
      ( "combat",
        [
          Alcotest.test_case "attack damages target" `Quick
            test_combat_attack_damages_target;
          Alcotest.test_case "critical fail misses" `Quick
            test_combat_attack_critical_fail_misses;
          Alcotest.test_case "defense reduces damage" `Quick
            test_combat_defense_reduces_damage;
          Alcotest.test_case "attack with advantage" `Quick
            test_combat_attack_with_advantage;
        ] );
      ( "event",
        [
          Alcotest.test_case "hp changed applies" `Quick test_hp_changed_event;
          Alcotest.test_case "turn action proposed logs narration" `Quick
            test_turn_action_proposed_added_to_narration_log;
          Alcotest.test_case "room restart clears previous session state" `Quick
            test_room_restart_clears_previous_session_state;
          Alcotest.test_case "turn timeout advances turn" `Quick
            test_turn_timeout_advances_turn;
          Alcotest.test_case "keeper unavailable sets auto-pilot" `Quick
            test_keeper_unavailable_sets_auto_pilot;
          Alcotest.test_case "world event damages all alive" `Quick
            test_world_event_damages_all_alive;
          Alcotest.test_case "session started sets timestamp" `Quick
            test_session_started_sets_timestamp;
        ] );
    ]
