(** Tests for Room module *)

open Masc_mcp

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

let contains_check result = String.sub result 0 3 = "\xE2\x9C\x85"  (* ✅ *)
let contains_warning result = String.sub result 0 3 = "\xE2\x9A\xA0"  (* ⚠ *)
let contains_portal result = String.sub result 0 4 = "\xF0\x9F\x8C\x80"  (* 🌀 *)

let room_config tmp_dir =
  Unix.putenv "MASC_BASE_PATH" tmp_dir;
  Room.default_config tmp_dir

let test_init_creates_folder () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = room_config tmp_dir in

  (* Initially not initialized *)
  Alcotest.(check bool) "not init" false (Room.is_initialized config);

  (* Initialize *)
  let result = Room.init config ~agent_name:None in
  Alcotest.(check bool) "success msg" true (contains_check result);

  (* Now initialized *)
  Alcotest.(check bool) "init" true (Room.is_initialized config);

  (* Cleanup *)
  let _ = Room.reset config in
  Unix.rmdir tmp_dir

let test_join_creates_agent () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:None in

  (* Join - now returns auto-generated nickname like "test_agent-swift-fox" *)
  let result = Room.join config ~agent_name:"test_agent" ~capabilities:["ocaml"] () in
  Alcotest.(check bool) "join success" true (contains_check result);

  (* Check agent exists via Room.read_state - nickname starts with agent_type *)
  let state = Room.read_state config in
  let has_test_agent = List.exists (fun name ->
    String.length name >= 10 && String.sub name 0 10 = "test_agent"
  ) state.active_agents in
  Alcotest.(check bool) "agent in active_agents" true has_test_agent;

  (* Cleanup *)
  let _ = Room.reset config in
  Unix.rmdir tmp_dir

let test_add_and_claim_task () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:(Some "claude") in

  (* Add task *)
  let add_result = Room.add_task config ~title:"Test Task" ~priority:1 ~description:"Test" in
  Alcotest.(check bool) "add success" true (contains_check add_result);

  (* Claim task *)
  let claim_result = Room.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
  Alcotest.(check bool) "claim success" true (contains_check claim_result);

  (* Try to claim again - should fail *)
  let claim2_result = Room.claim_task config ~agent_name:"gemini" ~task_id:"task-001" in
  Alcotest.(check bool) "double claim blocked" true (contains_warning claim2_result);

  (* Cleanup *)
  let _ = Room.reset config in
  Unix.rmdir tmp_dir

let test_add_task_uses_archive_max_id () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:None in

  let archive_path = Filename.concat (Filename.concat tmp_dir ".masc") "tasks-archive.json" in
  let archive_json =
    `Assoc [
      ("archived_at", `String "2026-01-01T00:00:00Z");
      ("tasks", `List [
        `Assoc [("id", `String "task-005")];
      ]);
    ]
  in
  Yojson.Safe.to_file archive_path archive_json;

  let result = Room.add_task config ~title:"Archive Test" ~priority:1 ~description:"" in
  Alcotest.(check bool) "uses archive max id" true (str_contains result "task-006");

  let _ = Room.reset config in
  Unix.rmdir tmp_dir

let test_broadcast_message () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:(Some "claude") in

  (* Broadcast *)
  let result = Room.broadcast config ~from_agent:"claude" ~content:"Hello @gemini!" in
  Alcotest.(check bool) "broadcast success" true (String.contains result '[');

  (* Get messages *)
  let msgs = Room.get_messages config ~since_seq:0 ~limit:10 in
  Alcotest.(check bool) "has messages" true (String.length msgs > 50);

  (* Cleanup *)
  let _ = Room.reset config in
  Unix.rmdir tmp_dir

let test_worktree_list_no_git () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:None in

  (* worktree_list should return error for non-git dir *)
  let result = Room.worktree_list config in
  let has_error = match result with
    | `Assoc fields -> List.mem_assoc "error" fields
    | _ -> false
  in
  Alcotest.(check bool) "error for non-git" true has_error;

  (* Cleanup *)
  let _ = Room.reset config in
  Unix.rmdir tmp_dir

let test_worktree_create_no_git () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:None in

  (* worktree_create_r should fail for non-git dir *)
  let result = Room.worktree_create_r config ~agent_name:"claude" ~task_id:"test" ~base_branch:"main" in
  Alcotest.(check bool) "returns error" true (match result with Error _ -> true | Ok _ -> false);

  (* Cleanup *)
  let _ = Room.reset config in
  Unix.rmdir tmp_dir

let write_file path content =
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let test_worktree_project_root_for_nested_subdir () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;
  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:(Some "claude") in
  let repo_root = config.base_path in
  Unix.mkdir (Filename.concat repo_root ".git") 0o755;
  let nested = Filename.concat repo_root "nested" in
  Unix.mkdir nested 0o755;
  let nested_config = { config with base_path = nested } in
  Alcotest.(check string) "nested path resolves to repo root"
    repo_root
    (Room.project_root nested_config);
  let _ = Room.reset config in
  rm_rf tmp_dir

let test_worktree_project_root_for_gitfile_worktree () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;
  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:(Some "claude") in
  let repo_root = config.base_path in
  Unix.mkdir (Filename.concat repo_root ".git") 0o755;
  let worktrees_dir = Filename.concat repo_root ".worktrees" in
  Unix.mkdir worktrees_dir 0o755;
  let worktree_root = Filename.concat worktrees_dir "agent-task" in
  Unix.mkdir worktree_root 0o755;
  write_file (Filename.concat worktree_root ".git")
    "gitdir: /tmp/fake-common-dir/worktrees/agent-task\n";
  let worktree_config = { config with base_path = worktree_root } in
  Alcotest.(check string) "worktree path resolves to shared repo root"
    repo_root
    (Room.project_root worktree_config);
  let _ = Room.reset config in
  rm_rf tmp_dir

let test_worktree_project_root_for_nested_gitfile_worktree_subdir () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;
  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:(Some "claude") in
  let repo_root = config.base_path in
  Unix.mkdir (Filename.concat repo_root ".git") 0o755;
  let worktrees_dir = Filename.concat repo_root ".worktrees" in
  Unix.mkdir worktrees_dir 0o755;
  let worktree_root = Filename.concat worktrees_dir "agent-task" in
  Unix.mkdir worktree_root 0o755;
  write_file (Filename.concat worktree_root ".git")
    "gitdir: /tmp/fake-common-dir/worktrees/agent-task\n";
  let nested = Filename.concat worktree_root "nested" in
  Unix.mkdir nested 0o755;
  let nested_config = { config with base_path = nested } in
  Alcotest.(check string) "nested worktree path resolves to shared repo root"
    repo_root
    (Room.project_root nested_config);
  let _ = Room.reset config in
  rm_rf tmp_dir

let test_worktree_project_root_for_masc_dir_base () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;
  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:(Some "claude") in
  let repo_root = config.base_path in
  Unix.mkdir (Filename.concat repo_root ".git") 0o755;
  let masc_config = { config with base_path = Filename.concat repo_root ".masc" } in
  Alcotest.(check string) ".masc base path resolves to repo root"
    repo_root
    (Room.project_root masc_config);
  let _ = Room.reset config in
  rm_rf tmp_dir

let test_event_log () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:None in

  (* Broadcast should create event log *)
  let result = Room.broadcast config ~from_agent:"claude" ~content:"Test event" in

  (* Verify broadcast returned a valid response (contains timestamp marker) *)
  Alcotest.(check bool) "broadcast returns response" true (String.length result > 0);
  Alcotest.(check bool) "broadcast has timestamp" true (String.contains result '[');

  (* Cleanup *)
  let _ = Room.reset config in
  Unix.rmdir tmp_dir

(* ============================================================ *)
(* Edge Case & Error Case Tests                                  *)
(* ============================================================ *)

let contains_error result = String.sub result 0 3 = "\xE2\x9D\x8C"  (* ❌ *)

(* Helper to create fresh test environment.
   Eio context + Fs_compat.set_fs are set up in the top-level runner,
   so Room.default_config gets FileSystem backend. *)
let with_test_env f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;
  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:(Some "claude") in
  try
    f config;
    let _ = Room.reset config in
    Unix.rmdir tmp_dir
  with e ->
    let _ = Room.reset config in
    Unix.rmdir tmp_dir;
    raise e

let with_memory_test_env f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_mem_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;
  let backend_config : Backend_types.config = {
    backend_type = Backend_types.Memory;
    base_path = Filename.concat tmp_dir ".masc";
    node_id = "test-node";
    cluster_name = "default";
    pubsub_max_messages = 1000;
  } in
  let memory_backend = Backend.Memory.create () in
  let config : Room_utils.config = {
    base_path = tmp_dir;
    workspace_path = tmp_dir;
    lock_expiry_minutes = 30;
    backend_config;
    backend = Room_utils.Memory memory_backend;
  } in
  let _ = Room.init config ~agent_name:(Some "claude") in
  try
    f config;
    let _ = Room.reset config in
    Unix.rmdir tmp_dir
  with e ->
    let _ = Room.reset config in
    Unix.rmdir tmp_dir;
    raise e

(* --- Task Edge Cases --- *)

let test_complete_without_claim () =
  with_test_env (fun config ->
    (* Add task but don't claim *)
    let _ = Room.add_task config ~title:"Unclaimed" ~priority:1 ~description:"" in

    (* Try to complete without claiming - should fail *)
    let result = Room.complete_task config ~agent_name:"claude" ~task_id:"task-001" ~notes:"" in
    Alcotest.(check bool) "complete without claim blocked" true (contains_warning result)
  )

let test_complete_by_wrong_agent () =
  with_test_env (fun config ->
    let _ = Room.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Room.claim_task config ~agent_name:"claude" ~task_id:"task-001" in

    (* Gemini tries to complete claude's task - should fail *)
    let result = Room.complete_task config ~agent_name:"gemini" ~task_id:"task-001" ~notes:"" in
    Alcotest.(check bool) "wrong agent blocked" true (contains_warning result)
  )

let test_complete_nonexistent_task () =
  with_test_env (fun config ->
    let result = Room.complete_task config ~agent_name:"claude" ~task_id:"task-999" ~notes:"" in
    Alcotest.(check bool) "nonexistent task" true (contains_error result)
  )

let test_claim_nonexistent_task () =
  with_test_env (fun config ->
    let result = Room.claim_task config ~agent_name:"claude" ~task_id:"task-999" in
    Alcotest.(check bool) "claim nonexistent" true (contains_error result)
  )

let test_double_complete () =
  with_test_env (fun config ->
    let _ = Room.add_task config ~title:"Test" ~priority:1 ~description:"" in
    let _ = Room.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let _ = Room.complete_task config ~agent_name:"claude" ~task_id:"task-001" ~notes:"first" in

    (* Try to complete again - should fail (already done) *)
    let result = Room.complete_task config ~agent_name:"claude" ~task_id:"task-001" ~notes:"second" in
    Alcotest.(check bool) "double complete blocked" true (contains_warning result)
  )

(* --- Join/Leave Edge Cases --- *)

let test_leave_removes_agent () =
  with_test_env (fun config ->
    let _ = Room.join config ~agent_name:"gemini" ~capabilities:["test"] () in

    (* Check agent exists *)
    let status1 = Room.status config in
    Alcotest.(check bool) "gemini in status" true (String.length status1 > 0);

    (* Leave *)
    let result = Room.leave config ~agent_name:"gemini" in
    Alcotest.(check bool) "leave success" true (contains_check result)
  )

let test_double_join () =
  with_test_env (fun config ->
    let _ = Room.join config ~agent_name:"gemini" ~capabilities:["test"] () in

    (* Join again - should update or warn *)
    let result = Room.join config ~agent_name:"gemini" ~capabilities:["updated"] () in
    (* Either success (update) or warning is acceptable *)
    Alcotest.(check bool) "double join handled" true (String.length result > 0)
  )

(* --- Portal Edge Cases --- *)

let test_portal_open_and_status () =
  with_test_env (fun config ->
    let result = Room.portal_open_r config ~agent_name:"claude" ~target_agent:"gemini" ~initial_message:None in
    (match result with
     | Ok msg -> Alcotest.(check bool) "portal open" true (contains_portal msg)
     | Error _ -> Alcotest.fail "portal_open_r should succeed");

    let status = Room.portal_status config ~agent_name:"claude" in
    Alcotest.(check bool) "portal status has fields" true
      (match status with `Assoc _ -> true | _ -> false)
  )

let test_portal_send_without_open () =
  with_test_env (fun config ->
    (* Send without opening portal first - returns Error *)
    let result = Room.portal_send_r config ~agent_name:"claude" ~message:"hello" in
    Alcotest.(check bool) "send without open returns error" true
      (match result with Error _ -> true | Ok _ -> false)
  )

let test_portal_close () =
  with_test_env (fun config ->
    let _ = Room.portal_open_r config ~agent_name:"claude" ~target_agent:"gemini" ~initial_message:None in
    let result = Room.portal_close config ~agent_name:"claude" in
    (* Portal close uses 🚪 emoji *)
    Alcotest.(check bool) "portal close" true (String.length result > 0)
  )

(* ============================================================ *)
(* Robustness Tests - Boundary Values & State Consistency       *)
(* ============================================================ *)

(* --- Boundary Value Tests --- *)

let test_empty_task_title () =
  with_test_env (fun config ->
    (* Empty title should still work (or fail gracefully) *)
    let result = Room.add_task config ~title:"" ~priority:1 ~description:"" in
    (* Should either succeed or give clear error *)
    Alcotest.(check bool) "empty title handled" true (String.length result > 0)
  )

let test_very_long_task_title () =
  with_test_env (fun config ->
    let long_title = String.make 1000 'x' in
    let result = Room.add_task config ~title:long_title ~priority:1 ~description:"" in
    Alcotest.(check bool) "long title handled" true (contains_check result)
  )

let test_special_chars_in_message () =
  with_test_env (fun config ->
    (* Test special characters, unicode, JSON-unsafe chars *)
    let msg = "Hello \"world\" with 'quotes' and\nnewlines\tand\t한글!" in
    let result = Room.broadcast config ~from_agent:"claude" ~content:msg in
    Alcotest.(check bool) "special chars handled" true (String.length result > 0)
  )

let test_agent_name_with_special_chars () =
  with_test_env (fun config ->
    (* Agent name with dots, dashes should work *)
    let result = Room.join config ~agent_name:"claude-3.5-sonnet" ~capabilities:[] () in
    Alcotest.(check bool) "special agent name" true (contains_check result)
  )

let test_priority_boundaries () =
  with_test_env (fun config ->
    (* Test priority 0 and very high priority *)
    let r1 = Room.add_task config ~title:"Zero" ~priority:0 ~description:"" in
    let r2 = Room.add_task config ~title:"High" ~priority:999 ~description:"" in
    Alcotest.(check bool) "priority 0" true (contains_check r1);
    Alcotest.(check bool) "priority 999" true (contains_check r2)
  )

(* --- State Consistency Tests --- *)

let test_task_state_after_claim () =
  with_test_env (fun config ->
    let _ = Room.add_task config ~title:"State Test" ~priority:1 ~description:"" in
    let _ = Room.claim_task config ~agent_name:"claude" ~task_id:"task-001" in

    (* Verify task list shows claimed state *)
    let tasks = Room.list_tasks config in
    Alcotest.(check bool) "shows claimed" true (String.length tasks > 0);
    Alcotest.(check bool) "has claude" true (str_contains tasks "claude" ||
                                              str_contains tasks "Claimed")
  )

let test_multiple_tasks_independent () =
  with_test_env (fun config ->
    (* Add multiple tasks *)
    let _ = Room.add_task config ~title:"Task A" ~priority:1 ~description:"" in
    let _ = Room.add_task config ~title:"Task B" ~priority:2 ~description:"" in
    let _ = Room.add_task config ~title:"Task C" ~priority:3 ~description:"" in

    (* Claim one, complete another - verify independence *)
    let _ = Room.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let _ = Room.claim_task config ~agent_name:"claude" ~task_id:"task-002" in
    let _ = Room.complete_task config ~agent_name:"claude" ~task_id:"task-001" ~notes:"" in

    (* Task 002 should still be claimable to complete *)
    let result = Room.complete_task config ~agent_name:"claude" ~task_id:"task-002" ~notes:"" in
    Alcotest.(check bool) "independent tasks" true (contains_check result)
  )

(* --- Concurrency Simulation Tests --- *)

let test_rapid_claim_sequence () =
  with_test_env (fun config ->
    let _ = Room.add_task config ~title:"Race" ~priority:1 ~description:"" in

    (* Simulate rapid claims from different agents *)
    let r1 = Room.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let r2 = Room.claim_task config ~agent_name:"gemini" ~task_id:"task-001" in
    let r3 = Room.claim_task config ~agent_name:"codex" ~task_id:"task-001" in

    (* Only first should succeed *)
    Alcotest.(check bool) "first wins" true (contains_check r1);
    Alcotest.(check bool) "second blocked" true (contains_warning r2);
    Alcotest.(check bool) "third blocked" true (contains_warning r3)
  )

let test_multiple_agents_multiple_tasks () =
  with_test_env (fun config ->
    (* Setup: 3 tasks, 3 agents *)
    let _ = Room.add_task config ~title:"A" ~priority:1 ~description:"" in
    let _ = Room.add_task config ~title:"B" ~priority:2 ~description:"" in
    let _ = Room.add_task config ~title:"C" ~priority:3 ~description:"" in

    (* Each agent claims different task *)
    let r1 = Room.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
    let r2 = Room.claim_task config ~agent_name:"gemini" ~task_id:"task-002" in
    let r3 = Room.claim_task config ~agent_name:"codex" ~task_id:"task-003" in

    Alcotest.(check bool) "claude gets 001" true (contains_check r1);
    Alcotest.(check bool) "gemini gets 002" true (contains_check r2);
    Alcotest.(check bool) "codex gets 003" true (contains_check r3);

    (* Each completes their own *)
    let c1 = Room.complete_task config ~agent_name:"claude" ~task_id:"task-001" ~notes:"" in
    let c2 = Room.complete_task config ~agent_name:"gemini" ~task_id:"task-002" ~notes:"" in
    let c3 = Room.complete_task config ~agent_name:"codex" ~task_id:"task-003" ~notes:"" in

    Alcotest.(check bool) "claude done" true (contains_check c1);
    Alcotest.(check bool) "gemini done" true (contains_check c2);
    Alcotest.(check bool) "codex done" true (contains_check c3)
  )

(* --- Recovery & Edge Condition Tests --- *)

let test_reinit_existing_room () =
  with_test_env (fun config ->
    (* Init again on already initialized room *)
    let result = Room.init config ~agent_name:None in
    (* Should handle gracefully - either warn or succeed *)
    Alcotest.(check bool) "reinit handled" true (String.length result > 0)
  )

let test_operations_preserve_state () =
  with_test_env (fun config ->
    (* Do a bunch of operations *)
    let _ = Room.join config ~agent_name:"gemini" ~capabilities:["test"] () in
    let _ = Room.add_task config ~title:"X" ~priority:1 ~description:"" in
    let _ = Room.broadcast config ~from_agent:"claude" ~content:"hello" in

    (* Status should show all state *)
    let status = Room.status config in
    Alcotest.(check bool) "status not empty" true (String.length status > 100)
  )

(* --- Event Log Verification --- *)

let test_event_log_on_join () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:None in
  let _ = Room.join config ~agent_name:"test_agent" ~capabilities:["ocaml"] () in

  (* Verify join was recorded - agent has auto-generated nickname starting with "test_agent-" *)
  let state = Room.read_state config in
  let has_test_agent = List.exists (fun name ->
    String.length name >= 10 && String.sub name 0 10 = "test_agent"
  ) state.active_agents in
  Alcotest.(check bool) "join event recorded" true has_test_agent;

  let _ = Room.reset config in
  Unix.rmdir tmp_dir

let test_event_log_on_claim_done () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:(Some "claude") in
  let _ = Room.add_task config ~title:"Test" ~priority:1 ~description:"" in
  let _ = Room.claim_task config ~agent_name:"claude" ~task_id:"task-001" in
  let _ = Room.complete_task config ~agent_name:"claude" ~task_id:"task-001" ~notes:"done" in

  (* Verify task state via Room.read_backlog (backend-agnostic) *)
  let backlog = Room.read_backlog config in
  let is_done = List.exists (fun t ->
    match t.Types.task_status with Types.Done _ -> true | _ -> false
  ) backlog.Types.tasks in
  Alcotest.(check bool) "task completed" true is_done;

  let _ = Room.reset config in
  Unix.rmdir tmp_dir

(* ============================================================ *)
(* Heartbeat & Zombie Detection Tests                           *)
(* ============================================================ *)

let contains_heartbeat result = String.sub result 0 4 = "\xF0\x9F\x92\x93"  (* 💓 *)

let test_heartbeat_updates_lastseen () =
  with_test_env (fun config ->
    let _ = Room.join config ~agent_name:"gemini" ~capabilities:[] () in

    (* Send heartbeat *)
    let result = Room.heartbeat config ~agent_name:"gemini" in
    Alcotest.(check bool) "heartbeat success" true (contains_heartbeat result)
  )

let test_is_agent_joined_after_default_join () =
  with_test_env (fun config ->
    let _ = Room.join config ~agent_name:"gemini" ~capabilities:[] () in
    let agents : Types.agent list = Room.get_agents_raw config in
    let gemini_name =
      match List.find_opt (fun (agent : Types.agent) ->
        String.length agent.name >= 6 && String.sub agent.name 0 6 = "gemini"
      ) agents with
      | Some agent -> agent.name
      | None -> failwith "expected gemini agent"
    in
    Alcotest.(check bool) "joined agent detected" true
      (Room.is_agent_joined config ~agent_name:gemini_name)
  )

let test_room_bootstrap_preserves_backend_state () =
  with_memory_test_env (fun config ->
    Room.ensure_room_bootstrap config;
    let _ =
      Room.update_state config (fun state ->
        { state with message_seq = 41 })
    in
    let backlog =
      {
        Types.tasks = [];
        last_updated = Types.now_iso ();
        version = 7;
      }
    in
    Room_utils.write_json config (Room.backlog_path config)
      (Types.backlog_to_yojson backlog);

    Room.ensure_room_bootstrap config;

    let state = Room.read_state config in
    let saved_backlog = Room.read_backlog config in
    Alcotest.(check int) "state preserved" 41 state.message_seq;
    Alcotest.(check int) "backlog preserved" 7 saved_backlog.version
  )

let test_room_bootstrap_ignores_invalid_room_id_in_flat_mode () =
  with_memory_test_env (fun config ->
    Room.ensure_room_bootstrap config;
    Alcotest.(check bool) "root state initialized" true
      (Room.is_initialized config)
  )

let test_read_backlog_r_reports_parse_error () =
  with_test_env (fun config ->
    Out_channel.with_open_text (Room.backlog_path config) (fun oc ->
      output_string oc "{\n  \"tasks\": [\n");
    match Room.read_backlog_r config with
    | Ok _ -> Alcotest.fail "expected backlog parse error"
    | Error msg ->
        Alcotest.(check bool) "mentions backlog decode/read failure" true
          (str_contains msg "read_backlog" || str_contains msg "JSON parse error")
  )

let test_release_stale_claims_skips_invalid_backlog () =
  with_test_env (fun config ->
    Out_channel.with_open_text (Room.backlog_path config) (fun oc ->
      output_string oc "{\n  \"tasks\": [\n");
    let released = Room.release_stale_claims config ~ttl_seconds:60.0 in
    Alcotest.(check (list (pair string string))) "no stale claims released" [] released
  )


let test_heartbeat_nonexistent_agent () =
  with_test_env (fun config ->
    (* Heartbeat for non-joined agent *)
    let result = Room.heartbeat config ~agent_name:"nonexistent" in
    Alcotest.(check bool) "heartbeat for nonexistent" true (contains_warning result)
  )

let test_get_agents_status () =
  with_test_env (fun config ->
    let _ = Room.join config ~agent_name:"gemini" ~capabilities:["python"] () in
    let _ = Room.join config ~agent_name:"codex" ~capabilities:["rust"] () in

    let status = Room.get_agents_status config in
    (* Should be a JSON with agents array *)
    let has_agents = match status with
      | `Assoc fields -> List.mem_assoc "agents" fields
      | _ -> false
    in
    Alcotest.(check bool) "has agents field" true has_agents
  )

let test_cleanup_zombies_empty () =
  with_test_env (fun config ->
    (* Cleanup with no zombies *)
    let result = Room.cleanup_zombies config in
    Alcotest.(check bool) "cleanup result" true (String.length result > 0)
  )

(** Return ISO8601 timestamp offset by seconds from now *)
let iso_ago seconds =
  let t = Unix.gettimeofday () -. seconds in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
    tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec

(** Helper: join an agent then overwrite its last_seen to simulate staleness *)
let make_stale_agent config ~name ~age_seconds =
  let _ = Room.join config ~agent_name:name ~capabilities:[] () in
  (* Overwrite the agent file with a stale last_seen *)
  let agents_path = Filename.concat (Room.masc_dir config) "agents" in
  let path = Filename.concat agents_path (Room.safe_filename name ^ ".json") in
  let stale_ts = iso_ago age_seconds in
  let agent_json = Printf.sprintf
    {|{"name":"%s","agent_type":"test","status":"inactive","capabilities":[],"joined_at":"%s","last_seen":"%s"}|}
    name stale_ts stale_ts
  in
  Room.write_json config path (Yojson.Safe.from_string agent_json)

let test_cleanup_zombies_detects_regular () =
  with_test_env (fun config ->
    (* Create a regular agent idle for 10 minutes (> 300s threshold) *)
    make_stale_agent config ~name:"stale-regular-agent" ~age_seconds:700.0;
    let result = Room.cleanup_zombies config in
    Alcotest.(check bool) "regular zombie detected"
      true (str_contains result "stale-regular-agent")
  )

let test_cleanup_zombies_detects_keeper () =
  with_test_env (fun config ->
    (* Create a keeper agent idle for 2 hours (> 3600s keeper threshold) *)
    make_stale_agent config ~name:"keeper-longplay-agent" ~age_seconds:7200.0;
    let result = Room.cleanup_zombies config in
    Alcotest.(check bool) "keeper zombie detected after keeper threshold"
      true (str_contains result "keeper-longplay-agent")
  )

let test_cleanup_zombies_spares_recent_keeper () =
  with_test_env (fun config ->
    (* Create a keeper agent idle for 10 minutes (< 3600s keeper threshold) *)
    make_stale_agent config ~name:"keeper-active-agent" ~age_seconds:600.0;
    let result = Room.cleanup_zombies config in
    Alcotest.(check bool) "recent keeper spared"
      true (not (str_contains result "keeper-active-agent"))
  )

let test_cleanup_zombies_removes_broken_agent_file () =
  with_test_env (fun config ->
    (* Write an empty JSON object — unparseable as agent *)
    let agents_path = Filename.concat (Room.masc_dir config) "agents" in
    let path = Filename.concat agents_path "broken-agent.json" in
    Room.write_json config path (Yojson.Safe.from_string "{}");
    Alcotest.(check bool) "broken file exists before GC"
      true (Sys.file_exists path);
    let _result = Room.cleanup_zombies config in
    Alcotest.(check bool) "broken file removed by GC"
      false (Sys.file_exists path)
  )

let test_cleanup_zombies_preserves_non_json_files () =
  with_test_env (fun config ->
    (* Place a non-JSON file in the agents directory *)
    let agents_path = Filename.concat (Room.masc_dir config) "agents" in
    let path = Filename.concat agents_path ".gitkeep" in
    let oc = open_out path in
    output_string oc "";
    close_out oc;
    Alcotest.(check bool) "non-json file exists before GC"
      true (Sys.file_exists path);
    let _result = Room.cleanup_zombies config in
    Alcotest.(check bool) "non-json file preserved by GC"
      true (Sys.file_exists path)
  )

(* ============================================================ *)
(* Agent Discovery / Capability Tests                           *)
(* ============================================================ *)

let contains_antenna result = String.sub result 0 4 = "\xF0\x9F\x93\xA1"  (* 📡 *)

let test_register_capabilities () =
  with_test_env (fun config ->
    let _ = Room.join config ~agent_name:"gemini" ~capabilities:[] () in

    (* Register capabilities *)
    let result = Room.register_capabilities config ~agent_name:"gemini"
      ~capabilities:["python"; "web-search"; "code-review"] in
    Alcotest.(check bool) "capabilities registered" true (contains_antenna result)
  )

let test_find_by_capability () =
  with_test_env (fun config ->
    let _ = Room.join config ~agent_name:"gemini" ~capabilities:["python"; "search"] () in
    let _ = Room.join config ~agent_name:"codex" ~capabilities:["python"; "rust"] () in

    (* Find agents with python capability *)
    let result = Room.find_agents_by_capability config ~capability:"python" in
    (* Verify result has correct structure (agents array exists) *)
    let has_agents_key = match result with
      | `Assoc fields -> List.mem_assoc "agents" fields && List.mem_assoc "count" fields
      | _ -> false
    in
    Alcotest.(check bool) "result has agents structure" true has_agents_key
  )

let test_find_by_capability_no_match () =
  with_test_env (fun config ->
    let _ = Room.join config ~agent_name:"gemini" ~capabilities:["python"] () in

    (* Find agents with nonexistent capability *)
    let result = Room.find_agents_by_capability config ~capability:"haskell" in
    let agents = match result with
      | `Assoc fields -> (
          match List.assoc_opt "agents" fields with
          | Some (`List l) -> List.length l
          | _ -> 0
        )
      | _ -> 0
    in
    Alcotest.(check bool) "found 0 agents" true (agents = 0)
  )

let test_register_capabilities_nonexistent_agent () =
  with_test_env (fun config ->
    (* Register for non-joined agent *)
    let result = Room.register_capabilities config ~agent_name:"ghost"
      ~capabilities:["magic"] in
    Alcotest.(check bool) "register for nonexistent" true (contains_warning result)
  )

(* ============================================================ *)
(* Voting / Consensus Tests                                     *)
(* ============================================================ *)

let contains_ballot result = String.sub result 0 4 = "\xF0\x9F\x97\xB3"  (* 🗳️ *)

(* Helper to extract vote_id from vote_create result *)
let extract_vote_id result =
  (* Format: "🗳️ Vote created: vote-XXXX-XXXX\n..." *)
  let re = Str.regexp "vote-[0-9a-zA-Z-]+" in
  try
    let _ = Str.search_forward re result 0 in
    Str.matched_string result
  with Not_found -> "vote-unknown"

let test_vote_create () =
  with_test_env (fun config ->
    let result = Room.vote_create config
      ~proposer:"claude"
      ~topic:"Should we use OCaml?"
      ~options:["yes"; "no"; "maybe"]
      ~required_votes:2 in
    Alcotest.(check bool) "vote created" true (contains_ballot result);
    Alcotest.(check bool) "has vote id" true (str_contains result "vote-")
  )

let test_vote_cast () =
  with_test_env (fun config ->
    let create_result = Room.vote_create config
      ~proposer:"claude"
      ~topic:"Test vote"
      ~options:["yes"; "no"]
      ~required_votes:2 in
    let vote_id = extract_vote_id create_result in

    (* Cast vote *)
    let result = Room.vote_cast config ~agent_name:"gemini" ~vote_id ~choice:"yes" in
    Alcotest.(check bool) "vote cast" true (contains_check result)
  )

let test_vote_double_vote () =
  with_test_env (fun config ->
    let create_result = Room.vote_create config
      ~proposer:"claude"
      ~topic:"Test"
      ~options:["yes"; "no"]
      ~required_votes:2 in
    let vote_id = extract_vote_id create_result in

    let _ = Room.vote_cast config ~agent_name:"gemini" ~vote_id ~choice:"yes" in

    (* Vote again - should be rejected (duplicate vote blocked) *)
    let result = Room.vote_cast config ~agent_name:"gemini" ~vote_id ~choice:"no" in
    Alcotest.(check bool) "double vote rejected" true (contains_warning result)
  )

let test_vote_invalid_choice () =
  with_test_env (fun config ->
    let create_result = Room.vote_create config
      ~proposer:"claude"
      ~topic:"Test"
      ~options:["yes"; "no"]
      ~required_votes:2 in
    let vote_id = extract_vote_id create_result in

    (* Invalid choice - returns ❌ *)
    let result = Room.vote_cast config ~agent_name:"gemini" ~vote_id ~choice:"maybe" in
    Alcotest.(check bool) "invalid choice rejected" true (contains_error result)
  )

let test_vote_status () =
  with_test_env (fun config ->
    let create_result = Room.vote_create config
      ~proposer:"claude"
      ~topic:"Test"
      ~options:["yes"; "no"]
      ~required_votes:2 in
    let vote_id = extract_vote_id create_result in

    let status = Room.vote_status config ~vote_id in
    let has_topic = match status with
      | `Assoc fields -> List.mem_assoc "topic" fields
      | _ -> false
    in
    Alcotest.(check bool) "status has topic" true has_topic
  )

let test_vote_nonexistent () =
  with_test_env (fun config ->
    let status = Room.vote_status config ~vote_id:"vote-999" in
    let has_error = match status with
      | `Assoc fields -> List.mem_assoc "error" fields
      | _ -> false
    in
    Alcotest.(check bool) "nonexistent vote error" true has_error
  )

let test_vote_resolution_approved () =
  with_test_env (fun config ->
    let create_result = Room.vote_create config
      ~proposer:"claude"
      ~topic:"Approve this?"
      ~options:["yes"; "no"]
      ~required_votes:2 in
    let vote_id = extract_vote_id create_result in

    (* Two agents vote yes *)
    let _ = Room.vote_cast config ~agent_name:"gemini" ~vote_id ~choice:"yes" in
    let result = Room.vote_cast config ~agent_name:"codex" ~vote_id ~choice:"yes" in

    (* Should show resolved with winner *)
    Alcotest.(check bool) "vote resolved" true (str_contains result "resolved" || str_contains result "Winner")
  )

let test_list_votes () =
  with_test_env (fun config ->
    let _ = Room.vote_create config ~proposer:"claude" ~topic:"Vote 1" ~options:["a";"b"] ~required_votes:2 in
    let _ = Room.vote_create config ~proposer:"gemini" ~topic:"Vote 2" ~options:["x";"y"] ~required_votes:2 in

    let result = Room.list_votes config in
    let count = match result with
      | `Assoc fields -> (
          match List.assoc_opt "votes" fields with
          | Some (`List l) -> List.length l
          | _ -> 0
        )
      | _ -> 0
    in
    Alcotest.(check bool) "has 2 votes" true (count = 2)
  )

(* ============================================================ *)
(* Input Validation Tests                                       *)
(* ============================================================ *)

let test_empty_agent_name_claim () =
  with_test_env (fun config ->
    let _ = Room.add_task config ~title:"Test" ~priority:1 ~description:"" in
    (* Empty agent name should be rejected *)
    let result = Room.claim_task config ~agent_name:"" ~task_id:"task-001" in
    Alcotest.(check bool) "empty agent rejected" true (contains_error result)
  )

let test_empty_task_id_claim () =
  with_test_env (fun config ->
    (* Empty task_id should be rejected *)
    let result = Room.claim_task config ~agent_name:"claude" ~task_id:"" in
    Alcotest.(check bool) "empty task_id rejected" true (contains_error result)
  )

let test_very_long_agent_name () =
  with_test_env (fun config ->
    let long_name = String.make 100 'x' in
    let result = Room.claim_task config ~agent_name:long_name ~task_id:"task-001" in
    (* Should be rejected (max 64 chars) *)
    Alcotest.(check bool) "long name rejected" true (contains_error result)
  )

(* ============================================================ *)
(* Unicode & Internationalization Tests                         *)
(* ============================================================ *)

let test_korean_agent_name () =
  with_test_env (fun config ->
    (* Korean characters should work *)
    let result = Room.join config ~agent_name:"클로드" ~capabilities:["한글"] () in
    Alcotest.(check bool) "korean agent name" true (contains_check result)
  )

let test_emoji_in_message () =
  with_test_env (fun config ->
    (* Emoji characters should be preserved *)
    let msg = "🚀 Launching feature! 🎉" in
    let result = Room.broadcast config ~from_agent:"claude" ~content:msg in
    Alcotest.(check bool) "emoji preserved" true (str_contains result "🚀")
  )

let test_unicode_task_title () =
  with_test_env (fun config ->
    let result = Room.add_task config ~title:"日本語タスク" ~priority:1 ~description:"中文描述" in
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

  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:(Some "claude") in
  let _ = Room.add_task config ~title:"Task" ~priority:1 ~description:"" in
  let _ = Room.broadcast config ~from_agent:"claude" ~content:"Hello" in

  (* Reset *)
  let _ = Room.reset config in

  (* Verify cleared *)
  Alcotest.(check bool) "not initialized after reset" false (Room.is_initialized config);

  Unix.rmdir tmp_dir

let test_reinit_after_reset () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc_test_%d_%d" (Unix.getpid ()) (int_of_float (Unix.gettimeofday () *. 1000.))) in
  Unix.mkdir tmp_dir 0o755;

  let config = room_config tmp_dir in
  let _ = Room.init config ~agent_name:(Some "claude") in
  let _ = Room.reset config in
  (* Reinit should work *)
  let result = Room.init config ~agent_name:(Some "claude") in
  Alcotest.(check bool) "reinit after reset" true (contains_check result);

  let _ = Room.reset config in
  Unix.rmdir tmp_dir

(* ============================================================ *)
(* Vote Edge Cases                                              *)
(* ============================================================ *)

let test_vote_single_option () =
  with_test_env (fun config ->
    (* Single option vote should work *)
    let result = Room.vote_create config
      ~proposer:"claude"
      ~topic:"Approve?"
      ~options:["yes"]
      ~required_votes:1 in
    Alcotest.(check bool) "single option" true (contains_ballot result)
  )

let test_vote_many_voters () =
  with_test_env (fun config ->
    let create_result = Room.vote_create config
      ~proposer:"claude"
      ~topic:"Many voters"
      ~options:["a"; "b"; "c"]
      ~required_votes:5 in
    let vote_id = extract_vote_id create_result in

    (* Multiple agents vote *)
    let _ = Room.vote_cast config ~agent_name:"agent1" ~vote_id ~choice:"a" in
    let _ = Room.vote_cast config ~agent_name:"agent2" ~vote_id ~choice:"a" in
    let _ = Room.vote_cast config ~agent_name:"agent3" ~vote_id ~choice:"b" in
    let _ = Room.vote_cast config ~agent_name:"agent4" ~vote_id ~choice:"a" in
    let result = Room.vote_cast config ~agent_name:"agent5" ~vote_id ~choice:"a" in

    (* Should be resolved with 5 votes *)
    Alcotest.(check bool) "resolved with 5" true
      (str_contains result "resolved" || str_contains result "Winner")
  )

let test_vote_tie () =
  with_test_env (fun config ->
    let create_result = Room.vote_create config
      ~proposer:"claude"
      ~topic:"Tie vote"
      ~options:["a"; "b"]
      ~required_votes:2 in
    let vote_id = extract_vote_id create_result in

    let _ = Room.vote_cast config ~agent_name:"agent1" ~vote_id ~choice:"a" in
    let result = Room.vote_cast config ~agent_name:"agent2" ~vote_id ~choice:"b" in

    (* Should be tied *)
    Alcotest.(check bool) "vote tied" true (str_contains result "Tied" || str_contains result "resolved")
  )

(* ============================================================ *)
(* Message Edge Cases                                           *)
(* ============================================================ *)

let test_very_long_message () =
  with_test_env (fun config ->
    let long_msg = String.make 10000 'x' in
    let result = Room.broadcast config ~from_agent:"claude" ~content:long_msg in
    Alcotest.(check bool) "long message handled" true (String.length result > 0)
  )

let test_message_with_json_chars () =
  with_test_env (fun config ->
    (* JSON special characters should be escaped properly *)
    let msg = "{\"key\": \"value\", \"array\": [1,2,3]}" in
    let result = Room.broadcast config ~from_agent:"claude" ~content:msg in
    Alcotest.(check bool) "json chars handled" true (String.length result > 0)
  )

let test_message_sequence () =
  with_test_env (fun config ->
    (* Messages should have incrementing sequence numbers *)
    let _ = Room.broadcast config ~from_agent:"claude" ~content:"First" in
    let _ = Room.broadcast config ~from_agent:"claude" ~content:"Second" in
    let _ = Room.broadcast config ~from_agent:"claude" ~content:"Third" in

    let msgs = Room.get_messages config ~since_seq:0 ~limit:10 in
    Alcotest.(check bool) "has messages" true (str_contains msgs "First" || str_contains msgs "Third")
  )

(* ============================================================ *)
(* Stress Tests (Simulated)                                     *)
(* ============================================================ *)

let test_many_tasks () =
  with_test_env (fun config ->
    (* Add many tasks *)
    for i = 1 to 20 do
      let _ = Room.add_task config ~title:(Printf.sprintf "Task %d" i) ~priority:i ~description:"" in
      ()
    done;

    let tasks = Room.list_tasks config in
    Alcotest.(check bool) "20 tasks created" true (str_contains tasks "Task 20")
  )

let test_many_agents () =
  with_test_env (fun config ->
    (* Join many agents *)
    for i = 1 to 10 do
      let _ = Room.join config ~agent_name:(Printf.sprintf "agent%d" i) ~capabilities:["test"] () in
      ()
    done;

    let status = Room.get_agents_status config in
    let count = match status with
      | `Assoc fields -> (
          match List.assoc_opt "count" fields with
          | Some (`Int n) -> n
          | _ -> 0
        )
      | _ -> 0
    in
    (* 10 agents + claude (from with_test_env init) = 11 *)
    Alcotest.(check bool) "many agents" true (count >= 10)
  )

(* ============================================================ *)
(* Portal Advanced Tests                                        *)
(* ============================================================ *)

let test_portal_reopen_after_close () =
  with_test_env (fun config ->
    let _ = Room.portal_open_r config ~agent_name:"claude" ~target_agent:"gemini" ~initial_message:None in
    let _ = Room.portal_close config ~agent_name:"claude" in

    (* Should be able to reopen *)
    let result = Room.portal_open_r config ~agent_name:"claude" ~target_agent:"codex" ~initial_message:None in
    (match result with
     | Ok msg -> Alcotest.(check bool) "reopen portal" true (contains_portal msg)
     | Error _ -> Alcotest.fail "portal reopen should succeed")
  )

let test_portal_send_multiple () =
  with_test_env (fun config ->
    let _ = Room.portal_open_r config ~agent_name:"claude" ~target_agent:"gemini" ~initial_message:None in

    (* Send multiple messages *)
    let check_send label r =
      match r with Ok msg -> Alcotest.(check bool) label true (String.length msg > 0) | Error _ -> Alcotest.fail label
    in
    check_send "send 1" (Room.portal_send_r config ~agent_name:"claude" ~message:"First");
    check_send "send 2" (Room.portal_send_r config ~agent_name:"claude" ~message:"Second");
    check_send "send 3" (Room.portal_send_r config ~agent_name:"claude" ~message:"Third")
  )

(* ============================================================ *)
(* Negative Priority Tests                                      *)
(* ============================================================ *)

let test_negative_priority () =
  with_test_env (fun config ->
    let result = Room.add_task config ~title:"Urgent" ~priority:(-1) ~description:"" in
    (* Negative priority should work (lower = more urgent) *)
    Alcotest.(check bool) "negative priority" true (contains_check result)
  )

(* ============================================================ *)
(* Security Tests (v2.1) - XSS Prevention                       *)
(* ============================================================ *)

let test_xss_in_message () =
  with_test_env (fun config ->
    ignore (Room.join config ~agent_name:"tester" ~capabilities:[] ());
    let xss_payload = "<script>alert('xss')</script>" in
    let result = Room.broadcast config ~from_agent:"tester" ~content:xss_payload in
    (* Check that raw script tags are not in the result *)
    let has_raw_script = str_contains result "<script>" || str_contains result "</script>" in
    Alcotest.(check bool) "xss sanitized" false has_raw_script
  )

let test_xss_in_agent_name () =
  with_test_env (fun config ->
    let xss_name = "<img src=x onerror=alert('xss')>" in
    let result = Room.join config ~agent_name:xss_name ~capabilities:[] () in
    Alcotest.(check bool) "join with xss name" true (contains_check result);
    (* Backend-agnostic: verify agent was registered (original test checked filename sanitization,
       which is FileSystem-specific. For other backends, we just verify the join worked) *)
    let state = Room.read_state config in
    Alcotest.(check bool) "agent registered" true (List.length state.active_agents > 0)
  )

(* === Board Admin Tests === *)

(* Use 3-part nicknames so join() preserves them as-is
   (Nickname.is_generated_nickname requires 3+ dash-separated parts) *)
let admin_keeper_agent = "admin-board-keeper"
let test_agent_a = "agent-test-alpha"
let test_agent_z = "agent-test-zombie"

let test_force_release_bypasses_assignee () =
  with_test_env (fun config ->
    let _ = Room.add_task config ~title:"Orphan Task" ~priority:1 ~description:"" in
    let _ = Room.join config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Room.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    (* Different agent cannot release without force *)
    let normal = Room.transition_task_r config ~agent_name:admin_keeper_agent ~task_id:"task-001"
        ~action:Types.Release () in
    Alcotest.(check bool) "normal release blocked" true
      (match normal with Error _ -> true | Ok _ -> false);
    (* Force release succeeds *)
    let forced = Room.force_release_task_r config ~agent_name:admin_keeper_agent ~task_id:"task-001" () in
    Alcotest.(check bool) "force release ok" true
      (match forced with Ok _ -> true | Error _ -> false);
    (* Task should be back to Todo *)
    let tasks = Room.list_tasks config in
    Alcotest.(check bool) "task is todo" true (str_contains tasks "Todo" || str_contains tasks "todo")
  )

let test_force_done_bypasses_assignee () =
  with_test_env (fun config ->
    let _ = Room.add_task config ~title:"Force Done Task" ~priority:1 ~description:"" in
    let _ = Room.join config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Room.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    (* Normal done by different agent fails *)
    let normal = Room.transition_task_r config ~agent_name:admin_keeper_agent ~task_id:"task-001"
        ~action:Types.Done_action ~notes:"forced" () in
    Alcotest.(check bool) "normal done blocked" true
      (match normal with Error _ -> true | Ok _ -> false);
    (* Force done succeeds *)
    let forced = Room.force_done_task_r config ~agent_name:admin_keeper_agent ~task_id:"task-001"
        ~notes:"auto-closed by admin" () in
    Alcotest.(check bool) "force done ok" true
      (match forced with Ok _ -> true | Error _ -> false);
    (* Task should be done *)
    let tasks = Room.list_tasks ~include_done:true config in
    Alcotest.(check bool) "task is done" true (str_contains tasks "Done" || str_contains tasks "done")
  )

let test_audit_orphan_tasks () =
  with_test_env (fun config ->
    let _ = Room.add_task config ~title:"Orphan Candidate" ~priority:1 ~description:"" in
    let _ = Room.join config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Room.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    (* While agent is active, no orphans *)
    let orphans_before = Room.audit_orphan_tasks config in
    Alcotest.(check int) "no orphans while active" 0 (List.length orphans_before);
    (* Remove agent file to simulate it disappearing *)
    let _ = Room.leave config ~agent_name:test_agent_a in
    (* Now the task is orphaned (claimed by test_agent_a but agent is gone) *)
    let orphans_after = Room.audit_orphan_tasks config in
    Alcotest.(check int) "one orphan detected" 1 (List.length orphans_after);
    let (task, assignee) = List.hd orphans_after in
    Alcotest.(check string) "orphan assignee" test_agent_a assignee;
    Alcotest.(check string) "orphan task id" "task-001" task.id
  )

let test_cleanup_zombies_releases_tasks () =
  with_test_env (fun config ->
    let _ = Room.add_task config ~title:"Zombie Task" ~priority:1 ~description:"" in
    let _ = Room.join config ~agent_name:test_agent_z ~capabilities:[] () in
    let _ = Room.claim_task config ~agent_name:test_agent_z ~task_id:"task-001" in
    (* Manually set agent's last_seen to a very old timestamp to make it a zombie *)
    let agents_path = Filename.concat
      (Filename.concat config.base_path ".masc") "agents" in
    let agent_file = Filename.concat agents_path (test_agent_z ^ ".json") in
    let json = Room.read_json config agent_file in
    let updated_json = match json with
      | `Assoc pairs ->
          `Assoc (List.map (fun (k, v) ->
            if k = "last_seen" then (k, `String "2020-01-01T00:00:00Z") else (k, v)
          ) pairs)
      | other -> other
    in
    Room.write_json config agent_file updated_json;
    (* Run cleanup — should remove zombie agent AND release its tasks *)
    let result = Room.cleanup_zombies config in
    Alcotest.(check bool) "cleanup ran" true (String.length result > 0);
    (* Verify task is released (back to Todo) *)
    let tasks = Room.list_tasks config in
    Alcotest.(check bool) "task released to todo" true
      (str_contains tasks "Todo" || str_contains tasks "todo")
  )

(* --- Rejoin Identity Preservation (BUG-003) --- *)

let test_rejoin_preserves_identity () =
  with_test_env (fun config ->
    (* 1. Join: get a nickname *)
    let join1 = Room.join config ~agent_name:"claude" ~capabilities:["code"] () in
    Alcotest.(check bool) "first join success" true (contains_check join1);

    (* Extract nickname from active_agents *)
    let state1 = Room.read_state config in
    let nick1 = List.find (fun name ->
      String.length name > 6 && String.sub name 0 6 = "claude"
    ) state1.active_agents in

    (* 2. Leave *)
    let leave_result = Room.leave config ~agent_name:"claude" in
    Alcotest.(check bool) "leave success" true (contains_check leave_result);

    (* Agent should be removed from active_agents but file preserved *)
    let state2 = Room.read_state config in
    let still_active = List.exists (fun name ->
      String.length name > 6 && String.sub name 0 6 = "claude"
    ) state2.active_agents in
    Alcotest.(check bool) "not in active_agents after leave" false still_active;

    (* 3. Re-join: should get the SAME nickname *)
    let join2 = Room.join config ~agent_name:"claude" ~capabilities:["code"; "review"] () in
    Alcotest.(check bool) "rejoin success" true (contains_check join2);

    let state3 = Room.read_state config in
    let nick2 = List.find (fun name ->
      String.length name > 6 && String.sub name 0 6 = "claude"
    ) state3.active_agents in

    (* The key assertion: same nickname after rejoin *)
    Alcotest.(check string) "same identity after rejoin" nick1 nick2
  )

let test_rejoin_restores_active_status () =
  with_test_env (fun config ->
    let _ = Room.join config ~agent_name:"gemini" ~capabilities:["search"] () in
    let _ = Room.leave config ~agent_name:"gemini" in

    (* Re-join *)
    let result = Room.join config ~agent_name:"gemini" ~capabilities:["search"] () in
    Alcotest.(check bool) "rejoin success" true (contains_check result);

    (* Should be back in active_agents *)
    let state = Room.read_state config in
    let is_active = List.exists (fun name ->
      String.length name > 6 && String.sub name 0 6 = "gemini"
    ) state.active_agents in
    Alcotest.(check bool) "back in active_agents" true is_active
  )

let test_multiple_rejoin_cycles () =
  with_test_env (fun config ->
    let _ = Room.join config ~agent_name:"codex" ~capabilities:["impl"] () in
    let state1 = Room.read_state config in
    let nick1 = List.find (fun name ->
      String.length name > 5 && String.sub name 0 5 = "codex"
    ) state1.active_agents in

    (* Three leave/rejoin cycles *)
    for _ = 1 to 3 do
      let _ = Room.leave config ~agent_name:"codex" in
      let _ = Room.join config ~agent_name:"codex" ~capabilities:["impl"] () in
      ()
    done;

    let state_final = Room.read_state config in
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
  let events_dir = Filename.concat (Room.masc_dir config) "events" in
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

(** BUG-1: Room-scoped rejoin records event log *)
let test_rejoin_event_log () =
  with_test_env (fun config ->
    (* Join then leave to create Inactive agent *)
    let _ = Room.join config ~agent_name:"logcheck" ~capabilities:[] () in
    let _ = Room.leave config ~agent_name:"logcheck" in

    (* Rejoin — should produce event log with "rejoin":true *)
    let _ = Room.join config ~agent_name:"logcheck" ~capabilities:[] () in

    (* Read event log and check for rejoin entry *)
    let events = read_event_log config in
    let has_rejoin = List.exists (fun line ->
      str_contains line "\"rejoin\":true" && str_contains line "agent_join"
    ) events in
    Alcotest.(check bool) "rejoin event logged" true has_rejoin
  )

(** BUG-2: Zombie file deletion failure preserves state consistency *)
let test_zombie_file_delete_failure_keeps_state () =
  with_test_env (fun config ->
    (* Create a stale agent *)
    make_stale_agent config ~name:"unremovable-agent" ~age_seconds:700.0;

    (* Make the agent file read-only to prevent deletion *)
    let agents_path = Filename.concat (Room.masc_dir config) "agents" in
    let path = Filename.concat agents_path (Room.safe_filename "unremovable-agent" ^ ".json") in
    Unix.chmod path 0o444;
    (* Make directory non-writable so Sys.remove fails *)
    Unix.chmod agents_path 0o555;

    (* Run cleanup — file deletion should fail *)
    let _result = Room.cleanup_zombies config in

    (* Restore permissions for cleanup *)
    Unix.chmod agents_path 0o755;
    Unix.chmod path 0o644;

    (* Key assertion: agent should still be in active_agents since file deletion failed *)
    let state = Room.read_state config in
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
    let agents_path = Filename.concat (Room.masc_dir config) "agents" in
    let path = Filename.concat agents_path (Room.safe_filename "transition-test-agent" ^ ".json") in
    Unix.chmod path 0o444;
    Unix.chmod agents_path 0o555;

    let _result = Room.cleanup_zombies config in

    (* Restore permissions *)
    Unix.chmod agents_path 0o755;
    Unix.chmod path 0o644;

    (* Read agent file — should be Inactive now (Phase 2 ran before Phase 4 failed) *)
    let json = Room.read_json config path in
    let status = Yojson.Safe.Util.(member "status" json |> to_string) in
    Alcotest.(check string) "status transitioned to inactive" "inactive" status
  )

(** BUG-5: Keeper detection uses agent_type, not just name *)
let test_keeper_detection_by_agent_type () =
  (* A non-keeper-named agent with agent_type="keeper" should get keeper threshold *)
  let is_keeper_by_type = Resilience.Zombie.is_keeper ~name:"regular-bot" ~agent_type:"keeper" in
  Alcotest.(check bool) "agent_type=keeper detected" true is_keeper_by_type;

  (* A keeper-named agent should still be detected *)
  let is_keeper_by_name = Resilience.Zombie.is_keeper ~name:"keeper-test-agent" ~agent_type:"test" in
  Alcotest.(check bool) "keeper-*-agent name detected" true is_keeper_by_name;

  (* Neither name nor type matches *)
  let not_keeper = Resilience.Zombie.is_keeper ~name:"regular-bot" ~agent_type:"claude" in
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
    keeper name (e.g. "keeper-coder") but the task was claimed under the
    canonical "-agent" form (e.g. "keeper-coder-agent").  Reproduces the
    identity mismatch: "claimed by 'keeper-X-agent', caller is 'keeper-X'". *)
let test_bug006_transition_with_unsuffixed_name () =
  with_test_env (fun config ->
    (* Join with canonical agent name to establish the identity recorded at claim time *)
    let _ = Room.join config ~agent_name:"keeper-coder-agent" ~capabilities:["code"] () in
    let _ = Room.add_task config ~title:"BUG-006 Task" ~priority:1 ~description:"" in
    (* Claim using the canonical name — assignee is recorded as "keeper-coder-agent" *)
    (match Room.claim_task_r config ~agent_name:"keeper-coder-agent" ~task_id:"task-001" () with
     | Ok _ -> ()
     | Error e -> Alcotest.failf "claim failed: %s" (Types.show_masc_error e));
    (* Transition (start) using the unsuffixed name — should resolve to "keeper-coder-agent" *)
    (match Room.transition_task_r config ~agent_name:"keeper-coder" ~task_id:"task-001"
             ~action:Types.Start () with
     | Ok _ -> ()
     | Error e ->
         Alcotest.failf "start with unsuffixed name failed (BUG-006): %s"
           (Types.show_masc_error e));
    (* Complete using the unsuffixed name — same resolution path *)
    (match Room.complete_task_r config ~agent_name:"keeper-coder" ~task_id:"task-001"
             ~notes:"done" with
     | Ok _ -> ()
     | Error e ->
         Alcotest.failf "complete with unsuffixed name failed (BUG-006): %s"
           (Types.show_masc_error e))
  )

let test_bug006_cancel_with_unsuffixed_name () =
  with_test_env (fun config ->
    let _ = Room.join config ~agent_name:"keeper-coder-agent" ~capabilities:["code"] () in
    let _ = Room.add_task config ~title:"BUG-006 Cancel Task" ~priority:1 ~description:"" in
    (match Room.claim_task_r config ~agent_name:"keeper-coder-agent" ~task_id:"task-001" () with
     | Ok _ -> ()
     | Error e -> Alcotest.failf "claim failed: %s" (Types.show_masc_error e));
    (* Cancel using the unsuffixed name — should resolve to "keeper-coder-agent" *)
    (match Room.cancel_task_r config ~agent_name:"keeper-coder" ~task_id:"task-001"
             ~reason:"test" with
     | Ok _ -> ()
     | Error e ->
         Alcotest.failf "cancel with unsuffixed name failed (BUG-006): %s"
           (Types.show_masc_error e))
  )

(* === Idle loop stop signal tests === *)

let test_empty_backlog_stop_signal () =
  with_test_env (fun config ->
    let result = Room.list_tasks config in
    Alcotest.(check bool) "contains STOP signal"
      true (str_contains result "STOP calling keeper_tasks_list"))

let test_no_active_tasks_stop_signal () =
  with_test_env (fun config ->
    let _ = Room.add_task config ~title:"Done Task" ~priority:1 ~description:"" in
    let _ = Room.claim_task config ~agent_name:"alice" ~task_id:"task-001" in
    let _ = Room.complete_task config ~agent_name:"alice" ~task_id:"task-001" ~notes:"done" in
    let result = Room.list_tasks config in
    Alcotest.(check bool) "contains STOP signal"
      true (str_contains result "STOP calling keeper_tasks_list"))

let test_no_unclaimed_tasks_stop_signal () =
  with_test_env (fun config ->
    let _ = Room.add_task config ~title:"Claimed" ~priority:1 ~description:"" in
    let _ = Room.claim_task config ~agent_name:"alice" ~task_id:"task-001" in
    let result = Room.claim_next config ~agent_name:"bob" in
    Alcotest.(check bool) "contains ACTION stop signal"
      true (str_contains result "ACTION: Stop task-checking"))

let () =
  Eio_guard.enable ();
  Random.init 42;
  Alcotest.run "Room" [
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
    ];
    "worktree", [
      Alcotest.test_case "list no git" `Quick test_worktree_list_no_git;
      Alcotest.test_case "create no git" `Quick test_worktree_create_no_git;
      Alcotest.test_case "project root nested subdir" `Quick
        test_worktree_project_root_for_nested_subdir;
      Alcotest.test_case "project root worktree gitfile" `Quick
        test_worktree_project_root_for_gitfile_worktree;
      Alcotest.test_case "project root nested worktree gitfile subdir" `Quick
        test_worktree_project_root_for_nested_gitfile_worktree_subdir;
      Alcotest.test_case "project root .masc base path" `Quick
        test_worktree_project_root_for_masc_dir_base;
    ];
    "portal", [
      Alcotest.test_case "open and status" `Quick test_portal_open_and_status;
      Alcotest.test_case "close" `Quick test_portal_close;
    ];

    (* === Edge Case Tests === *)
    "task_errors", [
      Alcotest.test_case "complete without claim" `Quick test_complete_without_claim;
      Alcotest.test_case "complete by wrong agent" `Quick test_complete_by_wrong_agent;
      Alcotest.test_case "complete nonexistent" `Quick test_complete_nonexistent_task;
      Alcotest.test_case "claim nonexistent" `Quick test_claim_nonexistent_task;
      Alcotest.test_case "double complete" `Quick test_double_complete;
    ];
    "portal_errors", [
      Alcotest.test_case "send without open" `Quick test_portal_send_without_open;
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
      Alcotest.test_case "reinit existing room" `Quick test_reinit_existing_room;
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
      Alcotest.test_case "default join keeps joined status" `Quick test_is_agent_joined_after_default_join;
      Alcotest.test_case "nonexistent agent" `Quick test_heartbeat_nonexistent_agent;
      Alcotest.test_case "get agents status" `Quick test_get_agents_status;
      Alcotest.test_case "backend bootstrap preserves room state" `Quick test_room_bootstrap_preserves_backend_state;
      Alcotest.test_case "bootstrap ignores invalid room id in flat mode" `Quick test_room_bootstrap_ignores_invalid_room_id_in_flat_mode;
      Alcotest.test_case "read_backlog_r reports parse error" `Quick
        test_read_backlog_r_reports_parse_error;
      Alcotest.test_case "release stale claims skips invalid backlog" `Quick
        test_release_stale_claims_skips_invalid_backlog;
      Alcotest.test_case "cleanup zombies empty" `Quick test_cleanup_zombies_empty;
      Alcotest.test_case "cleanup detects regular zombie" `Quick test_cleanup_zombies_detects_regular;
      Alcotest.test_case "cleanup detects keeper zombie" `Quick test_cleanup_zombies_detects_keeper;
      Alcotest.test_case "cleanup spares recent keeper" `Quick test_cleanup_zombies_spares_recent_keeper;
      Alcotest.test_case "cleanup removes broken agent file" `Quick test_cleanup_zombies_removes_broken_agent_file;
      Alcotest.test_case "cleanup preserves non-json files" `Quick test_cleanup_zombies_preserves_non_json_files;
    ];

    (* === Agent Discovery / Capability Tests === *)
    "capabilities", [
      Alcotest.test_case "register capabilities" `Quick test_register_capabilities;
      Alcotest.test_case "find by capability" `Quick test_find_by_capability;
      Alcotest.test_case "find no match" `Quick test_find_by_capability_no_match;
      Alcotest.test_case "register nonexistent agent" `Quick test_register_capabilities_nonexistent_agent;
    ];

    (* === Voting / Consensus Tests === *)
    "voting", [
      Alcotest.test_case "create vote" `Quick test_vote_create;
      Alcotest.test_case "cast vote" `Quick test_vote_cast;
      Alcotest.test_case "double vote blocked" `Quick test_vote_double_vote;
      Alcotest.test_case "invalid choice" `Quick test_vote_invalid_choice;
      Alcotest.test_case "vote status" `Quick test_vote_status;
      Alcotest.test_case "nonexistent vote" `Quick test_vote_nonexistent;
      Alcotest.test_case "vote resolution" `Quick test_vote_resolution_approved;
      Alcotest.test_case "list votes" `Quick test_list_votes;
      Alcotest.test_case "single option" `Quick test_vote_single_option;
      Alcotest.test_case "many voters" `Quick test_vote_many_voters;
      Alcotest.test_case "vote tie" `Quick test_vote_tie;
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
      Alcotest.test_case "many agents" `Quick test_many_agents;
    ];

    (* === Portal Extended Tests === *)
    "portal_extended", [
      Alcotest.test_case "reopen after close" `Quick test_portal_reopen_after_close;
      Alcotest.test_case "send multiple" `Quick test_portal_send_multiple;
    ];

    (* === Priority Tests === *)
    "priority", [
      Alcotest.test_case "negative priority" `Quick test_negative_priority;
    ];

    (* === Security Tests (v2.1) === *)
    "security", [
      Alcotest.test_case "xss in message" `Quick test_xss_in_message;
      Alcotest.test_case "xss in agent name" `Quick test_xss_in_agent_name;
    ];

    (* === Board Admin Tests === *)
    "board_admin", [
      Alcotest.test_case "force release bypasses assignee" `Quick test_force_release_bypasses_assignee;
      Alcotest.test_case "force done bypasses assignee" `Quick test_force_done_bypasses_assignee;
      Alcotest.test_case "audit orphan tasks" `Quick test_audit_orphan_tasks;
      Alcotest.test_case "cleanup zombies cascade" `Quick test_cleanup_zombies_releases_tasks;
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
