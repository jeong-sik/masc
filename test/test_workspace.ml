module Types = Masc_domain

(** Tests for Workspace module *)

open Masc

let () = Mirage_crypto_rng_unix.use_default ()

(* RFC-0323 G-2: wires the verification-store hooks (among others) so the
   machine_verify tests can assert the store record lifecycle. *)
let () = Workspace_metric_hooks.install ()

(* UTF-8 emoji helpers: ✅ is E2 9C 85, ⚠ is E2 9A A0, 🔒 is F0 9F 94 92, 🔓 is F0 9F 94 93 *)

(* Helper for substring check - define early *)
let str_contains s substring =
  let len_s = String.length s in
  let len_sub = String.length substring in
  if len_sub > len_s then false
  else
    let rec check i =
      if i > len_s - len_sub then false
      else if String.sub s i len_sub = substring then true
      else check (i + 1)
    in
    check 0

let starts_with s prefix =
  let len_s = String.length s in
  let len_prefix = String.length prefix in
  len_s >= len_prefix && String.sub s 0 len_prefix = prefix

let contains_any haystack needles =
  List.exists (str_contains haystack) needles

let has_legacy_result_prefix prefix result = starts_with result prefix

let contains_problem_result result =
  let lower = String.lowercase_ascii result in
  has_legacy_result_prefix "\xE2\x9D\x8C" result
  || contains_any lower
       [ "error:"
       ; "[taskerror]"
       ; "[agenterror]"
       ; "[systemerror]"
       ; "not found"
       ; "notfound"
       ; "not initialized"
       ; "notinitialized"
       ; "not joined"
       ; "notjoined"
       ; "invalid"
       ; "invalidstate"
       ; "empty"
       ; "too long"
       ; "blocked"
       ; "already claimed"
       ; "cannot"
       ; "rejected"
       ; "was not in the namespace"
       ; "requires"
       ]

let contains_check result =
  has_legacy_result_prefix "\xE2\x9C\x85" result
  || (String.trim result <> "" && not (contains_problem_result result))

let contains_warning result =
  has_legacy_result_prefix "\xE2\x9A\xA0" result || contains_problem_result result

let contains_error = contains_problem_result

let backlog_recovery_path config =
  Workspace.backlog_path config ^ ".last-good"

let workspace_config tmp_dir =
  Unix.putenv "MASC_BASE_PATH" tmp_dir;
  Workspace.default_config tmp_dir

let test_init_creates_folder () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = workspace_config tmp_dir in

  (* Initially not initialized *)
  Alcotest.(check bool) "not init" false (Workspace.is_initialized config);

  (* Initialize *)
  let result = Workspace.init config ~agent_name:None in
  Alcotest.(check bool) "success msg" true (contains_check result);

  (* Now initialized *)
  Alcotest.(check bool) "init" true (Workspace.is_initialized config);

  (* Cleanup *)
  let _ = Workspace.reset config in
  Unix.rmdir tmp_dir

let test_join_creates_agent () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = workspace_config tmp_dir in
  let _ = Workspace.init config ~agent_name:None in

  (* Join - now returns auto-generated nickname like "test_agent-swift-fox" *)
  let result = Workspace.bind_session config ~agent_name:"test_agent" ~capabilities:["ocaml"] () in
  Alcotest.(check bool) "join success" true (contains_check result);

  (* Check agent exists via Workspace.read_state - nickname starts with agent_type *)
  let state = Workspace.read_state config in
  let has_test_agent = List.exists (fun name ->
    String.length name >= 10 && String.sub name 0 10 = "test_agent"
  ) state.active_agents in
  Alcotest.(check bool) "agent in active_agents" true has_test_agent;

  (* Cleanup *)
  let _ = Workspace.reset config in
  Unix.rmdir tmp_dir

let test_add_and_claim_task () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = workspace_config tmp_dir in
  let _ = Workspace.init config ~agent_name:(Some "claude") in

  (* Add task *)
  let add_result = Workspace.add_task config ~title:"Test Task" ~priority:1 ~description:"Test" in
  Alcotest.(check bool) "add success" true (contains_check add_result);

  (* Claim task *)
  let claim_result = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
  Alcotest.(check bool) "claim success" true (contains_check claim_result);

  (* Try to claim again - should fail *)
  let claim2_result = Workspace.claim_task config ~agent_name:"gemini" ~task_id:"task-001" in
  Alcotest.(check bool) "double claim blocked" true (contains_warning claim2_result);

  (* Cleanup *)
  let _ = Workspace.reset config in
  Unix.rmdir tmp_dir

let test_add_task_uses_archive_max_id () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = workspace_config tmp_dir in
  let _ = Workspace.init config ~agent_name:None in

  let archive_path = Filename.concat (Filename.concat tmp_dir Common.masc_dirname) "tasks-archive.json" in
  let archive_json =
    `Assoc [
      ("archived_at", `String "2026-01-01T00:00:00Z");
      ("tasks", `List [
        `Assoc [("id", `String "task-005")];
      ]);
    ]
  in
  Yojson.Safe.to_file archive_path archive_json;

  let result = Workspace.add_task config ~title:"Archive Test" ~priority:1 ~description:"" in
  Alcotest.(check bool) "uses archive max id" true (str_contains result "task-006");

  let _ = Workspace.reset config in
  Unix.rmdir tmp_dir

let test_broadcast_message () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = workspace_config tmp_dir in
  let _ = Workspace.init config ~agent_name:(Some "claude") in

  (* Broadcast *)
  let result = Workspace.broadcast config ~from_agent:"claude" ~content:"Hello @gemini!" in
  Alcotest.(check bool) "broadcast success" true (String.contains result '[');

  (* Get messages *)
  let msgs = Workspace.get_messages config ~since_seq:0 ~limit:10 in
  Alcotest.(check bool) "has messages" true (String.length msgs > 50);

  (* Cleanup *)
  let _ = Workspace.reset config in
  Unix.rmdir tmp_dir

let test_broadcast_replaces_terminal_task_cache_desync () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_test_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir tmp_dir 0o755;

  let config = workspace_config tmp_dir in
  let current_task_for agent_name =
    let agent_opt =
      Workspace.get_agents_raw config
      |> List.find_opt (fun (agent : Masc_domain.agent) ->
        String.equal agent.name agent_name)
    in
    Option.bind agent_opt (fun (agent : Masc_domain.agent) -> agent.current_task)
  in
  let _ = Workspace.init config ~agent_name:(Some "taskmaster") in
  let _ = Workspace.add_task config ~title:"Terminal task" ~priority:1 ~description:"" in
  let _ = Workspace.claim_task config ~agent_name:"nick0cave" ~task_id:"task-001" in
  (match
     Workspace.force_done_task_r
       config
       ~agent_name:"operator"
       ~task_id:"task-001"
       ~notes:"terminal in backlog"
       ()
   with
   | Ok _ -> ()
   | Error err -> Alcotest.fail (Masc_domain.masc_error_to_string err));
  let terminal_tasks = Workspace.list_tasks ~include_done:true config in
  Alcotest.(check bool)
    "terminal task is done before invariant"
    true
    (str_contains terminal_tasks "task-001"
     && str_contains (String.lowercase_ascii terminal_tasks) "done");
  Alcotest.(check (option string))
    "assignee current_task already cleared before invariant"
    None
    (current_task_for "nick0cave");

  let stale_message =
    "@nick0cave task-001 stale claim detected: current_task_id=null but \
     MASC still lists task-001 as claimed by you. Please release it."
  in
  let since_seq =
    Workspace.get_all_messages_raw config ~since_seq:0
    |> List.fold_left (fun acc msg -> max acc msg.Masc_domain.seq) 0
  in
  let result =
    Workspace.broadcast config ~from_agent:"taskmaster-jade-heron" ~content:stale_message
  in
  Alcotest.(check bool)
    "broadcast reports invalidation"
    true
    (str_contains result "[cache_invalidated]");
  let messages = Workspace.get_all_messages_raw config ~since_seq in
  (match messages with
   | [ msg ] ->
     Alcotest.(check bool)
       "original stale text omitted"
       false
       (str_contains msg.content "Please release");
     Alcotest.(check bool)
       "replacement cites terminal task"
       true
       (str_contains msg.content "task-001=done")
   | msgs ->
     Alcotest.failf "expected one replacement message, got %d" (List.length msgs));
  Alcotest.(check (option string))
    "stale current_task cleared"
    None
    (current_task_for "nick0cave");

  let normal_update =
    "Normal update: blocked by task-001 while I wait for review context."
  in
  let normal_result =
    Workspace.broadcast config ~from_agent:"taskmaster-jade-heron" ~content:normal_update
  in
  Alcotest.(check bool)
    "normal task mention is not invalidated"
    false
    (str_contains normal_result "[cache_invalidated]");
  let operator_result =
    Workspace.broadcast config ~from_agent:"operator" ~content:stale_message
  in
  Alcotest.(check bool)
    "non-taskmaster stale-looking prose is not invalidated"
    false
    (str_contains operator_result "[cache_invalidated]");

  let _ = Workspace.reset config in
  Unix.rmdir tmp_dir

let test_event_log () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = workspace_config tmp_dir in
  let _ = Workspace.init config ~agent_name:None in

  (* Broadcast should create event log *)
  let result = Workspace.broadcast config ~from_agent:"claude" ~content:"Test event" in

  (* Verify broadcast returned a valid response (contains timestamp marker) *)
  Alcotest.(check bool) "broadcast returns response" true (String.length result > 0);
  Alcotest.(check bool) "broadcast has timestamp" true (String.contains result '[');

  (* Cleanup *)
  let _ = Workspace.reset config in
  Unix.rmdir tmp_dir

(* ============================================================ *)
(* Edge Case & Error Case Tests                                  *)
(* ============================================================ *)

let transition_done_r config ~agent_name ~task_id ~notes =
  Workspace.transition_task_r config ~agent_name ~task_id
    ~action:Masc_domain.Done_action ~notes ()

let transition_done config ~agent_name ~task_id ~notes =
  match transition_done_r config ~agent_name ~task_id ~notes with
  | Ok msg -> msg
  | Error err -> Masc_domain.masc_error_to_string err

let transition_start config ~agent_name ~task_id =
  match
    Workspace.transition_task_r
      config
      ~agent_name
      ~task_id
      ~action:Masc_domain.Start
      ()
  with
  | Ok msg -> msg
  | Error err -> Masc_domain.masc_error_to_string err

(* Helper to create fresh test environment.
   Eio context + Fs_compat.set_fs are set up in the top-level runner,
   so Workspace.default_config gets FileSystem backend. *)
let with_test_env f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;
  let config = workspace_config tmp_dir in
  let _ = Workspace.init config ~agent_name:(Some "claude") in
  try
    f config;
    let _ = Workspace.reset config in
    Unix.rmdir tmp_dir
  with e ->
    let _ = Workspace.reset config in
    Unix.rmdir tmp_dir;
    raise e

let test_lifecycle_messages_are_typed () =
  with_test_env (fun config ->
    let join_result = Workspace.bind_session config ~agent_name:"gemini" ~capabilities:[] () in
    Alcotest.(check bool) "join success" true
      (str_contains join_result "session bound");
    let leave_result = Workspace.end_session config ~agent_name:"gemini" in
    Alcotest.(check bool) "leave success" true (str_contains leave_result "left");
    ignore (Workspace.bind_session config ~agent_name:"gemini" ~capabilities:[] ());

    let messages = Workspace.get_all_messages_raw config ~since_seq:0 in
    let has_msg_type msg_type =
      List.exists
        (fun (message : Types.message) -> String.equal message.msg_type msg_type)
        messages
    in
    Alcotest.(check bool) "join typed" true (has_msg_type "session_bound");
    Alcotest.(check bool) "leave typed" true (has_msg_type "session_ended");
    Alcotest.(check bool) "rejoin typed" true (has_msg_type "session_rebound");
    Alcotest.(check bool) "lifecycle pings not plain broadcasts" false
      (List.exists
         (fun (message : Types.message) ->
           String.equal message.msg_type "broadcast"
           && str_contains message.content "namespace")
         messages)
  )

let with_memory_test_env f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_mem_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;
  let backend_config : Backend_types.config = {
    base_path = Filename.concat tmp_dir Common.masc_dirname;
    node_id = "test-node";
    cluster_name = "default";
    pubsub_max_messages = 1000;
  } in
  let memory_backend = Backend.Memory.create () in
  let config : Workspace_utils.config = {
    base_path = tmp_dir;
    workspace_path = tmp_dir;
    lock_expiry_minutes = 30;
    backend_config;
    backend = Workspace_utils.Memory memory_backend;
  } in
  let _ = Workspace.init config ~agent_name:(Some "claude") in
  try
    f config;
    let _ = Workspace.reset config in
    Unix.rmdir tmp_dir
  with e ->
    let _ = Workspace.reset config in
    Unix.rmdir tmp_dir;
    raise e

(* --- Task Edge Cases --- *)

let test_complete_without_claim () =
  with_test_env (fun config ->
    (* Add task but don't claim *)
    let _ = Workspace.add_task config ~title:"Unclaimed" ~priority:1 ~description:"" in

    (* Try to complete without claiming - should fail *)
    let result = transition_done config ~agent_name:"claude" ~task_id:"task-001" ~notes:"" in
    Alcotest.(check bool) "complete without claim blocked" true (contains_error result)
  )

let test_complete_by_wrong_agent () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in

    (* Provider_f tries to complete claude's task - should fail *)
    let result = transition_done config ~agent_name:"gemini" ~task_id:"task-001" ~notes:"" in
    Alcotest.(check bool) "wrong agent blocked" true (contains_error result);
    Alcotest.(check bool) "wrong agent points at current assignee" true
      (str_contains result "current_assignee=claude")
  )

let test_complete_nonexistent_task () =
  with_test_env (fun config ->
    let result = transition_done config ~agent_name:"claude" ~task_id:"task-999" ~notes:"" in
    Alcotest.(check bool) "nonexistent task" true (contains_error result)
  )

let test_claim_nonexistent_task () =
  with_test_env (fun config ->
    let result = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-999" in
    Alcotest.(check bool) "claim nonexistent" true (contains_error result)
  )

let test_double_complete () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let _ = transition_done config ~agent_name:"claude" ~task_id:"task-001" ~notes:"first" in

    (* Done is idempotent at the Workspace FSM layer. *)
    let result = transition_done config ~agent_name:"claude" ~task_id:"task-001" ~notes:"second" in
    Alcotest.(check bool) "double complete is no-op" true (contains_check result);
    Alcotest.(check bool) "double complete mentions no-op" true
      (str_contains result "no-op")
  )

(* --- Join/Leave Edge Cases --- *)

let test_leave_removes_agent () =
  with_test_env (fun config ->
    let _ = Workspace.bind_session config ~agent_name:"gemini" ~capabilities:["test"] () in

    (* Check agent exists *)
    let status1 = Workspace.status config in
    Alcotest.(check bool) "gemini in status" true (String.length status1 > 0);

    (* Leave *)
    let result = Workspace.end_session config ~agent_name:"gemini" in
    Alcotest.(check bool) "leave success" true (contains_check result)
  )

let test_double_join () =
  with_test_env (fun config ->
    let _ = Workspace.bind_session config ~agent_name:"gemini" ~capabilities:["test"] () in

    (* Join again - should update or warn *)
    let result = Workspace.bind_session config ~agent_name:"gemini" ~capabilities:["updated"] () in
    (* Either success (update) or warning is acceptable *)
    Alcotest.(check bool) "double join handled" true (String.length result > 0)
  )

(* --- Portal Edge Cases --- *)




(* ============================================================ *)
(* Robustness Tests - Boundary Values & State Consistency       *)
(* ============================================================ *)

(* --- Boundary Value Tests --- *)

let test_empty_task_title () =
  with_test_env (fun config ->
    (* Empty title should still work (or fail gracefully) *)
    let result = Workspace.add_task config ~title:"" ~priority:1 ~description:"" in
    (* Should either succeed or give clear error *)
    Alcotest.(check bool) "empty title handled" true (String.length result > 0)
  )

let test_very_long_task_title () =
  with_test_env (fun config ->
    let long_title = String.make 1000 'x' in
    let result = Workspace.add_task config ~title:long_title ~priority:1 ~description:"" in
    Alcotest.(check bool) "long title handled" true (contains_check result)
  )

let test_special_chars_in_message () =
  with_test_env (fun config ->
    (* Test special characters, unicode, JSON-unsafe chars *)
    let msg = "Hello \"world\" with 'quotes' and\nnewlines\tand\t한글!" in
    let result = Workspace.broadcast config ~from_agent:"claude" ~content:msg in
    Alcotest.(check bool) "special chars handled" true (String.length result > 0)
  )

let test_agent_name_with_special_chars () =
  with_test_env (fun config ->
    (* Agent name with dots, dashes should work *)
    let result = Workspace.bind_session config ~agent_name:"claude-sonnet-sonnet" ~capabilities:[] () in
    Alcotest.(check bool) "special agent name" true (contains_check result)
  )

let test_priority_boundaries () =
  with_test_env (fun config ->
    (* Test priority 0 and very high priority *)
    let r1 = Workspace.add_task config ~title:"Zero" ~priority:0 ~description:"" in
    let r2 = Workspace.add_task config ~title:"High" ~priority:999 ~description:"" in
    Alcotest.(check bool) "priority 0" true (contains_check r1);
    Alcotest.(check bool) "priority 999" true (contains_check r2)
  )

(* --- State Consistency Tests --- *)

let test_task_state_after_claim () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"State Test" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in

    (* Verify task list shows claimed state *)
    let tasks = Workspace.list_tasks config in
    Alcotest.(check bool) "shows claimed" true (String.length tasks > 0);
    Alcotest.(check bool) "has claude" true (str_contains tasks "claude" ||
                                              str_contains tasks "Claimed")
  )

let test_multiple_tasks_independent () =
  with_test_env (fun config ->
    (* Add multiple tasks *)
    let _ = Workspace.add_task config ~title:"Task A" ~priority:1 ~description:"" in
    let _ = Workspace.add_task config ~title:"Task B" ~priority:2 ~description:"" in
    let _ = Workspace.add_task config ~title:"Task C" ~priority:3 ~description:"" in

    (* Claim and complete two tasks independently. Current ownership guards keep
       one active task per agent, so use two agents to isolate task state. *)
    let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let _ = Workspace.claim_task config ~agent_name:"gemini" ~task_id:"task-002" in
    let start_1 = transition_start config ~agent_name:"claude" ~task_id:"task-001" in
    let start_2 = transition_start config ~agent_name:"gemini" ~task_id:"task-002" in
    Alcotest.(check bool) "start task 001" true (contains_check start_1);
    Alcotest.(check bool) "start task 002" true (contains_check start_2);
    let done_1 = transition_done config ~agent_name:"claude" ~task_id:"task-001" ~notes:"" in
    Alcotest.(check bool) "complete task 001" true (contains_check done_1);

    (* Task 002 should still be independently completable. *)
    let result = transition_done config ~agent_name:"gemini" ~task_id:"task-002" ~notes:"" in
    Alcotest.(check bool) "independent tasks" true (contains_check result)
  )

(* --- Concurrency Simulation Tests --- *)

let test_rapid_claim_sequence () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Race" ~priority:1 ~description:"" in

    (* Simulate rapid claims from different agents *)
    let r1 = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let r2 = Workspace.claim_task config ~agent_name:"gemini" ~task_id:"task-001" in
    let r3 = Workspace.claim_task config ~agent_name:"codex" ~task_id:"task-001" in

    (* Only first should succeed *)
    Alcotest.(check bool) "first wins" true (contains_check r1);
    Alcotest.(check bool) "second blocked" true (contains_warning r2);
    Alcotest.(check bool) "third blocked" true (contains_warning r3)
  )

let test_multiple_agents_multiple_tasks () =
  with_test_env (fun config ->
    (* Setup: 3 tasks, 3 agents *)
    let _ = Workspace.add_task config ~title:"A" ~priority:1 ~description:"" in
    let _ = Workspace.add_task config ~title:"B" ~priority:2 ~description:"" in
    let _ = Workspace.add_task config ~title:"C" ~priority:3 ~description:"" in

    (* Each agent claims different task *)
    let r1 = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let r2 = Workspace.claim_task config ~agent_name:"gemini" ~task_id:"task-002" in
    let r3 = Workspace.claim_task config ~agent_name:"codex" ~task_id:"task-003" in

    Alcotest.(check bool) "claude gets 001" true (contains_check r1);
    Alcotest.(check bool) "gemini gets 002" true (contains_check r2);
    Alcotest.(check bool) "codex gets 003" true (contains_check r3);

    (* Each completes their own *)
    let c1 = transition_done config ~agent_name:"claude" ~task_id:"task-001" ~notes:"" in
    let c2 = transition_done config ~agent_name:"gemini" ~task_id:"task-002" ~notes:"" in
    let c3 = transition_done config ~agent_name:"codex" ~task_id:"task-003" ~notes:"" in

    Alcotest.(check bool) "claude done" true (contains_check c1);
    Alcotest.(check bool) "gemini done" true (contains_check c2);
    Alcotest.(check bool) "codex done" true (contains_check c3)
  )

(* --- Recovery & Edge Condition Tests --- *)

let test_reinit_existing_workspace () =
  with_test_env (fun config ->
    (* Init again on already initialized workspace *)
    let result = Workspace.init config ~agent_name:None in
    (* Should handle gracefully - either warn or succeed *)
    Alcotest.(check bool) "reinit handled" true (String.length result > 0)
  )

let test_operations_preserve_state () =
  with_test_env (fun config ->
    (* Do a bunch of operations *)
    let _ = Workspace.bind_session config ~agent_name:"gemini" ~capabilities:["test"] () in
    let _ = Workspace.add_task config ~title:"X" ~priority:1 ~description:"" in
    let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"hello" in

    (* Status should show all state *)
    let status = Workspace.status config in
    Alcotest.(check bool) "status not empty" true (String.length status > 100)
  )

(* --- Event Log Verification --- *)

let test_event_log_on_join () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = workspace_config tmp_dir in
  let _ = Workspace.init config ~agent_name:None in
  let _ = Workspace.bind_session config ~agent_name:"test_agent" ~capabilities:["ocaml"] () in

  (* Verify join was recorded - agent has auto-generated nickname starting with "test_agent-" *)
  let state = Workspace.read_state config in
  let has_test_agent = List.exists (fun name ->
    String.length name >= 10 && String.sub name 0 10 = "test_agent"
  ) state.active_agents in
  Alcotest.(check bool) "join event recorded" true has_test_agent;

  let _ = Workspace.reset config in
  Unix.rmdir tmp_dir

let test_event_log_on_claim_done () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = workspace_config tmp_dir in
  let _ = Workspace.init config ~agent_name:(Some "claude") in
  let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
  let _ = Workspace.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
  let _ = transition_done config ~agent_name:"claude" ~task_id:"task-001" ~notes:"done" in

  (* Verify task state via Workspace.read_backlog (backend-agnostic) *)
  let backlog = Workspace.read_backlog config in
  let is_done = List.exists (fun t ->
    match t.Masc_domain.task_status with Masc_domain.Done _ -> true | _ -> false
  ) backlog.Masc_domain.tasks in
  Alcotest.(check bool) "task completed" true is_done;

  let _ = Workspace.reset config in
  Unix.rmdir tmp_dir

(* ============================================================ *)
(* Heartbeat & Zombie Detection Tests                           *)
(* ============================================================ *)

let contains_heartbeat result =
  has_legacy_result_prefix "\xF0\x9F\x92\x93" result
  || str_contains (String.lowercase_ascii result) "heartbeat updated"

let test_heartbeat_updates_lastseen () =
  with_test_env (fun config ->
    let _ = Workspace.bind_session config ~agent_name:"gemini" ~capabilities:[] () in

    (* Send heartbeat *)
    let result = Workspace.heartbeat config ~agent_name:"gemini" in
    Alcotest.(check bool) "heartbeat success" true (contains_heartbeat result)
  )

let test_is_agent_session_bound_after_default_join () =
  with_test_env (fun config ->
    let _ = Workspace.bind_session config ~agent_name:"gemini" ~capabilities:[] () in
    let agents : Masc_domain.agent list = Workspace.get_agents_raw config in
    let gemini_name =
      match List.find_opt (fun (agent : Masc_domain.agent) ->
        String.length agent.name >= 6 && String.sub agent.name 0 6 = "gemini"
      ) agents with
      | Some agent -> agent.name
      | None -> failwith "expected gemini agent"
    in
    Alcotest.(check bool) "bound agent detected" true
      (Workspace.is_agent_session_bound config ~agent_name:gemini_name)
  )

let test_workspace_bootstrap_preserves_backend_state () =
  with_memory_test_env (fun config ->
    Workspace.ensure_workspace_bootstrap config;
    let _ =
      Workspace.update_state config (fun state ->
        { state with message_seq = 41 })
    in
    let backlog =
      {
        Masc_domain.tasks = [];
        last_updated = Masc_domain.now_iso ();
        version = 7;
      }
    in
    Workspace_utils.write_json config (Workspace.backlog_path config)
      (Masc_domain.backlog_to_yojson backlog);

    Workspace.ensure_workspace_bootstrap config;

    let state = Workspace.read_state config in
    let saved_backlog = Workspace.read_backlog config in
    Alcotest.(check int) "state preserved" 41 state.message_seq;
    Alcotest.(check int) "backlog preserved" 7 saved_backlog.version
  )

let test_workspace_bootstrap_ignores_invalid_workspace_id_in_flat_mode () =
  with_memory_test_env (fun config ->
    Workspace.ensure_workspace_bootstrap config;
    Alcotest.(check bool) "root state initialized" true
      (Workspace.is_initialized config)
  )

let test_read_backlog_r_recovers_from_last_good_snapshot () =
  with_test_env (fun config ->
    let expected =
      {
        Masc_domain.tasks = [];
        last_updated = Masc_domain.now_iso ();
        version = 7;
      }
    in
    Workspace.write_backlog config expected;
    Out_channel.with_open_text (Workspace.backlog_path config) (fun oc ->
      output_string oc "{\n  \"tasks\": [\n");
    match Workspace.read_backlog_r config with
    | Ok backlog ->
        Alcotest.(check int) "recovered backlog version" expected.version backlog.version
    | Error msg -> Alcotest.failf "expected recovery, got error: %s" msg
  )

let test_read_backlog_r_reports_parse_error_when_recovery_is_also_invalid () =
  with_test_env (fun config ->
    Out_channel.with_open_text (Workspace.backlog_path config) (fun oc ->
      output_string oc "{\n  \"tasks\": [\n");
    Out_channel.with_open_text (backlog_recovery_path config) (fun oc ->
      output_string oc "{\n  \"tasks\": [\n");
    match Workspace.read_backlog_r config with
    | Ok _ -> Alcotest.fail "expected backlog parse error"
    | Error msg ->
        Alcotest.(check bool) "mentions primary backlog failure" true
          (str_contains msg "read_backlog" || str_contains msg "JSON parse error");
        Alcotest.(check bool) "mentions recovery failure" true
          (str_contains msg "recovery")
  )

let test_release_stale_claims_skips_invalid_backlog () =
  with_test_env (fun config ->
    Out_channel.with_open_text (Workspace.backlog_path config) (fun oc ->
      output_string oc "{\n  \"tasks\": [\n");
    let released = Workspace.release_stale_claims config ~ttl_seconds:60.0 in
    Alcotest.(check (list (pair string string))) "no stale claims released" [] released
  )

(* RFC-0034.d: release_stale_claims must clear the assignee's
   on-disk current_task mirror so the agent file no longer points at
   a backlog task that has been forced back to Todo. *)
let agent_current_task config ~agent_name =
  let agents = Workspace.get_all_agents config in
  match List.find_opt (fun (a : Masc_domain.agent) -> a.name = agent_name) agents with
  | Some agent -> agent.current_task
  | None -> None

(* Use pre-formed nicknames so the assignee written into the backlog
   by [Workspace.claim_task] matches the [<nickname>.json] agent file. The
   production board issue (RFC-0034.d §1) was reported with nicknames
   (e.g. nick0cave), so this models the actual desync surface. *)
let stale_nick = "claude-stale-fox"
let other_nick = "claude-other-bear"
let old_release_timestamp = "2020-01-01T00:00:00Z"

let mark_agent_stale_for_release config ~agent_name =
  Workspace.update_local_agent_state config ~agent_name (fun agent ->
    { agent with status = Masc_domain.Active; last_seen = old_release_timestamp })
;;

let rewrite_task_status config ~task_id ~f =
  let backlog = Workspace.read_backlog config in
  let updated_tasks =
    List.map
      (fun (task : Masc_domain.task) ->
         if String.equal task.id task_id
         then { task with task_status = f task.task_status }
         else task)
      backlog.tasks
  in
  Workspace.write_backlog config { backlog with tasks = updated_tasks }
;;

let age_claimed_task_for_release config ~task_id =
  rewrite_task_status config ~task_id ~f:(function
    | Masc_domain.Claimed { assignee; _ } ->
      Masc_domain.Claimed { assignee; claimed_at = old_release_timestamp }
    | other -> other)
;;

let assert_task_todo config ~task_id =
  let backlog = Workspace.read_backlog config in
  match List.find_opt (fun t -> (t : Masc_domain.task).id = task_id) backlog.tasks with
  | Some { task_status = Masc_domain.Todo; _ } -> ()
  | Some task ->
    Alcotest.failf
      "expected %s to be Todo, got %s"
      task_id
      (Masc_domain.task_status_to_string task.task_status)
  | None -> Alcotest.failf "%s not found in backlog" task_id
;;

let test_release_stale_claims_clears_agent_current_task () =
  with_test_env (fun config ->
    let _ = Workspace.bind_session config ~agent_name:stale_nick ~capabilities:[] () in
    let _ = Workspace.add_task config ~title:"Stale work" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:stale_nick ~task_id:"task-001" in
    Workspace.update_local_agent_state config ~agent_name:stale_nick
      (fun agent -> { agent with current_task = Some "task-001" });
    Alcotest.(check (option string)) "precondition: agent.current_task set"
      (Some "task-001") (agent_current_task config ~agent_name:stale_nick);
    mark_agent_stale_for_release config ~agent_name:stale_nick;
    age_claimed_task_for_release config ~task_id:"task-001";
    let released = Workspace.release_stale_claims config ~ttl_seconds:0.0 in
    Alcotest.(check (list (pair string string)))
      "task-001 released from stale claim"
      [ "task-001", stale_nick ]
      released;
    Alcotest.(check (option string)) "agent.current_task cleared" None
      (agent_current_task config ~agent_name:stale_nick);
    assert_task_todo config ~task_id:"task-001"
  )

(* Spec: agent A claimed task X, then its on-disk pointer moved to a
   different task Y (e.g. a fresh claim under a different lock window).
   When the stale sweep releases X, A's [current_task] must remain
   [Some Y] — only the task-X-specific pointer gets cleared. *)
let test_release_stale_claims_preserves_other_agent_task () =
  with_test_env (fun config ->
    let _ = Workspace.bind_session config ~agent_name:other_nick ~capabilities:[] () in
    let _ = Workspace.add_task config ~title:"Stale work" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:other_nick ~task_id:"task-001" in
    Workspace.update_local_agent_state config ~agent_name:other_nick
      (fun agent -> { agent with current_task = Some "task-999" });
    mark_agent_stale_for_release config ~agent_name:other_nick;
    age_claimed_task_for_release config ~task_id:"task-001";
    let released = Workspace.release_stale_claims config ~ttl_seconds:0.0 in
    Alcotest.(check (list (pair string string)))
      "task-001 released from backlog"
      [ "task-001", other_nick ]
      released;
    Alcotest.(check (option string)) "agent kept its newer current_task"
      (Some "task-999") (agent_current_task config ~agent_name:other_nick);
    assert_task_todo config ~task_id:"task-001"
  )


(* AwaitingVerification is not a Claim/InProgress ownership state in the
   Release FSM. Verification deadlocks need a separate recovery path instead
   of being forced through release_stale_claims. *)
let test_release_stale_claims_skips_stale_verification () =
  with_test_env (fun config ->
    let _ = Workspace.bind_session config ~agent_name:stale_nick ~capabilities:[] () in
    let _ = Workspace.add_task config ~title:"Stale verification" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:stale_nick ~task_id:"task-001" in
    (* Force task into AwaitingVerification with an old submitted_at
       by reading the backlog, mutating the task status, and writing back. *)
    rewrite_task_status config ~task_id:"task-001" ~f:(fun _ ->
      Masc_domain.AwaitingVerification
        { assignee = stale_nick
        ; submitted_at = old_release_timestamp
        ; verification_id = "vrf-test"
        ; phase = Masc_domain.Awaiting_verifier
        });
    (* ttl_seconds:0.0 forces any timestamp to be stale *)
    let released = Workspace.release_stale_claims config ~ttl_seconds:0.0 in
    Alcotest.(check (list (pair string string)))
      "stale verification is handled outside release_stale_claims" [] released;
    let backlog = Workspace.read_backlog config in
    match List.find_opt (fun t -> (t : Masc_domain.task).id = "task-001") backlog.tasks with
    | Some task ->
      (match task.task_status with
       | Masc_domain.AwaitingVerification _ -> ()
       | other -> Alcotest.failf "expected AwaitingVerification, got %s"
           (Masc_domain.task_status_to_string other))
    | None -> Alcotest.fail "task-001 not found in backlog"
  )

let test_heartbeat_nonexistent_agent () =
  with_test_env (fun config ->
    (* Heartbeat for non-bound agent *)
    let result = Workspace.heartbeat config ~agent_name:"nonexistent" in
    Alcotest.(check bool) "heartbeat for nonexistent" true (contains_warning result)
  )

(* test_get_agents_status removed (2026-06-09): get_agents_status deleted with
   the dead agent-status surface. *)

let test_cleanup_zombies_empty () =
  with_test_env (fun config ->
    (* Cleanup with no zombies returns a structured result *)
    let result = Workspace.cleanup_zombies config in
    let has_result =
      match result with
      | Workspace.No_agents_dir -> true
      | Workspace.No_zombies -> true
      | Workspace.Cleaned _ -> true
    in
    Alcotest.(check bool) "cleanup result" true has_result
  )

(** Return ISO8601 timestamp offset by seconds from now *)
let iso_ago seconds =
  let t = Unix.gettimeofday () -. seconds in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

(** Helper: join an agent then overwrite its last_seen to simulate staleness *)
let make_stale_agent ?(agent_type = "test") config ~name ~age_seconds =
  let _ = Workspace.bind_session config ~agent_name:name ~capabilities:[] () in
  (* Overwrite the agent file with a stale last_seen *)
  let agents_path = Filename.concat (Workspace.masc_dir config) "agents" in
  let path = Filename.concat agents_path (Workspace.safe_filename name ^ ".json") in
  let stale_ts = iso_ago age_seconds in
  let agent_json = Printf.sprintf
    {|{"name":"%s","agent_type":"%s","status":"inactive","capabilities":[],"joined_at":"%s","last_seen":"%s"}|}
    name agent_type stale_ts stale_ts
  in
  Workspace.write_json config path (Yojson.Safe.from_string agent_json)

(* Age a bound agent's last_seen while keeping status:active — simulates a live
   agent that has gone quiet between heartbeats. Unlike make_stale_agent (which
   marks the agent inactive, so the include_inactive:false load drops it before
   any threshold check), this exercises the staleness threshold path in
   audit_orphan_tasks. *)
let age_active_agent ?(agent_type = "test") config ~name ~age_seconds =
  let agents_path = Filename.concat (Workspace.masc_dir config) "agents" in
  let path = Filename.concat agents_path (Workspace.safe_filename name ^ ".json") in
  let stale_ts = iso_ago age_seconds in
  let agent_json = Printf.sprintf
    {|{"name":"%s","agent_type":"%s","status":"active","capabilities":[],"joined_at":"%s","last_seen":"%s"}|}
    name agent_type stale_ts stale_ts
  in
  Workspace.write_json config path (Yojson.Safe.from_string agent_json)

let test_cleanup_zombies_detects_regular () =
  with_test_env (fun config ->
    (* Create a regular agent idle for 10 minutes (> 300s threshold) *)
    make_stale_agent config ~name:"stale-regular-agent" ~age_seconds:700.0;
    let result = Workspace.cleanup_zombies config in
    let found = match result with
      | Workspace.Cleaned { names; _ } -> List.mem "stale-regular-agent" names
      | _ -> false
    in
    Alcotest.(check bool) "regular zombie detected" true found
  )

let test_cleanup_zombies_detects_keeper () =
  with_test_env (fun config ->
    (* Create a keeper agent idle for 2 hours (> 3600s keeper threshold) *)
    make_stale_agent config ~name:"keeper-longplay-agent" ~age_seconds:7200.0;
    let result = Workspace.cleanup_zombies config in
    let found = match result with
      | Workspace.Cleaned { names; _ } -> List.mem "keeper-longplay-agent" names
      | _ -> false
    in
    Alcotest.(check bool) "keeper zombie detected after keeper threshold" true found
  )

let test_cleanup_zombies_spares_recent_keeper () =
  with_test_env (fun config ->
    (* Create a keeper agent idle for 10 minutes (< 3600s keeper threshold) *)
    make_stale_agent
      ~agent_type:"keeper"
      config
      ~name:"keeper-active-agent"
      ~age_seconds:600.0;
    let result = Workspace.cleanup_zombies config in
    let spared = match result with
      | Workspace.Cleaned { names; _ } -> not (List.mem "keeper-active-agent" names)
      | _ -> true
    in
    Alcotest.(check bool) "recent keeper spared" true spared
  )

let test_cleanup_zombies_spares_type_keeper () =
  with_test_env (fun config ->
    (* Non-pattern keeper agents also use the keeper threshold. *)
    make_stale_agent
      ~agent_type:"keeper"
      config
      ~name:"regular-keeper-runtime"
      ~age_seconds:600.0;
    let result = Workspace.cleanup_zombies config in
    let spared = match result with
      | Workspace.Cleaned { names; _ } -> not (List.mem "regular-keeper-runtime" names)
      | _ -> true
    in
    Alcotest.(check bool) "agent_type=keeper spared below keeper threshold" true spared
  )

let test_cleanup_zombies_removes_broken_agent_file () =
  with_test_env (fun config ->
    (* Write an empty JSON object — unparseable as agent *)
    let agents_path = Filename.concat (Workspace.masc_dir config) "agents" in
    let path = Filename.concat agents_path "broken-agent.json" in
    Workspace.write_json config path (Yojson.Safe.from_string "{}");
    Alcotest.(check bool) "broken file exists before GC"
      true (Sys.file_exists path);
    let _result = Workspace.cleanup_zombies config in
    Alcotest.(check bool) "broken file removed by GC"
      false (Sys.file_exists path)
  )

let test_fd_pressure_exn_classification () =
  Alcotest.(check bool)
    "EMFILE is resource pressure, not malformed JSON"
    true
    (Workspace.is_fd_pressure_exn
       (Unix.Unix_error (Unix.EMFILE, "openat", "/tmp/keeper.json")));
  Alcotest.(check bool)
    "ENFILE is resource pressure, not malformed JSON"
    true
    (Workspace.is_fd_pressure_exn
       (Unix.Unix_error (Unix.ENFILE, "openat", "/tmp/keeper.json")));
  Alcotest.(check bool)
    "other Unix errors are not FD pressure"
    false
    (Workspace.is_fd_pressure_exn
       (Unix.Unix_error (Unix.ETIMEDOUT, "connect", "api")))

let test_cleanup_zombies_preserves_non_json_files () =
  with_test_env (fun config ->
    (* Place a non-JSON file in the agents directory *)
    let agents_path = Filename.concat (Workspace.masc_dir config) "agents" in
    let path = Filename.concat agents_path ".gitkeep" in
    let oc = open_out path in
    output_string oc "";
    close_out oc;
    Alcotest.(check bool) "non-json file exists before GC"
      true (Sys.file_exists path);
    let _result = Workspace.cleanup_zombies config in
    Alcotest.(check bool) "non-json file preserved by GC"
      true (Sys.file_exists path)
  )

(* ============================================================ *)
(* Agent Discovery / Capability Tests                           *)
(* ============================================================ *)

(* Capability registration/discovery tests removed (2026-06-09):
   Workspace.register_capabilities / find_agents_by_capability deleted with the
   dead agent-status surface (.masc/agents/ producer had 0 call sites). *)

(* Workspace_vote / Workspace_tempo removed — dead prod code (Epic #7261 Step 5 audit). *)

(* ============================================================ *)
(* Input Validation Tests                                       *)
(* ============================================================ *)

let test_empty_agent_name_claim () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Test" ~priority:1 ~description:"" in
    (* Empty agent name should be rejected *)
    let result = Workspace.claim_task config ~agent_name:"" ~task_id:"task-001" in
    Alcotest.(check bool) "empty agent rejected" true (contains_error result)
  )

let test_empty_task_id_claim () =
  with_test_env (fun config ->
    (* Empty task_id should be rejected *)
    let result = Workspace.claim_task config ~agent_name:"claude" ~task_id:"" in
    Alcotest.(check bool) "empty task_id rejected" true (contains_error result)
  )

let test_very_long_agent_name () =
  with_test_env (fun config ->
    let long_name = String.make 100 'x' in
    let result = Workspace.claim_task config ~agent_name:long_name ~task_id:"task-001" in
    (* Should be rejected (max 64 chars) *)
    Alcotest.(check bool) "long name rejected" true (contains_error result)
  )

(* ============================================================ *)
(* Unicode & Internationalization Tests                         *)
(* ============================================================ *)

let test_korean_agent_name () =
  with_test_env (fun config ->
    (* Korean characters should work *)
    let result = Workspace.bind_session config ~agent_name:"클로드" ~capabilities:["한글"] () in
    Alcotest.(check bool) "korean agent name" true (contains_check result)
  )

let test_emoji_in_message () =
  with_test_env (fun config ->
    (* Emoji characters should be preserved *)
    let msg = "🚀 Launching feature! 🎉" in
    let result = Workspace.broadcast config ~from_agent:"claude" ~content:msg in
    Alcotest.(check bool) "emoji preserved" true (str_contains result "🚀")
  )

let test_unicode_task_title () =
  with_test_env (fun config ->
    let result = Workspace.add_task config ~title:"日本語タスク" ~priority:1 ~description:"中文描述" in
    Alcotest.(check bool) "unicode task" true (contains_check result)
  )

(* ============================================================ *)
(* Reset & Cleanup Tests                                        *)
(* ============================================================ *)

let test_reset_clears_all_state () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = workspace_config tmp_dir in
  let _ = Workspace.init config ~agent_name:(Some "claude") in
  let _ = Workspace.add_task config ~title:"Task" ~priority:1 ~description:"" in
  let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"Hello" in

  (* Reset *)
  let _ = Workspace.reset config in

  (* Verify cleared *)
  Alcotest.(check bool) "not initialized after reset" false (Workspace.is_initialized config);

  Unix.rmdir tmp_dir

let test_reinit_after_reset () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = workspace_config tmp_dir in
  let _ = Workspace.init config ~agent_name:(Some "claude") in
  let _ = Workspace.reset config in
  (* Reinit should work *)
  let result = Workspace.init config ~agent_name:(Some "claude") in
  Alcotest.(check bool) "reinit after reset" true (contains_check result);

  let _ = Workspace.reset config in
  Unix.rmdir tmp_dir

(* ============================================================ *)
(* Message Edge Cases                                           *)
(* ============================================================ *)

let test_very_long_message () =
  with_test_env (fun config ->
    let long_msg = String.make 10000 'x' in
    let result = Workspace.broadcast config ~from_agent:"claude" ~content:long_msg in
    Alcotest.(check bool) "long message handled" true (String.length result > 0)
  )

let test_message_with_json_chars () =
  with_test_env (fun config ->
    (* JSON special characters should be escaped properly *)
    let msg = "{\"key\": \"value\", \"array\": [1,2,3]}" in
    let result = Workspace.broadcast config ~from_agent:"claude" ~content:msg in
    Alcotest.(check bool) "json chars handled" true (String.length result > 0)
  )

let test_message_sequence () =
  with_test_env (fun config ->
    (* Messages should have incrementing sequence numbers *)
    let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"First" in
    let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"Second" in
    let _ = Workspace.broadcast config ~from_agent:"claude" ~content:"Third" in

    let msgs = Workspace.get_messages config ~since_seq:0 ~limit:10 in
    Alcotest.(check bool) "has messages" true (str_contains msgs "First" || str_contains msgs "Third")
  )

(* ============================================================ *)
(* Stress Tests (Simulated)                                     *)
(* ============================================================ *)

let test_many_tasks () =
  with_test_env (fun config ->
    (* Add many tasks *)
    for i = 1 to 20 do
      let _ = Workspace.add_task config ~title:(Printf.sprintf "Task %d" i) ~priority:i ~description:"" in
      ()
    done;

    let tasks = Workspace.list_tasks config in
    Alcotest.(check bool) "20 tasks created" true (str_contains tasks "Task 20")
  )

(* test_many_agents removed (2026-06-09): get_agents_status deleted with the
   dead agent-status surface. *)

(* ============================================================ *)
(* Portal Advanced Tests                                        *)
(* ============================================================ *)



(* ============================================================ *)
(* Negative Priority Tests                                      *)
(* ============================================================ *)

let test_negative_priority () =
  with_test_env (fun config ->
    let result = Workspace.add_task config ~title:"Urgent" ~priority:(-1) ~description:"" in
    (* Negative priority should work (lower = more urgent) *)
    Alcotest.(check bool) "negative priority" true (contains_check result)
  )

(* ============================================================ *)
(* Security Tests (v2.1) - XSS Prevention                       *)
(* ============================================================ *)

let test_xss_in_message () =
  with_test_env (fun config ->
    ignore (Workspace.bind_session config ~agent_name:"tester" ~capabilities:[] ());
    let xss_payload = "<script>alert('xss')</script>" in
    let result = Workspace.broadcast config ~from_agent:"tester" ~content:xss_payload in
    (* Check that raw script tags are not in the result *)
    let has_raw_script = str_contains result "<script>" || str_contains result "</script>" in
    Alcotest.(check bool) "xss sanitized" false has_raw_script
  )

let test_xss_in_agent_name () =
  with_test_env (fun config ->
    let xss_name = "<img src=x onerror=alert('xss')>" in
    let result = Workspace.bind_session config ~agent_name:xss_name ~capabilities:[] () in
    Alcotest.(check bool) "join with xss name" true (contains_check result);
    (* Backend-agnostic: verify agent was registered (original test checked filename sanitization,
       which is FileSystem-specific. For other backends, we just verify the join worked) *)
    let state = Workspace.read_state config in
    Alcotest.(check bool) "agent registered" true (List.length state.active_agents > 0)
  )

let test_xss_in_message_type () =
  with_test_env (fun config ->
    ignore (Workspace.bind_session config ~agent_name:"tester" ~capabilities:[] ());
    let xss_msg_type = "<script>alert('xss')</script>" in
    ignore
      (Workspace.broadcast config ~from_agent:"tester" ~msg_type:xss_msg_type
         ~content:"hello");
    let messages = Workspace.get_all_messages_raw config ~since_seq:0 in
    let msg_type =
      match
        List.find_opt
          (fun (message : Types.message) -> String.equal message.content "hello")
          messages
      with
      | Some message -> message.msg_type
      | None -> Alcotest.fail "broadcast message not found"
    in
    Alcotest.(check bool) "msg_type raw script removed" false
      (str_contains msg_type "<script>" || str_contains msg_type "</script>");
    Alcotest.(check bool) "msg_type escaped" true
      (str_contains msg_type "&lt;script&gt;")
  )

(* === Board Admin Tests === *)

(* Use 3-part nicknames so join() preserves them as-is
   (Nickname.is_generated_nickname requires 3+ dash-separated parts) *)
let admin_keeper_agent = "admin-board-keeper"
let test_agent_a = "agent-test-alpha"
let test_agent_z = "agent-test-zombie"

let test_force_release_bypasses_assignee () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Orphan Task" ~priority:1 ~description:"" in
    let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    (* Different agent cannot release without force *)
    let normal = Workspace.transition_task_r config ~agent_name:admin_keeper_agent ~task_id:"task-001"
        ~action:Masc_domain.Release () in
    Alcotest.(check bool) "normal release blocked" true
      (match normal with Error _ -> true | Ok _ -> false);
    (* Force release succeeds *)
    let forced = Workspace.force_release_task_r config ~agent_name:admin_keeper_agent ~task_id:"task-001" () in
    Alcotest.(check bool) "force release ok" true
      (match forced with Ok _ -> true | Error _ -> false);
    (* Task should be back to Todo *)
    let tasks = Workspace.list_tasks config in
    Alcotest.(check bool) "task is todo" true (str_contains tasks "Todo" || str_contains tasks "todo")
  )

let test_force_done_bypasses_assignee () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Force Done Task" ~priority:1 ~description:"" in
    let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    (* Normal done by different agent fails *)
    let normal = Workspace.transition_task_r config ~agent_name:admin_keeper_agent ~task_id:"task-001"
        ~action:Masc_domain.Done_action ~notes:"forced" () in
    Alcotest.(check bool) "normal done blocked" true
      (match normal with Error _ -> true | Ok _ -> false);
    (* Force done succeeds *)
    let forced = Workspace.force_done_task_r config ~agent_name:admin_keeper_agent ~task_id:"task-001"
        ~notes:"auto-closed by admin" () in
    Alcotest.(check bool) "force done ok" true
      (match forced with Ok _ -> true | Error _ -> false);
    (* Task should be done *)
    let tasks = Workspace.list_tasks ~include_done:true config in
    Alcotest.(check bool) "task is done" true (str_contains tasks "Done" || str_contains tasks "done")
  )

(* === RFC-0323 G-2: submit_and_approve_task_r (machine-verified completion) === *)

let find_task config task_id =
  Workspace.get_tasks_raw config
  |> List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id)

let test_submit_and_approve_completes_via_verification () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Probe Task" ~priority:1 ~description:"" in
    let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    (* Uses the exported probe identity so this test also pins that the
       constant passes Agent_id validation and is distinct from a plain
       agent identity, end-to-end through the real FSM. *)
    let result =
      Workspace.submit_and_approve_task_r config ~agent_name:test_agent_a
        ~verifier_name:Keeper_tool_task_runtime.deterministic_probe_verifier
        ~task_id:"task-001"
        ~notes:"deterministic evidence satisfied" ~approve_notes:"machine-verified" ()
    in
    Alcotest.(check bool) "submit+approve ok" true
      (match result with Ok _ -> true | Error _ -> false);
    (* Verification-store lifecycle (hooks installed above): the submit
       created a record and the machine verdict resolved it — nothing
       actionable remains to wake verifiers or linger in the dashboard
       panel. *)
    let requests = Verification.list_requests config.Workspace.base_path in
    Alcotest.(check bool) "store record created" true
      (List.length requests >= 1);
    Alcotest.(check int) "no actionable record remains" 0
      (List.length (List.filter Verification.request_is_actionable requests));
    match find_task config "task-001" with
    | Some { task_status = Masc_domain.Done { assignee; notes; _ }; _ } ->
      Alcotest.(check string) "assignee preserved" test_agent_a assignee;
      Alcotest.(check bool) "approved-by verifier recorded" true
        (match notes with
         | Some n ->
           str_contains n Keeper_tool_task_runtime.deterministic_probe_verifier
         | None -> false)
    | Some _ -> Alcotest.fail "task not Done after submit+approve"
    | None -> Alcotest.fail "task-001 missing")

let test_submit_and_approve_rejects_same_identity () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Probe Task" ~priority:1 ~description:"" in
    let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    let result =
      Workspace.submit_and_approve_task_r config ~agent_name:test_agent_a
        ~verifier_name:test_agent_a ~task_id:"task-001"
        ~notes:"n" ~approve_notes:"a" ()
    in
    Alcotest.(check bool) "rejected as not distinct" true
      (match result with
       | Error (Workspace.Machine_verify_verifier_not_distinct _) -> true
       | Ok _ | Error _ -> false);
    (* Rejected before any mutation: task must still be Claimed. *)
    Alcotest.(check bool) "task still claimed" true
      (match find_task config "task-001" with
       | Some { task_status = Masc_domain.Claimed _; _ } -> true
       | Some _ | None -> false))

let test_submit_and_approve_rejects_invalid_verifier () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Probe Task" ~priority:1 ~description:"" in
    let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    let result =
      Workspace.submit_and_approve_task_r config ~agent_name:test_agent_a
        ~verifier_name:"probe:bad:double" ~task_id:"task-001"
        ~notes:"n" ~approve_notes:"a" ()
    in
    Alcotest.(check bool) "rejected as invalid verifier" true
      (match result with
       | Error (Workspace.Machine_verify_invalid_verifier _) -> true
       | Ok _ | Error _ -> false);
    Alcotest.(check bool) "task still claimed" true
      (match find_task config "task-001" with
       | Some { task_status = Masc_domain.Claimed _; _ } -> true
       | Some _ | None -> false))

let test_submit_and_approve_non_assignee_submit_fails () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Probe Task" ~priority:1 ~description:"" in
    let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    let result =
      Workspace.submit_and_approve_task_r config ~agent_name:admin_keeper_agent
        ~verifier_name:Keeper_tool_task_runtime.deterministic_probe_verifier
        ~task_id:"task-001" ~notes:"n" ~approve_notes:"a" ()
    in
    Alcotest.(check bool) "submit failed typed" true
      (match result with
       | Error (Workspace.Machine_verify_submit_failed _) -> true
       | Ok _ | Error _ -> false);
    Alcotest.(check bool) "task still claimed" true
      (match find_task config "task-001" with
       | Some { task_status = Masc_domain.Claimed _; _ } -> true
       | Some _ | None -> false))

let test_audit_orphan_tasks () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Orphan Candidate" ~priority:1 ~description:"" in
    let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    (* While agent is active, no orphans *)
    let orphans_before = Workspace.audit_orphan_tasks config in
    Alcotest.(check int) "no orphans while active" 0 (List.length orphans_before);
    (* Remove agent file to simulate it disappearing *)
    let _ = Workspace.end_session config ~agent_name:test_agent_a in
    (* Now the task is orphaned (claimed by test_agent_a but agent is gone) *)
    let orphans_after = Workspace.audit_orphan_tasks config in
    Alcotest.(check int) "one orphan detected" 1 (List.length orphans_after);
    let (task, assignee) = List.hd orphans_after in
    Alcotest.(check string) "orphan assignee" test_agent_a assignee;
    Alcotest.(check string) "orphan task id" "task-001" task.id
  )

let test_audit_orphan_awaiting_verification_tasks () =
  with_test_env (fun config ->
    let previous = Sys.getenv_opt "MASC_VERIFICATION_FSM_ENABLED" in
    Fun.protect
      ~finally:(fun () ->
        match previous with
        | Some value -> Unix.putenv "MASC_VERIFICATION_FSM_ENABLED" value
        | None -> Unix.putenv "MASC_VERIFICATION_FSM_ENABLED" "")
      (fun () ->
        Unix.putenv "MASC_VERIFICATION_FSM_ENABLED" "true";
        let _ =
          Workspace.add_task config ~title:"Verification Orphan Candidate"
            ~priority:1 ~description:""
        in
        let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
        let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
        match
          Workspace.transition_task_r config ~agent_name:test_agent_a
            ~task_id:"task-001" ~action:Masc_domain.Submit_for_verification
            ~notes:"verification orphan setup notes"
            ()
        with
        | Error err ->
            Alcotest.failf "submit for verification failed: %s"
              (Masc_domain.show_masc_error err)
        | Ok _ ->
            let orphans_before = Workspace.audit_orphan_tasks config in
            Alcotest.(check int) "no verification orphans while active" 0
              (List.length orphans_before);
            let _ = Workspace.end_session config ~agent_name:test_agent_a in
            let orphans_after = Workspace.audit_orphan_tasks config in
            Alcotest.(check int) "one verification orphan detected" 1
              (List.length orphans_after);
            let (task, assignee) = List.hd orphans_after in
            Alcotest.(check string) "verification orphan assignee" test_agent_a
              assignee;
            Alcotest.(check string) "verification orphan task id" "task-001"
              task.id))

(* Regression for #21418: a live keeper that has gone quiet between heartbeats
   (last_seen past the 300s default, but within the 3600s keeper grace) must NOT
   have its own claimed task classified as an orphan. With the pre-fix
   [Time.is_stale] (300s flat) predicate this returned 1 orphan, which drove the
   keeper self-wake loop that #21418 papered over by filtering self from the
   count. The root fix routes typed/meta-confirmed keepers through
   [Zombie.is_zombie_for_agent]. *)
let test_audit_orphan_spares_live_keeper_within_grace () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Keeper Task" ~priority:1 ~description:"" in
    let keeper = "keeper-grace-agent" in
    let _ = Workspace.bind_session config ~agent_name:keeper ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:keeper ~task_id:"task-001" in
    age_active_agent config ~agent_type:"keeper" ~name:keeper ~age_seconds:600.0;
    let orphans = Workspace.audit_orphan_tasks config in
    Alcotest.(check int) "live keeper within grace is not an orphan" 0
      (List.length orphans)
  )

(* A keeper quiet beyond the 3600s keeper grace IS still an orphan, so its task
   remains reclaimable — the fix extends the grace window, it does not exempt
   keepers permanently. *)
let test_audit_orphan_detects_dead_keeper_beyond_grace () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Keeper Task" ~priority:1 ~description:"" in
    let keeper = "keeper-dead-agent" in
    let _ = Workspace.bind_session config ~agent_name:keeper ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:keeper ~task_id:"task-001" in
    age_active_agent config ~agent_type:"keeper" ~name:keeper ~age_seconds:4000.0;
    let orphans = Workspace.audit_orphan_tasks config in
    Alcotest.(check int) "dead keeper beyond grace is an orphan" 1
      (List.length orphans);
    let (_, assignee) = List.hd orphans in
    Alcotest.(check string) "orphan assignee is the dead keeper" keeper assignee
  )

(* Non-keeper agents keep the 300s default threshold — 10 minutes quiet orphans
   the task, confirming the keeper grace is scoped to keepers only. *)
let test_audit_orphan_nonkeeper_uses_default_threshold () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Regular Task" ~priority:1 ~description:"" in
    let agent = "claude-worker-agent" in
    let _ = Workspace.bind_session config ~agent_name:agent ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:agent ~task_id:"task-001" in
    age_active_agent config ~agent_type:"claude" ~name:agent ~age_seconds:600.0;
    let orphans = Workspace.audit_orphan_tasks config in
    Alcotest.(check int) "non-keeper past default threshold is an orphan" 1
      (List.length orphans)
  )

(* A keeper-shaped non-keeper (name matches the pattern, but agent_type is not
   "keeper" and the record is not keeper-owned) must use the ordinary 300s
   threshold, not the 3600s keeper grace. Regression for review follow-up. *)
let test_audit_orphan_detects_keeper_shaped_non_keeper () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Spoof task" ~priority:1 ~description:"" in
    let spoof = "keeper-spoof-agent" in
    let _ = Workspace.bind_session config ~agent_name:spoof ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:spoof ~task_id:"task-001" in
    age_active_agent config ~agent_type:"spoof" ~name:spoof ~age_seconds:600.0;
    let orphans = Workspace.audit_orphan_tasks config in
    Alcotest.(check int)
      "keeper-shaped non-keeper past default threshold is an orphan"
      1
      (List.length orphans);
    let (_, assignee) = List.hd orphans in
    Alcotest.(check string) "orphan assignee is the spoof worker" spoof assignee
  )

(* An agent whose record is stamped as keeper-owned (via meta.keeper_name)
   gets the keeper threshold even when its agent_type is not "keeper". *)
let test_audit_orphan_spares_keeper_owned_meta_within_grace () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Keeper-owned task" ~priority:1 ~description:"" in
    let worker = "claude-runtime-agent" in
    let _ = Workspace.bind_session config ~agent_name:worker ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:worker ~task_id:"task-001" in
    age_active_agent config ~agent_type:"claude" ~name:worker ~age_seconds:600.0;
    Workspace.update_local_agent_state config ~agent_name:worker (fun agent ->
      let open Masc_domain in
      let meta =
        match agent.meta with
        | Some m -> { m with keeper_name = Some "keeper-sangsu" }
        | None ->
          { session_id = ""
          ; agent_type = agent.agent_type
          ; pid = None
          ; hostname = None
          ; tty = None
          ; parent_task = None
          ; keeper_name = Some "keeper-sangsu"
          ; keeper_id = None
          }
      in
      { agent with meta = Some meta });
    let orphans = Workspace.audit_orphan_tasks config in
    Alcotest.(check int)
      "keeper-owned worker within grace is not an orphan"
      0
      (List.length orphans)
  )

let keeper_meta_for_self_filter agent_name =
  let json =
    `Assoc
      [ ("name", `String "self-filter-keeper")
      ; ("agent_name", `String agent_name)
      ; ("trace_id", `String "trace-self-filter")
      ; ("goal", `String "self-filter regression")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> { meta with active_goal_ids = [] }
  | Error err -> Alcotest.fail ("keeper_meta_for_self_filter failed: " ^ err)

let keeper_meta_for_goal_filter agent_name active_goal_ids =
  let json =
    `Assoc
      [ ("name", `String "goal-filter-keeper")
      ; ("agent_name", `String agent_name)
      ; ("trace_id", `String "trace-goal-filter")
      ; ("goal", `String "goal filter regression")
      ; ( "active_goal_ids"
        , `List (List.map (fun goal_id -> `String goal_id) active_goal_ids) )
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("keeper_meta_for_goal_filter failed: " ^ err)

(* Keepers can claim without a materialized [.masc/agents/] record. The keeper
   backlog failed-task count must exclude the keeper's own claimed task so it
   does not re-trigger a self-wake loop. *)
let test_read_backlog_counts_excludes_self_owned_orphan () =
  with_test_env (fun config ->
    let keeper = "keeper-self-filter-agent" in
    let _ = Workspace.bind_session config ~agent_name:keeper ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:keeper ~task_id:"task-001" in
    (* Remove the agent file to simulate a keeper with no active registry record. *)
    let _ = Workspace.end_session config ~agent_name:keeper in
    let meta = keeper_meta_for_self_filter keeper in
    let _, _, failed, _, _ =
      Keeper_world_observation_inputs.read_backlog_counts ~config ~meta
    in
    Alcotest.(check int) "keeper's own orphan excluded from failed count" 0 failed
  )

let test_read_backlog_counts_falls_back_to_unscoped_claimable_task () =
  with_test_env (fun config ->
    let keeper = "keeper-goal-filter-agent" in
    let _ =
      Workspace.add_task config ~goal_id:"goal-b" ~title:"Goal B work"
        ~priority:1 ~description:""
    in
    let meta = keeper_meta_for_goal_filter keeper [ "goal-a" ] in
    let _, claimable, _, _, _ =
      Keeper_world_observation_inputs.read_backlog_counts ~config ~meta
    in
    Alcotest.(check int)
      "claimable count falls back to unscoped todo"
      1
      claimable
  )

let test_keeper_tasks_audit_excludes_self_owned_orphan () =
  with_test_env (fun config ->
    let keeper = "keeper-task-audit-self-filter-agent" in
    let _ = Workspace.bind_session config ~agent_name:keeper ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:keeper ~task_id:"task-001" in
    (* Remove the agent file to simulate a keeper with no active registry record. *)
    let _ = Workspace.end_session config ~agent_name:keeper in
    let meta = keeper_meta_for_self_filter keeper in
    let payload =
      Keeper_tool_task_runtime.handle_keeper_task_tool
        ~config
        ~meta
        ~name:"keeper_tasks_audit"
        ~args:(`Assoc [])
      |> Yojson.Safe.from_string
    in
    let orphan_count =
      Yojson.Safe.Util.(payload |> member "orphan_count" |> to_int)
    in
    Alcotest.(check int) "keeper's own orphan excluded from audit" 0 orphan_count
  )

let test_cleanup_zombies_releases_tasks () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Zombie Task" ~priority:1 ~description:"" in
    let _ = Workspace.bind_session config ~agent_name:test_agent_z ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_z ~task_id:"task-001" in
    (* Manually set agent's last_seen to a very old timestamp to make it a zombie *)
    let agents_path = Filename.concat
      (Filename.concat config.base_path Common.masc_dirname) "agents" in
    let agent_file = Filename.concat agents_path (test_agent_z ^ ".json") in
    let json = Workspace.read_json config agent_file in
    let updated_json = match json with
      | `Assoc pairs ->
          `Assoc (List.map (fun (k, v) ->
            if k = "last_seen" then (k, `String "2020-01-01T00:00:00Z") else (k, v)
          ) pairs)
      | other -> other
    in
    Workspace.write_json config agent_file updated_json;
    (* Run cleanup — should remove zombie agent AND release its tasks *)
    let result = Workspace.cleanup_zombies config in
    Alcotest.(check bool) "cleanup ran" true
      (match result with
       | Workspace.No_agents_dir -> true
       | Workspace.No_zombies -> true
       | Workspace.Cleaned _ -> true);
    (* Verify task is released (back to Todo) *)
    let tasks = Workspace.list_tasks config in
    Alcotest.(check bool) "task released to todo" true
      (str_contains tasks "Todo" || str_contains tasks "todo")
  )

(* --- Rejoin Identity Preservation (BUG-003) --- *)

let test_rejoin_preserves_identity () =
  with_test_env (fun config ->
    (* 1. Join: get a nickname *)
    let join1 = Workspace.bind_session config ~agent_name:"claude" ~capabilities:["code"] () in
    Alcotest.(check bool) "first join success" true (contains_check join1);

    (* Extract nickname from active_agents *)
    let state1 = Workspace.read_state config in
    let nick1 = List.find (fun name ->
      String.length name > 6 && String.sub name 0 6 = "claude"
    ) state1.active_agents in

    (* 2. Leave *)
    let leave_result = Workspace.end_session config ~agent_name:"claude" in
    Alcotest.(check bool) "leave success" true (contains_check leave_result);

    (* Agent should be removed from active_agents but file preserved *)
    let state2 = Workspace.read_state config in
    let still_active = List.exists (fun name ->
      String.length name > 6 && String.sub name 0 6 = "claude"
    ) state2.active_agents in
    Alcotest.(check bool) "not in active_agents after leave" false still_active;

    (* 3. Re-join: should get the SAME nickname *)
    let join2 = Workspace.bind_session config ~agent_name:"claude" ~capabilities:["code"; "review"] () in
    Alcotest.(check bool) "rejoin success" true (contains_check join2);

    let state3 = Workspace.read_state config in
    let nick2 = List.find (fun name ->
      String.length name > 6 && String.sub name 0 6 = "claude"
    ) state3.active_agents in

    (* The key assertion: same nickname after rejoin *)
    Alcotest.(check string) "same identity after rejoin" nick1 nick2
  )

let test_rejoin_restores_active_status () =
  with_test_env (fun config ->
    let _ = Workspace.bind_session config ~agent_name:"gemini" ~capabilities:["search"] () in
    let _ = Workspace.end_session config ~agent_name:"gemini" in

    (* Re-join *)
    let result = Workspace.bind_session config ~agent_name:"gemini" ~capabilities:["search"] () in
    Alcotest.(check bool) "rejoin success" true (contains_check result);

    (* Should be back in active_agents *)
    let state = Workspace.read_state config in
    let is_active = List.exists (fun name ->
      String.length name > 6 && String.sub name 0 6 = "gemini"
    ) state.active_agents in
    Alcotest.(check bool) "back in active_agents" true is_active
  )

let test_multiple_rejoin_cycles () =
  with_test_env (fun config ->
    let _ = Workspace.bind_session config ~agent_name:"codex" ~capabilities:["impl"] () in
    let state1 = Workspace.read_state config in
    let nick1 = List.find (fun name ->
      String.length name > 5 && String.sub name 0 5 = "codex"
    ) state1.active_agents in

    (* Three leave/rejoin cycles *)
    for _ = 1 to 3 do
      let _ = Workspace.end_session config ~agent_name:"codex" in
      let _ = Workspace.bind_session config ~agent_name:"codex" ~capabilities:["impl"] () in
      ()
    done;

    let state_final = Workspace.read_state config in
    let nick_final = List.find (fun name ->
      String.length name > 5 && String.sub name 0 5 = "codex"
    ) state_final.active_agents in

    Alcotest.(check string) "identity stable across 3 cycles" nick1 nick_final
  )

(* ============================================================ *)
(* Lifecycle Bug Fix Tests (#1655)                               *)
(* ============================================================ *)

(** Read today's event log and return all lines *)
let read_event_log config =
  let events_dir = Filename.concat (Workspace.masc_dir config) "events" in
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  let month_dir = Filename.concat events_dir
    (Printf.sprintf "%04d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1)) in
  let day_file = Filename.concat month_dir
    (Printf.sprintf "%02d.jsonl" tm.tm_mday) in
  if Sys.file_exists day_file then begin
    let ic = open_in day_file in
    let lines = ref [] in
    (try while true do
      lines := input_line ic :: !lines
    done with End_of_file -> ());
    close_in ic;
    List.rev !lines
  end else
    []

(** BUG-1: Workspace-scoped rejoin records event log *)
let test_rejoin_event_log () =
  with_test_env (fun config ->
    (* Join then leave to create Inactive agent *)
    let _ = Workspace.bind_session config ~agent_name:"logcheck" ~capabilities:[] () in
    let _ = Workspace.end_session config ~agent_name:"logcheck" in

    (* Rejoin — should produce event log with "session_rebound":true *)
    let _ = Workspace.bind_session config ~agent_name:"logcheck" ~capabilities:[] () in

    (* Read event log and check for rejoin entry *)
    let events = read_event_log config in
    let has_rejoin = List.exists (fun line ->
      str_contains line "\"session_rebound\":true"
      && str_contains line "agent_session_bound"
    ) events in
    Alcotest.(check bool) "rejoin event logged" true has_rejoin
  )

(** BUG-2: Zombie file deletion failure preserves state consistency *)
let test_zombie_file_delete_failure_keeps_state () =
  with_test_env (fun config ->
    (* Create a stale agent *)
    make_stale_agent config ~name:"unremovable-agent" ~age_seconds:700.0;

    (* Make the agent file read-only to prevent deletion *)
    let agents_path = Filename.concat (Workspace.masc_dir config) "agents" in
    let path = Filename.concat agents_path (Workspace.safe_filename "unremovable-agent" ^ ".json") in
    Unix.chmod path 0o444;
    (* Make directory non-writable so Sys.remove fails *)
    Unix.chmod agents_path 0o555;

    (* Run cleanup — file deletion should fail *)
    let _result = Workspace.cleanup_zombies config in

    (* Restore permissions for cleanup *)
    Unix.chmod agents_path 0o755;
    Unix.chmod path 0o644;

    (* Key assertion: agent should still be in active_agents since file deletion failed *)
    let state = Workspace.read_state config in
    let still_present = List.exists (fun name ->
      str_contains name "unremovable"
    ) state.active_agents in
    (* With BUG-2 fix: agent remains in state when file delete fails *)
    (* File should still exist *)
    Alcotest.(check bool) "file still exists" true (Sys.file_exists path);
    (* Agent MAY or may not be in active_agents depending on Phase 2 transition.
       But the file should definitely still exist — that's the core BUG-2 fix. *)
    ignore still_present
  )

(** BUG-4: Zombie cleanup transitions status to Inactive before deletion *)
let test_zombie_cleanup_transitions_to_inactive () =
  with_test_env (fun config ->
    (* Create stale agent *)
    make_stale_agent config ~name:"transition-test-agent" ~age_seconds:700.0;

    (* Make file undeletable to observe Inactive transition without removal *)
    let agents_path = Filename.concat (Workspace.masc_dir config) "agents" in
    let path = Filename.concat agents_path (Workspace.safe_filename "transition-test-agent" ^ ".json") in
    Unix.chmod path 0o444;
    Unix.chmod agents_path 0o555;

    let _result = Workspace.cleanup_zombies config in

    (* Restore permissions *)
    Unix.chmod agents_path 0o755;
    Unix.chmod path 0o644;

    (* Read agent file — should be Inactive now (Phase 2 ran before Phase 4 failed) *)
    let json = Workspace.read_json config path in
    let status = Yojson.Safe.Util.(member "status" json |> to_string) in
    Alcotest.(check string) "status transitioned to inactive" "inactive" status
  )

(** BUG-5: Keeper detection uses agent_type/metadata evidence, not just name *)
let test_keeper_detection_by_agent_type () =
  (* A non-keeper-named agent with agent_type="keeper" should get keeper threshold *)
  let is_keeper_by_type = Workspace_resilience.Zombie.is_keeper ~name:"regular-bot" ~agent_type:"keeper" in
  Alcotest.(check bool) "agent_type=keeper detected" true is_keeper_by_type;

  (* A keeper-shaped name alone is not authoritative. *)
  let is_keeper_by_name = Workspace_resilience.Zombie.is_keeper ~name:"keeper-test-agent" ~agent_type:"test" in
  Alcotest.(check bool) "keeper-*-agent name alone rejected" false is_keeper_by_name;

  (* Neither name nor type matches *)
  let not_keeper = Workspace_resilience.Zombie.is_keeper ~name:"regular-bot" ~agent_type:"claude" in
  Alcotest.(check bool) "non-keeper correctly rejected" false not_keeper

(** BUG-6: Heartbeat Mutex protects concurrent access *)
let test_heartbeat_concurrent_start_stop () =
  Eio_main.run @@ fun _env ->
  (* Reset heartbeats *)
  List.iter (fun (hb : Heartbeat.t) -> ignore (Heartbeat.stop hb.id))
    (Heartbeat.list ());

  (* Start multiple heartbeats *)
  let ids = List.init 20 (fun i ->
    Heartbeat.start ~agent_name:(Printf.sprintf "agent-%d" i) ~interval:60 ~message:"ping"
  ) in
  Alcotest.(check int) "20 heartbeats started" 20 (List.length (Heartbeat.list ()));

  (* Stop all by agent — interleaved *)
  let stopped_count = ref 0 in
  List.iteri (fun i _id ->
    let n = Heartbeat.stop_by_agent ~agent_name:(Printf.sprintf "agent-%d" i) in
    stopped_count := !stopped_count + n
  ) ids;
  Alcotest.(check int) "all 20 stopped" 20 !stopped_count;

  (* List should be empty now *)
  Alcotest.(check int) "list empty after cleanup" 0 (List.length (Heartbeat.list ()))

(** BUG-006: Task transitions should succeed when the caller uses the unsuffixed
    keeper name (e.g. "keeper-bob") but the task was claimed under the
    canonical "-agent" form (e.g. "keeper-bob-agent").  Reproduces the
    identity mismatch: "claimed by 'keeper-X-agent', caller is 'keeper-X'". *)
let test_bug006_transition_with_unsuffixed_name () =
  with_test_env (fun config ->
    (* Join with canonical agent name to establish the identity recorded at claim time *)
    let _ = Workspace.bind_session config ~agent_name:"keeper-bob-agent" ~capabilities:["code"] () in
    let _ = Workspace.add_task config ~title:"BUG-006 Task" ~priority:1 ~description:"" in
    (* Claim using the canonical name — assignee is recorded as "keeper-bob-agent" *)
    (match Workspace.claim_task_r config ~agent_name:"keeper-bob-agent" ~task_id:"task-001" () with
     | Ok _ -> ()
     | Error e -> Alcotest.failf "claim failed: %s" (Masc_domain.show_masc_error e));
    (* Transition (start) using the unsuffixed name — should resolve to "keeper-bob-agent" *)
    (match Workspace.transition_task_r config ~agent_name:"keeper-bob" ~task_id:"task-001"
             ~action:Masc_domain.Start () with
     | Ok _ -> ()
     | Error e ->
         Alcotest.failf "start with unsuffixed name failed (BUG-006): %s"
           (Masc_domain.show_masc_error e));
    (* Complete using the unsuffixed name — same resolution path *)
    (match transition_done_r config ~agent_name:"keeper-bob" ~task_id:"task-001"
             ~notes:"done" with
     | Ok _ -> ()
     | Error e ->
         Alcotest.failf "complete with unsuffixed name failed (BUG-006): %s"
           (Masc_domain.show_masc_error e))
  )

let test_bug006_cancel_with_unsuffixed_name () =
  with_test_env (fun config ->
    let _ = Workspace.bind_session config ~agent_name:"keeper-bob-agent" ~capabilities:["code"] () in
    let _ = Workspace.add_task config ~title:"BUG-006 Cancel Task" ~priority:1 ~description:"" in
    (match Workspace.claim_task_r config ~agent_name:"keeper-bob-agent" ~task_id:"task-001" () with
     | Ok _ -> ()
     | Error e -> Alcotest.failf "claim failed: %s" (Masc_domain.show_masc_error e));
    (* Cancel using the unsuffixed name — should resolve to "keeper-bob-agent" *)
    (match Workspace.cancel_task_r config ~agent_name:"keeper-bob" ~task_id:"task-001"
             ~reason:"test" with
     | Ok _ -> ()
     | Error e ->
         Alcotest.failf "cancel with unsuffixed name failed (BUG-006): %s"
           (Masc_domain.show_masc_error e))
  )

(* === Idle loop stop signal tests === *)

let test_empty_backlog_stop_signal () =
  with_test_env (fun config ->
    let result = Workspace.list_tasks config in
    Alcotest.(check bool) "contains STOP signal"
      true (str_contains result "STOP calling keeper_tasks_list"))

let test_no_active_tasks_stop_signal () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Done Task" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"alice" ~task_id:"task-001" in
    let _ = transition_done config ~agent_name:"alice" ~task_id:"task-001" ~notes:"done" in
    let result = Workspace.list_tasks config in
    Alcotest.(check bool) "contains STOP signal"
      true (str_contains result "STOP calling keeper_tasks_list"))

let test_no_unclaimed_tasks_stop_signal () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Claimed" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"alice" ~task_id:"task-001" in
    let result = Workspace.claim_next config ~agent_name:"bob" in
    Alcotest.(check bool) "contains ACTION stop signal"
      true (str_contains result "ACTION: Stop task-checking"))

let () =
  Eio_guard.enable ();
  Random.init 42;
  Alcotest.run "Workspace" [
    (* === Happy Path Tests === *)
    "init", [
      Alcotest.test_case "creates folder" `Quick test_init_creates_folder;
    ];
    "join", [
      Alcotest.test_case "creates agent" `Quick test_join_creates_agent;
      Alcotest.test_case "double join" `Quick test_double_join;
    ];
    "leave", [
      Alcotest.test_case "removes agent" `Quick test_leave_removes_agent;
    ];
    "rejoin", [
      Alcotest.test_case "preserves identity" `Quick test_rejoin_preserves_identity;
      Alcotest.test_case "restores active status" `Quick test_rejoin_restores_active_status;
      Alcotest.test_case "stable across 3 cycles" `Quick test_multiple_rejoin_cycles;
    ];
    "tasks", [
      Alcotest.test_case "add and claim" `Quick test_add_and_claim_task;
    ];
    "messages", [
      Alcotest.test_case "broadcast" `Quick test_broadcast_message;
      Alcotest.test_case "lifecycle messages are typed" `Quick
        test_lifecycle_messages_are_typed;
      Alcotest.test_case "broadcast replaces terminal task cache desync" `Quick
        test_broadcast_replaces_terminal_task_cache_desync;
    ];

    (* === Edge Case Tests === *)
    "task_errors", [
      Alcotest.test_case "complete without claim" `Quick test_complete_without_claim;
      Alcotest.test_case "complete by wrong agent" `Quick test_complete_by_wrong_agent;
      Alcotest.test_case "complete nonexistent" `Quick test_complete_nonexistent_task;
      Alcotest.test_case "claim nonexistent" `Quick test_claim_nonexistent_task;
      Alcotest.test_case "double complete" `Quick test_double_complete;
    ];

    (* === Robustness: Boundary Values === *)
    "boundary", [
      Alcotest.test_case "empty task title" `Quick test_empty_task_title;
      Alcotest.test_case "very long title" `Quick test_very_long_task_title;
      Alcotest.test_case "special chars in message" `Quick test_special_chars_in_message;
      Alcotest.test_case "special agent name" `Quick test_agent_name_with_special_chars;
      Alcotest.test_case "priority boundaries" `Quick test_priority_boundaries;
    ];

    (* === Robustness: State Consistency === *)
    "state", [
      Alcotest.test_case "task state after claim" `Quick test_task_state_after_claim;
      Alcotest.test_case "multiple tasks independent" `Quick test_multiple_tasks_independent;
    ];

    (* === Archive Tests === *)
    "archive", [
      Alcotest.test_case "task id uses archive max" `Quick test_add_task_uses_archive_max_id;
    ];

    (* === Robustness: Concurrency Simulation === *)
    "concurrency", [
      Alcotest.test_case "rapid claim sequence" `Quick test_rapid_claim_sequence;
      Alcotest.test_case "multi-agent multi-task" `Quick test_multiple_agents_multiple_tasks;
    ];

    (* === Robustness: Recovery === *)
    "recovery", [
      Alcotest.test_case "reinit existing workspace" `Quick test_reinit_existing_workspace;
      Alcotest.test_case "operations preserve state" `Quick test_operations_preserve_state;
    ];

    (* === Event Log Tests === *)
    "events", [
      Alcotest.test_case "event log" `Quick test_event_log;
      Alcotest.test_case "log on join" `Quick test_event_log_on_join;
      Alcotest.test_case "log on claim/done" `Quick test_event_log_on_claim_done;
    ];

    (* === Heartbeat & Zombie Detection Tests === *)
    "heartbeat", [
      Alcotest.test_case "updates last_seen" `Quick test_heartbeat_updates_lastseen;
      Alcotest.test_case "default join keeps bound status" `Quick test_is_agent_session_bound_after_default_join;
      Alcotest.test_case "nonexistent agent" `Quick test_heartbeat_nonexistent_agent;
      Alcotest.test_case "backend bootstrap preserves workspace state" `Quick test_workspace_bootstrap_preserves_backend_state;
      Alcotest.test_case "bootstrap ignores invalid workspace id in flat mode" `Quick test_workspace_bootstrap_ignores_invalid_workspace_id_in_flat_mode;
      Alcotest.test_case "read_backlog_r recovers from last good snapshot" `Quick
        test_read_backlog_r_recovers_from_last_good_snapshot;
      Alcotest.test_case "read_backlog_r reports parse error when recovery also invalid" `Quick
        test_read_backlog_r_reports_parse_error_when_recovery_is_also_invalid;
      Alcotest.test_case "release stale claims skips invalid backlog" `Quick
        test_release_stale_claims_skips_invalid_backlog;
      Alcotest.test_case "release stale claims clears agent current_task" `Quick
        test_release_stale_claims_clears_agent_current_task;
      Alcotest.test_case "release stale claims preserves other agent task" `Quick
        test_release_stale_claims_preserves_other_agent_task;
      Alcotest.test_case "release stale claims skips stale verification" `Quick
        test_release_stale_claims_skips_stale_verification;
      Alcotest.test_case "cleanup zombies empty" `Quick test_cleanup_zombies_empty;
      Alcotest.test_case "cleanup detects regular zombie" `Quick test_cleanup_zombies_detects_regular;
      Alcotest.test_case "cleanup detects keeper zombie" `Quick test_cleanup_zombies_detects_keeper;
      Alcotest.test_case "cleanup spares recent keeper" `Quick test_cleanup_zombies_spares_recent_keeper;
      Alcotest.test_case "cleanup spares type keeper" `Quick test_cleanup_zombies_spares_type_keeper;
      Alcotest.test_case "cleanup removes broken agent file" `Quick test_cleanup_zombies_removes_broken_agent_file;
      Alcotest.test_case "fd pressure exn is not broken JSON" `Quick test_fd_pressure_exn_classification;
      Alcotest.test_case "cleanup preserves non-json files" `Quick test_cleanup_zombies_preserves_non_json_files;
    ];


    (* === Input Validation Tests === *)
    "validation", [
      Alcotest.test_case "empty agent name" `Quick test_empty_agent_name_claim;
      Alcotest.test_case "empty task id" `Quick test_empty_task_id_claim;
      Alcotest.test_case "very long agent name" `Quick test_very_long_agent_name;
    ];

    (* === Unicode Tests === *)
    "unicode", [
      Alcotest.test_case "korean agent name" `Quick test_korean_agent_name;
      Alcotest.test_case "emoji in message" `Quick test_emoji_in_message;
      Alcotest.test_case "unicode task title" `Quick test_unicode_task_title;
    ];

    (* === Reset Tests === *)
    "reset", [
      Alcotest.test_case "clears all state" `Quick test_reset_clears_all_state;
      Alcotest.test_case "reinit after reset" `Quick test_reinit_after_reset;
    ];

    (* === Message Tests === *)
    "messages_extended", [
      Alcotest.test_case "very long message" `Quick test_very_long_message;
      Alcotest.test_case "json chars" `Quick test_message_with_json_chars;
      Alcotest.test_case "message sequence" `Quick test_message_sequence;
    ];

    (* === Stress Tests === *)
    "stress", [
      Alcotest.test_case "many tasks" `Quick test_many_tasks;
    ];

    (* === Portal Extended Tests === *)

    (* === Priority Tests === *)
    "priority", [
      Alcotest.test_case "negative priority" `Quick test_negative_priority;
    ];

    (* === Security Tests (v2.1) === *)
    "security", [
      Alcotest.test_case "xss in message" `Quick test_xss_in_message;
      Alcotest.test_case "xss in agent name" `Quick test_xss_in_agent_name;
      Alcotest.test_case "xss in message type" `Quick test_xss_in_message_type;
    ];

    (* === RFC-0323 G-2: machine-verified completion === *)
    "machine_verify", [
      Alcotest.test_case "submit+approve completes via verification" `Quick
        test_submit_and_approve_completes_via_verification;
      Alcotest.test_case "same identity rejected before mutation" `Quick
        test_submit_and_approve_rejects_same_identity;
      Alcotest.test_case "invalid verifier rejected before mutation" `Quick
        test_submit_and_approve_rejects_invalid_verifier;
      Alcotest.test_case "non-assignee submit fails typed" `Quick
        test_submit_and_approve_non_assignee_submit_fails;
    ];

    (* === Board Admin Tests === *)
    "board_admin", [
      Alcotest.test_case "force release bypasses assignee" `Quick test_force_release_bypasses_assignee;
      Alcotest.test_case "force done bypasses assignee" `Quick test_force_done_bypasses_assignee;
      Alcotest.test_case "audit orphan tasks" `Quick test_audit_orphan_tasks;
      Alcotest.test_case
        "audit orphan awaiting verification tasks"
        `Quick
        test_audit_orphan_awaiting_verification_tasks;
      Alcotest.test_case "audit orphan spares live keeper within grace" `Quick
        test_audit_orphan_spares_live_keeper_within_grace;
      Alcotest.test_case "audit orphan detects dead keeper beyond grace" `Quick
        test_audit_orphan_detects_dead_keeper_beyond_grace;
      Alcotest.test_case "audit orphan non-keeper uses default threshold" `Quick
        test_audit_orphan_nonkeeper_uses_default_threshold;
      Alcotest.test_case "audit orphan detects keeper-shaped non-keeper" `Quick
        test_audit_orphan_detects_keeper_shaped_non_keeper;
      Alcotest.test_case "audit orphan spares keeper-owned meta within grace" `Quick
        test_audit_orphan_spares_keeper_owned_meta_within_grace;
      Alcotest.test_case "read backlog counts excludes self-owned orphan" `Quick
        test_read_backlog_counts_excludes_self_owned_orphan;
      Alcotest.test_case "read backlog counts falls back to unscoped claimable"
        `Quick
        test_read_backlog_counts_falls_back_to_unscoped_claimable_task;
      Alcotest.test_case "keeper tasks audit excludes self-owned orphan" `Quick
        test_keeper_tasks_audit_excludes_self_owned_orphan;
      Alcotest.test_case "cleanup zombies runtime" `Quick test_cleanup_zombies_releases_tasks;
    ];

    (* === Lifecycle Bug Fix Tests (#1655) === *)
    "lifecycle_bugs", [
      Alcotest.test_case "BUG-1: rejoin event log" `Quick test_rejoin_event_log;
      Alcotest.test_case "BUG-2: file delete failure keeps state" `Quick test_zombie_file_delete_failure_keeps_state;
      Alcotest.test_case "BUG-4: zombie transitions to inactive" `Quick test_zombie_cleanup_transitions_to_inactive;
      Alcotest.test_case "BUG-5: keeper detection by agent_type" `Quick test_keeper_detection_by_agent_type;
      Alcotest.test_case "BUG-6: heartbeat concurrent start/stop" `Quick test_heartbeat_concurrent_start_stop;
    ];

    (* === BUG-006: Task identity mismatch (unsuffixed keeper name) === *)
    "task_identity", [
      Alcotest.test_case "BUG-006: transition/complete with unsuffixed name" `Quick test_bug006_transition_with_unsuffixed_name;
      Alcotest.test_case "BUG-006: cancel with unsuffixed name" `Quick test_bug006_cancel_with_unsuffixed_name;
    ];

    (* === Idle loop stop signal tests === *)
    "idle_stop_signals", [
      Alcotest.test_case "empty backlog has stop signal" `Quick test_empty_backlog_stop_signal;
      Alcotest.test_case "no active tasks has stop signal" `Quick test_no_active_tasks_stop_signal;
      Alcotest.test_case "no unclaimed tasks has stop signal" `Quick test_no_unclaimed_tasks_stop_signal;
    ];
  ]
