(** test_memory_oas_5tier -- Tests for Memory_oas_bridge 5-tier integration.

    Covers oas_procedure_of_masc, OAS Memory tier lifecycle, flush,
    and hook-first pure-read functions without external dependencies.

    Imperative seeding tests removed (RFC-MASC-004 Phase 3).
    episode_of_entry tests removed (Memory_stream removed).

    @since 2.124.0
    @since 2.266.0 (imperative seeding tests removed) *)

open Masc_mcp

module Oas = Agent_sdk

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let setup_tmp_dir () =
  let dir = Filename.temp_dir "masc_mem_test" "" in
  Unix.putenv "MASC_DATA_DIR" dir;
  Unix.putenv "MASC_BASE_PATH" dir;
  Fs_compat.mkdir_p (Filename.concat dir ".masc");
  dir

let cleanup_tmp_dir dir =
  (* Best-effort cleanup *)
  ignore (Sys.command (Printf.sprintf "rm -rf %s" (Filename.quote dir)))

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

let test_memory_scratchpad_lifecycle () =
  let dir = setup_tmp_dir () in
  let memory =
    Memory_oas_bridge.create_memory ~agent_name:"test-scratch" ()
  in
  (* Store to scratchpad *)
  ignore (Oas.Memory.store memory ~tier:Oas.Memory.Scratchpad
    "current_tool" (`String "bash"));
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
    Memory_oas_bridge.create_memory ~agent_name:"test-working" ()
  in
  ignore (Oas.Memory.store memory ~tier:Oas.Memory.Working
    "session_goal" (`String "deploy v2"));
  ignore (Oas.Memory.store memory ~tier:Oas.Memory.Scratchpad
    "temp" (`String "ephemeral"));
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
    Memory_oas_bridge.create_memory ~agent_name:"test-promote" ()
  in
  ignore (Oas.Memory.store memory ~tier:Oas.Memory.Scratchpad
    "important_finding" (`String "bug in auth"));
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
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-ep" () in
  let ep : Oas.Memory.episode = {
    id = "ep-1";
    timestamp = Unix.gettimeofday ();
    participants = ["alice"; "bob"];
    action = "Deployed v2 to staging";
    outcome = Oas.Memory.Success "all tests passed";
    salience = 0.8;
    metadata = [];
  } in
  ignore (Oas.Memory.store_episode memory ep);
  let recalled = Oas.Memory.recall_episodes memory ~limit:10 () in
  Alcotest.(check int) "1 episode recalled" 1 (List.length recalled);
  let r = List.hd recalled in
  Alcotest.(check string) "id matches" "ep-1" r.id;
  Alcotest.(check string) "action matches"
    "Deployed v2 to staging" r.action;
  cleanup_tmp_dir dir

let test_episodic_salience_ordering () =
  let dir = setup_tmp_dir () in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-sal" () in
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
  ignore (Oas.Memory.store_episode memory ep_low);
  ignore (Oas.Memory.store_episode memory ep_high);
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
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-pr" () in
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
  ignore (Oas.Memory.store_procedure memory proc);
  (match Oas.Memory.best_procedure memory ~pattern:"deploy" with
   | Some p ->
     Alcotest.(check string) "id matches" "pr-1" p.id;
     Alcotest.(check int) "success" 5 p.success_count
   | None -> Alcotest.fail "expected procedure recall");
  cleanup_tmp_dir dir

let test_procedural_record_success () =
  let dir = setup_tmp_dir () in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-prs" () in
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
  ignore (Oas.Memory.store_procedure memory proc);
  Oas.Memory.record_success memory "pr-s";
  (match Oas.Memory.best_procedure memory ~pattern:"test" with
   | Some p ->
     Alcotest.(check int) "success incremented" 4 p.success_count;
     Alcotest.(check int) "failure unchanged" 1 p.failure_count
   | None -> Alcotest.fail "expected procedure after success");
  cleanup_tmp_dir dir

let test_flush_procedures_dedupes_legacy_records () =
  let dir = setup_tmp_dir () in
  let agent_name = "test-pr-flush" in
  let existing_old : Procedural_memory.procedure = {
    id = "proc-legacy";
    agent_name;
    pattern = "deploy failure";
    evidence = ["old"];
    success_count = 1;
    failure_count = 0;
    confidence = 1.0;
    created_at = 100.0;
    last_applied = 110.0;
  } in
  let existing_latest = {
    existing_old with
    evidence = ["latest"];
    success_count = 2;
    created_at = 200.0;
    last_applied = 210.0;
  } in
  Procedural_memory.save_procedure ~agent_name existing_old;
  Procedural_memory.save_procedure ~agent_name existing_latest;
  let memory = Memory_oas_bridge.create_memory ~agent_name () in
  let oas_proc : Oas.Memory.procedure = {
    id = "proc-legacy";
    pattern = "deploy failure";
    action = "rollback";
    success_count = 2;
    failure_count = 0;
    confidence = 1.0;
    last_used = 210.0;
    metadata = [];
  } in
  ignore (Oas.Memory.store_procedure memory oas_proc);
  let flushed = Memory_oas_bridge.flush_procedures ~memory ~agent_name in
  Alcotest.(check int) "no flush when latest record already matches" 0 flushed;
  let persisted = Procedural_memory.load_procedures ~agent_name in
  Alcotest.(check int) "legacy duplicates rewritten away" 1
    (List.length persisted);
  let final = List.hd persisted in
  Alcotest.(check string) "id preserved" "proc-legacy" final.id;
  Alcotest.(check int) "latest success count preserved" 2 final.success_count;
  Alcotest.(check string) "latest evidence preserved" "latest"
    (List.hd final.evidence);
  cleanup_tmp_dir dir

let contains_substring haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen then false
  else
    let found = ref false in
    for i = 0 to hlen - nlen do
      if not !found && String.sub haystack i nlen = needle then
        found := true
    done;
    !found

let test_load_procedures_text_refreshes_after_external_append () =
  let dir = setup_tmp_dir () in
  let agent_name = "test-pr-refresh" in
  let first : Procedural_memory.procedure = {
    id = "proc-first";
    agent_name;
    pattern = "restart worker";
    evidence = ["ev-1"; "ev-2"; "ev-3"];
    success_count = 3;
    failure_count = 0;
    confidence = 1.0;
    created_at = 100.0;
    last_applied = 110.0;
  } in
  let second : Procedural_memory.procedure = {
    id = "proc-second";
    agent_name;
    pattern = "drain queue";
    evidence = ["ev-4"; "ev-5"; "ev-6"];
    success_count = 3;
    failure_count = 0;
    confidence = 1.0;
    created_at = 120.0;
    last_applied = 130.0;
  } in
  Procedural_memory.save_procedure ~agent_name first;
  let text_before = Memory_oas_bridge.load_procedures_text ~agent_name ~limit:10 in
  (match text_before with
   | Some t ->
     Alcotest.(check bool) "first procedure in text" true
       (contains_substring t "restart")
   | None -> Alcotest.fail "expected at least 1 procedure in text");
  Procedural_memory.save_procedure ~agent_name second;
  let text_after = Memory_oas_bridge.load_procedures_text ~agent_name ~limit:10 in
  (match text_after with
   | Some t ->
     Alcotest.(check bool) "cache invalidated — both procedures in text" true
       (contains_substring t "restart" && contains_substring t "drain")
   | None -> Alcotest.fail "expected procedures text after second save");
  cleanup_tmp_dir dir

let test_flush_procedures_updates_cache_for_immediate_reload () =
  let dir = setup_tmp_dir () in
  let agent_name = "test-pr-cache-writeback" in
  let existing : Procedural_memory.procedure = {
    id = "proc-writeback";
    agent_name;
    pattern = "rollback deploy";
    evidence = ["ev-1"; "ev-2"; "ev-3"];
    success_count = 3;
    failure_count = 0;
    confidence = 1.0;
    created_at = 100.0;
    last_applied = 110.0;
  } in
  Procedural_memory.save_procedure ~agent_name existing;
  let memory = Memory_oas_bridge.create_memory ~agent_name () in
  ignore
    (Oas.Memory.store_procedure memory
       {
         Oas.Memory.id = existing.id;
         pattern = existing.pattern;
         action = "rollback and notify";
         success_count = 7;
         failure_count = 1;
         confidence = 0.875;
         last_used = 210.0;
         metadata = [];
       });
  let flushed = Memory_oas_bridge.flush_procedures ~memory ~agent_name in
  Alcotest.(check int) "updated procedure flushed" 1 flushed;
  (* Verify cache is updated: load_procedures_text should see the new counts *)
  let text = Memory_oas_bridge.load_procedures_text ~agent_name ~limit:10 in
  (match text with
   | Some t ->
     Alcotest.(check bool) "flushed procedure visible in text" true
       (contains_substring t "rollback")
   | None -> Alcotest.fail "expected procedure text after flush + cache update");
  cleanup_tmp_dir dir

(* ================================================================ *)
(* Stats                                                             *)
(* ================================================================ *)

let test_stats_all_tiers () =
  let dir = setup_tmp_dir () in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-stats" () in
  ignore (Oas.Memory.store memory ~tier:Oas.Memory.Scratchpad "s1" (`Int 1));
  ignore (Oas.Memory.store memory ~tier:Oas.Memory.Working "w1" (`Int 2));
  ignore (Oas.Memory.store memory ~tier:Oas.Memory.Working "w2" (`Int 3));
  let ep : Oas.Memory.episode = {
    id = "stat-ep"; timestamp = 0.0; participants = [];
    action = "a"; outcome = Oas.Memory.Neutral;
    salience = 0.5; metadata = [];
  } in
  ignore (Oas.Memory.store_episode memory ep);
  let proc : Oas.Memory.procedure = {
    id = "stat-pr"; pattern = "p"; action = "a";
    success_count = 1; failure_count = 0; confidence = 1.0;
    last_used = 0.0; metadata = [];
  } in
  ignore (Oas.Memory.store_procedure memory proc);
  let (sp, wk, epc, prc, _lt) = Oas.Memory.stats memory in
  Alcotest.(check int) "scratchpad = 1" 1 sp;
  Alcotest.(check int) "working = 2" 2 wk;
  Alcotest.(check int) "episodic = 1" 1 epc;
  Alcotest.(check int) "procedural = 1" 1 prc;
  cleanup_tmp_dir dir

(* ================================================================ *)
(* JSONL backend + bridge verification                                *)
(* ================================================================ *)

let test_jsonl_backend_persist () =
  let sid = Printf.sprintf "test-persist-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) in
  let backend =
    Memory_oas_bridge.make_backend ~agent_name:"test-jsonl" ~session_id:sid ()
  in
  let result = backend.persist ~key:"test" (`String "value") in
  Alcotest.(check bool) "persist returns Ok" true (Result.is_ok result)

let test_jsonl_backend_retrieve () =
  let sid = Printf.sprintf "test-retrieve-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) in
  let backend =
    Memory_oas_bridge.make_backend ~agent_name:"test-jsonl" ~session_id:sid ()
  in
  let result = backend.retrieve ~key:"nonexistent" in
  Alcotest.(check bool) "retrieve returns None for missing key" true (Option.is_none result)

let test_jsonl_backend_query () =
  let sid = Printf.sprintf "test-query-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) in
  let backend =
    Memory_oas_bridge.make_backend ~agent_name:"test-jsonl" ~session_id:sid ()
  in
  let result = backend.query ~prefix:"test" ~limit:10 in
  Alcotest.(check int) "query returns empty on fresh session" 0 (List.length result)

let test_jsonl_backend_uses_explicit_base_dir () =
  let dir = setup_tmp_dir () in
  let base_dir = Filename.concat dir ".masc-room-a" in
  let sid = Printf.sprintf "test-scope-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) in
  let backend =
    Memory_oas_bridge.make_backend
      ~base_dir
      ~agent_name:"test-jsonl"
      ~session_id:sid
      ()
  in
  let result = backend.persist ~key:"scoped" (`String "value") in
  Alcotest.(check bool) "persist returns Ok" true (Result.is_ok result);
  let expected_path =
    Filename.concat
      (Filename.concat (Filename.concat base_dir "memory") "test-jsonl")
      (sid ^ ".jsonl")
  in
  Alcotest.(check bool) "writes under explicit base_dir" true (Sys.file_exists expected_path);
  cleanup_tmp_dir dir

let test_flush_episodes_appends_only_new_records () =
  let dir = setup_tmp_dir () in
  let existing =
    Institution_eio.record_episode_jsonl
      ~event_type:"existing"
      ~summary:"already persisted"
      ~participants:["keeper-existing"]
      ~outcome:`Success
      ~learnings:["persist once"]
  in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-ep-flush" () in
  (* Store a new episode directly into OAS memory (no imperative seeding) *)
  Oas.Memory.store_episode memory
    {
      Oas.Memory.id = "new-episode-id";
      timestamp = Unix.gettimeofday ();
      participants = [];
      action = "new episode from oas";
      outcome = Oas.Memory.Success "completed";
      salience = 0.88;
      metadata =
        [
          ("event_type", `String "oas_memory");
          ("institution_summary", `String "new episode from oas");
          ("institution_outcome", `String "success");
          ("learnings", `List [`String "written back to jsonl"]);
          ("context", `Assoc [("source", `String "unit-test")]);
        ];
    };
  let flushed = Memory_oas_bridge.flush_episodes ~memory ~agent_name:"test-ep-flush" in
  Alcotest.(check int) "only new episodes flushed" 1 flushed;
  let persisted = Institution_eio.load_recent_episodes_jsonl ~limit:10 in
  let ids = List.map (fun (episode : Institution_eio.episode) -> episode.id) persisted in
  Alcotest.(check bool) "existing record preserved" true (List.mem existing.id ids);
  Alcotest.(check bool) "new record appended" true (List.mem "new-episode-id" ids);
  cleanup_tmp_dir dir

(* ================================================================ *)
(* Test Suite                                                        *)
(* ================================================================ *)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Alcotest.run "memory_oas_5tier" [
    ("oas_procedure_of_masc", [
      Alcotest.test_case "basic conversion" `Quick test_procedure_basic;
      Alcotest.test_case "metadata fields" `Quick test_procedure_metadata;
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
      Alcotest.test_case "flush dedupes legacy records" `Quick
        test_flush_procedures_dedupes_legacy_records;
      Alcotest.test_case "load_procedures_text refreshes after append" `Quick
        test_load_procedures_text_refreshes_after_external_append;
      Alcotest.test_case "flush updates cache for immediate reload" `Quick
        test_flush_procedures_updates_cache_for_immediate_reload;
    ]);
    ("stats", [
      Alcotest.test_case "all tiers" `Quick test_stats_all_tiers;
    ]);
    ("jsonl_backend", [
      Alcotest.test_case "persist returns Ok" `Quick test_jsonl_backend_persist;
      Alcotest.test_case "retrieve returns None" `Quick test_jsonl_backend_retrieve;
      Alcotest.test_case "query returns empty" `Quick test_jsonl_backend_query;
      Alcotest.test_case "uses explicit base_dir" `Quick
        test_jsonl_backend_uses_explicit_base_dir;
      Alcotest.test_case "flush_episodes appends only new" `Quick
        test_flush_episodes_appends_only_new_records;
    ]);
  ]
