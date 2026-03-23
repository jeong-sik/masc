(** Keeper Tool Exposure Tests

    Verifies that keeper_allowed_tool_names correctly filters tools
    based on profile attributes: soul_profile, policy_shell_mode,
    policy_voice_enabled, write_done, and learned mode. *)

open Alcotest
open Masc_mcp

(* ============================================================
   Test Helpers
   ============================================================ *)

let make_meta ?(name = "test-keeper") ?(soul_profile = "")
    ?(policy_shell_mode = "disabled") ?(policy_voice_enabled = false)
    ?(policy_mode = "") () : Keeper_types.keeper_meta =
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String name);
        ("trace_id", `String "test-trace-exposure");
        ("soul_profile", `String soul_profile);
        ("policy_shell_mode", `String policy_shell_mode);
        ("policy_voice_enabled", `Bool policy_voice_enabled);
        ("policy_mode", `String policy_mode);
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_meta failed: %s" e)

let has_tool name tools = List.mem name tools
let has_any_prefix prefix tools =
  List.exists (fun n -> String.length n >= String.length prefix
    && String.sub n 0 (String.length prefix) = prefix) tools

(* ============================================================
   1. write_done isolation
   ============================================================ *)

let test_write_done_blocks_all_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names ~write_done:true meta in
  check int "write_done=true returns empty list" 0 (List.length tools)

let test_write_done_false_has_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names ~write_done:false meta in
  check bool "write_done=false returns nonempty" true (List.length tools > 0)

(* ============================================================
   2. Default profile (no special attributes)
   ============================================================ *)

let test_default_has_base_tools () =
  let meta = make_meta () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  (* Non-learned mode uses keeper_model_tools (shard-based names) *)
  check bool "has tools" true (List.length tools > 0);
  check bool "has keeper_time_now" true (has_tool "keeper_time_now" tools);
  check bool "has keeper_context_status" true (has_tool "keeper_context_status" tools)

let test_default_has_no_voice () =
  (* Non-learned default mode uses shard-based tools which may include
     voice if voice shard is in defaults. Check learned mode instead. *)
  let meta = make_meta ~policy_voice_enabled:false
    ~policy_mode:"learned_offline_v1" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "no voice tools in learned mode" false (has_tool "keeper_voice_speak" tools)

let test_default_has_no_research () =
  let meta = make_meta ~soul_profile:"default" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "no autoresearch" false (has_any_prefix "masc_autoresearch_" tools)

(* ============================================================
   3. Voice profile
   ============================================================ *)

let test_voice_enabled_adds_voice_tools () =
  let meta = make_meta ~policy_voice_enabled:true
    ~policy_mode:"learned_offline_v1" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_voice_speak" true (has_tool "keeper_voice_speak" tools);
  check bool "has keeper_voice_agent" true (has_tool "keeper_voice_agent" tools);
  check bool "has keeper_voice_sessions" true (has_tool "keeper_voice_sessions" tools)

let test_voice_disabled_no_voice_tools () =
  let meta = make_meta ~policy_voice_enabled:false
    ~policy_mode:"learned_offline_v1" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "no voice_speak" false (has_tool "keeper_voice_speak" tools);
  check bool "no voice_agent" false (has_tool "keeper_voice_agent" tools)

(* ============================================================
   4. Shell mode (readonly)
   ============================================================ *)

let test_readonly_shell_adds_shell_tool () =
  let meta = make_meta ~policy_shell_mode:"readonly"
    ~policy_mode:"learned_offline_v1" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_shell_readonly" true
    (has_tool "keeper_shell_readonly" tools)

let test_disabled_shell_no_shell_tool () =
  let meta = make_meta ~policy_shell_mode:"disabled"
    ~policy_mode:"learned_offline_v1" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "no keeper_shell_readonly" false
    (has_tool "keeper_shell_readonly" tools)

(* ============================================================
   5. Shell mode (coding) — documents current behavior
      NOTE: canonical_policy_shell_mode maps "coding" -> "disabled",
      so coding tools are NOT added. This documents the current
      behavior as a regression test. When the canonical mapping
      is fixed to include "coding", update these expected values.
   ============================================================ *)

let test_coding_shell_current_behavior () =
  let meta = make_meta ~policy_shell_mode:"coding"
    ~policy_mode:"learned_offline_v1" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  (* Current: canonical_policy_shell_mode "coding" = "disabled",
     so coding tools are NOT added. This test documents the gap.
     When fixed: change false -> true *)
  let coding_names = Tool_code_write.tool_names in
  let has_any_coding = List.exists (fun n -> has_tool n tools) coding_names in
  check bool "coding tools absent (canonical maps coding->disabled)" false has_any_coding

(* ============================================================
   6. Research profile
   ============================================================ *)

let test_research_adds_autoresearch () =
  let meta = make_meta ~soul_profile:"research" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has autoresearch" true (has_any_prefix "masc_autoresearch_" tools)

let test_non_research_no_autoresearch () =
  let meta = make_meta ~soul_profile:"teaching" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "no autoresearch" false (has_any_prefix "masc_autoresearch_" tools)

(* ============================================================
   7. Learned mode vs normal mode
   ============================================================ *)

let test_learned_mode_has_board_tools () =
  let meta = make_meta ~policy_mode:"learned_offline_v1" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_board_get" true (has_tool "keeper_board_get" tools);
  check bool "has keeper_board_post" true (has_tool "keeper_board_post" tools)

let test_learned_mode_has_read_tools () =
  let meta = make_meta ~policy_mode:"learned_offline_v1" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has keeper_read" true (has_tool "keeper_read" tools);
  check bool "has keeper_fs_read" true (has_tool "keeper_fs_read" tools);
  check bool "has keeper_library_search" true (has_tool "keeper_library_search" tools)

let test_normal_mode_uses_shard_tools () =
  let meta = make_meta ~policy_mode:"" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  (* Normal mode uses keeper_model_tools (shard-based, 26 tools) *)
  check bool "has keeper_time_now" true (has_tool "keeper_time_now" tools);
  check bool "tool count from shards" true (List.length tools >= 20)

(* ============================================================
   8. Combined profiles
   ============================================================ *)

let test_research_learned_voice_combined () =
  let meta = make_meta ~soul_profile:"research"
    ~policy_mode:"learned_offline_v1"
    ~policy_voice_enabled:true
    ~policy_shell_mode:"readonly" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  check bool "has voice" true (has_tool "keeper_voice_speak" tools);
  check bool "has shell readonly" true (has_tool "keeper_shell_readonly" tools);
  check bool "has autoresearch" true (has_any_prefix "masc_autoresearch_" tools);
  check bool "has board" true (has_tool "keeper_board_get" tools);
  check bool "has read" true (has_tool "keeper_read" tools)

(* ============================================================
   9. Tool deduplication
   ============================================================ *)

let test_no_duplicate_tools () =
  let meta = make_meta ~soul_profile:"research"
    ~policy_mode:"learned_offline_v1"
    ~policy_voice_enabled:true
    ~policy_shell_mode:"readonly" () in
  let tools = Keeper_exec_tools.keeper_allowed_tool_names meta in
  let unique = List.sort_uniq String.compare tools in
  check int "no duplicates" (List.length unique) (List.length tools)

(* ============================================================
   Runner
   ============================================================ *)

let () =
  run "Keeper_tool_exposure" [
    ("write_done", [
      test_case "blocks all tools" `Quick test_write_done_blocks_all_tools;
      test_case "false has tools" `Quick test_write_done_false_has_tools;
    ]);
    ("default_profile", [
      test_case "has base tools" `Quick test_default_has_base_tools;
      test_case "no voice tools" `Quick test_default_has_no_voice;
      test_case "no research tools" `Quick test_default_has_no_research;
    ]);
    ("voice_profile", [
      test_case "enabled adds voice" `Quick test_voice_enabled_adds_voice_tools;
      test_case "disabled no voice" `Quick test_voice_disabled_no_voice_tools;
    ]);
    ("shell_readonly", [
      test_case "readonly adds shell" `Quick test_readonly_shell_adds_shell_tool;
      test_case "disabled no shell" `Quick test_disabled_shell_no_shell_tool;
    ]);
    ("shell_coding", [
      test_case "coding current behavior" `Quick test_coding_shell_current_behavior;
    ]);
    ("research_profile", [
      test_case "adds autoresearch" `Quick test_research_adds_autoresearch;
      test_case "non-research no autoresearch" `Quick test_non_research_no_autoresearch;
    ]);
    ("learned_mode", [
      test_case "has board tools" `Quick test_learned_mode_has_board_tools;
      test_case "has read tools" `Quick test_learned_mode_has_read_tools;
      test_case "normal mode uses shards" `Quick test_normal_mode_uses_shard_tools;
    ]);
    ("combined_profiles", [
      test_case "research+learned+voice+readonly" `Quick test_research_learned_voice_combined;
    ]);
    ("deduplication", [
      test_case "no duplicate tools" `Quick test_no_duplicate_tools;
    ]);
  ]
