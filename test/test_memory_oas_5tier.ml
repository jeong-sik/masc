(** test_memory_oas_5tier -- Tests for Memory_oas_bridge 5-tier integration.

    Covers oas_procedure_of_masc, create_memory_full, and OAS Memory
    tier lifecycle without external dependencies.

    episode_of_entry tests removed (Memory_stream removed).

    @since 2.124.0 *)

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

let test_create_memory_full_seeds_recent_episodes () =
  let dir = setup_tmp_dir () in
  ignore
    (Institution_eio.record_episode_jsonl
       ~event_type:"execution_session"
       ~summary:"worker completed setup"
       ~participants:["worker-a"]
       ~outcome:`Success
       ~learnings:["seeded into memory"]);
  let memory =
    Memory_oas_bridge.create_memory_full ~agent_name:"test-seeded"
      ~episode_limit:5 ~procedure_limit:5 ()
  in
  let (_, _, ep, _, _) = Oas.Memory.stats memory in
  Alcotest.(check int) "episodic seeded from jsonl" 1 ep;
  cleanup_tmp_dir dir

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

let test_seed_procedures_refreshes_after_external_append () =
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
  let memory_before = Memory_oas_bridge.create_memory ~agent_name () in
  let seeded_before =
    Memory_oas_bridge.seed_procedures_as_oas ~memory:memory_before ~agent_name ~limit:10
  in
  Alcotest.(check int) "initial seed count" 1 seeded_before;
  Procedural_memory.save_procedure ~agent_name second;
  let memory_after = Memory_oas_bridge.create_memory ~agent_name () in
  let seeded_after =
    Memory_oas_bridge.seed_procedures_as_oas ~memory:memory_after ~agent_name ~limit:10
  in
  Alcotest.(check int) "cache invalidated after append" 2 seeded_after;
  (match Oas.Memory.best_procedure memory_after ~pattern:"drain" with
   | Some proc -> Alcotest.(check string) "new procedure visible" "proc-second" proc.id
   | None -> Alcotest.fail "expected appended procedure to be visible after reseed");
  cleanup_tmp_dir dir

let test_flush_procedures_updates_cache_for_immediate_reseed () =
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
  let memory_reseed = Memory_oas_bridge.create_memory ~agent_name () in
  let seeded =
    Memory_oas_bridge.seed_procedures_as_oas ~memory:memory_reseed ~agent_name ~limit:10
  in
  Alcotest.(check int) "reseed count" 1 seeded;
  (match Oas.Memory.best_procedure memory_reseed ~pattern:"rollback" with
   | Some proc ->
       Alcotest.(check int) "updated success count visible" 7 proc.success_count;
       Alcotest.(check int) "updated failure count visible" 1 proc.failure_count
   | None -> Alcotest.fail "expected rewritten procedure after immediate reseed");
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

let test_seed_episodes_loads_recent_jsonl () =
  let dir = setup_tmp_dir () in
  let first =
    Institution_eio.record_episode_jsonl
      ~event_type:"keeper_turn"
      ~summary:"keeper observed drift"
      ~participants:["keeper-a"]
      ~outcome:`Partial
      ~learnings:["watch alert frequency"]
  in
  let second =
    Institution_eio.record_episode_jsonl
      ~event_type:"incident"
      ~summary:"rollback completed"
      ~participants:["keeper-b"; "operator"]
      ~outcome:`Success
      ~learnings:["rollback path healthy"]
  in
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-ep-seed" () in
  let count = Memory_oas_bridge.seed_episodes ~memory ~agent_name:"test-ep-seed" ~limit:10 in
  Alcotest.(check int) "seed_episodes loads both records" 2 count;
  let recalled = Oas.Memory.recall_episodes memory ~limit:10 () in
  let ids = List.map (fun (episode : Oas.Memory.episode) -> episode.id) recalled in
  Alcotest.(check bool) "first episode present" true (List.mem first.id ids);
  Alcotest.(check bool) "second episode present" true (List.mem second.id ids);
  cleanup_tmp_dir dir

let test_seed_episodes_respects_limit () =
  let dir = setup_tmp_dir () in
  ignore
    (Institution_eio.record_episode_jsonl
       ~event_type:"a"
       ~summary:"episode-a"
       ~participants:["agent-a"]
       ~outcome:`Partial
       ~learnings:[]);
  ignore
    (Institution_eio.record_episode_jsonl
       ~event_type:"b"
       ~summary:"episode-b"
       ~participants:["agent-b"]
       ~outcome:`Success
       ~learnings:[]);
  ignore
    (Institution_eio.record_episode_jsonl
       ~event_type:"c"
       ~summary:"episode-c"
       ~participants:["agent-c"]
       ~outcome:`Failure
       ~learnings:["inspect retry budget"]);
  let memory = Memory_oas_bridge.create_memory ~agent_name:"test-ep-limit" () in
  let count = Memory_oas_bridge.seed_episodes ~memory ~agent_name:"test-ep-limit" ~limit:2 in
  Alcotest.(check int) "seed_episodes limit applied" 2 count;
  let recalled = Oas.Memory.recall_episodes memory ~limit:10 () in
  Alcotest.(check int) "only 2 episodes recalled" 2 (List.length recalled);
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
  ignore (Memory_oas_bridge.seed_episodes ~memory ~agent_name:"test-ep-flush" ~limit:10);
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
  let memory_reseed = Memory_oas_bridge.create_memory ~agent_name:"test-ep-flush" () in
  let reseeded =
    Memory_oas_bridge.seed_episodes ~memory:memory_reseed ~agent_name:"test-ep-flush"
      ~limit:10
  in
  Alcotest.(check int) "reseed count stays deduped" 2 reseeded;
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
    ("create_memory_full", [
      Alcotest.test_case "empty agent" `Quick test_create_memory_full_empty;
      Alcotest.test_case "seeds recent episodes" `Quick
        test_create_memory_full_seeds_recent_episodes;
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
      Alcotest.test_case "seed refreshes after external append" `Quick
        test_seed_procedures_refreshes_after_external_append;
      Alcotest.test_case "flush updates cache for immediate reseed" `Quick
        test_flush_procedures_updates_cache_for_immediate_reseed;
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
      Alcotest.test_case "seed_episodes loads recent jsonl" `Quick
        test_seed_episodes_loads_recent_jsonl;
      Alcotest.test_case "seed_episodes respects limit" `Quick
        test_seed_episodes_respects_limit;
      Alcotest.test_case "flush_episodes appends only new" `Quick
        test_flush_episodes_appends_only_new_records;
    ]);
  ]
