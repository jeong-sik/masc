(** Tests for P1-1a: keeper turn prompt hard/soft separation.

    Verifies that:
    1. [turn_prompt] type correctly separates hard constraints from soft context
    2. [skill_route_context_text] produces standalone text without base prompt
    3. [skill_route_system_prompt_agent] composes base + context_text
    4. Hard constraints (policy guards, tool guidance, direct reply) stay in system_prompt
    5. Soft context (skill route, continuity, worktree, turn instructions) goes to dynamic_context *)

open Alcotest

module KAR = Masc_mcp.Keeper_agent_run
module KSR = Masc_mcp.Keeper_skill_routing
module KP = Masc_mcp.Keeper_prompt

(* ── turn_prompt type ───────────────────────────────────── *)

let test_turn_prompt_empty_dynamic () =
  let tp : KAR.turn_prompt =
    { system_prompt = "You are a keeper.";
      dynamic_context = "" }
  in
  check string "system_prompt preserved"
    "You are a keeper." tp.system_prompt;
  check string "dynamic_context empty" "" tp.dynamic_context

let test_turn_prompt_with_dynamic () =
  let tp : KAR.turn_prompt =
    { system_prompt = "You are a keeper.";
      dynamic_context = "Recent continuity snapshot:\nGoal: deploy v2" }
  in
  check string "system_prompt unchanged"
    "You are a keeper." tp.system_prompt;
  check bool "dynamic_context non-empty" true
    (String.trim tp.dynamic_context <> "")

(* ── skill_route_context_text ───────────────────────────── *)

let test_skill_route_context_text_standalone () =
  let route : KSR.keeper_skill_route =
    { primary_skill = "general_chat"; secondary_skills = []; reason = "" }
  in
  let text = KSR.skill_route_context_text
    ~fallback_route:route ~soul_profile:"delivery" in
  (* Must NOT contain a base system prompt prefix *)
  check bool "starts with Skill routing"
    true (String.length text > 0
          && String.sub text 0 (min 14 (String.length text)) = "Skill routing ");
  (* Must contain the fallback skill *)
  check bool "contains fallback skill" true
    (let re = Str.regexp_string "general_chat" in
     try ignore (Str.search_forward re text 0); true with Not_found -> false);
  (* Must contain soul_profile *)
  check bool "contains soul_profile" true
    (let re = Str.regexp_string "delivery" in
     try ignore (Str.search_forward re text 0); true with Not_found -> false)

let test_skill_route_system_prompt_uses_context_text () =
  let route : KSR.keeper_skill_route =
    { primary_skill = "code_review"; secondary_skills = []; reason = "" }
  in
  let base = "Base prompt here." in
  let combined = KSR.skill_route_system_prompt_agent
    ~base_system_prompt:base
    ~fallback_route:route
    ~soul_profile:"research" in
  let standalone = KSR.skill_route_context_text
    ~fallback_route:route
    ~soul_profile:"research" in
  (* Combined should be base + separator + standalone *)
  let expected = Printf.sprintf "%s\n\n%s" base standalone in
  check string "system_prompt_agent = base + context_text"
    expected combined

(* ── hard constraint: direct_reply_mode ─────────────────── *)

let test_direct_reply_stays_in_system () =
  let base = "Identity prompt." in
  let with_dr = KP.append_direct_reply_mode_prompt ~base_prompt:base in
  check bool "contains direct_reply_mode tag" true
    (let re = Str.regexp_string "<direct_reply_mode>" in
     try ignore (Str.search_forward re with_dr 0); true with Not_found -> false);
  check bool "starts with base prompt" true
    (String.length with_dr >= String.length base
     && String.sub with_dr 0 (String.length base) = base)

(* ── separation contract ────────────────────────────────── *)

let test_separation_contract () =
  (* Simulate what build_turn_prompt does: hard in system_prompt, soft in dynamic *)
  let base = "You are keeper-test." in
  let hard_system =
    Printf.sprintf "%s\n\n%s"
      (KP.append_direct_reply_mode_prompt ~base_prompt:base)
      "Output guard: NEVER output [STATE] or [/STATE] blocks in this turn."
  in
  let route : KSR.keeper_skill_route =
    { primary_skill = "general_chat"; secondary_skills = []; reason = "" }
  in
  let soft_parts = [
    KSR.skill_route_context_text ~fallback_route:route ~soul_profile:"delivery";
    "Recent continuity snapshot:\nGoal: deploy v2";
  ] in
  let dynamic = String.concat "\n\n" soft_parts in
  let tp : KAR.turn_prompt =
    { system_prompt = hard_system; dynamic_context = dynamic }
  in
  (* Hard constraints in system_prompt *)
  check bool "system has direct_reply" true
    (let re = Str.regexp_string "<direct_reply_mode>" in
     try ignore (Str.search_forward re tp.system_prompt 0); true
     with Not_found -> false);
  check bool "system has output guard" true
    (let re = Str.regexp_string "Output guard:" in
     try ignore (Str.search_forward re tp.system_prompt 0); true
     with Not_found -> false);
  (* Soft context NOT in system_prompt *)
  check bool "system has no Skill routing" true
    (let re = Str.regexp_string "Skill routing policy" in
     (try ignore (Str.search_forward re tp.system_prompt 0); false
      with Not_found -> true));
  check bool "system has no continuity" true
    (let re = Str.regexp_string "continuity snapshot" in
     (try ignore (Str.search_forward re tp.system_prompt 0); false
      with Not_found -> true));
  (* Soft context in dynamic_context *)
  check bool "dynamic has Skill routing" true
    (let re = Str.regexp_string "Skill routing policy" in
     try ignore (Str.search_forward re tp.dynamic_context 0); true
     with Not_found -> false);
  check bool "dynamic has continuity" true
    (let re = Str.regexp_string "continuity snapshot" in
     try ignore (Str.search_forward re tp.dynamic_context 0); true
     with Not_found -> false)

(* ── test suite ─────────────────────────────────────────── *)

let () =
  run "keeper_turn_prompt"
    [
      ( "turn_prompt_type",
        [
          test_case "empty dynamic_context" `Quick test_turn_prompt_empty_dynamic;
          test_case "with dynamic_context" `Quick test_turn_prompt_with_dynamic;
        ] );
      ( "skill_route_context_text",
        [
          test_case "standalone text" `Quick test_skill_route_context_text_standalone;
          test_case "system_prompt_agent = base + context_text" `Quick
            test_skill_route_system_prompt_uses_context_text;
        ] );
      ( "hard_constraints",
        [
          test_case "direct_reply in system" `Quick test_direct_reply_stays_in_system;
        ] );
      ( "separation_contract",
        [
          test_case "hard in system, soft in dynamic" `Quick test_separation_contract;
        ] );
    ]
