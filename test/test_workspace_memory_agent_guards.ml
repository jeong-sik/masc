open Masc

let with_memory_test_env f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let tmp_dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc_mem_agent_guards_%d_%d"
         (Unix.getpid ())
         (int_of_float (Unix.gettimeofday () *. 1000.)))
  in
  Unix.mkdir tmp_dir 0o755;
  let backend_config : Backend_types.config =
    { base_path = Filename.concat tmp_dir Common.masc_dirname
    ; node_id = "test-node"
    ; cluster_name = "default"
    ; pubsub_max_messages = 1000
    }
  in
  let memory_backend = Backend.Memory.create () in
  let config : Workspace_utils.config =
    { base_path = tmp_dir
    ; workspace_path = tmp_dir
    ; lock_expiry_minutes = 30
    ; backend_config
    ; backend = Workspace_utils.Memory memory_backend
    }
  in
  ignore (Workspace.init config ~agent_name:(Some "memory-agent"));
  Fun.protect
    ~finally:(fun () ->
      ignore (Workspace.reset config);
      Unix.rmdir tmp_dir)
    (fun () -> f config)
;;

let agent_name config =
  match Workspace.get_agents_raw config with
  | [ agent ] -> agent.Masc_domain.name
  | agents -> Alcotest.failf "expected one memory agent, got %d" (List.length agents)
;;

let agent_file config =
  Filename.concat
    (Workspace.agents_dir config)
    (Workspace.safe_filename (agent_name config) ^ ".json")
;;

let set_stale_current_task config task_id =
  let path = agent_file config in
  let agent =
    match Workspace.read_json config path |> Masc_domain.agent_of_yojson with
    | Ok agent -> agent
    | Error msg -> Alcotest.failf "agent fixture is invalid: %s" msg
  in
  Workspace.write_json config path
    (Masc_domain.agent_to_yojson
       { agent with status = Masc_domain.Busy; current_task = Some task_id })
;;

let current_task config =
  match Workspace.read_json config (agent_file config) |> Masc_domain.agent_of_yojson with
  | Ok agent -> agent.current_task
  | Error msg -> Alcotest.failf "agent read failed: %s" msg
;;

let assert_backend_child_without_parent config =
  Workspace_utils.delete_path config (Workspace.agents_dir config);
  Alcotest.(check bool)
    "agents parent key is absent"
    false
    (Workspace_utils.path_exists config (Workspace.agents_dir config));
  let listed = Workspace_utils.list_dir config (Workspace.agents_dir config) in
  let expected_name =
    Workspace.safe_filename (agent_name config) ^ ".json"
  in
  if not (List.mem expected_name listed)
  then
    let backend_keys =
      match Workspace_utils.key_of_path config (Workspace.agents_dir config) with
      | None -> []
      | Some prefix ->
        (match Workspace_utils.backend_list_keys config ~prefix:(prefix ^ ":") with
         | Ok keys -> keys
         | Error _ -> [])
    in
    Alcotest.failf
      "agent child key is missing; listed=%s backend_keys=%s"
      (String.concat "," listed)
      (String.concat "," backend_keys)
;;

let test_memory_cache_desync_clears_agent_child_key () =
  with_memory_test_env (fun config ->
    let task_id = "task-memory-cache-desync" in
    assert_backend_child_without_parent config;
    set_stale_current_task config task_id;
    (Atomic.get Workspace_hooks.cache_desync_cleared_fn)
      config
      ~module_name:"test"
      ~task_id
      ~status:"done";
    Alcotest.(check (option string))
      "cache desync clears child-key agent"
      None
      (current_task config))
;;

let test_memory_reconcile_sweeps_agent_child_key () =
  with_memory_test_env (fun config ->
    let task_id = "task-memory-reconcile" in
    assert_backend_child_without_parent config;
    set_stale_current_task config task_id;
    Workspace.reconcile_all_agent_current_tasks_with_backlog
      config
      (Workspace.read_backlog config);
    Alcotest.(check (option string))
      "reconcile clears child-key agent"
      None
      (current_task config))
;;

let () =
  Alcotest.run
    "workspace-memory-agent-guards"
    [ ( "memory backend"
      , [ Alcotest.test_case
            "cache desync scans child keys"
            `Quick
            test_memory_cache_desync_clears_agent_child_key
        ; Alcotest.test_case
            "reconcile scans child keys"
            `Quick
            test_memory_reconcile_sweeps_agent_child_key
        ] ) ]
;;
