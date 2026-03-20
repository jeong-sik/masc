(** test_memory_oas_5tier — Tests for Memory_oas_bridge 5-tier integration.

    Covers episode_of_entry, oas_procedure_of_masc, seed/flush roundtrips,
    and create_memory_full without external dependencies.

    Uses temporary directories for Memory_stream JSONL files.

    @since 2.124.0 *)

open Masc_mcp

module Oas = Agent_sdk

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let setup_tmp_dir () =
  let dir = Filename.temp_dir "masc_mem_test" "" in
  Unix.putenv "MASC_DATA_DIR" dir;
  dir

let cleanup_tmp_dir dir =
  (* Best-effort cleanup *)
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))

(* ================================================================ *)
(* episode_of_entry                                                  *)
(* ================================================================ *)

let test_episode_basic () =
  let entry : Memory_stream.memory_entry = {
    id = "e-001";
    agent_name = "test-agent";
    content = "Observed system health check passing";
    timestamp = 1711000000.0;
    importance = 7;
    entry_type = Memory_stream.Observation "health check";
    access_count = 2;
    last_accessed = 1711000100.0;
    links = [];
  } in
  let ep = Memory_oas_bridge.episode_of_entry entry in
  Alcotest.(check string) "id preserved" "e-001" ep.id;
  Alcotest.(check (float 0.01)) "timestamp preserved"
    1711000000.0 ep.timestamp;
  Alcotest.(check (list string)) "participants"
    ["test-agent"] ep.participants;
  Alcotest.(check string) "action = content"
    "Observed system health check passing" ep.action;
  Alcotest.(check (float 0.01)) "salience = importance/10"
    0.7 ep.salience

let test_episode_salience_bounds () =
  let make_entry importance : Memory_stream.memory_entry = {
    id = "e-bound";
    agent_name = "a";
    content = "test";
    timestamp = 0.0;
    importance;
    entry_type = Memory_stream.Observation "t";
    access_count = 0;
    last_accessed = 0.0;
    links = [];
  } in
  let ep_low = Memory_oas_bridge.episode_of_entry (make_entry 0) in
  let ep_high = Memory_oas_bridge.episode_of_entry (make_entry 15) in
  Alcotest.(check (float 0.01)) "salience floor 0.0"
    0.0 ep_low.salience;
  Alcotest.(check (float 0.01)) "salience cap 1.0"
    1.0 ep_high.salience

let test_episode_with_links () =
  let entry : Memory_stream.memory_entry = {
    id = "e-links";
    agent_name = "a";
    content = "linked entry";
    timestamp = 0.0;
    importance = 5;
    entry_type = Memory_stream.Reflection "ref";
    access_count = 0;
    last_accessed = 0.0;
    links = ["e-001"; "e-002"];
  } in
  let ep = Memory_oas_bridge.episode_of_entry entry in
  Alcotest.(check int) "metadata has links"
    1 (List.length ep.metadata);
  match List.assoc_opt "links" ep.metadata with
  | Some (`List items) ->
    Alcotest.(check int) "2 links" 2 (List.length items)
  | _ -> Alcotest.fail "expected links in metadata"

let test_episode_outcome_is_neutral () =
  let entry : Memory_stream.memory_entry = {
    id = "e-neutral";
    agent_name = "a";
    content = "action taken";
    timestamp = 0.0;
    importance = 5;
    entry_type = Memory_stream.Action "deploy";
    access_count = 0;
    last_accessed = 0.0;
    links = [];
  } in
  let ep = Memory_oas_bridge.episode_of_entry entry in
  Alcotest.(check bool) "outcome is Neutral"
    true
    (ep.outcome = Oas.Memory.Neutral)

(* ================================================================ *)
(* oas_procedure_of_masc                                             *)
(* ================================================================ *)

let test_procedure_basic () =
  let proc : Procedural_memory.procedure = {
    id = "p-001";
    agent_name = "keeper-dm";
    pattern = "When deploy fails, rollback and notify";
    evidence = ["d-1"; "d-2"; "d-3"];
    success_count = 8;
    failure_count = 2;
    confidence = 0.8;
    created_at = 1711000000.0;
    last_applied = 1711001000.0;
  } in
  let op = Memory_oas_bridge.oas_procedure_of_masc proc in
  Alcotest.(check string) "id preserved" "p-001" op.id;
  Alcotest.(check string) "pattern preserved"
    "When deploy fails, rollback and notify" op.pattern;
  Alcotest.(check string) "action = pattern"
    "When deploy fails, rollback and notify" op.action;
  Alcotest.(check int) "success_count" 8 op.success_count;
  Alcotest.(check int) "failure_count" 2 op.failure_count;
  Alcotest.(check (float 0.01)) "confidence" 0.8 op.confidence;
  Alcotest.(check (float 0.01)) "last_used" 1711001000.0 op.last_used

let test_procedure_metadata () =
  let proc : Procedural_memory.procedure = {
    id = "p-meta";
    agent_name = "test-agent";
    pattern = "test pattern";
    evidence = ["a"; "b"];
    success_count = 1;
    failure_count = 0;
    confidence = 1.0;
    created_at = 100.0;
    last_applied = 200.0;
  } in
  let op = Memory_oas_bridge.oas_procedure_of_masc proc in
  Alcotest.(check int) "metadata count" 3 (List.length op.metadata);
  (match List.assoc_opt "agent_name" op.metadata with
   | Some (`String name) ->
     Alcotest.(check string) "agent_name" "test-agent" name
   | _ -> Alcotest.fail "expected agent_name in metadata");
  (match List.assoc_opt "evidence_count" op.metadata with
   | Some (`Int n) -> Alcotest.(check int) "evidence_count" 2 n
   | _ -> Alcotest.fail "expected evidence_count in metadata")

(* ================================================================ *)
(* create_memory_full (integration)                                  *)
(* ================================================================ *)

let test_create_memory_full_empty () =
  let dir = setup_tmp_dir () in
  let memory =
    Memory_oas_bridge.create_memory_full ~agent_name:"test-new"
      ~episode_limit:10 ~procedure_limit:5 ()
  in
  let (sp, wk, ep, pr, _lt) = Oas.Memory.stats memory in
  Alcotest.(check int) "scratchpad empty" 0 sp;
  Alcotest.(check int) "working empty" 0 wk;
  Alcotest.(check int) "episodic empty (no data)" 0 ep;
  Alcotest.(check int) "procedural empty (no data)" 0 pr;
  cleanup_tmp_dir dir

let test_memory_scratchpad_lifecycle () =
  let dir = setup_tmp_dir () in
  let memory =
    Memory_oas_bridge.create_memory ~agent_name:"test-scratch"
  in
  (* Store to scratchpad *)
  Oas.Memory.store memory ~tier:Oas.Memory.Scratchpad
    "current_tool" (`String "bash");
  let (sp, _, _, _, _) = Oas.Memory.stats memory in
  Alcotest.(check int) "scratchpad has 1" 1 sp;
  (* Clear scratchpad (simulating turn boundary) *)
  Oas.Memory.clear_scratchpad memory;
  let (sp2, _, _, _, _) = Oas.Memory.stats memory in
  Alcotest.(check int) "scratchpad cleared" 0 sp2;
  cleanup_tmp_dir dir

let test_memory_working_survives_clear () =
  let dir = setup_tmp_dir () in
  let memory =
    Memory_oas_bridge.create_memory ~agent_name:"test-working"
  in
  Oas.Memory.store memory ~tier:Oas.Memory.Working
    "session_goal" (`String "deploy v2");
  Oas.Memory.store memory ~tier:Oas.Memory.Scratchpad
    "temp" (`String "ephemeral");
  Oas.Memory.clear_scratchpad memory;
  let (sp, wk, _, _, _) = Oas.Memory.stats memory in
  Alcotest.(check int) "scratchpad cleared" 0 sp;
  Alcotest.(check int) "working survives" 1 wk;
  (match Oas.Memory.recall memory ~tier:Oas.Memory.Working "session_goal" with
   | Some (`String g) ->
     Alcotest.(check string) "goal preserved" "deploy v2" g
   | _ -> Alcotest.fail "expected working memory to survive clear");
  cleanup_tmp_dir dir

let test_memory_promote_scratchpad_to_working () =
  let dir = setup_tmp_dir () in
  let memory =
    Memory_oas_bridge.create_memory ~agent_name:"test-promote"
  in
  Oas.Memory.store memory ~tier:Oas.Memory.Scratchpad
    "important_finding" (`String "bug in auth");
  let promoted = Oas.Memory.promote memory "important_finding" in
  Alcotest.(check bool) "promote succeeded" true promoted;
  Oas.Memory.clear_scratchpad memory;
  (match Oas.Memory.recall memory ~tier:Oas.Memory.Working "important_finding" with
   | Some (`String v) ->
     Alcotest.(check string) "promoted value" "bug in auth" v
   | _ -> Alcotest.fail "promoted value should be in Working after clear");
  cleanup_tmp_dir dir

(* ================================================================ *)
(* Episodic store/recall cycle                                       *)
(* ================================================================ *)

let test_episodic_store_recall () =
  let dir = setup_tmp_dir () in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-ep" in
  let ep : Oas.Memory.episode = {
    id = "ep-1";
    timestamp = Unix.gettimeofday ();
    participants = ["alice"; "bob"];
    action = "Deployed v2 to staging";
    outcome = Oas.Memory.Success "all tests passed";
    salience = 0.8;
    metadata = [];
  } in
  Oas.Memory.store_episode memory ep;
  let recalled = Oas.Memory.recall_episodes memory ~limit:10 () in
  Alcotest.(check int) "1 episode recalled" 1 (List.length recalled);
  let r = List.hd recalled in
  Alcotest.(check string) "id matches" "ep-1" r.id;
  Alcotest.(check string) "action matches"
    "Deployed v2 to staging" r.action;
  cleanup_tmp_dir dir

let test_episodic_salience_ordering () =
  let dir = setup_tmp_dir () in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-sal" in
  let now = Unix.gettimeofday () in
  let ep_low : Oas.Memory.episode = {
    id = "low"; timestamp = now;
    participants = []; action = "minor";
    outcome = Oas.Memory.Neutral; salience = 0.2; metadata = [];
  } in
  let ep_high : Oas.Memory.episode = {
    id = "high"; timestamp = now;
    participants = []; action = "critical";
    outcome = Oas.Memory.Neutral; salience = 0.9; metadata = [];
  } in
  Oas.Memory.store_episode memory ep_low;
  Oas.Memory.store_episode memory ep_high;
  let recalled = Oas.Memory.recall_episodes memory ~limit:2 () in
  Alcotest.(check int) "2 episodes" 2 (List.length recalled);
  Alcotest.(check string) "highest salience first"
    "high" (List.hd recalled).id;
  cleanup_tmp_dir dir

(* ================================================================ *)
(* Procedural store/recall cycle                                     *)
(* ================================================================ *)

let test_procedural_store_recall () =
  let dir = setup_tmp_dir () in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-pr" in
  let proc : Oas.Memory.procedure = {
    id = "pr-1";
    pattern = "deploy failure";
    action = "rollback and notify team";
    success_count = 5;
    failure_count = 1;
    confidence = 0.833;
    last_used = Unix.gettimeofday ();
    metadata = [];
  } in
  Oas.Memory.store_procedure memory proc;
  (match Oas.Memory.best_procedure memory ~pattern:"deploy" with
   | Some p ->
     Alcotest.(check string) "id matches" "pr-1" p.id;
     Alcotest.(check int) "success" 5 p.success_count
   | None -> Alcotest.fail "expected procedure recall");
  cleanup_tmp_dir dir

let test_procedural_record_success () =
  let dir = setup_tmp_dir () in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-prs" in
  let proc : Oas.Memory.procedure = {
    id = "pr-s";
    pattern = "test pattern";
    action = "test action";
    success_count = 3;
    failure_count = 1;
    confidence = 0.75;
    last_used = 0.0;
    metadata = [];
  } in
  Oas.Memory.store_procedure memory proc;
  Oas.Memory.record_success memory "pr-s";
  (match Oas.Memory.best_procedure memory ~pattern:"test" with
   | Some p ->
     Alcotest.(check int) "success incremented" 4 p.success_count;
     Alcotest.(check int) "failure unchanged" 1 p.failure_count
   | None -> Alcotest.fail "expected procedure after success");
  cleanup_tmp_dir dir

(* ================================================================ *)
(* Stats                                                             *)
(* ================================================================ *)

let test_stats_all_tiers () =
  let dir = setup_tmp_dir () in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-stats" in
  Oas.Memory.store memory ~tier:Oas.Memory.Scratchpad "s1" (`Int 1);
  Oas.Memory.store memory ~tier:Oas.Memory.Working "w1" (`Int 2);
  Oas.Memory.store memory ~tier:Oas.Memory.Working "w2" (`Int 3);
  let ep : Oas.Memory.episode = {
    id = "stat-ep"; timestamp = 0.0; participants = [];
    action = "a"; outcome = Oas.Memory.Neutral;
    salience = 0.5; metadata = [];
  } in
  Oas.Memory.store_episode memory ep;
  let proc : Oas.Memory.procedure = {
    id = "stat-pr"; pattern = "p"; action = "a";
    success_count = 1; failure_count = 0; confidence = 1.0;
    last_used = 0.0; metadata = [];
  } in
  Oas.Memory.store_procedure memory proc;
  let (sp, wk, epc, prc, _lt) = Oas.Memory.stats memory in
  Alcotest.(check int) "scratchpad = 1" 1 sp;
  Alcotest.(check int) "working = 2" 2 wk;
  Alcotest.(check int) "episodic = 1" 1 epc;
  Alcotest.(check int) "procedural = 1" 1 prc;
  cleanup_tmp_dir dir

(* ================================================================ *)
(* Test Suite                                                        *)
(* ================================================================ *)

let () =
  Alcotest.run "memory_oas_5tier" [
    ("episode_of_entry", [
      Alcotest.test_case "basic conversion" `Quick test_episode_basic;
      Alcotest.test_case "salience bounds" `Quick test_episode_salience_bounds;
      Alcotest.test_case "links in metadata" `Quick test_episode_with_links;
      Alcotest.test_case "outcome is Neutral" `Quick test_episode_outcome_is_neutral;
    ]);
    ("oas_procedure_of_masc", [
      Alcotest.test_case "basic conversion" `Quick test_procedure_basic;
      Alcotest.test_case "metadata fields" `Quick test_procedure_metadata;
    ]);
    ("create_memory_full", [
      Alcotest.test_case "empty agent" `Quick test_create_memory_full_empty;
    ]);
    ("scratchpad_working", [
      Alcotest.test_case "scratchpad lifecycle" `Quick test_memory_scratchpad_lifecycle;
      Alcotest.test_case "working survives clear" `Quick test_memory_working_survives_clear;
      Alcotest.test_case "promote to working" `Quick test_memory_promote_scratchpad_to_working;
    ]);
    ("episodic", [
      Alcotest.test_case "store and recall" `Quick test_episodic_store_recall;
      Alcotest.test_case "salience ordering" `Quick test_episodic_salience_ordering;
    ]);
    ("procedural", [
      Alcotest.test_case "store and recall" `Quick test_procedural_store_recall;
      Alcotest.test_case "record success" `Quick test_procedural_record_success;
    ]);
    ("stats", [
      Alcotest.test_case "all tiers" `Quick test_stats_all_tiers;
    ]);
  ]
