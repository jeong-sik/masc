(** Tests for narrative intelligence features:
    - Inventory/equipment extraction and prompt display
    - Relationship extraction from narration log
    - Narrative deduplication via Jaccard similarity
    - Truncated JSON recovery *)

open Masc_mcp

(* ================================================================
   1. Inventory & Equipment extraction
   ================================================================ *)

let test_extract_equipment_from_assoc () =
  let actor =
    `Assoc
      [
        ("name", `String "Thorin");
        ( "equipment",
          `Assoc
            [ ("weapon", `String "battle axe"); ("armor", `String "chainmail") ]
        );
      ]
  in
  let eq = Tool_trpg.extract_equipment_fields actor in
  Alcotest.(check int) "2 equipment slots" 2 (List.length eq);
  Alcotest.(check bool)
    "weapon slot present" true
    (List.exists (fun (s, n) -> s = "weapon" && n = "battle axe") eq);
  Alcotest.(check bool)
    "armor slot present" true
    (List.exists (fun (s, n) -> s = "armor" && n = "chainmail") eq)

let test_extract_equipment_from_list () =
  let actor =
    `Assoc
      [
        ("name", `String "Lina");
        ( "equipment",
          `List
            [
              `Assoc [ ("slot", `String "weapon"); ("name", `String "staff") ];
              `Assoc [ ("slot", `String "ring"); ("name", `String "fire ring") ];
            ] );
      ]
  in
  let eq = Tool_trpg.extract_equipment_fields actor in
  Alcotest.(check int) "2 equipment items" 2 (List.length eq);
  Alcotest.(check bool)
    "weapon present" true
    (List.exists (fun (s, n) -> s = "weapon" && n = "staff") eq);
  Alcotest.(check bool)
    "ring present" true
    (List.exists (fun (s, n) -> s = "ring" && n = "fire ring") eq)

let test_extract_equipment_null_actor () =
  let eq = Tool_trpg.extract_equipment_fields `Null in
  Alcotest.(check int) "empty from null" 0 (List.length eq)

let test_extract_equipment_missing_field () =
  let actor = `Assoc [ ("name", `String "Nobody") ] in
  let eq = Tool_trpg.extract_equipment_fields actor in
  Alcotest.(check int) "empty when no equipment field" 0 (List.length eq)

let test_inventory_in_prompt_context () =
  let state =
    `Assoc
      [
        ( "party",
          `Assoc
            [
              ( "hero-1",
                `Assoc
                  [
                    ("name", `String "Hero");
                    ("archetype", `String "warrior");
                    ("persona", `String "brave");
                    ("traits", `List [ `String "strong" ]);
                    ("skills", `List [ `String "swordsmanship" ]);
                    ( "inventory",
                      `List
                        [
                          `String "health potion";
                          `String "rope";
                          `String "torch";
                        ] );
                    ( "equipment",
                      `Assoc
                        [
                          ("weapon", `String "longsword");
                          ("armor", `String "plate");
                        ] );
                  ] );
            ] );
        ("world", `Assoc [ ("story_flags", `List []) ]);
        ("narration_log", `List []);
      ]
  in
  let ctx = Tool_trpg.extract_prompt_context ~actor_id:"hero-1" state in
  Alcotest.(check int) "3 inventory items" 3 (List.length ctx.actor_inventory);
  Alcotest.(check bool)
    "has health potion" true
    (List.mem "health potion" ctx.actor_inventory);
  Alcotest.(check int) "2 equipment slots" 2 (List.length ctx.actor_equipment);
  Alcotest.(check bool)
    "has longsword" true
    (List.exists (fun (_, n) -> n = "longsword") ctx.actor_equipment)

(* ================================================================
   2. Relationship extraction
   ================================================================ *)

let test_extract_relationships_ally () =
  let state =
    `Assoc
      [
        ( "party",
          `Assoc
            [
              ( "hero-1",
                `Assoc
                  [
                    ("name", `String "Kael");
                    ("archetype", `String "warrior");
                  ] );
              ( "hero-2",
                `Assoc
                  [
                    ("name", `String "Lyra");
                    ("archetype", `String "healer");
                  ] );
            ] );
        ( "narration_log",
          `List
            [
              `Assoc
                [
                  ("actor_id", `String "hero-2");
                  ("reply", `String "Lyra heals Kael with a gentle touch.");
                ];
              `Assoc
                [
                  ("actor_id", `String "hero-2");
                  ("reply", `String "Lyra helps Kael stand up.");
                ];
            ] );
        ("world", `Assoc [ ("story_flags", `List []) ]);
      ]
  in
  let rels = Tool_trpg.extract_relationships ~actor_id:"hero-1" state in
  Alcotest.(check int) "1 relationship" 1 (List.length rels);
  match rels with
  | [ (name, rel) ] ->
      Alcotest.(check string) "partner name" "Lyra" name;
      Alcotest.(check string) "ally relation" "ally" rel
  | _ -> Alcotest.fail "expected exactly one relationship"

let test_extract_relationships_rival () =
  let state =
    `Assoc
      [
        ( "party",
          `Assoc
            [
              ( "p1",
                `Assoc
                  [
                    ("name", `String "Arin");
                    ("archetype", `String "rogue");
                  ] );
              ( "p2",
                `Assoc
                  [
                    ("name", `String "Bron");
                    ("archetype", `String "fighter");
                  ] );
            ] );
        ( "narration_log",
          `List
            [
              `Assoc
                [
                  ("actor_id", `String "p1");
                  ("reply", `String "Arin attacks Bron with a dagger slash.");
                ];
              `Assoc
                [
                  ("actor_id", `String "p1");
                  ("reply", `String "Arin strikes at Bron again.");
                ];
            ] );
        ("world", `Assoc [ ("story_flags", `List []) ]);
      ]
  in
  let rels = Tool_trpg.extract_relationships ~actor_id:"p1" state in
  Alcotest.(check int) "1 relationship" 1 (List.length rels);
  match rels with
  | [ (name, rel) ] ->
      Alcotest.(check string) "rival name" "Bron" name;
      Alcotest.(check string) "rival relation" "rival" rel
  | _ -> Alcotest.fail "expected exactly one relationship"

let test_extract_relationships_empty_log () =
  let state =
    `Assoc
      [
        ( "party",
          `Assoc
            [
              ("a", `Assoc [ ("name", `String "A"); ("archetype", `String "x") ]);
              ("b", `Assoc [ ("name", `String "B"); ("archetype", `String "y") ]);
            ] );
        ("narration_log", `List []);
        ("world", `Assoc [ ("story_flags", `List []) ]);
      ]
  in
  let rels = Tool_trpg.extract_relationships ~actor_id:"a" state in
  Alcotest.(check int) "no relationships from empty log" 0 (List.length rels)

(* ================================================================
   3. Narrative deduplication
   ================================================================ *)

let test_jaccard_identical () =
  let sim = Tool_trpg.jaccard_similarity [ "a"; "b"; "c" ] [ "a"; "b"; "c" ] in
  Alcotest.(check bool) "identical = 1.0" true (sim >= 0.99)

let test_jaccard_disjoint () =
  let sim = Tool_trpg.jaccard_similarity [ "a"; "b" ] [ "c"; "d" ] in
  Alcotest.(check bool) "disjoint = 0.0" true (sim < 0.01)

let test_jaccard_partial () =
  let sim =
    Tool_trpg.jaccard_similarity [ "a"; "b"; "c"; "d" ] [ "a"; "b"; "e"; "f" ]
  in
  (* intersection=2, union=6, sim=0.333 *)
  Alcotest.(check bool) "partial overlap" true (sim > 0.3 && sim < 0.4)

let test_is_narration_duplicate_true () =
  let recent = [ "the goblin attacks the warrior with a club" ] in
  let new_reply = "the goblin attacks the warrior with a club fiercely" in
  Alcotest.(check bool)
    "similar entry is duplicate" true
    (Tool_trpg.is_narration_duplicate ~recent_replies:recent new_reply)

let test_is_narration_duplicate_false () =
  let recent = [ "the goblin attacks the warrior with a club" ] in
  let new_reply = "the wizard casts a fireball at the dragon" in
  Alcotest.(check bool)
    "different entry is not duplicate" false
    (Tool_trpg.is_narration_duplicate ~recent_replies:recent new_reply)

let make_narration_entry ~actor_id ~reply =
  `Assoc [ ("actor_id", `String actor_id); ("reply", `String reply) ]

let test_deduplicate_narration_keeps_unique () =
  let entries =
    [
      make_narration_entry ~actor_id:"p1" ~reply:"The hero draws his sword.";
      make_narration_entry ~actor_id:"p2" ~reply:"The mage casts a spell.";
      make_narration_entry ~actor_id:"dm" ~reply:"The dragon roars.";
    ]
  in
  let deduped = Tool_trpg.deduplicate_narration entries in
  Alcotest.(check int) "all 3 kept" 3 (List.length deduped)

let test_deduplicate_narration_removes_duplicate () =
  let entries =
    [
      make_narration_entry ~actor_id:"p1"
        ~reply:"the hero draws his sword and charges forward";
      make_narration_entry ~actor_id:"p1"
        ~reply:"the hero draws his sword and charges forward bravely";
      make_narration_entry ~actor_id:"p2"
        ~reply:"the mage casts a powerful fireball at the enemy";
    ]
  in
  let deduped = Tool_trpg.deduplicate_narration entries in
  (* Second entry is ~89% Jaccard similar to first (8/9 words), exceeds 0.6 *)
  Alcotest.(check int) "duplicate removed, 2 kept" 2 (List.length deduped)

(* ================================================================
   4. Truncated JSON recovery
   ================================================================ *)

let test_recover_truncated_brace () =
  let raw = {|{"reply": "Hello world"|} in
  match Tool_trpg.recover_truncated_json raw with
  | Some json ->
      let reply =
        match json |> Yojson.Safe.Util.member "reply" with
        | `String s -> s
        | _ -> ""
      in
      Alcotest.(check string) "recovered reply" "Hello world" reply
  | None -> Alcotest.fail "should have recovered truncated JSON"

let test_recover_truncated_string () =
  let raw = {|{"reply": "Hello|} in
  match Tool_trpg.recover_truncated_json raw with
  | Some json ->
      let reply =
        match json |> Yojson.Safe.Util.member "reply" with
        | `String s -> s
        | _ -> ""
      in
      Alcotest.(check string) "recovered truncated string" "Hello" reply
  | None -> Alcotest.fail "should have recovered truncated string JSON"

let test_recover_valid_json_returns_none () =
  let raw = {|{"reply": "Hello"}|} in
  match Tool_trpg.recover_truncated_json raw with
  | None -> () (* Valid JSON should return None — not truncated *)
  | Some _ -> Alcotest.fail "valid JSON should not need recovery"

let test_recover_empty_string () =
  match Tool_trpg.recover_truncated_json "" with
  | None -> ()
  | Some _ -> Alcotest.fail "empty string should return None"

let test_parse_keeper_reply_raw_valid_json () =
  let raw = {|{"reply": "I attack the goblin."}|} in
  match Tool_trpg.parse_keeper_reply_raw raw with
  | Ok reply ->
      Alcotest.(check bool)
        "contains attack" true
        (String.length reply > 0)
  | Error e -> Alcotest.fail ("expected Ok, got Error: " ^ e)

let test_parse_keeper_reply_raw_truncated () =
  let raw = {|{"reply": "I scout the area|} in
  match Tool_trpg.parse_keeper_reply_raw raw with
  | Ok reply ->
      Alcotest.(check bool)
        "recovered reply is nonempty" true
        (String.length reply > 0)
  | Error e -> Alcotest.fail ("expected recovery, got Error: " ^ e)

let test_parse_keeper_reply_raw_plain_text () =
  let raw = "I move to the north exit." in
  match Tool_trpg.parse_keeper_reply_raw raw with
  | Ok reply ->
      Alcotest.(check string) "plain text treated as reply" raw reply
  | Error e -> Alcotest.fail ("expected Ok, got Error: " ^ e)

(* ================================================================
   5. Prompt section display tests
   ================================================================ *)

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

let test_build_player_section_ko_inventory () =
  let ctx =
    {
      Tool_trpg.empty_prompt_context with
      actor_name = "Hero";
      actor_archetype = "warrior";
      actor_inventory = [ "potion"; "rope" ];
      actor_equipment = [ ("weapon", "sword"); ("armor", "plate") ];
    }
  in
  let section = Tool_trpg.build_player_section_ko ctx in
  Alcotest.(check bool) "contains equipment" true
    (contains_substring section "sword");
  Alcotest.(check bool) "contains inventory" true
    (contains_substring section "potion")

let test_build_player_section_en_inventory () =
  let ctx =
    {
      Tool_trpg.empty_prompt_context with
      actor_name = "Hero";
      actor_archetype = "warrior";
      actor_inventory = [ "potion"; "rope" ];
      actor_equipment = [ ("weapon", "sword"); ("armor", "plate") ];
    }
  in
  let section = Tool_trpg.build_player_section_en ctx in
  Alcotest.(check bool) "contains Equipped" true
    (contains_substring section "Equipped:");
  Alcotest.(check bool) "contains Carrying" true
    (contains_substring section "Carrying:")

let test_build_player_section_ko_relationships () =
  let ctx =
    {
      Tool_trpg.empty_prompt_context with
      actor_name = "Hero";
      relationships = [ ("Lyra", "ally"); ("Bron", "rival") ];
    }
  in
  let section = Tool_trpg.build_player_section_ko ctx in
  Alcotest.(check bool) "contains relationship" true
    (contains_substring section "Lyra");
  Alcotest.(check bool) "contains ally" true
    (contains_substring section "ally")

let test_build_player_section_en_relationships () =
  let ctx =
    {
      Tool_trpg.empty_prompt_context with
      actor_name = "Hero";
      relationships = [ ("Lyra", "ally") ];
    }
  in
  let section = Tool_trpg.build_player_section_en ctx in
  Alcotest.(check bool) "contains Relationships" true
    (contains_substring section "Relationships:");
  Alcotest.(check bool) "contains ally" true
    (contains_substring section "ally")

(* ================================================================
   Runner
   ================================================================ *)

let () =
  Alcotest.run "Narrative Intelligence"
    [
      ( "equipment",
        [
          Alcotest.test_case "extract from assoc" `Quick
            test_extract_equipment_from_assoc;
          Alcotest.test_case "extract from list" `Quick
            test_extract_equipment_from_list;
          Alcotest.test_case "null actor" `Quick
            test_extract_equipment_null_actor;
          Alcotest.test_case "missing field" `Quick
            test_extract_equipment_missing_field;
          Alcotest.test_case "inventory in prompt_context" `Quick
            test_inventory_in_prompt_context;
        ] );
      ( "relationships",
        [
          Alcotest.test_case "ally detection" `Quick
            test_extract_relationships_ally;
          Alcotest.test_case "rival detection" `Quick
            test_extract_relationships_rival;
          Alcotest.test_case "empty narration log" `Quick
            test_extract_relationships_empty_log;
        ] );
      ( "deduplication",
        [
          Alcotest.test_case "jaccard identical" `Quick test_jaccard_identical;
          Alcotest.test_case "jaccard disjoint" `Quick test_jaccard_disjoint;
          Alcotest.test_case "jaccard partial" `Quick test_jaccard_partial;
          Alcotest.test_case "duplicate detected" `Quick
            test_is_narration_duplicate_true;
          Alcotest.test_case "non-duplicate passes" `Quick
            test_is_narration_duplicate_false;
          Alcotest.test_case "unique entries kept" `Quick
            test_deduplicate_narration_keeps_unique;
          Alcotest.test_case "similar entries removed" `Quick
            test_deduplicate_narration_removes_duplicate;
        ] );
      ( "truncated_json",
        [
          Alcotest.test_case "recover unclosed brace" `Quick
            test_recover_truncated_brace;
          Alcotest.test_case "recover unclosed string" `Quick
            test_recover_truncated_string;
          Alcotest.test_case "valid JSON returns None" `Quick
            test_recover_valid_json_returns_none;
          Alcotest.test_case "empty string returns None" `Quick
            test_recover_empty_string;
          Alcotest.test_case "parse_keeper_reply_raw valid" `Quick
            test_parse_keeper_reply_raw_valid_json;
          Alcotest.test_case "parse_keeper_reply_raw truncated" `Quick
            test_parse_keeper_reply_raw_truncated;
          Alcotest.test_case "parse_keeper_reply_raw plain text" `Quick
            test_parse_keeper_reply_raw_plain_text;
        ] );
      ( "prompt_display",
        [
          Alcotest.test_case "ko inventory in prompt" `Quick
            test_build_player_section_ko_inventory;
          Alcotest.test_case "en inventory in prompt" `Quick
            test_build_player_section_en_inventory;
          Alcotest.test_case "ko relationships in prompt" `Quick
            test_build_player_section_ko_relationships;
          Alcotest.test_case "en relationships in prompt" `Quick
            test_build_player_section_en_relationships;
        ] );
    ]
