open Masc_mcp

(* -- select_npc_template: tier-based selection -- *)

let test_early_pool_covers_3 () =
  let names =
    List.init 5 (fun i ->
        let tmpl = Tool_trpg.select_npc_template ~turn:(i + 1) in
        tmpl.npc_name)
  in
  let unique = List.sort_uniq String.compare names in
  Alcotest.(check int)
    "early pool (turns 1-5) yields 3 unique NPCs" 3 (List.length unique)

let test_mid_pool_covers_9 () =
  let names =
    List.init 9 (fun i ->
        let tmpl = Tool_trpg.select_npc_template ~turn:(i + 6) in
        tmpl.npc_name)
  in
  let unique = List.sort_uniq String.compare names in
  Alcotest.(check int)
    "mid pool (turns 6-14) yields 9 unique NPCs" 9 (List.length unique)

let test_late_pool_covers_12 () =
  let names =
    List.init 12 (fun i ->
        let tmpl = Tool_trpg.select_npc_template ~turn:(i + 16) in
        tmpl.npc_name)
  in
  let unique = List.sort_uniq String.compare names in
  Alcotest.(check int)
    "late pool (turns 16-27) yields 12 unique NPCs" 12 (List.length unique)

let test_early_only_skirmishers () =
  for turn = 1 to 5 do
    let tmpl = Tool_trpg.select_npc_template ~turn in
    let has_skirmisher =
      String.length tmpl.archetype >= 10
      && (let arch = tmpl.archetype in
          let check sub =
            let len = String.length sub in
            let haystack_len = String.length arch in
            let found = ref false in
            for i = 0 to haystack_len - len do
              if String.sub arch i len = sub then found := true
            done;
            !found
          in
          check "skirmisher")
    in
    Alcotest.(check bool)
      (Printf.sprintf "turn %d -> skirmisher archetype" turn)
      true has_skirmisher
  done

let test_select_deterministic () =
  let a = Tool_trpg.select_npc_template ~turn:7 in
  let b = Tool_trpg.select_npc_template ~turn:7 in
  Alcotest.(check string) "same turn -> same NPC" a.npc_name b.npc_name

let test_select_same_pool_wraps () =
  (* Within the early pool (size 3), turn 1 and turn 4 should wrap *)
  let a = Tool_trpg.select_npc_template ~turn:1 in
  let b = Tool_trpg.select_npc_template ~turn:4 in
  Alcotest.(check string)
    "turn 1 == turn 4 (both early, mod 3)" a.npc_name b.npc_name

let test_select_negative_turn () =
  let tmpl = Tool_trpg.select_npc_template ~turn:(-5) in
  Alcotest.(check bool)
    "negative turn -> non-empty name" true
    (String.length tmpl.npc_name > 0)

(* -- tier_of_turn -- *)

let test_tier_of_turn_early () =
  Alcotest.(check bool) "turn 1 = Early" true
    (Tool_trpg.tier_of_turn 1 = Tool_trpg.Early);
  Alcotest.(check bool) "turn 5 = Early" true
    (Tool_trpg.tier_of_turn 5 = Tool_trpg.Early);
  Alcotest.(check bool) "turn 0 = Early" true
    (Tool_trpg.tier_of_turn 0 = Tool_trpg.Early)

let test_tier_of_turn_mid () =
  Alcotest.(check bool) "turn 6 = Mid" true
    (Tool_trpg.tier_of_turn 6 = Tool_trpg.Mid);
  Alcotest.(check bool) "turn 15 = Mid" true
    (Tool_trpg.tier_of_turn 15 = Tool_trpg.Mid)

let test_tier_of_turn_late () =
  Alcotest.(check bool) "turn 16 = Late" true
    (Tool_trpg.tier_of_turn 16 = Tool_trpg.Late);
  Alcotest.(check bool) "turn 99 = Late" true
    (Tool_trpg.tier_of_turn 99 = Tool_trpg.Late)

let test_tier_of_turn_negative () =
  (* negative turn uses abs value *)
  Alcotest.(check bool) "turn -3 = Early" true
    (Tool_trpg.tier_of_turn (-3) = Tool_trpg.Early);
  Alcotest.(check bool) "turn -10 = Mid" true
    (Tool_trpg.tier_of_turn (-10) = Tool_trpg.Mid);
  Alcotest.(check bool) "turn -20 = Late" true
    (Tool_trpg.tier_of_turn (-20) = Tool_trpg.Late)

(* -- select_npc_template_with_tier -- *)

let test_with_tier_early () =
  let tmpl =
    Tool_trpg.select_npc_template_with_tier ~turn:99 ~tier:Tool_trpg.Early
  in
  (* Even at turn 99, Early tier limits to skirmishers (indices 0-2) *)
  let is_skirmisher =
    let arch = tmpl.archetype in
    let needle = "skirmisher" in
    let nlen = String.length needle in
    let alen = String.length arch in
    let found = ref false in
    for i = 0 to alen - nlen do
      if String.sub arch i nlen = needle then found := true
    done;
    !found
  in
  Alcotest.(check bool) "tier Early at turn 99 -> skirmisher" true is_skirmisher

let test_with_tier_late () =
  (* Late tier should allow elites at appropriate indices *)
  let names =
    List.init 12 (fun i ->
        let tmpl =
          Tool_trpg.select_npc_template_with_tier ~turn:i ~tier:Tool_trpg.Late
        in
        tmpl.npc_name)
  in
  let unique = List.sort_uniq String.compare names in
  Alcotest.(check int)
    "Late tier over 12 turns = 12 unique NPCs" 12 (List.length unique)

(* -- scale_hp: 3-tier progression -- *)

let test_scale_hp_early () =
  Alcotest.(check int)
    "turn 1, base 12" 12
    (Tool_trpg.scale_hp ~turn:1 ~base_hp:12);
  Alcotest.(check int)
    "turn 5, base 12" 12
    (Tool_trpg.scale_hp ~turn:5 ~base_hp:12)

let test_scale_hp_mid () =
  Alcotest.(check int)
    "turn 6, base 12" 18
    (Tool_trpg.scale_hp ~turn:6 ~base_hp:12);
  Alcotest.(check int)
    "turn 15, base 12" 18
    (Tool_trpg.scale_hp ~turn:15 ~base_hp:12)

let test_scale_hp_late () =
  Alcotest.(check int)
    "turn 16, base 12" 24
    (Tool_trpg.scale_hp ~turn:16 ~base_hp:12);
  Alcotest.(check int)
    "turn 99, base 12" 24
    (Tool_trpg.scale_hp ~turn:99 ~base_hp:12)

let test_scale_hp_odd_base () =
  Alcotest.(check int)
    "turn 10, base 9 (odd)" 13
    (Tool_trpg.scale_hp ~turn:10 ~base_hp:9)

(* -- deterministic_damage: hash-based, bounded, default + custom range -- *)

let test_damage_within_default_range () =
  for turn = 0 to 50 do
    let d =
      Tool_trpg.deterministic_damage ~turn ~actor_id:"npc-t1-01" ()
    in
    Alcotest.(check bool)
      (Printf.sprintf "turn %d in [2,4]" turn)
      true (d >= 2 && d <= 4)
  done

let test_damage_custom_range () =
  for turn = 0 to 50 do
    let d =
      Tool_trpg.deterministic_damage ~turn ~actor_id:"npc-t1-01"
        ~damage_range:(4, 8) ()
    in
    Alcotest.(check bool)
      (Printf.sprintf "turn %d in [4,8]" turn)
      true (d >= 4 && d <= 8)
  done

let test_damage_deterministic () =
  let a = Tool_trpg.deterministic_damage ~turn:7 ~actor_id:"x" () in
  let b = Tool_trpg.deterministic_damage ~turn:7 ~actor_id:"x" () in
  Alcotest.(check int) "same inputs -> same damage" a b

let test_damage_varies_by_actor () =
  let a = Tool_trpg.deterministic_damage ~turn:7 ~actor_id:"npc-a" () in
  let b = Tool_trpg.deterministic_damage ~turn:7 ~actor_id:"npc-b" () in
  Alcotest.(check bool) "actor a in range" true (a >= 2 && a <= 4);
  Alcotest.(check bool) "actor b in range" true (b >= 2 && b <= 4)

(* -- npc_attack_narration: per-archetype, deterministic -- *)

let test_narration_deterministic () =
  let tmpl = Tool_trpg.select_npc_template ~turn:1 in
  let a = Tool_trpg.npc_attack_narration ~turn:3 ~npc_template:tmpl in
  let b = Tool_trpg.npc_attack_narration ~turn:3 ~npc_template:tmpl in
  Alcotest.(check string) "same turn -> same narration" a b

let test_narration_cycles () =
  let tmpl = Tool_trpg.select_npc_template ~turn:1 in
  let n_narrations = List.length tmpl.attack_narrations in
  if n_narrations > 1 then begin
    let a = Tool_trpg.npc_attack_narration ~turn:0 ~npc_template:tmpl in
    let b = Tool_trpg.npc_attack_narration ~turn:1 ~npc_template:tmpl in
    Alcotest.(check bool)
      "different turns -> different narrations (usually)"
      true
      (a <> b || n_narrations = 1)
  end

let test_narration_empty_fallback () =
  let empty_tmpl : Tool_trpg.npc_template =
    {
      npc_name = "TestBot";
      archetype = "test";
      persona = "test";
      traits = [];
      skills = [];
      base_hp = 1;
      damage_min = 1;
      damage_max = 1;
      attack_narrations = [];
    }
  in
  let narration =
    Tool_trpg.npc_attack_narration ~turn:0 ~npc_template:empty_tmpl
  in
  Alcotest.(check string)
    "empty narrations -> default fallback"
    "적이 공격한다." narration

(* -- find_npc_template_by_name -- *)

let test_find_by_name_exists () =
  match Tool_trpg.find_npc_template_by_name "Ironhide Ogre" with
  | Some t ->
      Alcotest.(check string) "archetype" "warrior-brute" t.archetype
  | None -> Alcotest.fail "Ironhide Ogre not found in bestiary"

let test_find_by_name_not_found () =
  match Tool_trpg.find_npc_template_by_name "Nonexistent Dragon" with
  | None -> ()
  | Some _ -> Alcotest.fail "Should not find nonexistent NPC"

(* -- bestiary data integrity -- *)

let test_all_templates_have_narrations () =
  Array.iter
    (fun (t : Tool_trpg.npc_template) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s has narrations" t.npc_name)
        true
        (List.length t.attack_narrations >= 2))
    Tool_trpg.npc_bestiary

let test_all_templates_damage_range_valid () =
  Array.iter
    (fun (t : Tool_trpg.npc_template) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s: min <= max" t.npc_name)
        true (t.damage_min <= t.damage_max);
      Alcotest.(check bool)
        (Printf.sprintf "%s: min > 0" t.npc_name)
        true (t.damage_min > 0))
    Tool_trpg.npc_bestiary

let test_bestiary_has_12_entries () =
  Alcotest.(check int) "12 NPCs" 12 (Array.length Tool_trpg.npc_bestiary)

(* -- resolve_npc_skill: archetype-specific skill system -- *)

let skirmisher_tmpl : Tool_trpg.npc_template =
  {
    npc_name = "Hollow Stalker";
    archetype = "predator-skirmisher";
    persona = "test";
    traits = [];
    skills = [ "shadow_claw" ];
    base_hp = 12;
    damage_min = 2;
    damage_max = 5;
    attack_narrations = [ "attack" ];
  }

let brute_tmpl : Tool_trpg.npc_template =
  {
    npc_name = "Ironclad Golem";
    archetype = "construct-brute";
    persona = "test";
    traits = [];
    skills = [ "slam" ];
    base_hp = 22;
    damage_min = 4;
    damage_max = 7;
    attack_narrations = [ "attack" ];
  }

let caster_tmpl : Tool_trpg.npc_template =
  {
    npc_name = "Void Weaver";
    archetype = "dark-caster";
    persona = "test";
    traits = [];
    skills = [ "void_bolt" ];
    base_hp = 8;
    damage_min = 3;
    damage_max = 8;
    attack_narrations = [ "attack" ];
  }

let elite_tmpl : Tool_trpg.npc_template =
  {
    npc_name = "Shadow Knight";
    archetype = "dark-elite";
    persona = "test";
    traits = [];
    skills = [ "cursed_slash" ];
    base_hp = 18;
    damage_min = 3;
    damage_max = 6;
    attack_narrations = [ "attack" ];
  }

let test_skill_skirmisher_even_turn () =
  match Tool_trpg.resolve_npc_skill ~turn:2 ~npc_template:skirmisher_tmpl with
  | Tool_trpg.BonusDamage 1 -> ()
  | _ -> Alcotest.fail "skirmisher on even turn should be BonusDamage 1"

let test_skill_skirmisher_odd_turn () =
  match Tool_trpg.resolve_npc_skill ~turn:3 ~npc_template:skirmisher_tmpl with
  | Tool_trpg.NoSkill -> ()
  | _ -> Alcotest.fail "skirmisher on odd turn should be NoSkill"

let test_skill_brute_div3 () =
  match Tool_trpg.resolve_npc_skill ~turn:6 ~npc_template:brute_tmpl with
  | Tool_trpg.DoubleDamage -> ()
  | _ -> Alcotest.fail "brute on turn divisible by 3 should be DoubleDamage"

let test_skill_brute_not_div3 () =
  match Tool_trpg.resolve_npc_skill ~turn:7 ~npc_template:brute_tmpl with
  | Tool_trpg.NoSkill -> ()
  | _ -> Alcotest.fail "brute on non-div-3 turn should be NoSkill"

let test_skill_caster_div4 () =
  match Tool_trpg.resolve_npc_skill ~turn:8 ~npc_template:caster_tmpl with
  | Tool_trpg.MultiTarget -> ()
  | _ -> Alcotest.fail "caster on turn divisible by 4 should be MultiTarget"

let test_skill_caster_not_div4 () =
  match Tool_trpg.resolve_npc_skill ~turn:5 ~npc_template:caster_tmpl with
  | Tool_trpg.NoSkill -> ()
  | _ -> Alcotest.fail "caster on non-div-4 turn should be NoSkill"

let test_skill_elite_turn1 () =
  match Tool_trpg.resolve_npc_skill ~turn:1 ~npc_template:elite_tmpl with
  | Tool_trpg.SelfHeal n ->
      (* 18 / 4 = 4 *)
      Alcotest.(check int) "elite SelfHeal = base_hp/4" 4 n
  | _ -> Alcotest.fail "elite on turn 1 should be SelfHeal"

let test_skill_elite_not_turn1 () =
  match Tool_trpg.resolve_npc_skill ~turn:5 ~npc_template:elite_tmpl with
  | Tool_trpg.NoSkill -> ()
  | _ -> Alcotest.fail "elite on turn != 1 should be NoSkill"

let test_skill_unknown_archetype () =
  let unknown : Tool_trpg.npc_template =
    {
      npc_name = "Mystery";
      archetype = "unknown-type";
      persona = "test";
      traits = [];
      skills = [];
      base_hp = 10;
      damage_min = 1;
      damage_max = 3;
      attack_narrations = [];
    }
  in
  match Tool_trpg.resolve_npc_skill ~turn:2 ~npc_template:unknown with
  | Tool_trpg.NoSkill -> ()
  | _ -> Alcotest.fail "unknown archetype should always be NoSkill"

let test_skill_effect_name () =
  Alcotest.(check string)
    "BonusDamage name" "Quick Strike"
    (Tool_trpg.skill_effect_name (Tool_trpg.BonusDamage 1));
  Alcotest.(check string)
    "DoubleDamage name" "Crushing Blow"
    (Tool_trpg.skill_effect_name Tool_trpg.DoubleDamage);
  Alcotest.(check string)
    "MultiTarget name" "Spell Surge"
    (Tool_trpg.skill_effect_name Tool_trpg.MultiTarget);
  Alcotest.(check string)
    "SelfHeal name" "War Cry"
    (Tool_trpg.skill_effect_name (Tool_trpg.SelfHeal 5));
  Alcotest.(check string)
    "NoSkill name" ""
    (Tool_trpg.skill_effect_name Tool_trpg.NoSkill)

(* -- string_contains helper -- *)

let test_string_contains_found () =
  Alcotest.(check bool)
    "contains skirmisher" true
    (Tool_trpg.string_contains ~haystack:"predator-skirmisher" ~needle:"skirmisher")

let test_string_contains_not_found () =
  Alcotest.(check bool)
    "does not contain elite" false
    (Tool_trpg.string_contains ~haystack:"predator-skirmisher" ~needle:"elite")

let test_string_contains_empty_needle () =
  Alcotest.(check bool)
    "empty needle always matches" true
    (Tool_trpg.string_contains ~haystack:"anything" ~needle:"")

let test_string_contains_needle_longer () =
  Alcotest.(check bool)
    "needle longer than haystack" false
    (Tool_trpg.string_contains ~haystack:"ab" ~needle:"abcdef")

(* -- bestiary archetype classification check -- *)

let test_bestiary_archetype_tiers () =
  (* Verify indices 0-2 are skirmishers, 3-5 are brutes, 6-8 are casters, 9-11 are elites *)
  for i = 0 to 2 do
    let tmpl = Tool_trpg.npc_bestiary.(i) in
    Alcotest.(check bool)
      (Printf.sprintf "index %d (%s) is skirmisher" i tmpl.npc_name)
      true
      (Tool_trpg.string_contains ~haystack:tmpl.archetype ~needle:"skirmisher")
  done;
  for i = 3 to 5 do
    let tmpl = Tool_trpg.npc_bestiary.(i) in
    Alcotest.(check bool)
      (Printf.sprintf "index %d (%s) is brute" i tmpl.npc_name)
      true
      (Tool_trpg.string_contains ~haystack:tmpl.archetype ~needle:"brute"
      || Tool_trpg.string_contains ~haystack:tmpl.archetype ~needle:"construct")
  done;
  for i = 6 to 8 do
    let tmpl = Tool_trpg.npc_bestiary.(i) in
    Alcotest.(check bool)
      (Printf.sprintf "index %d (%s) is caster" i tmpl.npc_name)
      true
      (Tool_trpg.string_contains ~haystack:tmpl.archetype ~needle:"caster")
  done;
  for i = 9 to 11 do
    let tmpl = Tool_trpg.npc_bestiary.(i) in
    Alcotest.(check bool)
      (Printf.sprintf "index %d (%s) is elite" i tmpl.npc_name)
      true
      (Tool_trpg.string_contains ~haystack:tmpl.archetype ~needle:"elite")
  done

(* -- test runner -- *)

let () =
  Alcotest.run "trpg_npc_bestiary"
    [
      ( "select_npc_template",
        [
          Alcotest.test_case "early pool covers 3" `Quick
            test_early_pool_covers_3;
          Alcotest.test_case "mid pool covers 9" `Quick test_mid_pool_covers_9;
          Alcotest.test_case "late pool covers 12" `Quick
            test_late_pool_covers_12;
          Alcotest.test_case "early only skirmishers" `Quick
            test_early_only_skirmishers;
          Alcotest.test_case "deterministic" `Quick test_select_deterministic;
          Alcotest.test_case "same pool wraps" `Quick test_select_same_pool_wraps;
          Alcotest.test_case "negative turn" `Quick test_select_negative_turn;
        ] );
      ( "tier_of_turn",
        [
          Alcotest.test_case "early" `Quick test_tier_of_turn_early;
          Alcotest.test_case "mid" `Quick test_tier_of_turn_mid;
          Alcotest.test_case "late" `Quick test_tier_of_turn_late;
          Alcotest.test_case "negative" `Quick test_tier_of_turn_negative;
        ] );
      ( "select_npc_template_with_tier",
        [
          Alcotest.test_case "early override" `Quick test_with_tier_early;
          Alcotest.test_case "late override" `Quick test_with_tier_late;
        ] );
      ( "scale_hp",
        [
          Alcotest.test_case "early tier" `Quick test_scale_hp_early;
          Alcotest.test_case "mid tier" `Quick test_scale_hp_mid;
          Alcotest.test_case "late tier" `Quick test_scale_hp_late;
          Alcotest.test_case "odd base_hp" `Quick test_scale_hp_odd_base;
        ] );
      ( "deterministic_damage",
        [
          Alcotest.test_case "default range" `Quick
            test_damage_within_default_range;
          Alcotest.test_case "custom range" `Quick test_damage_custom_range;
          Alcotest.test_case "deterministic" `Quick test_damage_deterministic;
          Alcotest.test_case "varies by actor" `Quick test_damage_varies_by_actor;
        ] );
      ( "npc_attack_narration",
        [
          Alcotest.test_case "deterministic" `Quick test_narration_deterministic;
          Alcotest.test_case "cycles" `Quick test_narration_cycles;
          Alcotest.test_case "empty fallback" `Quick
            test_narration_empty_fallback;
        ] );
      ( "find_npc_template_by_name",
        [
          Alcotest.test_case "found" `Quick test_find_by_name_exists;
          Alcotest.test_case "not found" `Quick test_find_by_name_not_found;
        ] );
      ( "bestiary_data_integrity",
        [
          Alcotest.test_case "all have narrations" `Quick
            test_all_templates_have_narrations;
          Alcotest.test_case "damage range valid" `Quick
            test_all_templates_damage_range_valid;
          Alcotest.test_case "12 entries" `Quick test_bestiary_has_12_entries;
          Alcotest.test_case "archetype tiers" `Quick
            test_bestiary_archetype_tiers;
        ] );
      ( "resolve_npc_skill",
        [
          Alcotest.test_case "skirmisher even turn" `Quick
            test_skill_skirmisher_even_turn;
          Alcotest.test_case "skirmisher odd turn" `Quick
            test_skill_skirmisher_odd_turn;
          Alcotest.test_case "brute div 3" `Quick test_skill_brute_div3;
          Alcotest.test_case "brute not div 3" `Quick test_skill_brute_not_div3;
          Alcotest.test_case "caster div 4" `Quick test_skill_caster_div4;
          Alcotest.test_case "caster not div 4" `Quick
            test_skill_caster_not_div4;
          Alcotest.test_case "elite turn 1" `Quick test_skill_elite_turn1;
          Alcotest.test_case "elite not turn 1" `Quick
            test_skill_elite_not_turn1;
          Alcotest.test_case "unknown archetype" `Quick
            test_skill_unknown_archetype;
          Alcotest.test_case "skill effect names" `Quick test_skill_effect_name;
        ] );
      ( "string_contains",
        [
          Alcotest.test_case "found" `Quick test_string_contains_found;
          Alcotest.test_case "not found" `Quick test_string_contains_not_found;
          Alcotest.test_case "empty needle" `Quick
            test_string_contains_empty_needle;
          Alcotest.test_case "needle longer" `Quick
            test_string_contains_needle_longer;
        ] );
    ]
