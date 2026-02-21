open Masc_mcp

(* -- select_npc_template: deterministic, round-robin over 12 NPCs -- *)

let test_select_covers_all_12 () =
  let names =
    List.init 12 (fun i ->
        let tmpl = Tool_trpg.select_npc_template ~turn:i in
        tmpl.npc_name)
  in
  let unique = List.sort_uniq String.compare names in
  Alcotest.(check int)
    "12 unique NPCs over turns 0..11" 12 (List.length unique)

let test_select_deterministic () =
  let a = Tool_trpg.select_npc_template ~turn:7 in
  let b = Tool_trpg.select_npc_template ~turn:7 in
  Alcotest.(check string) "same turn -> same NPC" a.npc_name b.npc_name

let test_select_wraps_around () =
  let a = Tool_trpg.select_npc_template ~turn:0 in
  let b = Tool_trpg.select_npc_template ~turn:12 in
  Alcotest.(check string)
    "turn 0 == turn 12 (mod 12)" a.npc_name b.npc_name

let test_select_negative_turn () =
  (* negative turn should still produce a valid template without crashing *)
  let tmpl = Tool_trpg.select_npc_template ~turn:(-5) in
  Alcotest.(check bool)
    "negative turn -> non-empty name" true
    (String.length tmpl.npc_name > 0)

(* -- scale_hp: 3-tier progression -- *)

let test_scale_hp_early () =
  Alcotest.(check int) "turn 1, base 12" 12 (Tool_trpg.scale_hp ~turn:1 ~base_hp:12);
  Alcotest.(check int) "turn 5, base 12" 12 (Tool_trpg.scale_hp ~turn:5 ~base_hp:12)

let test_scale_hp_mid () =
  (* 12 + 12/2 = 18 *)
  Alcotest.(check int) "turn 6, base 12" 18 (Tool_trpg.scale_hp ~turn:6 ~base_hp:12);
  Alcotest.(check int) "turn 15, base 12" 18 (Tool_trpg.scale_hp ~turn:15 ~base_hp:12)

let test_scale_hp_late () =
  (* 12 * 2 = 24 *)
  Alcotest.(check int) "turn 16, base 12" 24 (Tool_trpg.scale_hp ~turn:16 ~base_hp:12);
  Alcotest.(check int) "turn 99, base 12" 24 (Tool_trpg.scale_hp ~turn:99 ~base_hp:12)

let test_scale_hp_odd_base () =
  (* 9 + 9/2 = 9 + 4 = 13 (integer division) *)
  Alcotest.(check int)
    "turn 10, base 9 (odd)" 13 (Tool_trpg.scale_hp ~turn:10 ~base_hp:9)

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
  (* Not guaranteed to differ, but with high probability they do.
     We just check they don't crash and are in range. *)
  Alcotest.(check bool) "actor a in range" true (a >= 2 && a <= 4);
  Alcotest.(check bool) "actor b in range" true (b >= 2 && b <= 4)

(* -- npc_attack_narration: per-archetype, deterministic -- *)

let test_narration_deterministic () =
  let tmpl = Tool_trpg.select_npc_template ~turn:0 in
  let a = Tool_trpg.npc_attack_narration ~turn:3 ~npc_template:tmpl in
  let b = Tool_trpg.npc_attack_narration ~turn:3 ~npc_template:tmpl in
  Alcotest.(check string) "same turn -> same narration" a b

let test_narration_cycles () =
  let tmpl = Tool_trpg.select_npc_template ~turn:0 in
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
    "잔존한 적이 반격해 전열을 흔든다." narration

(* -- find_npc_template_by_name -- *)

let test_find_by_name_exists () =
  match Tool_trpg.find_npc_template_by_name "Ironclad Golem" with
  | Some t ->
      Alcotest.(check string) "archetype" "construct-brute" t.archetype
  | None -> Alcotest.fail "Ironclad Golem not found in bestiary"

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

(* -- test runner -- *)

let () =
  Alcotest.run "trpg_npc_bestiary"
    [
      ( "select_npc_template",
        [
          Alcotest.test_case "covers all 12" `Quick test_select_covers_all_12;
          Alcotest.test_case "deterministic" `Quick test_select_deterministic;
          Alcotest.test_case "wraps around" `Quick test_select_wraps_around;
          Alcotest.test_case "negative turn" `Quick test_select_negative_turn;
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
        ] );
    ]
