module Types = Masc_domain

(** Tests for Workspace module *)

open Masc

let () = Mirage_crypto_rng_unix.use_default ()

(* Install production workspace hooks for verification and metrics tests. *)
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

let verification_id_for_task config task_id =
  match
    Workspace.get_tasks_raw config
    |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id)
  with
  | Some
      { task_status = Masc_domain.AwaitingVerification { verification_id; _ }; _ } ->
    verification_id
  | Some _ -> Alcotest.failf "task %s is not awaiting verification" task_id
  | None -> Alcotest.failf "task %s not found" task_id

let transition_done_r config ~agent_name ~task_id ~notes =
  let evidence_notes =
    if String.equal (String.trim notes) ""
    then "test completion evidence"
    else notes
  in
  match
    Workspace.get_tasks_raw config
    |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id)
  with
  | Some { task_status = Masc_domain.Done _; _ } ->
    Workspace.transition_task_r config ~agent_name ~task_id
      ~action:Masc_domain.Done_action
      ~notes:evidence_notes ()
  | Some _ | None ->
    (match
       Workspace.transition_task_r config ~agent_name ~task_id
         ~action:Masc_domain.Submit_for_verification ~notes:evidence_notes ()
     with
     | Error _ as error -> error
     | Ok _ ->
       (* No peer-keeper claim: the verdict comes from a completion authority. *)
       Workspace.commit_verdict_r
         config
         ~authority:(Masc_domain.Human_operator { operator_id = "operator-test" })
         ~verdict:Masc_domain.Verdict_approved
         ~task_id
         ~verification_id:(verification_id_for_task config task_id)
         ~notes:("verified: " ^ evidence_notes)
         ()
       |> Result.map (fun (o : Workspace.transition_outcome) -> o.Workspace.message))

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
  let result =
    Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"Hello @gemini!"
    |> Result.get_ok
  in
  Alcotest.(check bool) "broadcast success" true (String.contains result.rendered '[');

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
  let _ = Workspace.init config ~agent_name:(Some "fixture-observer") in
  let observer =
    match Workspace.get_agents_raw config with
    | [ agent ] -> agent.Masc_domain.name
    | _ -> Alcotest.fail "expected exactly one bound observer"
  in
  let _ =
    Workspace.bind_session
      config
      ~agent_name:"fixture-subject"
      ~capabilities:[ "test" ]
      ()
  in
  let subject = Workspace.resolve_agent_name config "fixture-subject" in
  let _ = Workspace.add_task config ~title:"Terminal task" ~priority:1 ~description:"" in
  let _ = Workspace.claim_task config ~agent_name:subject ~task_id:"task-001" in
  (match
     transition_done_r
       config
       ~agent_name:subject
       ~task_id:"task-001"
       ~notes:"terminal in backlog"
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
    (current_task_for subject);

  let agent_file =
    Filename.concat
      (Workspace.agents_dir config)
      (Workspace.safe_filename subject ^ ".json")
  in
  let stale_agent =
    match Workspace.read_json config agent_file |> Masc_domain.agent_of_yojson with
    | Ok agent ->
      { agent with status = Masc_domain.Busy; current_task = Some "task-001" }
    | Error msg -> Alcotest.fail ("agent parse failed: " ^ msg)
  in
  Workspace.write_json config agent_file (Masc_domain.agent_to_yojson stale_agent);

  let stale_message =
    Printf.sprintf
      "@%s task-001 stale claim detected: current_task_id=null but the cache \
       still lists task-001 as active."
      subject
  in
  let since_seq =
    Workspace.get_all_messages_raw config ~since_seq:0
    |> List.fold_left (fun acc msg -> max acc msg.Masc_domain.seq) 0
  in
  let result =
    Workspace.broadcast
      ~task_cache_signal:{ subject_agent = subject; task_id = "task-001" }
      ~audience:Workspace_broadcast.System_record
      config
      ~from_agent:observer
      ~content:stale_message
    |> Result.get_ok
  in
  Alcotest.(check bool)
    "broadcast reports invalidation"
    true
    (str_contains result.rendered "[cache_invalidated]");
  Alcotest.(check bool)
    "delivery exposes the canonical replacement"
    true
    (str_contains result.content "[cache_invalidated]");
  Alcotest.(check (option string))
    "delivery preserves the original mention"
    (Some subject)
    result.mention;
  Alcotest.(check string)
    "delivery exposes the canonical persisted sender"
    observer
    result.from_agent;
  let messages = Workspace.get_all_messages_raw config ~since_seq in
  (match messages with
   | [ msg ] ->
     Alcotest.(check bool)
       "original stale text omitted"
       false
       (str_contains msg.content "still lists task-001 as active");
     Alcotest.(check bool)
       "replacement cites terminal task"
       true
       (str_contains msg.content (subject ^ " cached task task-001 as active"))
   | msgs ->
     Alcotest.failf "expected one replacement message, got %d" (List.length msgs));
  Alcotest.(check (option string))
    "stale current_task cleared"
    None
    (current_task_for subject);
  Alcotest.(check (option string))
    "observer has no task cache ownership"
    None
    (current_task_for observer);

  (* The reactive path clears only after reading the canonical backlog and
     finding the task terminal, so it is the one that names a real desync. The
     after-commit sweeps that run on every transition emit their own name, or
     their volume buries this signal -- two thirds of 3,000 recorded events
     came from one after-commit site (#27411). *)
  let event_types () =
    let events_dir = Filename.concat (Workspace.masc_dir config) "events" in
    let rec files dir =
      Sys.readdir dir
      |> Array.to_list
      |> List.concat_map (fun name ->
        let path = Filename.concat dir name in
        if Sys.is_directory path then files path else [ path ])
    in
    if not (Sys.file_exists events_dir)
    then []
    else
      files events_dir
      |> List.concat_map (fun path ->
        In_channel.with_open_text path In_channel.input_all
        |> String.split_on_char '\n'
        |> List.filter_map (fun line ->
          if String.length line = 0
          then None
          else
            match Yojson.Safe.from_string line with
            | `Assoc fields ->
              (match List.assoc_opt "type" fields with
               | Some (`String t) -> Some t
               | _ -> None)
            | _ -> None
            | exception _ -> None))
  in
  let types = event_types () in
  Alcotest.(check bool)
    "the reactive clear is recorded as a desync"
    true
    (List.exists (String.equal "cache_desync.cleared") types);
  (* This run also claimed and completed a task, so the after-commit sweeps
     ran. They have to appear under their own name, or the split did not
     actually separate the two populations. *)
  Alcotest.(check bool)
    "after-commit sweeps are recorded under their own name"
    true
    (List.exists (String.equal "task_cache.cleared_after_commit") types);
  Alcotest.(check int)
    "the reactive clear is the only desync in this run"
    1
    (List.length (List.filter (String.equal "cache_desync.cleared") types));

  let before_rejected =
    Workspace.get_all_messages_raw config ~since_seq:0 |> List.length
  in
  let rejected =
    Workspace.broadcast
      ~task_cache_signal:{ subject_agent = subject; task_id = "task-001" }
      ~audience:Workspace_broadcast.System_record
      config
      ~from_agent:observer
      ~content:"typed signal without a matching subject cache"
  in
  Alcotest.(check bool)
    "mismatched subject cache is rejected"
    true
    (match rejected with
     | Error (Workspace_broadcast.Broadcast_policy_rejected _) -> true
     | Error _ | Ok _ -> false);
  Alcotest.(check int)
    "rejected typed signal is not persisted"
    before_rejected
    (Workspace.get_all_messages_raw config ~since_seq:0 |> List.length);

  let absent_agent =
    match Workspace.read_json config agent_file |> Masc_domain.agent_of_yojson with
    | Ok agent ->
      { agent with status = Masc_domain.Busy; current_task = Some "task-ghost" }
    | Error msg -> Alcotest.fail ("agent parse failed: " ^ msg)
  in
  Workspace.write_json config agent_file (Masc_domain.agent_to_yojson absent_agent);
  let absent_result =
    Workspace.broadcast
      ~task_cache_signal:{ subject_agent = subject; task_id = "task-ghost" }
      ~audience:Workspace_broadcast.System_record
      config
      ~from_agent:observer
      ~content:"typed signal for a task absent from the canonical backlog"
    |> Result.get_ok
  in
  Alcotest.(check bool)
    "absent canonical task invalidates an exact subject cache"
    true
    (str_contains absent_result.content "[cache_invalidated]");
  Alcotest.(check (option string))
    "absent canonical task cache is cleared"
    None
    (current_task_for subject);

  let _ =
    Workspace.add_task config ~title:"Active task" ~priority:1 ~description:""
  in
  let _ = Workspace.claim_task config ~agent_name:subject ~task_id:"task-002" in
  let active_content = "typed signal for a still-active canonical task" in
  let active_result =
    Workspace.broadcast
      ~task_cache_signal:{ subject_agent = subject; task_id = "task-002" }
      ~audience:Workspace_broadcast.System_record
      config
      ~from_agent:observer
      ~content:active_content
    |> Result.get_ok
  in
  Alcotest.(check string)
    "active exact subject cache is preserved"
    active_content
    active_result.content;
  Alcotest.(check (option string))
    "active exact subject cache remains owned"
    (Some "task-002")
    (current_task_for subject);

  (* A subject record we cannot decode is a failure to look, not a subject
     that disagrees. Rejecting it would tell a correct observer its report was
     wrong and leave the stale cache in place. *)
  let readable_subject_json = Workspace.read_json config agent_file in
  Workspace.write_json config agent_file (`String "not an agent record");
  let unreadable_result =
    Workspace.broadcast
      ~task_cache_signal:{ subject_agent = subject; task_id = "task-002" }
      ~audience:Workspace_broadcast.System_record
      config
      ~from_agent:observer
      ~content:"typed signal whose subject record cannot be decoded"
  in
  Alcotest.(check bool)
    "an undecodable subject record reports a dependency failure"
    true
    (match unreadable_result with
     | Error (Workspace_broadcast.Broadcast_dependency_unavailable _) -> true
     | Error _ | Ok _ -> false);
  Workspace.write_json config agent_file readable_subject_json;

  let normal_update =
    "Normal update: blocked by task-001 while I wait for review context."
  in
  let normal_result =
    Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:observer ~content:normal_update
    |> Result.get_ok
  in
  Alcotest.(check bool)
    "normal task mention is not invalidated"
    false
    (str_contains normal_result.rendered "[cache_invalidated]");
  let untyped_result =
    Workspace.broadcast
      ~audience:Workspace_broadcast.System_record
      config
      ~from_agent:observer
      ~content:stale_message
    |> Result.get_ok
  in
  Alcotest.(check string)
    "same observer prose without a typed signal is preserved"
    stale_message
    untyped_result.content;

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
  let result =
    Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"Test event"
    |> Result.get_ok
  in

  (* Verify broadcast returned a valid response (contains timestamp marker) *)
  Alcotest.(check bool) "broadcast returns response" true (String.length result.rendered > 0);
  Alcotest.(check bool) "broadcast has timestamp" true (String.contains result.rendered '[');

  (* Cleanup *)
  let _ = Workspace.reset config in
  Unix.rmdir tmp_dir

(* ============================================================ *)
(* Edge Case & Error Case Tests                                  *)
(* ============================================================ *)

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
    let result =
      Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:msg
      |> Result.get_ok
    in
    Alcotest.(check bool) "special chars handled" true (String.length result.rendered > 0)
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
    let _ = Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"hello" in

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
    match Workspace.heartbeat config ~agent_name:"gemini" with
    | Workspace.Heartbeat_updated _ -> ()
    | outcome ->
      Alcotest.failf "expected an update, got %S"
        (Workspace.heartbeat_message outcome)
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

let test_read_backlog_r_rejects_non_authoritative_recovery () =
  with_test_env (fun config ->
    let expected =
      {
        Masc_domain.tasks = [];
        last_updated = Masc_domain.now_iso ();
        version = 7;
      }
    in
    let committed_revision =
      match Workspace.write_backlog_result config expected with
      | Ok outcome -> outcome.committed_revision
      | Error msg -> Alcotest.failf "failed to write recovery fixture: %s" msg
    in
    Out_channel.with_open_text (Workspace.backlog_path config) (fun oc ->
      output_string oc "{\n  \"tasks\": [\n");
    (match Workspace.read_backlog_r config with
     | Ok _ -> Alcotest.fail "strict backlog read accepted recovery as authoritative"
     | Error msg ->
       Alcotest.(check bool)
         "strict error identifies non-authoritative recovery"
         true
         (str_contains msg "non-authoritative for mutation"));
    (match Workspace.read_backlog_observation_with_source_r config with
     | Error msg -> Alcotest.failf "source-aware observation failed: %s" msg
     | Ok observation ->
       Alcotest.(check int)
         "source-aware observation keeps recovered revision"
         committed_revision
         observation.observed_backlog.version;
       Alcotest.(check bool)
         "source-aware observation identifies recovery"
         true
         (Option.is_some observation.recovered_from));
    (match Workspace.read_backlog_observation_r config with
     | Error msg -> Alcotest.failf "observation read rejected recovery: %s" msg
     | Ok backlog ->
       Alcotest.(check int)
         "observation read exposes recovered revision"
         committed_revision
         backlog.version);
    let backlog = Workspace.read_backlog config in
    Alcotest.(check int)
      "tolerant read exposes recovered revision"
      committed_revision
      backlog.version
  )

let test_write_backlog_result_rejects_revision_overflow () =
  with_test_env (fun config ->
    let primary_path = Workspace.backlog_path config in
    let recovery_path = backlog_recovery_path config in
    let read_file path = In_channel.with_open_bin path In_channel.input_all in
    let initial = Workspace.read_backlog config in
    (match Workspace.write_backlog_result config initial with
     | Ok _ -> ()
     | Error msg -> Alcotest.failf "failed to seed recovery fixture: %s" msg);
    let primary_before = read_file primary_path in
    let recovery_before = read_file recovery_path in
    let terminal =
      {
        Masc_domain.tasks = [];
        last_updated = Masc_domain.now_iso ();
        version = max_int;
      }
    in
    (match Workspace.write_backlog_result config terminal with
     | Ok _ -> Alcotest.fail "terminal revision wrapped and committed"
     | Error msg ->
       Alcotest.(check bool)
         "terminal revision reports exhaustion"
         true
         (str_contains msg "revision exhausted"));
    Alcotest.(check string)
      "overflow rejection preserves primary"
      primary_before
      (read_file primary_path);
    Alcotest.(check string)
      "overflow rejection preserves recovery"
      recovery_before
      (read_file recovery_path))

let test_read_backlog_r_rejects_recovery_after_invalid_primary_revision () =
  with_test_env (fun config ->
    let expected =
      {
        Masc_domain.tasks = [];
        last_updated = Masc_domain.now_iso ();
        version = 7;
      }
    in
    let committed_revision =
      match Workspace.write_backlog_result config expected with
      | Ok outcome -> outcome.committed_revision
      | Error msg -> Alcotest.failf "failed to write recovery fixture: %s" msg
    in
    Workspace_utils.write_json
      config
      (Workspace.backlog_path config)
      (`Assoc
        [ "tasks", `List []
        ; "last_updated", `String (Masc_domain.now_iso ())
        ; "version", `Int 0
        ]);
    (match Workspace.read_backlog_r config with
     | Ok _ ->
       Alcotest.fail "strict backlog read accepted decode recovery as authoritative"
     | Error msg ->
       Alcotest.(check bool)
         "decode recovery is explicitly non-authoritative"
         true
         (str_contains msg "non-authoritative for mutation"));
    let backlog = Workspace.read_backlog config in
    Alcotest.(check int)
      "tolerant decode recovery exposes committed revision"
      committed_revision
      backlog.version)

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

let test_heartbeat_nonexistent_agent () =
  with_test_env (fun config ->
    (* Heartbeat for non-bound agent *)
    match Workspace.heartbeat config ~agent_name:"nonexistent" with
    | Workspace.Agent_not_found _ -> ()
    | outcome ->
      Alcotest.failf "expected the agent to be missing, got %S"
        (Workspace.heartbeat_message outcome)
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

(* ============================================================ *)
(* Agent Discovery / Capability Tests                           *)
(* ============================================================ *)

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
    let result =
      Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:msg
      |> Result.get_ok
    in
    Alcotest.(check bool) "emoji preserved" true (str_contains result.rendered "🚀")
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
  let _ = Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"Hello" in

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
    let result =
      Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:long_msg
      |> Result.get_ok
    in
    Alcotest.(check bool) "long message handled" true (String.length result.rendered > 0)
  )

let test_message_with_json_chars () =
  with_test_env (fun config ->
    (* JSON special characters should be escaped properly *)
    let msg = "{\"key\": \"value\", \"array\": [1,2,3]}" in
    let result =
      Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:msg
      |> Result.get_ok
    in
    Alcotest.(check bool) "json chars handled" true (String.length result.rendered > 0)
  )

let test_message_sequence () =
  with_test_env (fun config ->
    (* Messages should have incrementing sequence numbers *)
    let _ = Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"First" in
    let _ = Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"Second" in
    let _ = Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"claude" ~content:"Third" in

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
      (Workspace.broadcast ~audience:Workspace_broadcast.System_record config ~from_agent:"tester" ~msg_type:xss_msg_type
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
    (* #29736 stopped escaping at the store, so the type comes back as the
       caller wrote it. [test_broadcast_stores_raw_text] pins the same contract
       for the content; the type has no coverage there, so it is pinned here. *)
    Alcotest.(check string) "msg_type is stored as written" xss_msg_type msg_type
  )

(* === Board Admin Tests === *)

(* Use 3-part nicknames so join() preserves them as-is
   (Nickname.is_generated_nickname requires 3+ dash-separated parts) *)
let admin_keeper_agent = "admin-board-keeper"
let test_agent_a = "agent-test-alpha"

let find_task config task_id =
  Workspace.get_tasks_raw config
  |> List.find_opt (fun (t : Masc_domain.task) -> String.equal t.id task_id)

(* === RFC-0323 G-3: completion side effects are state-keyed === *)

(* Records done-hook dispatch targets while [f] runs, restoring the previous
   hook.  Observes [relation_on_task_done_fn] because it receives the assignee
   the completion side effects are keyed on. *)
let with_done_hook_recorder f =
  let recorded = ref [] in
  let prev =
    Atomic.exchange Workspace_hooks.relation_on_task_done_fn
      (fun ~assignee ~active_agents:_ ->
        recorded := assignee :: !recorded)
  in
  Fun.protect
    ~finally:(fun () -> Atomic.set Workspace_hooks.relation_on_task_done_fn prev)
    (fun () -> f recorded)

let with_verdict_projection_recorders f =
  let terminal = ref [] in
  let notifications = ref [] in
  let previous_terminal =
    Atomic.exchange Workspace_hooks.task_terminal_committed_fn
      (fun _config ~agent_name ~task_id ->
        terminal := (agent_name, task_id) :: !terminal;
        Workspace_hooks.Task_terminal_delivered)
  in
  let previous_notification =
    Atomic.exchange Workspace_hooks.verification_notify_verdict_fn
      (fun ~task_id ~authority ~verification_id ~decision ->
        notifications :=
          (task_id, authority, verification_id, decision) :: !notifications)
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.task_terminal_committed_fn previous_terminal;
      Atomic.set Workspace_hooks.verification_notify_verdict_fn
        previous_notification)
    (fun () -> f terminal notifications)
;;

let test_approve_completion_credits_assignee () =
  with_test_env (fun config ->
    with_done_hook_recorder (fun recorded ->
      with_verdict_projection_recorders (fun terminal notifications ->
      let _ = Workspace.add_task config ~title:"Parity Task" ~priority:1 ~description:"" in
      let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
      let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
      let submitted =
        Workspace.transition_task_r config ~agent_name:test_agent_a ~task_id:"task-001"
          ~action:Masc_domain.Submit_for_verification ~notes:"evidence attached" ()
      in
      Alcotest.(check bool) "submit ok" true
        (match submitted with Ok _ -> true | Error _ -> false);
      Alcotest.(check (list string)) "no done hook before approve" [] !recorded;
      let approved =
        Workspace.commit_verdict_r
          config
          ~authority:(Masc_domain.Human_operator { operator_id = "operator-test" })
          ~verdict:Masc_domain.Verdict_approved
          ~task_id:"task-001"
          ~verification_id:(verification_id_for_task config "task-001")
          ~notes:"verified submitted evidence"
          ()
      in
      Alcotest.(check bool) "approve ok" true
        (match approved with Ok _ -> true | Error _ -> false);
      (* The verdict actor is an authority, not an agent, so the done hook must
         still credit the producer. *)
      Alcotest.(check (list string))
        "approve completion credits assignee" [ test_agent_a ] !recorded;
      Alcotest.(check (list (pair string string)))
        "terminal reconciliation credits producer"
        [ test_agent_a, "task-001" ]
        !terminal;
      Alcotest.(check int)
        "authority verdict notification emitted once"
        1
        (List.length !notifications)))
    )

let test_operator_rejection_rebinds_producer () =
  with_test_env (fun config ->
    let _ =
      Workspace.add_task
        config
        ~title:"Rejected Task"
        ~priority:1
        ~description:""
    in
    let _ =
      Workspace.bind_session
        config
        ~agent_name:test_agent_a
        ~capabilities:[]
        ()
    in
    let _ =
      Workspace.claim_task
        config
        ~agent_name:test_agent_a
        ~task_id:"task-001"
    in
    let _ =
      Workspace.transition_task_r
        config
        ~agent_name:test_agent_a
        ~task_id:"task-001"
        ~action:Masc_domain.Submit_for_verification
        ~notes:"evidence"
        ()
    in
    let rejected =
      Workspace.commit_verdict_r
        config
        ~authority:
          (Masc_domain.Human_operator { operator_id = "operator-test" })
        ~verdict:
          (Masc_domain.Verdict_rejected { reason = "missing focused test" })
        ~task_id:"task-001"
        ~verification_id:(verification_id_for_task config "task-001")
        ()
    in
    Alcotest.(check bool)
      "reject committed"
      true
      (Result.is_ok rejected);
    (match find_task config "task-001" with
     | Some
         { task_status =
             Masc_domain.InProgress { assignee; _ }
         ; _
         }
       when String.equal assignee test_agent_a -> ()
     | _ -> Alcotest.fail "rejection did not return task to producer");
    match
      Workspace.get_agents_raw config
      |> List.find_opt (fun (agent : Masc_domain.agent) ->
             String.equal agent.name test_agent_a)
    with
    | Some { status = Masc_domain.Busy; current_task = Some "task-001"; _ } -> ()
    | _ -> Alcotest.fail "rejection did not restore producer task binding")

(* The authority reads a request record, not the task status, so every path
   into [AwaitingVerification] must leave one behind. The cancel path did not:
   task-1303 (2026-09-03) sat awaiting a verdict on a record that was never
   written while the authority deferred on "verification not found". Driven
   through the real hooks installed at the top of this file. *)
let test_cancel_writes_the_record_the_authority_reads () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Stop me" ~priority:1 ~description:"" in
    let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    let refused =
      Workspace.transition_task_r config ~agent_name:test_agent_a ~task_id:"task-001"
        ~action:Masc_domain.Cancel ()
    in
    Alcotest.(check bool) "a cancel with no reason is refused" true (Result.is_error refused);
    (match
       Workspace.transition_task_r config ~agent_name:test_agent_a ~task_id:"task-001"
         ~action:Masc_domain.Cancel ~reason:"the defect no longer reproduces" ()
     with
     | Ok _ -> ()
     | Error _ -> Alcotest.fail "a cancel with a reason must be accepted");
    let verification_id = verification_id_for_task config "task-001" in
    match Verification.load_request config.Workspace.base_path verification_id with
    | Error e -> Alcotest.fail ("the authority would defer on: " ^ e)
    | Ok request ->
      Alcotest.(check string) "record carries the producer's reason"
        "the defect no longer reproduces"
        Yojson.Safe.Util.(request.output |> member "cancel_reason" |> to_string);
      (* Which question was asked is the Task's to answer, not the record's. *)
      (match find_task config "task-001" with
       | Some { task_status = Masc_domain.AwaitingVerification
                  { intent = Masc_domain.Cancel_task; _ }; _ } -> ()
       | Some _ | None ->
         Alcotest.fail "the task must be awaiting a verdict on a cancellation"))

(* [reason] is optional on this entry point while handoff_context.summary is
   required for every exit-class action, so a caller can put the whole
   explanation in the summary — the tool schema tells it to. Reading only
   [reason] refused exactly that call while the message log would have
   announced it with the summary as its reason. *)
let test_cancel_takes_its_reason_from_the_handoff_summary () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Stop me" ~priority:1 ~description:"" in
    let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    (match
       Workspace.transition_task_r config ~agent_name:test_agent_a ~task_id:"task-001"
         ~action:Masc_domain.Cancel
         ~handoff_context:
           { summary = "the premise this rests on is gone"
           ; reason = None
           ; next_step = None
           ; failure_mode = None
           ; reclaim_policy = None
           ; evidence_refs = []
           ; updated_at = None
           ; updated_by = None
           }
         ()
     with
     | Ok _ -> ()
     | Error e ->
       Alcotest.fail
         ("a cancellation explained in its summary must be accepted: "
          ^ Masc_domain.masc_error_to_string e));
    let verification_id = verification_id_for_task config "task-001" in
    match Verification.load_request config.Workspace.base_path verification_id with
    | Error e -> Alcotest.fail ("the authority would defer on: " ^ e)
    | Ok request ->
      Alcotest.(check string) "the summary is what the judge is given"
        "the premise this rests on is gone"
        Yojson.Safe.Util.(request.output |> member "cancel_reason" |> to_string))

let test_operator_verdict_boundary_is_reachable () =
  with_test_env (fun config ->
    let _ =
      Workspace.add_task
        config
        ~title:"Operator Boundary Task"
        ~priority:1
        ~description:""
    in
    let _ =
      Workspace.bind_session
        config
        ~agent_name:test_agent_a
        ~capabilities:[]
        ()
    in
    let _ =
      Workspace.claim_task
        config
        ~agent_name:test_agent_a
        ~task_id:"task-001"
    in
    let submitted =
      Workspace.transition_task_r
        config
        ~agent_name:test_agent_a
        ~task_id:"task-001"
        ~action:Masc_domain.Submit_for_verification
        ~notes:"evidence"
        ~prepare_verification_request:
          (fun ~task ~assignee ~verification_id ~claim ->
             Verification_protocol.create_submit_request
               ~config
               ~task
               ~assignee
               ~verification_id
               ~claim)
        ()
    in
    Alcotest.(check bool) "submit with evidence snapshot" true
      (Result.is_ok submitted);
    let evidence =
      Server_routes_http_routes_verification.For_testing.operator_evidence_json
        ~config
        ~operator_id:"operator-test"
        ~task_id:"task-001"
    in
    (match evidence with
     | Ok json ->
       Alcotest.(check string)
         "authority evidence available"
         "available"
         Yojson.Safe.Util.(
           json
           |> member "evidence"
           |> member "access"
           |> to_string)
     | Error message -> Alcotest.fail message);
    let parsed =
      Server_routes_http_routes_verification.For_testing
      .parse_operator_verdict_json
        (`Assoc
          [ "task_id", `String "task-001"
          ; "verdict", `String "approve"
          ; "notes", `String "evidence checked"
          ])
    in
    let request =
      match parsed with
      | Ok request -> request
      | Error message -> Alcotest.fail message
    in
    let committed =
      Server_routes_http_routes_verification.For_testing.commit_operator_verdict
        ~config
        ~operator_id:"operator-test"
        request
    in
    Alcotest.(check bool) "operator boundary commits verdict" true
      (Result.is_ok committed);
    match find_task config "task-001" with
    | Some { task_status = Masc_domain.Done _; _ } -> ()
    | _ -> Alcotest.fail "operator boundary did not complete the task")

let test_operator_verdict_parser_rejects_reasonless_rejection () =
  match
    Server_routes_http_routes_verification.For_testing
    .parse_operator_verdict_json
      (`Assoc
        [ "task_id", `String "task-001"
        ; "verdict", `String "reject"
        ])
  with
  | Error message when str_contains message "reason" -> ()
  | Ok _ | Error _ -> Alcotest.fail "reasonless rejection must fail parsing"

(* Replaces the approve-notes guard. An approval no longer needs a justification
   string because the caller authenticates the completion authority before this
   provenance value reaches the workspace. A *rejection* still needs a reason:
   the producer has to know what to fix. *)
let test_verdict_rejects_blank_rejection_reason () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Justification Task" ~priority:1 ~description:"" in
    let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    let _ =
      Workspace.transition_task_r config ~agent_name:test_agent_a ~task_id:"task-001"
        ~action:Masc_domain.Submit_for_verification ~notes:"evidence" ()
    in
    let rejected =
      Workspace.commit_verdict_r
        config
        ~authority:(Masc_domain.Human_operator { operator_id = "operator-test" })
        ~verdict:(Masc_domain.Verdict_rejected { reason = "   " })
        ~task_id:"task-001"
        ~verification_id:(verification_id_for_task config "task-001")
        ()
    in
    Alcotest.(check bool) "blank rejection reason refused before commit" false
      (match rejected with Ok _ -> true | Error _ -> false);
    (* A refused verdict leaves the obligation untouched, and the obligation
       carries no verifier binding to mutate in the first place. *)
    match find_task config "task-001" with
    | Some { task_status = Masc_domain.AwaitingVerification { assignee; _ }; _ }
      when String.equal assignee test_agent_a -> ()
    | _ -> Alcotest.fail "refused verdict mutated the verification state")

(* === RFC-0323 G-1 (implements RFC-0308): verification-required done guard === *)

let strict_contract : Masc_domain.task_contract =
  { strict = true
  ; completion_contract = [ "deliverable verified by a second agent" ]
  ; (* Declared up front so the strict evidence precheck is satisfied by the
       contract itself and direct done reaches the verification-lane guard. *)
    required_evidence = [ "artifact:deliverable" ]
  ; inspect_gate_evidence = []
  ; verify_gate_evidence = []
  }

let test_strict_task_done_requires_verification_submission () =
  with_test_env (fun config ->
    let _ =
      Workspace.add_task config ~contract:strict_contract ~title:"Strict Task"
        ~priority:1 ~description:""
    in
    let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    let direct =
      Workspace.transition_task_r config ~agent_name:test_agent_a ~task_id:"task-001"
        ~action:Masc_domain.Done_action
        ~notes:"evidence attached"
        ()
    in
    (match direct with
     | Error e ->
       Alcotest.(check bool) "error requires verification submission" true
         (str_contains
            (Masc_domain.masc_error_to_string e)
            "must be submitted for verification")
     | Ok _ -> Alcotest.fail "task bypassed verification submission");
    Alcotest.(check bool) "task remains nonterminal" true
      (match find_task config "task-001" with
       | Some { task_status = Masc_domain.Claimed _; _ } -> true
       | Some _ | None -> false))

let test_default_task_done_requires_verification_submission () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Default Task" ~priority:1 ~description:"" in
    let _ = Workspace.bind_session config ~agent_name:test_agent_a ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:test_agent_a ~task_id:"task-001" in
    let direct =
      Workspace.transition_task_r config ~agent_name:test_agent_a ~task_id:"task-001"
        ~action:Masc_domain.Done_action
        ~notes:"done" ()
    in
    (match direct with
     | Error e ->
       Alcotest.(check bool) "error requires verification submission" true
         (str_contains
            (Masc_domain.masc_error_to_string e)
            "must be submitted for verification")
     | Ok _ -> Alcotest.fail "default task bypassed verification submission");
    Alcotest.(check bool) "default task remains nonterminal" true
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
    Alcotest.(check string) "orphan task id" "task-001" task.id;
    Alcotest.(check int)
      "provided task snapshot is authoritative"
      0
      (List.length (Workspace.audit_orphan_tasks_in_tasks config []))
  )

let test_audit_orphan_awaiting_verification_tasks () =
  with_test_env (fun config ->
    (
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

let test_audit_orphan_ignores_elapsed_last_seen_for_active_agent () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Observed Task" ~priority:1 ~description:"" in
    let agent = "observed-active-agent" in
    let _ = Workspace.bind_session config ~agent_name:agent ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:agent ~task_id:"task-001" in
    Workspace.update_local_agent_state config ~agent_name:agent (fun record ->
      { record with last_seen = "2020-01-01T00:00:00Z" });
    let orphans = Workspace.audit_orphan_tasks config in
    Alcotest.(check int) "elapsed last_seen cannot orphan an active task" 0
      (List.length orphans)
  )

let assert_prefixed_identity_does_not_claim_membership ~assignee ~active_name =
  with_test_env (fun config ->
    let _ =
      Workspace.add_task
        config
        ~title:"Identity Boundary"
        ~priority:1
        ~description:""
    in
    let backlog = Workspace.read_backlog config in
    let tasks =
      List.map
        (fun (task : Masc_domain.task) ->
           if String.equal task.id "task-001"
           then
             { task with
               task_status =
                 Masc_domain.Claimed { assignee; claimed_at = "test" }
             }
           else task)
        backlog.tasks
    in
    Workspace.write_backlog config { backlog with tasks };
    let state = Workspace.read_state config in
    Workspace.write_state
      config
      { state with active_agents = active_name :: state.active_agents };
    let orphans = Workspace.audit_orphan_tasks config in
    Alcotest.(check bool)
      (Printf.sprintf "%s does not confer identity to %s" active_name assignee)
      true
      (List.exists
         (fun ((task : Masc_domain.task), orphan_assignee) ->
            String.equal task.id "task-001"
            && String.equal orphan_assignee assignee)
         orphans))

let test_audit_orphan_requires_exact_registered_identity () =
  assert_prefixed_identity_does_not_claim_membership
    ~assignee:"alice"
    ~active_name:"alice-worker";
  assert_prefixed_identity_does_not_claim_membership
    ~assignee:"alice-worker"
    ~active_name:"alice"

let keeper_meta_for_self_filter agent_name =
  let json =
    `Assoc
      [ ("name", `String agent_name)
      ; ("trace_id", `String "trace-self-filter")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("keeper_meta_for_self_filter failed: " ^ err)

let keeper_meta_for_goal_filter agent_name =
  let json =
    `Assoc
      [ ("name", `String agent_name)
      ; ("trace_id", `String "trace-goal-filter")
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("keeper_meta_for_goal_filter failed: " ^ err)

(* Keepers can claim without a materialized [.masc/agents/] record. The keeper
   backlog failed-task count must exclude the keeper's own claimed task so it
   does not re-trigger a self-wake loop. *)
let test_read_backlog_snapshot_excludes_self_owned_orphan () =
  with_test_env (fun config ->
    let keeper = "keeper-self-filter-agent" in
    let _ = Workspace.bind_session config ~agent_name:keeper ~capabilities:[] () in
    let _ = Workspace.claim_task config ~agent_name:keeper ~task_id:"task-001" in
    (* Remove the agent file to simulate a keeper with no active registry record. *)
    let _ = Workspace.end_session config ~agent_name:keeper in
    let meta = keeper_meta_for_self_filter keeper in
    let snapshot =
      Keeper_world_observation_inputs.read_backlog_snapshot ~config ~meta
    in
    Alcotest.(check int)
      "keeper's own orphan excluded from failed count"
      0
      snapshot.failed_count
  )

let test_read_backlog_snapshot_falls_back_to_unscoped_claimable_task () =
  with_test_env (fun config ->
    let keeper = "keeper-goal-filter-agent" in
    let _ =
      Workspace.add_task config ~goal_id:"goal-b" ~title:"Goal B work"
        ~priority:1 ~description:""
    in
    let meta = keeper_meta_for_goal_filter keeper in
    let snapshot =
      Keeper_world_observation_inputs.read_backlog_snapshot ~config ~meta
    in
    Alcotest.(check int)
      "claimable count falls back to unscoped todo"
      1
      (List.length snapshot.claimable_tasks)
  )

let test_read_backlog_snapshot_preserves_unreadable_observation () =
  with_test_env (fun config ->
    let task_id =
      match Keeper_id.Task_id.of_string "task-001" with
      | Ok task_id -> task_id
      | Error message -> Alcotest.fail message
    in
    let current_task_meta =
      { (keeper_meta_for_self_filter "keeper-backlog-recovery-agent") with
        current_task_id = Some task_id
      }
    in
    (* The recovery snapshot can only preserve a task the store already held;
       the setup step that creates it was missing. *)
    let _ =
      Workspace.add_task
        config
        ~title:"Backlog recovery observation"
        ~priority:1
        ~description:""
    in
    let write_corrupt path =
      Out_channel.with_open_text path (fun channel ->
        output_string channel "{\"tasks\":\"not-current\"}")
    in
    write_corrupt (Workspace.backlog_path config);
    (match
       Keeper_world_observation_inputs.read_current_task
         ~config
         ~meta:current_task_meta
     with
     | Keeper_world_observation_inputs.Recovered_current_task { task; recovery = _ } ->
       Alcotest.(check string) "recovered task id" "task-001" task.id
     | Keeper_world_observation_inputs.No_current_task
     | Keeper_world_observation_inputs.Current_task _
     | Keeper_world_observation_inputs.Current_task_missing _
     | Keeper_world_observation_inputs.Current_task_unavailable _ ->
       Alcotest.fail "valid recovery source was not preserved");
    let meta = keeper_meta_for_self_filter "keeper-backlog-recovery-agent" in
    let snapshot =
      Keeper_world_observation_inputs.read_backlog_snapshot ~config ~meta
    in
    Alcotest.(check int) "recovery unclaimed count is inert" 0 snapshot.unclaimed_count;
    Alcotest.(check int)
      "recovery claimable rows are inert"
      0
      (List.length snapshot.claimable_tasks);
    Alcotest.(check int) "recovery failed count is inert" 0 snapshot.failed_count;
    Alcotest.(check (option int))
      "recovery has no authoritative revision"
      None
      snapshot.revision;
    write_corrupt (Workspace.backlog_recovery_path config);
    let meta = keeper_meta_for_self_filter "keeper-backlog-failure-agent" in
    let snapshot =
      Keeper_world_observation_inputs.read_backlog_snapshot ~config ~meta
    in
    Alcotest.(check int)
      "unreadable unclaimed count is inert"
      0
      snapshot.unclaimed_count;
    Alcotest.(check int)
      "unreadable claimable rows are inert"
      0
      (List.length snapshot.claimable_tasks);
    Alcotest.(check int) "unreadable failed count is inert" 0 snapshot.failed_count;
    Alcotest.(check (option int))
      "unreadable backlog has no fabricated revision"
      None
      snapshot.revision;
    let board_event : Keeper_world_observation.pending_board_event =
      { event_kind = Board_post_created
      ; post_id = "post-backlog-unreadable"
      ; author = "peer"
      ; title = "independent stimulus"
      ; preview = "board event must survive a backlog read failure"
      ; hearth = None
      ; post_kind = Board.Human_post
      ; updated_at = 0.0
      ; explicit_mention = false
      ; matched_targets = []
      ; self_commented = false
      ; new_external_since = 0
      ; latest_external_author = None
      ; latest_external_preview = None
      }
    in
    let observation =
      Keeper_world_observation.observe
        ~pending_board_events:(Some [ board_event ])
        ~config
        ~meta
    in
    Alcotest.(check (option int))
      "world observation preserves unreadable backlog"
      None
      observation.backlog_revision;
    Alcotest.(check int)
      "independent board stimulus survives unreadable backlog"
      1
      (List.length observation.pending_board_events))

let test_read_current_task_preserves_unavailable_and_missing () =
  with_test_env (fun config ->
    let task_id =
      match Keeper_id.Task_id.of_string "task-001" with
      | Ok task_id -> task_id
      | Error message -> Alcotest.fail message
    in
    (* The phases below remove this task and then corrupt the store, so the
       first phase needs it to exist; the setup step was missing. *)
    let _ =
      Workspace.add_task
        config
        ~title:"Current task observation"
        ~priority:1
        ~description:""
    in
    let meta =
      { (keeper_meta_for_self_filter "keeper-current-task-observation-agent") with
        current_task_id = Some task_id
      }
    in
    (match Keeper_world_observation_inputs.read_current_task ~config ~meta with
     | Keeper_world_observation_inputs.Current_task _ -> ()
     | Keeper_world_observation_inputs.No_current_task
     | Keeper_world_observation_inputs.Recovered_current_task _
     | Keeper_world_observation_inputs.Current_task_missing _
     | Keeper_world_observation_inputs.Current_task_unavailable _ ->
       Alcotest.fail "existing task was not observed");
    let backlog = Workspace.read_backlog config in
    let without_task = { backlog with tasks = [] } in
    (match Workspace.write_backlog_result config without_task with
     | Ok _ -> ()
     | Error message -> Alcotest.fail message);
    (match Keeper_world_observation_inputs.read_current_task ~config ~meta with
     | Keeper_world_observation_inputs.Current_task_missing { task_id = missing; recovery = None } ->
       Alcotest.(check string)
         "missing task id"
         "task-001"
         (Keeper_id.Task_id.to_string missing)
     | Keeper_world_observation_inputs.Current_task_missing { recovery = Some _; _ } ->
       Alcotest.fail "missing task unexpectedly came from a recovery snapshot"
     | Keeper_world_observation_inputs.No_current_task
     | Keeper_world_observation_inputs.Current_task _
     | Keeper_world_observation_inputs.Recovered_current_task _
     | Keeper_world_observation_inputs.Current_task_unavailable _ ->
       Alcotest.fail "missing task was not distinguished from unavailable");
    let write_corrupt path =
      Out_channel.with_open_text path (fun channel ->
        output_string channel "{\"tasks\":\"not-current\"}")
    in
    write_corrupt (Workspace.backlog_path config);
    write_corrupt (Workspace.backlog_recovery_path config);
    match Keeper_world_observation_inputs.read_current_task ~config ~meta with
    | Keeper_world_observation_inputs.Current_task_unavailable { task_id = unavailable; error } ->
      Alcotest.(check string)
        "unavailable task id"
        "task-001"
        (Keeper_id.Task_id.to_string unavailable);
      Alcotest.(check bool)
        "unavailable error remains visible"
        true
        (String.length error > 0)
    | Keeper_world_observation_inputs.No_current_task
    | Keeper_world_observation_inputs.Current_task _
    | Keeper_world_observation_inputs.Recovered_current_task _
    | Keeper_world_observation_inputs.Current_task_missing _ ->
      Alcotest.fail "unreadable backlog did not remain explicitly unavailable")

let test_self_authored_scoped_task_does_not_hide_peer_work () =
  with_test_env (fun config ->
    let keeper = "keeper-goal-filter-agent" in
    let meta = keeper_meta_for_goal_filter keeper in
    let _ =
      Workspace.add_task config ~goal_id:"goal-a" ~created_by:meta.name
        ~title:"Own goal routing task" ~priority:1 ~description:""
    in
    let _ =
      Workspace.add_task config ~goal_id:"goal-b" ~created_by:"peer-keeper"
        ~title:"Peer work outside active goal" ~priority:1 ~description:""
    in
    let snapshot =
      Keeper_world_observation_inputs.read_backlog_snapshot ~config ~meta
    in
    Alcotest.(check int)
      "self-authored scoped work does not suppress peer fallback"
      1
      (List.length snapshot.claimable_tasks))
;;

(* The self-authored exclusion must hold through [read_backlog_snapshot], not
   only in [task_is_self_authored_todo]: dropping the filter clause leaves every
   predicate-level test green while the feedback loop stays open. Rows are
   compared against a baseline because the fixture seeds its own tasks. *)
let test_read_backlog_snapshot_excludes_self_authored_task () =
  with_test_env (fun config ->
    let meta = keeper_meta_for_self_filter "keeper-self-filter-agent" in
    let before = Keeper_world_observation_inputs.read_backlog_snapshot ~config ~meta in
    let claimable_before = List.length before.claimable_tasks in
    let _ =
      Workspace.add_task config ~created_by:meta.name
        ~title:"self-authored routing task" ~priority:3 ~description:""
    in
    let after_self =
      Keeper_world_observation_inputs.read_backlog_snapshot ~config ~meta
    in
    Alcotest.(check int)
      "a keeper's own task is not offered back to it as claimable"
      claimable_before
      (List.length after_self.claimable_tasks);
    let _ =
      Workspace.add_task config ~created_by:"peer-keeper"
        ~title:"peer authored task" ~priority:3 ~description:""
    in
    let after_peer =
      Keeper_world_observation_inputs.read_backlog_snapshot ~config ~meta
    in
    Alcotest.(check int)
      "a peer-authored task is still claimable"
      (claimable_before + 1)
      (List.length after_peer.claimable_tasks);
    Alcotest.(check int)
      "the unclaimed count still reports both tasks"
      (after_self.unclaimed_count + 1)
      after_peer.unclaimed_count
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

(** The task surface compares actors by exact identity: a task claimed under the
    canonical "keeper-bob-agent" is not transitionable by the alias
    "keeper-bob". BUG-006 once folded the two spellings, and these cases asserted
    that fold; the contract since moved the other way, and
    [test_tool_task_coverage]'s [handle_transition_submit_rejects_registered_keeper_alias]
    pins the rejection on a CI-wired path. Callers reach the surface through
    [Keeper_tool_shared_runtime.keeper_agent_sender], which yields
    [meta.agent_name], so the canonical spelling is what a keeper actually
    passes. These assert the rejection rather than the fold, and name the owning
    identity so an ownership refusal reads differently from an FSM one. *)
let test_bug006_transition_with_unsuffixed_name () =
  with_test_env (fun config ->
    (* Join with canonical agent name to establish the identity recorded at claim time *)
    let _ = Workspace.bind_session config ~agent_name:"keeper-bob-agent" ~capabilities:["code"] () in
    let _ = Workspace.add_task config ~title:"BUG-006 Task" ~priority:1 ~description:"" in
    (* Claim using the canonical name — assignee is recorded as "keeper-bob-agent" *)
    (match Workspace.claim_task_r config ~agent_name:"keeper-bob-agent" ~task_id:"task-001" () with
     | Ok _ -> ()
     | Error e -> Alcotest.failf "claim failed: %s" (Masc_domain.show_masc_error e));
    (match Workspace.transition_task_r config ~agent_name:"keeper-bob" ~task_id:"task-001"
             ~action:Masc_domain.Start () with
     | Ok _ -> Alcotest.fail "alias start was accepted for a canonically claimed task"
     | Error e ->
       let message = Masc_domain.show_masc_error e in
       Alcotest.(check bool)
         "refusal names the owning identity"
         true
         (str_contains message "keeper-bob-agent"))
  )

let test_bug006_cancel_with_unsuffixed_name () =
  with_test_env (fun config ->
    let _ = Workspace.bind_session config ~agent_name:"keeper-bob-agent" ~capabilities:["code"] () in
    let _ = Workspace.add_task config ~title:"BUG-006 Cancel Task" ~priority:1 ~description:"" in
    (match Workspace.claim_task_r config ~agent_name:"keeper-bob-agent" ~task_id:"task-001" () with
     | Ok _ -> ()
     | Error e -> Alcotest.failf "claim failed: %s" (Masc_domain.show_masc_error e));
    (match Workspace.transition_task_r config ~agent_name:"keeper-bob" ~task_id:"task-001"
             ~action:Masc_domain.Cancel ~reason:"test" () with
     | Ok _ -> Alcotest.fail "alias cancel was accepted for a canonically claimed task"
     | Error e ->
       let message = Masc_domain.show_masc_error e in
       Alcotest.(check bool)
         "refusal names the owning identity"
         true
         (str_contains message "keeper-bob-agent"))
  )

(* === Idle loop stop signal tests === *)

(* #26123 stopped the runtime choosing the agent's next tool, and the prose
   "STOP calling keeper_tasks_list" went with it. The listing states what is
   there and leaves the next call to the caller; the sibling test below already
   reads the typed variant for an empty claim pool. Assert the fact and assert
   the prescription stays out, so re-adding it fails here. *)
let test_empty_backlog_stop_signal () =
  with_test_env (fun config ->
    let result = Workspace.list_tasks config in
    Alcotest.(check string) "empty backlog states the fact" "No tasks." result;
    Alcotest.(check bool)
      "listing does not prescribe the next call"
      false
      (str_contains result "STOP calling"))

let test_no_active_tasks_stop_signal () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Done Task" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"alice" ~task_id:"task-001" in
    let _ = transition_done config ~agent_name:"alice" ~task_id:"task-001" ~notes:"done" in
    let result = Workspace.list_tasks config in
    Alcotest.(check string)
      "no active tasks states the fact"
      "No active tasks (all done/cancelled)."
      result;
    Alcotest.(check bool)
      "listing does not prescribe the next call"
      false
      (str_contains result "STOP calling"))

let test_no_unclaimed_tasks_stop_signal () =
  with_test_env (fun config ->
    let _ = Workspace.add_task config ~title:"Claimed" ~priority:1 ~description:"" in
    let _ = Workspace.claim_task config ~agent_name:"alice" ~task_id:"task-001" in
    (* The empty claim pool is a typed variant, not a prose signal. *)
    match Workspace.claim_next_r config ~agent_name:"bob" () with
    | Masc_domain.Claim_next_no_unclaimed -> ()
    | _ -> Alcotest.fail "expected Claim_next_no_unclaimed")


(* An absent backlog and a malformed one demand different operator actions, so
   the read must not report the first as the second. [read_json_result] answers a
   missing key with an empty object, which decodes as a schema violation unless
   absence is split out first (#29562). *)

let temp_workspace_dir () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_backlog_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000000.)))
  in
  Unix.mkdir dir 0o755;
  dir

let schema_complaint = "must contain exactly one tasks list"

let test_absent_backlog_is_not_reported_as_malformed () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = temp_workspace_dir () in
  let config = workspace_config tmp_dir in
  (match Workspace_backlog.read_backlog_observation_with_source_r config with
   | Ok _ -> Alcotest.fail "an absent backlog must not read as a backlog"
   | Error message ->
     Alcotest.(check bool)
       "names the absent primary"
       true
       (str_contains message "no backlog at");
     Alcotest.(check bool)
       "names the absent recovery mirror"
       true
       (str_contains message "no recovery mirror at");
     Alcotest.(check bool)
       "does not claim a schema violation"
       false
       (str_contains message schema_complaint));
  let _ = Workspace.reset config in
  ()

let test_malformed_backlog_still_reports_the_schema () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir = temp_workspace_dir () in
  let config = workspace_config tmp_dir in
  let _ = Workspace.init config ~agent_name:None in
  Workspace_utils.write_json config (Workspace.backlog_path config) (`Assoc []);
  (match Workspace_backlog.read_backlog_observation_with_source_r config with
   | Ok _ -> Alcotest.fail "an empty object is not a backlog"
   | Error message ->
     Alcotest.(check bool)
       "reports the schema violation"
       true
       (str_contains message schema_complaint);
     Alcotest.(check bool)
       "does not claim the file is absent"
       false
       (str_contains message "no backlog at"));
  let _ = Workspace.reset config in
  ()

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

    (* === Heartbeat Tests === *)
    "heartbeat", [
      Alcotest.test_case "updates last_seen" `Quick test_heartbeat_updates_lastseen;
      Alcotest.test_case "default join keeps bound status" `Quick test_is_agent_session_bound_after_default_join;
      Alcotest.test_case "nonexistent agent" `Quick test_heartbeat_nonexistent_agent;
      Alcotest.test_case "backend bootstrap preserves workspace state" `Quick test_workspace_bootstrap_preserves_backend_state;
      Alcotest.test_case "bootstrap ignores invalid workspace id in flat mode" `Quick test_workspace_bootstrap_ignores_invalid_workspace_id_in_flat_mode;
      Alcotest.test_case "read_backlog_r rejects non-authoritative recovery" `Quick
        test_read_backlog_r_rejects_non_authoritative_recovery;
      Alcotest.test_case "read_backlog_r rejects invalid-revision recovery" `Quick
        test_read_backlog_r_rejects_recovery_after_invalid_primary_revision;
      Alcotest.test_case "write_backlog_result rejects revision overflow" `Quick
        test_write_backlog_result_rejects_revision_overflow;
      Alcotest.test_case "read_backlog_r reports parse error when recovery also invalid" `Quick
        test_read_backlog_r_reports_parse_error_when_recovery_is_also_invalid;
      Alcotest.test_case "fd pressure exn is not broken JSON" `Quick test_fd_pressure_exn_classification;
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
      Alcotest.test_case "xss in agent name" `Quick test_xss_in_agent_name;
      Alcotest.test_case "xss in message type" `Quick test_xss_in_message_type;
    ];

    (* === RFC-0323 G-3: state-keyed completion side effects === *)
    "done_side_effects", [
      Alcotest.test_case "approve completion credits assignee" `Quick
        test_approve_completion_credits_assignee;
      Alcotest.test_case "operator rejection rebinds producer" `Quick
        test_operator_rejection_rebinds_producer;
      Alcotest.test_case "operator verdict boundary is reachable" `Quick
        test_operator_verdict_boundary_is_reachable;
      Alcotest.test_case "operator rejection parser requires reason" `Quick
        test_operator_verdict_parser_rejects_reasonless_rejection;
      Alcotest.test_case "operator rejection requires non-empty reason" `Quick
        test_verdict_rejects_blank_rejection_reason;
    ];

    (* === RFC-0323 G-1: verification-required done guard === *)
    "verification_guard", [
      Alcotest.test_case "strict task done requires verification submission" `Quick
        test_strict_task_done_requires_verification_submission;
      Alcotest.test_case "default task done requires verification submission" `Quick
        test_default_task_done_requires_verification_submission;
    ];

    "cancel_verification", [
      Alcotest.test_case "cancel writes the record the authority reads" `Quick
        test_cancel_writes_the_record_the_authority_reads;
      Alcotest.test_case "cancel takes its reason from the handoff summary" `Quick
        test_cancel_takes_its_reason_from_the_handoff_summary;
    ];

    (* === Board Admin Tests === *)
    "board_admin", [
      Alcotest.test_case "audit orphan tasks" `Quick test_audit_orphan_tasks;
      Alcotest.test_case
        "audit orphan awaiting verification tasks"
        `Quick
        test_audit_orphan_awaiting_verification_tasks;
      Alcotest.test_case "audit orphan ignores elapsed last_seen" `Quick
        test_audit_orphan_ignores_elapsed_last_seen_for_active_agent;
      Alcotest.test_case "audit orphan requires exact identity" `Quick
        test_audit_orphan_requires_exact_registered_identity;
      Alcotest.test_case "backlog snapshot excludes self-owned orphan" `Quick
        test_read_backlog_snapshot_excludes_self_owned_orphan;
      Alcotest.test_case "backlog snapshot falls back to unscoped claimable"
        `Quick
        test_read_backlog_snapshot_falls_back_to_unscoped_claimable_task;
      Alcotest.test_case "backlog snapshot preserves unreadable observation" `Quick
        test_read_backlog_snapshot_preserves_unreadable_observation;
      Alcotest.test_case "read current task preserves unavailable and missing" `Quick
        test_read_current_task_preserves_unavailable_and_missing;
      Alcotest.test_case "self-authored scoped task does not hide peer work"
        `Quick
        test_self_authored_scoped_task_does_not_hide_peer_work;
      Alcotest.test_case "backlog snapshot excludes self-authored task"
        `Quick
        test_read_backlog_snapshot_excludes_self_authored_task;
      Alcotest.test_case "keeper tasks audit excludes self-owned orphan" `Quick
        test_keeper_tasks_audit_excludes_self_owned_orphan;
    ];

    (* === Lifecycle Bug Fix Tests (#1655) === *)
    "lifecycle_bugs", [
      Alcotest.test_case "BUG-1: rejoin event log" `Quick test_rejoin_event_log;
      Alcotest.test_case "BUG-6: heartbeat concurrent start/stop" `Quick test_heartbeat_concurrent_start_stop;
    ];

    (* === BUG-006: Task identity mismatch (unsuffixed keeper name) === *)
    "task_identity", [
      Alcotest.test_case "BUG-006: transition/complete with unsuffixed name" `Quick test_bug006_transition_with_unsuffixed_name;
      Alcotest.test_case "BUG-006: cancel with unsuffixed name" `Quick test_bug006_cancel_with_unsuffixed_name;
    ];


    "backlog_absence", [
      Alcotest.test_case "absent backlog is not reported as malformed" `Quick test_absent_backlog_is_not_reported_as_malformed;
      Alcotest.test_case "malformed backlog still reports the schema" `Quick test_malformed_backlog_still_reports_the_schema;
    ];

    (* === Idle loop stop signal tests === *)
    "idle_stop_signals", [
      Alcotest.test_case "empty backlog has stop signal" `Quick test_empty_backlog_stop_signal;
      Alcotest.test_case "no active tasks has stop signal" `Quick test_no_active_tasks_stop_signal;
      Alcotest.test_case "no unclaimed tasks has stop signal" `Quick test_no_unclaimed_tasks_stop_signal;
    ];
  ]
