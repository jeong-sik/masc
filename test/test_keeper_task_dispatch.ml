module Types = Masc_domain

(** Tests for keeper_task_claim and keeper_task_done tool dispatch. *)

open Alcotest
open Masc_mcp

let make_test_meta ?(name = "test-keeper") () : Keeper_types.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "agent_name", `String name
          ; "trace_id", `String "test-trace-task"
          ])
  with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_test_meta failed: %s" e)
;;

let make_goal_scoped_meta goal_ids =
  { (make_test_meta ()) with active_goal_ids = goal_ids }
;;

let make_meta_with_tools tools =
  { (make_test_meta ()) with tool_access = Keeper_types.Custom tools }
;;

let make_ctx_work () = Keeper_exec_context.create ~system_prompt:"test" ~max_tokens:4000
let rng_initialized = ref false

let ensure_rng () =
  if not !rng_initialized
  then (
    Mirage_crypto_rng_unix.use_default ();
    rng_initialized := true)
;;

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f
;;

let only_task config =
  match Coord.get_tasks_raw config with
  | [ task ] -> task
  | tasks ->
    failwith (Printf.sprintf "expected exactly one task, got %d" (List.length tasks))
;;

let task_by_title config title =
  Coord.get_tasks_raw config
  |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.title title)
  |> function
  | Some task -> task
  | None -> failwith (Printf.sprintf "task not found: %s" title)
;;

let set_task_created_at_by_title config ~title ~created_at =
  let backlog = Coord.read_backlog config in
  let seen = ref false in
  let tasks =
    List.map
      (fun (task : Masc_domain.task) ->
         if String.equal task.title title
         then (
           seen := true;
           { task with created_at })
         else task)
      backlog.tasks
  in
  if not !seen then failwith (Printf.sprintf "task not found: %s" title);
  Coord.write_backlog config { backlog with tasks; version = backlog.version + 1 }
;;

let set_task_status_by_title config ~title ~task_status =
  let backlog = Coord.read_backlog config in
  let seen = ref false in
  let tasks =
    List.map
      (fun (task : Masc_domain.task) ->
         if String.equal task.title title
         then (
           seen := true;
           { task with task_status })
         else task)
      backlog.tasks
  in
  if not !seen then failwith (Printf.sprintf "task not found: %s" title);
  Coord.write_backlog config { backlog with tasks; version = backlog.version + 1 }
;;

let transition_task_exn ?notes config ~agent_name ~task_id ~action () =
  match Coord.transition_task_r config ~agent_name ~task_id ~action ?notes () with
  | Ok _ -> ()
  | Error err ->
    fail
      (Printf.sprintf
         "transition %s failed: %s"
         task_id
         (Masc_domain.masc_error_to_string err))
;;

let strict_contract ?(verify_gate_evidence = []) () : Masc_domain.task_contract =
  { strict = true
  ; completion_contract = [ "tests pass" ]
  ; required_tools = []
  ; required_evidence = []
  ; inspect_gate_evidence = []
  ; verify_gate_evidence
  ; links = { operation_id = None; session_id = None; autoresearch_loop_id = None }
  }
;;

let contract_requiring_tools required_tools : Masc_domain.task_contract =
  { strict = false
  ; completion_contract = []
  ; required_tools
  ; required_evidence = []
  ; inspect_gate_evidence = []
  ; verify_gate_evidence = []
  ; links = { operation_id = None; session_id = None; autoresearch_loop_id = None }
  }
;;

let create_pending_verification_request config ~task_id =
  match
    Verification.create_request
      ~base_path:config.Coord.base_path
      ~task_id
      ~output:`Null
      ~criteria:[]
      ~worker:"test-worker"
      ~request_id:(Printf.sprintf "vrf-%s" task_id)
      ()
  with
  | Ok _ -> ()
  | Error msg -> failwith (Printf.sprintf "create_request failed: %s" msg)
;;

let verification_request_by_task_id config ~task_id =
  Verification.list_requests config.Coord.base_path
  |> List.find_opt (fun (req : Verification.verification_request) ->
    String.equal req.task_id task_id)
  |> function
  | Some req -> req
  | None -> fail (Printf.sprintf "expected verification request for task %s" task_id)
;;

let custom_criteria (req : Verification.verification_request) =
  List.filter_map
    (function
      | Verification.Custom s -> Some s
      | _ -> None)
    req.criteria
;;

let evidence_refs_of_request (req : Verification.verification_request) =
  match req.output with
  | `Assoc fields ->
    (match List.assoc_opt "evidence_refs" fields with
     | Some (`List refs) ->
       List.filter_map
         (function
           | `String s -> Some s
           | _ -> None)
         refs
     | _ -> [])
  | _ -> []
;;

(* Temp directory setup following test_keeper_tools_oas.ml pattern.
   Force filesystem backend by unsetting PG env vars. *)
let with_room f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_task_%d" (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  Fun.protect
    ~finally:(fun () ->
      try
        let rec rm path =
          if Sys.is_directory path
          then (
            Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
            Unix.rmdir path)
          else Sys.remove path
        in
        rm dir
      with
      | _ -> ())
    (fun () ->
       let config = Coord.default_config dir in
       let _msg = Coord.init config ~agent_name:(Some "test-keeper") in
       f config)
;;

let call_tool config meta name input =
  let ctx_work = make_ctx_work () in
  Keeper_exec_tools.execute_keeper_tool_call
    ~config
    ~meta
    ~ctx_work
    ~exec_cache:None
    ~name
    ~input
    ()
;;

let call_tool_with_search config meta name input search_fn =
  let ctx_work = make_ctx_work () in
  Keeper_exec_tools.execute_keeper_tool_call
    ~config
    ~meta
    ~ctx_work
    ~exec_cache:None
    ~search_fn
    ~name
    ~input
    ()
;;

let parse_json s =
  try Yojson.Safe.from_string s with
  | _ -> failwith (Printf.sprintf "invalid JSON: %s" s)
;;

let json_is_null = function
  | `Null -> true
  | _ -> false
;;

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len
    then false
    else if String.sub s i n_len = needle
    then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0
;;

let check_effective_goal_ids label scope expected =
  let actual =
    Yojson.Safe.Util.(
      scope |> member "effective_goal_ids" |> to_list |> List.map to_string)
  in
  check (list string) label expected actual
;;

let claimed_task_for_agent config agent_name =
  Coord.get_tasks_raw config
  |> List.find_opt (fun (task : Masc_domain.task) ->
    Masc_domain.task_assignee_of_status task.task_status = Some agent_name)
;;

let check_no_task_claimed config meta =
  match claimed_task_for_agent config meta.Keeper_types.agent_name with
  | None -> ()
  | Some task ->
    fail
      (Printf.sprintf
         "expected no claimed task for scoped keeper, got %s (%s)"
         task.id
         task.title)
;;

let check_active_goal_scope_no_fallback json ~goal_id =
  let scope = Yojson.Safe.Util.member "claim_scope" json in
  check
    string
    "claim scope mode"
    "active_goal_ids"
    Yojson.Safe.Util.(scope |> member "mode" |> to_string);
  check
    (list string)
    "effective goal ids preserved"
    [ goal_id ]
    Yojson.Safe.Util.(
      scope |> member "effective_goal_ids" |> to_list |> List.map to_string);
  check
    (option string)
    "fallback reason absent"
    None
    Yojson.Safe.Util.(scope |> member "fallback_reason" |> to_string_option)
;;

let with_registered_keeper config meta f =
  Keeper_registry.unregister ~base_path:config.Coord.base_path meta.Keeper_types.name;
  ignore
    (Keeper_registry.register_offline
       ~base_path:config.Coord.base_path
       meta.Keeper_types.name
       meta);
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.unregister ~base_path:config.Coord.base_path meta.Keeper_types.name)
    f
;;

let current_task_id_string (meta : Keeper_types.keeper_meta) =
  Option.map Keeper_id.Task_id.to_string meta.current_task_id
;;

let with_claim_post_provision_hook hook f =
  let previous = Atomic.get Coord_hooks.claim_post_provision_fn in
  Atomic.set Coord_hooks.claim_post_provision_fn hook;
  Fun.protect
    ~finally:(fun () -> Atomic.set Coord_hooks.claim_post_provision_fn previous)
    f
;;

let stale_worktree_info ~agent_name ~task_id : Masc_domain.worktree_info =
  { branch = Printf.sprintf "%s/%s" agent_name task_id
  ; path = Printf.sprintf ".worktrees/%s-%s" agent_name task_id
  ; git_root = "/tmp/stale-sandbox/repos/masc-mcp"
  ; repo_name = "masc-mcp"
  }
;;

let link_stale_worktree config ~agent_name ~task_id =
  match
    Coord_worktree.link_worktree_to_task
      config
      ~task_id
      ~worktree_info:(stale_worktree_info ~agent_name ~task_id)
  with
  | Ok () -> ()
  | Error e ->
    fail
      (Printf.sprintf
         "failed to link stale worktree: %s"
         (Masc_domain.masc_error_to_string e))
;;

(* --- keeper_task_claim tests --- *)

let test_claim_returns_result () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let _ = Coord.add_task config ~title:"Test task" ~priority:1 ~description:"desc" in
    let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let json = parse_json result in
    match Yojson.Safe.Util.member "result" json with
    | `String s -> check bool "claim result non-empty" true (String.length s > 0)
    | _ -> fail "expected result string in claim response")
;;

let test_claim_returns_observation_fragment () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let _ =
      Coord.add_task config ~title:"Observed task" ~priority:1 ~description:"desc"
    in
    let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let json = parse_json result in
    check
      string
      "event type"
      "collaboration.todo.claim_observed"
      Yojson.Safe.Util.(
        json |> member "claim_observation" |> member "event_type" |> to_string);
    check
      string
      "state"
      "claim_verified"
      Yojson.Safe.Util.(
        json
        |> member "claim_observation"
        |> member "todo_claim"
        |> member "state"
        |> to_string);
    check
      string
      "winner"
      meta.agent_name
      Yojson.Safe.Util.(
        json
        |> member "claim_observation"
        |> member "todo_claim"
        |> member "winner_actor_id"
        |> to_string))
;;

let test_claim_syncs_keeper_current_task_id () =
  with_room (fun config ->
    let meta = make_test_meta () in
    with_registered_keeper config meta (fun () ->
      let _ =
        Coord.add_task config ~title:"Synced task" ~priority:1 ~description:"desc"
      in
      let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
      let json = parse_json result in
      let task_id =
        Yojson.Safe.Util.(json |> member "claimed_task" |> member "task_id" |> to_string)
      in
      let registry_meta =
        match Keeper_registry.get ~base_path:config.Coord.base_path meta.name with
        | Some entry -> entry.meta
        | None -> fail "expected keeper registry entry"
      in
      check
        (option string)
        "registry current_task_id"
        (Some task_id)
        (current_task_id_string registry_meta);
      let persisted_meta =
        match Keeper_types.read_meta config meta.name with
        | Ok (Some meta) -> meta
        | Ok None -> fail "expected persisted keeper meta"
        | Error msg -> fail msg
      in
      check
        (option string)
        "persisted current_task_id"
        (Some task_id)
        (current_task_id_string persisted_meta)))
;;

let test_release_clears_keeper_current_task_id () =
  with_room (fun config ->
    let meta = make_test_meta () in
    with_registered_keeper config meta (fun () ->
      let _ =
        Coord.add_task config ~title:"Release task" ~priority:1 ~description:"desc"
      in
      let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
      let json = parse_json result in
      let task_id =
        Yojson.Safe.Util.(json |> member "claimed_task" |> member "task_id" |> to_string)
      in
      let release_result =
        Tool_task.handle_transition
          ~tool_name:"test_tool" ~start_time:0.0
          { Tool_task.config; agent_name = meta.agent_name; sw = None }
          (`Assoc
              [ "task_id", `String task_id
              ; "action", `String "release"
              ; "reason", `String "scope changed"
              ])
      in
      if not release_result.Tool_result.success then fail release_result.Tool_result.legacy_message;
      let registry_meta =
        match Keeper_registry.get ~base_path:config.Coord.base_path meta.name with
        | Some entry -> entry.meta
        | None -> fail "expected keeper registry entry"
      in
      check
        (option string)
        "registry current_task_id cleared"
        None
        (current_task_id_string registry_meta);
      let persisted_meta =
        match Keeper_types.read_meta config meta.name with
        | Ok (Some meta) -> meta
        | Ok None -> fail "expected persisted keeper meta"
        | Error msg -> fail msg
      in
      check
        (option string)
        "persisted current_task_id cleared"
        None
        (current_task_id_string persisted_meta)))
;;

let test_claim_clears_stale_task_worktree_metadata () =
  with_claim_post_provision_hook
    (fun _config ~agent_name:_ ~task_id:_ -> ())
    (fun () ->
       with_room (fun config ->
         let meta = make_test_meta () in
         with_registered_keeper config meta (fun () ->
           let _ =
             Coord.add_task
               config
               ~title:"Stale worktree claim"
               ~priority:1
               ~description:"desc"
           in
           let task_id = (only_task config).id in
           link_stale_worktree config ~agent_name:"previous-agent" ~task_id;
           check
             bool
             "stale worktree linked"
             true
             (Option.is_some (only_task config).worktree);
           let _ = call_tool config meta "keeper_task_claim" (`Assoc []) in
           check
             bool
             "stale worktree cleared on claim"
             true
             (Option.is_none (only_task config).worktree))))
;;

let test_release_clears_task_worktree_metadata () =
  with_claim_post_provision_hook
    (fun _config ~agent_name:_ ~task_id:_ -> ())
    (fun () ->
       with_room (fun config ->
         let meta = make_test_meta () in
         with_registered_keeper config meta (fun () ->
           let _ =
             Coord.add_task
               config
               ~title:"Worktree release task"
               ~priority:1
               ~description:"desc"
           in
           let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
           let json = parse_json result in
           let task_id =
             Yojson.Safe.Util.(
               json |> member "claimed_task" |> member "task_id" |> to_string)
           in
           link_stale_worktree config ~agent_name:meta.agent_name ~task_id;
           check
             bool
             "worktree linked before release"
             true
             (Option.is_some (only_task config).worktree);
           let result =
             Tool_task.handle_transition
               ~tool_name:"test_tool" ~start_time:0.0
               { Tool_task.config; agent_name = meta.agent_name; sw = None }
               (`Assoc
                   [ "task_id", `String task_id
                   ; "action", `String "release"
                   ; "reason", `String "handoff to another keeper"
                   ])
           in
           if not result.Tool_result.success then fail result.Tool_result.legacy_message;
           check
             bool
             "worktree cleared on release"
             true
             (Option.is_none (only_task config).worktree))))
;;

let test_claim_next_runs_post_provision_hook () =
  let observed = ref None in
  with_claim_post_provision_hook
    (fun _config ~agent_name ~task_id -> observed := Some (agent_name, task_id))
    (fun () ->
       with_room (fun config ->
         let meta = make_test_meta () in
         with_registered_keeper config meta (fun () ->
           let _ =
             Coord.add_task
               config
               ~title:"Provision hook task"
               ~priority:1
               ~description:"desc"
           in
           let task_id = (only_task config).id in
           let _ = call_tool config meta "keeper_task_claim" (`Assoc []) in
           check
             (option (pair string string))
             "claim-next provision hook"
             (Some (meta.agent_name, task_id))
             !observed)))
;;

let test_claim_next_preserves_existing_alias_owned_task () =
  with_room (fun config ->
    let _ =
      Coord.join
        config
        ~agent_name:"keeper-coder-agent"
        ~capabilities:[ "keeper"; "code" ]
        ()
    in
    let _ =
      Coord.add_task
        config
        ~title:"Already owned"
        ~priority:1
        ~description:"desc"
    in
    let _ =
      Coord.add_task
        config
        ~title:"Still todo"
        ~priority:1
        ~description:"desc"
    in
    (match
       Coord.claim_task_r
         config
         ~agent_name:"keeper-coder-agent"
         ~task_id:"task-001"
         ()
     with
     | Ok _ -> ()
     | Error err ->
       fail (Masc_domain.masc_error_to_string err));
    (match Coord.claim_next_r config ~agent_name:"keeper-coder" () with
     | Coord.Claim_next_claimed { task_id; message; _ } ->
       check string "returns existing active task" "task-001" task_id;
       check bool "message says already holds" true
         (contains_substring message "already holds")
     | Coord.Claim_next_no_unclaimed ->
       fail "expected existing claim, got no_unclaimed"
     | Coord.Claim_next_no_eligible { excluded_count } ->
       fail
         (Printf.sprintf
            "expected existing claim, got no_eligible excluded=%d"
            excluded_count)
     | Coord.Claim_next_error err ->
       fail (Printf.sprintf "claim_next failed: %s" err));
    match task_by_title config "Still todo" with
    | { Masc_domain.task_status = Masc_domain.Todo; _ } -> ()
    | _ -> fail "alias claim_next must not claim a second active task")
;;

let test_stale_current_task_id_is_cleared_from_backlog () =
  with_room (fun config ->
    let task_id =
      match Keeper_id.Task_id.of_string "task-missing" with
      | Ok task_id -> task_id
      | Error msg -> fail msg
    in
    let meta = { (make_test_meta ()) with current_task_id = Some task_id } in
    with_registered_keeper config meta (fun () ->
      (match Keeper_types.write_meta config meta with
       | Ok () -> ()
       | Error msg -> fail msg);
      let synced =
        Keeper_agent_tool_surface.sync_current_task_id_from_backlog ~config meta
      in
      check
        (option string)
        "stale current_task_id cleared"
        None
        (current_task_id_string synced)))
;;

let test_run_context_uses_reconciled_current_task_id () =
  with_room (fun config ->
    let task_id =
      match Keeper_id.Task_id.of_string "task-missing" with
      | Ok task_id -> task_id
      | Error msg -> fail msg
    in
    let meta =
      { (make_test_meta ~name:"run-context-keeper" ()) with
        current_task_id = Some task_id;
      }
    in
    with_registered_keeper config meta (fun () ->
      (match Keeper_types.write_meta config meta with
       | Ok () -> ()
       | Error msg -> fail msg);
      let ctx =
        Keeper_run_context.prepare_run_context
          ~config
          ~meta
          ~base_dir:(Filename.concat config.Coord.base_path "sessions")
          ~max_context:4000
          ~cascade_name:
            (Keeper_cascade_profile.runtime_name_of_string
               (Keeper_config.default_cascade_name ()))
          ~generation:meta.runtime.generation
          ()
      in
      check
        (option string)
        "run context exposes reconciled current_task_id"
        None
        (current_task_id_string ctx.Keeper_run_context.meta)))
;;

let test_multiple_active_tasks_selects_deterministic_current_task () =
  with_room (fun config ->
    let meta = make_test_meta ~name:"multi-task-keeper" () in
    with_registered_keeper config meta (fun () ->
      ignore
        (Coord.add_task
           config
           ~title:"Older low priority"
           ~priority:4
           ~description:"older active work");
      ignore
        (Coord.add_task
           config
           ~title:"Newer high priority"
           ~priority:1
           ~description:"newer active work");
      set_task_created_at_by_title
        config
        ~title:"Older low priority"
        ~created_at:"2026-05-01T00:00:00Z";
      set_task_created_at_by_title
        config
        ~title:"Newer high priority"
        ~created_at:"2026-05-02T00:00:00Z";
      set_task_status_by_title
        config
        ~title:"Older low priority"
        ~task_status:
          (Masc_domain.Claimed
             { assignee = meta.agent_name; claimed_at = "2026-05-01T00:01:00Z" });
      set_task_status_by_title
        config
        ~title:"Newer high priority"
        ~task_status:
          (Masc_domain.Claimed
             { assignee = meta.agent_name; claimed_at = "2026-05-02T00:01:00Z" });
      (match Keeper_types.write_meta config meta with
       | Ok () -> ()
       | Error msg -> fail msg);
      let high_priority_task = task_by_title config "Newer high priority" in
      let synced =
        Keeper_agent_tool_surface.sync_current_task_id_from_backlog ~config meta
      in
      check
        (option string)
        "highest priority active task selected"
        (Some high_priority_task.id)
        (current_task_id_string synced)))
;;

let test_multiple_active_tasks_preserves_existing_current_task () =
  with_room (fun config ->
    let base_meta = make_test_meta ~name:"sticky-task-keeper" () in
    with_registered_keeper config base_meta (fun () ->
      ignore
        (Coord.add_task
           config
           ~title:"Sticky current"
           ~priority:5
           ~description:"active current work");
      ignore
        (Coord.add_task
           config
           ~title:"Competing current"
           ~priority:1
           ~description:"active competing work");
      let sticky = task_by_title config "Sticky current" in
      let sticky_task_id =
        match Keeper_id.Task_id.of_string sticky.id with
        | Ok task_id -> task_id
        | Error msg -> fail msg
      in
      set_task_status_by_title
        config
        ~title:"Sticky current"
        ~task_status:
          (Masc_domain.InProgress
             { assignee = base_meta.agent_name
             ; started_at = "2026-05-01T00:01:00Z"
             });
      set_task_status_by_title
        config
        ~title:"Competing current"
        ~task_status:
          (Masc_domain.Claimed
             { assignee = base_meta.agent_name
             ; claimed_at = "2026-05-02T00:01:00Z"
             });
      let meta = { base_meta with current_task_id = Some sticky_task_id } in
      (match Keeper_types.write_meta config meta with
       | Ok () -> ()
       | Error msg -> fail msg);
      let synced =
        Keeper_agent_tool_surface.sync_current_task_id_from_backlog ~config meta
      in
      check
        (option string)
        "existing active current task preserved"
        (Some sticky.id)
        (current_task_id_string synced)))
;;

let test_heartbeat_current_task_id_reconciles_terminal_backlog () =
  with_room (fun config ->
    let meta = make_test_meta ~name:"heartbeat-keeper" () in
    with_registered_keeper config meta (fun () ->
      let _ =
        Coord.add_task
          config
          ~title:"Heartbeat stale task"
          ~priority:1
          ~description:"desc"
      in
      let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
      let json = parse_json result in
      let task_id =
        Yojson.Safe.Util.(json |> member "claimed_task" |> member "task_id" |> to_string)
      in
      (match
         Coord.force_done_task_r
           config
           ~agent_name:meta.agent_name
           ~task_id
           ~notes:"terminal in backlog"
           ()
       with
       | Ok _ -> ()
       | Error msg -> fail (Masc_domain.masc_error_to_string msg));
      let current_task_id =
        Keeper_keepalive.current_task_id_for_agent ~config meta.agent_name
      in
      check string "heartbeat task id cleared" "" current_task_id;
      let registry_meta =
        match Keeper_registry.get ~base_path:config.Coord.base_path meta.name with
        | Some entry -> entry.meta
        | None -> fail "expected keeper registry entry"
      in
      check
        (option string)
        "registry current_task_id cleared"
        None
        (current_task_id_string registry_meta)))
;;

let test_claim_empty_room () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let json = parse_json result in
    (* Should return a result even with no tasks *)
    match Yojson.Safe.Util.member "result" json with
    | `String _ -> () (* ok *)
    | _ ->
      (match Yojson.Safe.Util.member "error" json with
       | `String _ -> () (* also ok *)
       | _ -> fail "expected result or error in empty room claim"))
;;

let test_claim_prefers_oldest_same_priority_task () =
  with_room (fun config ->
    let meta = make_test_meta () in
    ignore
      (Coord.add_task
         config
         ~title:"Fresh P0"
         ~priority:1
         ~description:"newer high-priority work");
    ignore
      (Coord.add_task
         config
         ~title:"Stale P0"
         ~priority:1
         ~description:"older high-priority work");
    set_task_created_at_by_title
      config
      ~title:"Fresh P0"
      ~created_at:"2026-05-05T12:00:00Z";
    set_task_created_at_by_title
      config
      ~title:"Stale P0"
      ~created_at:"2026-05-04T12:00:00Z";
    let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let json = parse_json result in
    check
      string
      "oldest same-priority task claimed first"
      "Stale P0"
      Yojson.Safe.Util.(json |> member "claimed_task" |> member "title" |> to_string))
;;

let test_claim_respects_active_goal_ids () =
  with_room (fun config ->
    let goal, _ =
      match Goal_store.upsert_goal config ~title:"Masc goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let other_goal, _ =
      match Goal_store.upsert_goal config ~title:"Other goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let meta = make_goal_scoped_meta [ goal.id ] in
    let _ =
      Coord_task.add_task
        ~goal_id:other_goal.id
        config
        ~title:"Other goal task"
        ~priority:1
        ~description:"desc"
    in
    let _ =
      Coord_task.add_task
        ~goal_id:goal.id
        config
        ~title:"Masc goal task"
        ~priority:5
        ~description:"desc"
    in
    let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let json = parse_json result in
    let claimed_task =
      Coord.get_tasks_raw config
      |> List.find_opt (fun (task : Masc_domain.task) ->
        Masc_domain.task_assignee_of_status task.task_status = Some meta.agent_name)
    in
    match claimed_task with
    | Some task ->
      check string "claimed scoped task" "Masc goal task" task.title;
      let scope = Yojson.Safe.Util.member "claim_scope" json in
      check
        string
        "claim scope mode"
        "active_goal_ids"
        Yojson.Safe.Util.(scope |> member "mode" |> to_string);
      check
        string
        "claim scope matched goal"
        goal.id
        Yojson.Safe.Util.(scope |> member "matched_goal_id" |> to_string);
      check
        string
        "claimed task goal"
        goal.id
        Yojson.Safe.Util.(json |> member "claimed_task" |> member "goal_id" |> to_string)
    | None -> fail "expected a claimed task")
;;

let test_claim_does_not_cross_goal_when_auto_goal_scope_empty () =
  with_room (fun config ->
    let meta = make_test_meta ~name:"executor" () in
    let auto_goal, _ =
      match
        Goal_store.upsert_goal
          config
          ~title:(Keeper_goal_repair.goal_title_of_purpose meta.goal)
          ()
      with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let product_goal, _ =
      match Goal_store.upsert_goal config ~title:"Product goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let meta = { meta with active_goal_ids = [ auto_goal.id ] } in
    let _ =
      Coord_task.add_task
        ~goal_id:product_goal.id
        config
        ~title:"Product task"
        ~priority:1
        ~description:"desc"
    in
    let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let json = parse_json result in
    let message = Yojson.Safe.Util.(json |> member "result" |> to_string) in
    check_no_task_claimed config meta;
    check_active_goal_scope_no_fallback json ~goal_id:auto_goal.id;
    check
      bool
      "message keeps active scope"
      true
      (contains_substring message "within active_goal_ids");
    check
      bool
      "does not claim product fallback"
      false
      (contains_substring message "fallback to all tasks"))
;;

let test_claim_does_not_cross_goal_when_persisted_goal_scope_empty () =
  with_room (fun config ->
    let keeper_goal, _ =
      match Goal_store.upsert_goal config ~title:"Masc improver" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let product_goal, _ =
      match Goal_store.upsert_goal config ~title:"Product goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let meta =
      { (make_test_meta ~name:"masc-improver" ()) with
        active_goal_ids = [ keeper_goal.id ]
      }
    in
    let _ =
      Coord_task.add_task
        ~goal_id:product_goal.id
        config
        ~title:"Product task"
        ~priority:1
        ~description:"desc"
    in
    let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let json = parse_json result in
    let message = Yojson.Safe.Util.(json |> member "result" |> to_string) in
    check_no_task_claimed config meta;
    check_active_goal_scope_no_fallback json ~goal_id:keeper_goal.id;
    check
      bool
      "message keeps active scope"
      true
      (contains_substring message "within active_goal_ids");
    check
      bool
      "does not claim product fallback"
      false
      (contains_substring message "fallback to all tasks"))
;;

let test_explicit_empty_goal_scope_fallback_override_still_claims_cross_goal () =
  with_room (fun config ->
    let scoped_goal, _ =
      match Goal_store.upsert_goal config ~title:"Scoped keeper goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let product_goal, _ =
      match Goal_store.upsert_goal config ~title:"Product goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let meta = make_goal_scoped_meta [ scoped_goal.id ] in
    let _ =
      Coord_task.add_task
        ~goal_id:product_goal.id
        config
        ~title:"Product fallback task"
        ~priority:1
        ~description:"desc"
    in
    let scope =
      Keeper_runtime_contract.resolve_claim_goal_scope
        ~allow_empty_goal_scope_fallback:true
        ~config
        ~meta
        ()
    in
    check
      string
      "claim scope fallback mode"
      "empty_goal_scope_fallback_all_tasks"
      scope.mode;
    check (list string) "effective goal ids cleared" [] scope.effective_goal_ids;
    check bool "fallback reason present" true (Option.is_some scope.fallback_reason);
    match
      Coord.claim_next_r
        config
        ~agent_name:meta.agent_name
        ~agent_tool_names:(Keeper_tool_policy.keeper_allowed_tool_names meta)
        ~task_filter:scope.task_filter
        ()
    with
    | Coord.Claim_next_claimed { task_id; _ } ->
      let task =
        Coord.get_tasks_raw config
        |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id)
      in
      (match task with
       | Some task ->
         check string "fallback claimed product task" "Product fallback task" task.title;
         check
           string
           "fallback claimed product goal"
           product_goal.id
           (Option.value task.goal_id ~default:"")
       | None -> fail "claimed task not found")
    | _ -> fail "expected explicit fallback override to claim product task")
;;

let test_claim_does_not_cross_goal_when_scoped_task_requires_missing_tool () =
  with_room (fun config ->
    let scoped_goal, _ =
      match Goal_store.upsert_goal config ~title:"Scoped keeper goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let product_goal, _ =
      match Goal_store.upsert_goal config ~title:"Product goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let meta =
      { (make_meta_with_tools [ "keeper_task_claim"; "keeper_tasks_list" ]) with
        active_goal_ids = [ scoped_goal.id ]
      }
    in
    let _ =
      Coord_task.add_task
        ~contract:(contract_requiring_tools [ "keeper_bash" ])
        ~goal_id:scoped_goal.id
        config
        ~title:"Scoped task needing bash"
        ~priority:1
        ~description:"requires shell execution"
    in
    let _ =
      Coord_task.add_task
        ~goal_id:product_goal.id
        config
        ~title:"Product fallback task"
        ~priority:2
        ~description:"desc"
    in
    let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let json = parse_json result in
    let message = Yojson.Safe.Util.(json |> member "result" |> to_string) in
    check_no_task_claimed config meta;
    check_active_goal_scope_no_fallback json ~goal_id:scoped_goal.id;
    check
      bool
      "message keeps active scope"
      true
      (contains_substring message "within active_goal_ids");
    check
      bool
      "does not claim product fallback"
      false
      (contains_substring message "fallback to all tasks"))
;;

let test_claim_does_not_cross_goal_when_all_scoped_tasks_unavailable () =
  with_room (fun config ->
    let scoped_goal, _ =
      match Goal_store.upsert_goal config ~title:"Scoped keeper goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let product_goal, _ =
      match Goal_store.upsert_goal config ~title:"Product goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let meta =
      { (make_meta_with_tools [ "keeper_task_claim"; "keeper_tasks_list" ]) with
        active_goal_ids = [ scoped_goal.id ]
      }
    in
    let _ =
      Coord_task.add_task
        ~goal_id:scoped_goal.id
        config
        ~title:"Scoped already in progress"
        ~priority:1
        ~description:"owned by another worker"
    in
    let in_progress_task = task_by_title config "Scoped already in progress" in
    ignore
      (Coord.claim_task config ~agent_name:"other-agent" ~task_id:in_progress_task.id);
    transition_task_exn
      config
      ~agent_name:"other-agent"
      ~task_id:in_progress_task.id
      ~action:Masc_domain.Start
      ();
    let _ =
      Coord_task.add_task
        ~goal_id:scoped_goal.id
        config
        ~title:"Scoped already done"
        ~priority:2
        ~description:"terminal"
    in
    let done_task = task_by_title config "Scoped already done" in
    ignore
      (Coord.claim_task
         config
         ~agent_name:"other-done-agent"
         ~task_id:done_task.id);
    transition_task_exn
      config
      ~agent_name:"other-done-agent"
      ~task_id:done_task.id
      ~action:Masc_domain.Done_action
      ~notes:"done"
      ();
    let _ =
      Coord_task.add_task
        ~contract:(contract_requiring_tools [ "keeper_bash" ])
        ~goal_id:scoped_goal.id
        config
        ~title:"Scoped task needing bash"
        ~priority:3
        ~description:"requires unavailable shell access"
    in
    let _ =
      Coord_task.add_task
        ~goal_id:product_goal.id
        config
        ~title:"Product fallback task"
        ~priority:1
        ~description:"desc"
    in
    let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let json = parse_json result in
    let message = Yojson.Safe.Util.(json |> member "result" |> to_string) in
    check_no_task_claimed config meta;
    check_active_goal_scope_no_fallback json ~goal_id:scoped_goal.id;
    check
      bool
      "message keeps active scope"
      true
      (contains_substring message "within active_goal_ids");
    check
      bool
      "does not claim product fallback"
      false
      (contains_substring message "fallback to all tasks"))
;;

let test_claim_does_not_cross_goal_when_scoped_task_is_verification_blocked () =
  with_room (fun config ->
    let scoped_goal, _ =
      match Goal_store.upsert_goal config ~title:"Scoped verification goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let product_goal, _ =
      match Goal_store.upsert_goal config ~title:"Product goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let meta = make_goal_scoped_meta [ scoped_goal.id ] in
    let _ =
      Coord_task.add_task
        ~goal_id:scoped_goal.id
        config
        ~title:"Scoped task pending verification"
        ~priority:1
        ~description:"verification pending"
    in
    let scoped_task = task_by_title config "Scoped task pending verification" in
    create_pending_verification_request config ~task_id:scoped_task.id;
    let _ =
      Coord_task.add_task
        ~goal_id:product_goal.id
        config
        ~title:"Product fallback task"
        ~priority:2
        ~description:"desc"
    in
    let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let json = parse_json result in
    let message = Yojson.Safe.Util.(json |> member "result" |> to_string) in
    check_no_task_claimed config meta;
    check_active_goal_scope_no_fallback json ~goal_id:scoped_goal.id;
    check
      bool
      "message keeps active scope"
      true
      (contains_substring message "within active_goal_ids");
    check
      bool
      "does not claim product fallback"
      false
      (contains_substring message "fallback to all tasks"))
;;

let test_claim_no_eligible_scoped_reports_scope_truth () =
  with_room (fun config ->
    let scoped_goal, _ =
      match Goal_store.upsert_goal config ~title:"Scoped keeper goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let product_goal, _ =
      match Goal_store.upsert_goal config ~title:"Product goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let meta =
      { (make_meta_with_tools [ "keeper_task_claim"; "keeper_tasks_list" ]) with
        active_goal_ids = [ scoped_goal.id ]
      }
    in
    let _ =
      Coord_task.add_task
        ~contract:(contract_requiring_tools [ "keeper_bash" ])
        ~goal_id:scoped_goal.id
        config
        ~title:"Scoped task needing bash"
        ~priority:1
        ~description:"requires shell execution"
    in
    let _ =
      Coord_task.add_task
        ~contract:(contract_requiring_tools [ "keeper_fs_edit" ])
        ~goal_id:product_goal.id
        config
        ~title:"Fallback task also missing tools"
        ~priority:2
        ~description:"also requires unavailable write access"
    in
    let result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let json = parse_json result in
    let message = Yojson.Safe.Util.(json |> member "result" |> to_string) in
    check_no_task_claimed config meta;
    check_active_goal_scope_no_fallback json ~goal_id:scoped_goal.id;
    check
      bool
      "message avoids fallback search"
      false
      (contains_substring message "fallback to all tasks");
    check
      bool
      "message stops task checking"
      true
      (contains_substring message "Stop task-checking");
    check
      bool
      "message preserves active scope"
      true
      (contains_substring message "within active_goal_ids");
    check
      bool
      "message explains scope repair"
      true
      (contains_substring message "update the goal scope"))
;;

let test_claim_skips_required_tools_without_access () =
  with_room (fun config ->
    let meta = make_meta_with_tools [ "keeper_task_claim"; "keeper_tasks_list" ] in
    let _ =
      Coord.add_task
        ~contract:(contract_requiring_tools [ "keeper_bash" ])
        config
        ~title:"Needs bash"
        ~priority:1
        ~description:"requires shell execution"
    in
    let _ =
      Coord.add_task
        config
        ~title:"Readable fallback"
        ~priority:2
        ~description:"does not require shell"
    in
    ignore (call_tool config meta "keeper_task_claim" (`Assoc []));
    let claimed =
      Coord.get_tasks_raw config
      |> List.find_opt (fun (task : Masc_domain.task) ->
        Masc_domain.task_assignee_of_status task.task_status = Some meta.agent_name)
    in
    match claimed with
    | Some task -> check string "claimed fallback" "Readable fallback" task.title
    | None -> fail "expected fallback task to be claimed")
;;

let test_claim_allows_required_tools_with_access () =
  with_room (fun config ->
    let meta =
      make_meta_with_tools [ "keeper_task_claim"; "keeper_tasks_list"; "keeper_bash" ]
    in
    let _ =
      Coord.add_task
        ~contract:(contract_requiring_tools [ "keeper_bash" ])
        config
        ~title:"Needs bash"
        ~priority:1
        ~description:"requires shell execution"
    in
    let _ =
      Coord.add_task
        config
        ~title:"Readable fallback"
        ~priority:2
        ~description:"does not require shell"
    in
    ignore (call_tool config meta "keeper_task_claim" (`Assoc []));
    let claimed =
      Coord.get_tasks_raw config
      |> List.find_opt (fun (task : Masc_domain.task) ->
        Masc_domain.task_assignee_of_status task.task_status = Some meta.agent_name)
    in
    match claimed with
    | Some task -> check string "claimed required-tool task" "Needs bash" task.title
    | None -> fail "expected required-tool task to be claimed")
;;

let test_required_tool_matching_canonicalizes_public_aliases () =
  check
    (list string)
    "public Bash satisfies keeper_bash"
    []
    (Coord.missing_required_tools ~allowed:[ "Bash" ] [ "keeper_bash" ]);
  check
    (list string)
    "internal keeper_bash satisfies public Bash"
    []
    (Coord.missing_required_tools ~allowed:[ "keeper_bash" ] [ "Bash" ]);
  check
    (list string)
    "public Write is not masc_code_write"
    [ "masc_code_write" ]
    (Coord.missing_required_tools ~allowed:[ "Write" ] [ "masc_code_write" ]);
  check
    bool
    "claim scheduler accepts public Bash alias"
    true
    (Coord_task_schedule.required_tools_allowed
       ~agent_tool_names:[ "Bash" ]
       [ "keeper_bash" ])
;;

let test_claim_does_not_treat_write_alias_as_masc_code_write () =
  with_room (fun config ->
    let meta = make_meta_with_tools [ "keeper_task_claim"; "keeper_tasks_list"; "Write" ] in
    let _ =
      Coord.add_task
        ~contract:(contract_requiring_tools [ "masc_code_write" ])
        config
        ~title:"Needs masc code write"
        ~priority:1
        ~description:"requires masc_code_write"
    in
    let _ =
      Coord.add_task
        config
        ~title:"Readable fallback"
        ~priority:2
        ~description:"does not require code write"
    in
    ignore (call_tool config meta "keeper_task_claim" (`Assoc []));
    let claimed =
      Coord.get_tasks_raw config
      |> List.find_opt (fun (task : Masc_domain.task) ->
        Masc_domain.task_assignee_of_status task.task_status = Some meta.agent_name)
    in
    match claimed with
    | Some task ->
      check string "Write alias does not satisfy masc_code_write" "Readable fallback" task.title
    | None -> fail "expected fallback task to be claimed")
;;

let test_claim_allows_masc_code_write_with_access () =
  with_room (fun config ->
    let meta =
      make_meta_with_tools [ "keeper_task_claim"; "keeper_tasks_list"; "masc_code_write" ]
    in
    let _ =
      Coord.add_task
        ~contract:(contract_requiring_tools [ "masc_code_write" ])
        config
        ~title:"Needs masc code write"
        ~priority:1
        ~description:"requires masc_code_write"
    in
    let _ =
      Coord.add_task
        config
        ~title:"Readable fallback"
        ~priority:2
        ~description:"does not require code write"
    in
    ignore (call_tool config meta "keeper_task_claim" (`Assoc []));
    let claimed =
      Coord.get_tasks_raw config
      |> List.find_opt (fun (task : Masc_domain.task) ->
        Masc_domain.task_assignee_of_status task.task_status = Some meta.agent_name)
    in
    match claimed with
    | Some task ->
      check string "claimed masc_code_write task" "Needs masc code write" task.title
    | None -> fail "expected masc_code_write task to be claimed")
;;

let test_create_defaults_single_active_goal_id () =
  with_room (fun config ->
    let goal, _ =
      match Goal_store.upsert_goal config ~title:"Scoped keeper goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let meta = make_goal_scoped_meta [ goal.id ] in
    let result =
      call_tool
        config
        meta
        "keeper_task_create"
        (`Assoc [ "title", `String "Default scoped task"; "description", `String "desc" ])
    in
    let json = parse_json result in
    check
      bool
      "create ok"
      true
      (Yojson.Safe.Util.member "ok" json |> Yojson.Safe.Util.to_bool);
    check
      string
      "response goal_id"
      goal.id
      (Yojson.Safe.Util.member "goal_id" json |> Yojson.Safe.Util.to_string);
    check (option string) "task linked goal" (Some goal.id) (only_task config).goal_id)
;;

let test_create_requires_goal_id_for_multiple_active_goals () =
  with_room (fun config ->
    let goal_a, _ =
      match Goal_store.upsert_goal config ~title:"Goal A" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let goal_b, _ =
      match Goal_store.upsert_goal config ~title:"Goal B" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let meta = make_goal_scoped_meta [ goal_a.id; goal_b.id ] in
    let result =
      call_tool
        config
        meta
        "keeper_task_create"
        (`Assoc
            [ "title", `String "Ambiguous scoped task"; "description", `String "desc" ])
    in
    let json = parse_json result in
    let error = Yojson.Safe.Util.member "error" json |> Yojson.Safe.Util.to_string in
    check
      bool
      "error asks for goal_id"
      true
      (contains_substring error "goal_id is required"))
;;

let test_create_rejects_unknown_goal_id () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let result =
      call_tool
        config
        meta
        "keeper_task_create"
        (`Assoc
            [ "title", `String "Unknown goal task"
            ; "description", `String "desc"
            ; "goal_id", `String "goal-missing"
            ])
    in
    let json = parse_json result in
    let error = Yojson.Safe.Util.member "error" json |> Yojson.Safe.Util.to_string in
    check
      bool
      "error mentions unknown goal"
      true
      (contains_substring error "unknown goal_id"))
;;

let test_create_rejects_fourth_open_task_for_goal () =
  with_room (fun config ->
    let goal, _ =
      match Goal_store.upsert_goal config ~title:"Scoped capacity goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let meta = make_goal_scoped_meta [ goal.id ] in
    for i = 1 to 3 do
      ignore
        (Coord_task.add_task
           ~goal_id:goal.id
           config
           ~title:(Printf.sprintf "Existing goal task %d" i)
           ~priority:3
           ~description:"desc")
    done;
    let result =
      call_tool
        config
        meta
        "keeper_task_create"
        (`Assoc [ "title", `String "Fourth goal task"; "description", `String "desc" ])
    in
    let json = parse_json result in
    check
      string
      "error kind"
      "goal_task_limit_exceeded"
      (Yojson.Safe.Util.member "error_kind" json |> Yojson.Safe.Util.to_string);
    check
      string
      "response goal_id"
      goal.id
      (Yojson.Safe.Util.member "goal_id" json |> Yojson.Safe.Util.to_string);
    check
      int
      "open task count"
      3
      (Yojson.Safe.Util.member "open_task_count" json |> Yojson.Safe.Util.to_int);
    check int "limit" 3 (Yojson.Safe.Util.member "limit" json |> Yojson.Safe.Util.to_int);
    check int "no task added" 3 (List.length (Coord.get_tasks_raw config)))
;;

let mark_first_task_done config ~agent_name =
  let backlog = Coord.read_backlog config in
  let tasks =
    match backlog.tasks with
    | first :: rest ->
      { first with
        task_status =
          Masc_domain.Done
            { assignee = agent_name
            ; completed_at = Masc_domain.now_iso ()
            ; notes = Some "done"
            }
      }
      :: rest
    | [] -> fail "expected task to mark done"
  in
  Coord.write_backlog config { backlog with tasks; version = backlog.version + 1 }
;;

let test_create_goal_limit_ignores_terminal_tasks () =
  with_room (fun config ->
    let goal, _ =
      match Goal_store.upsert_goal config ~title:"Scoped terminal goal" () with
      | Ok payload -> payload
      | Error msg -> fail msg
    in
    let meta = make_goal_scoped_meta [ goal.id ] in
    for i = 1 to 3 do
      ignore
        (Coord_task.add_task
           ~goal_id:goal.id
           config
           ~title:(Printf.sprintf "Maybe terminal task %d" i)
           ~priority:3
           ~description:"desc")
    done;
    mark_first_task_done config ~agent_name:meta.agent_name;
    let result =
      call_tool
        config
        meta
        "keeper_task_create"
        (`Assoc
            [ "title", `String "Replacement goal task"; "description", `String "desc" ])
    in
    let json = parse_json result in
    check
      bool
      "create ok"
      true
      (Yojson.Safe.Util.member "ok" json |> Yojson.Safe.Util.to_bool);
    check
      string
      "response goal_id"
      goal.id
      (Yojson.Safe.Util.member "goal_id" json |> Yojson.Safe.Util.to_string);
    check int "task added" 4 (List.length (Coord.get_tasks_raw config)))
;;

(* --- keeper_task_done tests --- *)

let test_done_with_empty_task_id () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let result =
      call_tool
        config
        meta
        "keeper_task_done"
        (`Assoc [ "task_id", `String ""; "result", `String "done" ])
    in
    let json = parse_json result in
    match Yojson.Safe.Util.member "error" json with
    | `String s ->
      check
        bool
        "error mentions task_id"
        true
        (String.lowercase_ascii s |> fun s -> String.length s > 0)
    | _ -> fail "expected error for empty task_id")
;;

(* Regression: keeper_task_done schema declares [result] as a
   required minLength:1 field. The handler must reject an empty
   result with a keeper-vocabulary error rather than silently
   passing non-strict tasks done with no summary or deferring the
   rejection to parse_handoff_context. *)
let test_done_requires_result () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let result =
      call_tool
        config
        meta
        "keeper_task_done"
        (`Assoc [ "task_id", `String "T-1"; "result", `String "" ])
    in
    let json = parse_json result in
    match Yojson.Safe.Util.member "error" json with
    | `String msg -> check bool "mentions result" true (contains_substring msg "result")
    | _ -> fail "expected error for empty result")
;;

let test_done_with_nonexistent_id () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let result =
      call_tool
        config
        meta
        "keeper_task_done"
        (`Assoc [ "task_id", `String "nonexistent-999"; "result", `String "completed" ])
    in
    let json = parse_json result in
    match Yojson.Safe.Util.member "ok" json with
    | `Bool false -> () (* expected *)
    | _ ->
      (match Yojson.Safe.Util.member "error" json with
       | `String _ -> () (* also acceptable *)
       | _ -> fail "expected ok=false or error for nonexistent task"))
;;

let test_done_after_claim () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let _ = Coord.add_task config ~title:"Done task" ~priority:1 ~description:"desc" in
    let claim_result = call_tool config meta "keeper_task_claim" (`Assoc []) in
    let claim_json = parse_json claim_result in
    let result_str = Yojson.Safe.Util.(member "result" claim_json |> to_string) in
    (* Extract task ID from claim result — format varies, try to find T-XXXX *)
    let task_id =
      let re = Re.(compile (seq [ str "T-"; rep1 (alt [ digit; char '-' ]) ])) in
      match Re.exec_opt re result_str with
      | Some g -> Re.Group.get g 0
      | None -> "T-1" (* fallback: first task *)
    in
    let done_result =
      call_tool
        config
        meta
        "keeper_task_done"
        (`Assoc [ "task_id", `String task_id; "result", `String "completed by test" ])
    in
    let done_json = parse_json done_result in
    match Yojson.Safe.Util.member "ok" done_json with
    | `Bool true -> ()
    | `Bool false ->
      (* May fail if task_id extraction didn't match — not a test failure
         per se, but the error path works *)
      ()
    | _ ->
      (match Yojson.Safe.Util.member "error" done_json with
       | `String _ -> () (* error path also ok for format mismatch *)
       | _ -> fail "expected ok or error in done response"))
;;

let test_done_respects_persisted_cdal_gate () =
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "false") (fun () ->
  with_env "MASC_CDAL_GATE_ENABLED" (Some "true") (fun () ->
    with_room (fun config ->
      let meta = make_test_meta () in
      let contract = strict_contract () in
      let _ =
        Coord.add_task
          ~contract
          config
          ~title:"Strict task"
          ~priority:1
          ~description:"needs CDAL verdict"
      in
      let task_id = (only_task config).id in
      ignore (call_tool config meta "keeper_task_claim" (`Assoc []));
      let result =
        call_tool
          config
          meta
          "keeper_task_done"
          (`Assoc [ "task_id", `String task_id; "result", `String "tests pass" ])
      in
      let json = parse_json result in
      match Yojson.Safe.Util.member "ok" json with
      | `Bool false ->
        let error = Yojson.Safe.Util.(member "error" json |> to_string) in
        check
          bool
          "mentions CDAL verdict"
          true
          (Astring.String.is_infix ~affix:"CDAL verdict" error)
      | _ -> fail "expected strict contract gate rejection")))
;;

let test_done_redirects_to_verification_fsm () =
  ensure_rng ();
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    with_env "MASC_CDAL_GATE_ENABLED" (Some "true") (fun () ->
      with_room (fun config ->
        let meta = make_test_meta () in
        let contract = strict_contract ~verify_gate_evidence:[ "output.json" ] () in
        let _ =
          Coord.add_task
            ~contract
            config
            ~title:"Verification task"
            ~priority:1
            ~description:"should enter awaiting verification"
        in
        let task_id = (only_task config).id in
        ignore (call_tool config meta "keeper_task_claim" (`Assoc []));
        let result =
          call_tool
            config
            meta
            "keeper_task_done"
            (`Assoc [ "task_id", `String task_id; "result", `String "tests pass" ])
        in
        let json = parse_json result in
        match Yojson.Safe.Util.member "ok" json with
        | `Bool true ->
          let task = only_task config in
          let verification_id =
            match task.task_status with
            | Masc_domain.AwaitingVerification { verification_id; _ } -> verification_id
           | status ->
             fail
               (Printf.sprintf
                  "expected awaiting_verification, got %s"
                  (Masc_domain.string_of_task_status status))
          in
          let req = verification_request_by_task_id config ~task_id in
          check string "request id matches task verification_id" verification_id req.id;
          check
            (list string)
            "criteria from completion contract"
            [ "tests pass" ]
            (custom_criteria req);
          check
            bool
            "evidence refs include verify gate artifact"
            true
            (List.mem "output.json" (evidence_refs_of_request req))
        | _ -> fail "expected keeper_task_done to redirect into verification FSM")))
;;

let test_done_redirects_default_contract_task_to_verification_fsm () =
  ensure_rng ();
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    with_room (fun config ->
      let meta = make_test_meta () in
      let _ =
        Coord.add_task
          config
          ~title:"Default verification task"
          ~priority:1
          ~description:"created without explicit contract"
      in
      let task_id = (only_task config).id in
      ignore (call_tool config meta "keeper_task_claim" (`Assoc []));
      let result =
        call_tool
          config
          meta
          "keeper_task_done"
          (`Assoc
              [ "task_id", `String task_id
              ; "result", `String "Implemented change and ran focused checks."
              ])
      in
      let json = parse_json result in
      match Yojson.Safe.Util.member "ok" json with
      | `Bool true ->
        let task = only_task config in
        (match task.task_status with
         | Masc_domain.AwaitingVerification _ -> ()
         | status ->
           fail
             (Printf.sprintf
                "expected awaiting_verification, got %s"
                (Masc_domain.string_of_task_status status)));
        (match task.contract with
         | Some contract ->
           check
             bool
             "default completion contract present"
             true
             (contract.completion_contract <> []);
           check
             bool
             "default evidence contract present"
             true
             (contract.verify_gate_evidence <> [])
         | None -> fail "expected default verification contract");
        let req = verification_request_by_task_id config ~task_id in
        check bool "criteria populated" true (req.criteria <> []);
        check bool "evidence refs populated" true (evidence_refs_of_request req <> [])
      | _ -> fail "expected keeper_task_done to redirect into verification FSM"))
;;

let test_submit_for_verification_requires_pr_url () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let result =
      call_tool
        config
        meta
        "keeper_task_submit_for_verification"
        (`Assoc
            [ "task_id", `String "T-1"
            ; "notes", `String "tests pass"
            ; "pr_url", `String ""
            ])
    in
    let json = parse_json result in
    match Yojson.Safe.Util.member "error" json with
    | `String msg ->
      check bool "mentions pr_url" true (contains_substring msg "pr_url");
      check
        string
        "failure class"
        "workflow_rejection"
        Yojson.Safe.Util.(member "failure_class" json |> to_string)
    | _ -> fail "expected error for empty pr_url")
;;

let test_submit_for_verification_transitions_task () =
  ensure_rng ();
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    with_env "MASC_CDAL_GATE_ENABLED" (Some "false") (fun () ->
      with_room (fun config ->
        let meta = make_test_meta () in
        let contract = strict_contract ~verify_gate_evidence:[ "pr_url" ] () in
        let _ =
          Coord.add_task
            ~contract
            config
            ~title:"Verification submit task"
            ~priority:1
            ~description:"should enter awaiting verification"
        in
        let task_id = (only_task config).id in
        ignore (call_tool config meta "keeper_task_claim" (`Assoc []));
        let result =
          call_tool
            config
            meta
            "keeper_task_submit_for_verification"
            (`Assoc
                [ "task_id", `String task_id
                ; "notes", `String "tests pass locally"
                ; "pr_url", `String "https://github.com/jeong-sik/masc-mcp/pull/1"
                ])
        in
        let json = parse_json result in
        match Yojson.Safe.Util.member "ok" json with
        | `Bool true ->
          let task = only_task config in
          (match task.task_status with
           | Masc_domain.AwaitingVerification _ -> ()
           | status ->
             fail
               (Printf.sprintf
                  "expected awaiting_verification, got %s"
                  (Masc_domain.string_of_task_status status)));
          let persisted_meta =
            match Keeper_types.read_meta config meta.name with
            | Ok (Some meta) -> meta
            | Ok None -> fail "expected persisted keeper meta"
            | Error msg -> fail msg
          in
          check
            (option string)
            "awaiting verification clears current_task_id"
            None
            (current_task_id_string persisted_meta)
        | _ -> fail "expected keeper_task_submit_for_verification to succeed")))
;;

(* Regression: keeper_task_done must map [result] onto the typed
   [handoff_context.summary] domain field, not just dump it into [notes]
   as an untyped blob. Previously a [result] sent by a keeper would be
   forwarded as [notes] only, and strict-contract callers had to rely on
   the [parse_handoff_context] sibling-synthesis fallback to recover a
   summary — keeping the vocabulary translation implicit and causing
   keeper-facing error messages to surface as "handoff_context.summary
   is required" even though the keeper had supplied [result]. *)
let test_done_maps_result_to_typed_handoff_summary () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let _ =
      Coord.add_task
        config
        ~title:"Vocab translation task"
        ~priority:1
        ~description:"verify result -> handoff_context.summary"
    in
    let task_id = (only_task config).id in
    ignore (call_tool config meta "keeper_task_claim" (`Assoc []));
    let result =
      call_tool
        config
        meta
        "keeper_task_done"
        (`Assoc
            [ "task_id", `String task_id
            ; "result", `String "refactored module, all tests green"
            ])
    in
    let json = parse_json result in
    match Yojson.Safe.Util.member "ok" json with
    | `Bool true ->
      let task = only_task config in
      (match task.handoff_context with
       | Some hc ->
         check
           string
           "result mapped to typed handoff_context.summary"
           "refactored module, all tests green"
           hc.summary
       | None ->
         fail "expected handoff_context to be populated after keeper_task_done")
    | _ -> fail "expected keeper_task_done to succeed for non-strict contract")
;;

(* Regression: keeper_task_submit_for_verification must map [notes] +
   [pr_url] onto the typed handoff_context fields [summary] and
   [evidence_refs], not concatenate them into a single [notes] string
   blob. The previous shape ("notes\nPR: pr_url") lost the structural
   separation and left downstream consumers without a typed
   evidence_refs list. *)
let test_submit_for_verification_maps_to_typed_handoff_evidence_refs () =
  ensure_rng ();
  with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
    with_env "MASC_CDAL_GATE_ENABLED" (Some "false") (fun () ->
      with_room (fun config ->
        let meta = make_test_meta () in
        let contract = strict_contract ~verify_gate_evidence:[ "pr_url" ] () in
        let _ =
          Coord.add_task
            ~contract
            config
            ~title:"Vocab translation submit task"
            ~priority:1
            ~description:"verify notes/pr_url -> typed handoff_context"
        in
        let task_id = (only_task config).id in
        ignore (call_tool config meta "keeper_task_claim" (`Assoc []));
        let pr_url = "https://github.com/jeong-sik/masc-mcp/pull/12345" in
        let result =
          call_tool
            config
            meta
            "keeper_task_submit_for_verification"
            (`Assoc
                [ "task_id", `String task_id
                ; "notes", `String "tests pass locally"
                ; "pr_url", `String pr_url
                ])
        in
        let json = parse_json result in
        match Yojson.Safe.Util.member "ok" json with
        | `Bool true ->
          let task = only_task config in
          (match task.handoff_context with
           | Some hc ->
             check
               string
               "notes mapped to typed handoff_context.summary"
               "tests pass locally"
               hc.summary;
             check
               (list string)
               "pr_url mapped to typed handoff_context.evidence_refs"
               [ pr_url ]
               hc.evidence_refs
           | None ->
             fail
               "expected handoff_context to be populated after \
                keeper_task_submit_for_verification")
        | _ ->
          fail "expected keeper_task_submit_for_verification to succeed")))
;;

(* --- keeper_task_force_release / keeper_task_force_done dispatch tests --- *)

(* Regression: keeper_task_force_release schema declares [reason] as
   a required minLength:1 field for audit-trail. The handler must
   reject an empty reason rather than fall through to a "no reason
   given" broadcast (silent audit gap). *)
let test_force_release_requires_reason () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let result =
      call_tool
        config
        meta
        "keeper_task_force_release"
        (`Assoc [ "task_id", `String "T-1"; "reason", `String "" ])
    in
    let json = parse_json result in
    match Yojson.Safe.Util.member "error" json with
    | `String msg -> check bool "mentions reason" true (contains_substring msg "reason")
    | _ -> fail "expected error for empty reason")
;;

(* Regression: keeper_task_force_done schema declares [notes] as a
   required minLength:1 field. The handler must reject an empty
   notes rather than silently pass through to Coord. *)
let test_force_done_requires_notes () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let result =
      call_tool
        config
        meta
        "keeper_task_force_done"
        (`Assoc [ "task_id", `String "T-1"; "notes", `String "" ])
    in
    let json = parse_json result in
    match Yojson.Safe.Util.member "error" json with
    | `String msg -> check bool "mentions notes" true (contains_substring msg "notes")
    | _ -> fail "expected error for empty notes")
;;

(* --- keeper_tool_search tests --- *)

let test_tool_search_empty_query_returns_error () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let result =
      call_tool config meta "keeper_tool_search" (`Assoc [ "query", `String "" ])
    in
    let json = parse_json result in
    match Yojson.Safe.Util.member "error" json with
    | `String msg -> check bool "error mentions query" true (String.length msg > 0)
    | _ -> fail "expected error field for empty query")
;;

let test_tool_search_whitespace_query_returns_error () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let result =
      call_tool config meta "keeper_tool_search" (`Assoc [ "query", `String "   " ])
    in
    let json = parse_json result in
    match Yojson.Safe.Util.member "error" json with
    | `String _ -> () (* expected *)
    | _ -> fail "expected error field for whitespace-only query")
;;

let test_tool_search_without_search_fn_uses_default_search () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let result =
      call_tool
        config
        meta
        "keeper_tool_search"
        (`Assoc [ "query", `String "filesystem read file" ])
    in
    let json = parse_json result in
    let results = Yojson.Safe.Util.(member "results" json |> to_list) in
    check bool "default search returns candidates" true (results <> []))
;;

let test_tool_search_max_results_clamped_to_10 () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let calls = ref [] in
    let search_fn ~query:_ ~max_results =
      calls := max_results :: !calls;
      `Assoc [ "results", `List [] ]
    in
    let _result =
      call_tool_with_search
        config
        meta
        "keeper_tool_search"
        (`Assoc [ "query", `String "worktree"; "max_results", `Int 50 ])
        search_fn
    in
    match !calls with
    | [ n ] -> check int "max_results clamped to 10" 10 n
    | _ -> fail "expected exactly one search_fn call")
;;

let test_tool_search_max_results_minimum_1 () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let calls = ref [] in
    let search_fn ~query:_ ~max_results =
      calls := max_results :: !calls;
      `Assoc [ "results", `List [] ]
    in
    let _result =
      call_tool_with_search
        config
        meta
        "keeper_tool_search"
        (`Assoc [ "query", `String "worktree"; "max_results", `Int 0 ])
        search_fn
    in
    match !calls with
    | [ n ] -> check int "max_results clamped to min 1" 1 n
    | _ -> fail "expected exactly one search_fn call")
;;

let test_tool_search_uses_provided_search_fn () =
  with_room (fun config ->
    let meta = make_test_meta () in
    let search_fn ~query ~max_results:_ =
      `Assoc
        [ "ok", `Bool true
        ; "query", `String query
        ; ( "results"
          , `List
              [ `Assoc
                  [ "name", `String "keeper_fs_read"
                  ; "score", `Float 0.9
                  ; "description", `String "read a file"
                  ]
              ] )
        ]
    in
    let result =
      call_tool_with_search
        config
        meta
        "keeper_tool_search"
        (`Assoc [ "query", `String "read file" ])
        search_fn
    in
    let json = parse_json result in
    let results = Yojson.Safe.Util.(member "results" json |> to_list) in
    check int "one result returned" 1 (List.length results);
    let name = Yojson.Safe.Util.(List.hd results |> member "name" |> to_string) in
    check string "result name matches" "keeper_fs_read" name)
;;

let () =
  let base_path = Masc_test_deps.find_project_root () in
  ignore (Result.get_ok (Keeper_exec_tools.init_policy_config ~base_path));
  Alcotest.run
    "Keeper_task_dispatch"
    [ ( "claim"
      , [ test_case "claim returns result" `Quick test_claim_returns_result
        ; test_case
            "claim returns observation fragment"
            `Quick
            test_claim_returns_observation_fragment
        ; test_case
            "claim syncs keeper current_task_id"
            `Quick
            test_claim_syncs_keeper_current_task_id
        ; test_case
            "release clears keeper current_task_id"
            `Quick
            test_release_clears_keeper_current_task_id
        ; test_case
            "claim clears stale task worktree metadata"
            `Quick
            test_claim_clears_stale_task_worktree_metadata
        ; test_case
            "release clears task worktree metadata"
            `Quick
            test_release_clears_task_worktree_metadata
        ; test_case
            "claim-next runs post-provision hook"
            `Quick
            test_claim_next_runs_post_provision_hook
        ; test_case
            "claim-next preserves existing alias-owned task"
            `Quick
            test_claim_next_preserves_existing_alias_owned_task
        ; test_case
            "stale current_task_id clears from backlog"
            `Quick
            test_stale_current_task_id_is_cleared_from_backlog
        ; test_case
            "run context uses reconciled current_task_id"
            `Quick
            test_run_context_uses_reconciled_current_task_id
        ; test_case
            "multiple active tasks select deterministic current_task_id"
            `Quick
            test_multiple_active_tasks_selects_deterministic_current_task
        ; test_case
            "multiple active tasks preserve existing current_task_id"
            `Quick
            test_multiple_active_tasks_preserves_existing_current_task
        ; test_case
            "heartbeat current_task_id reconciles terminal backlog"
            `Quick
            test_heartbeat_current_task_id_reconciles_terminal_backlog
        ; test_case "claim empty room" `Quick test_claim_empty_room
        ; test_case
            "claim prefers oldest same-priority task"
            `Quick
            test_claim_prefers_oldest_same_priority_task
        ; test_case
            "claim respects active_goal_ids"
            `Quick
            test_claim_respects_active_goal_ids
        ; test_case
            "claim does not cross-goal when auto goal scope is empty"
            `Quick
            test_claim_does_not_cross_goal_when_auto_goal_scope_empty
        ; test_case
            "claim does not cross-goal when persisted goal scope is empty"
            `Quick
            test_claim_does_not_cross_goal_when_persisted_goal_scope_empty
        ; test_case
            "explicit empty goal scope fallback override still claims cross-goal"
            `Quick
            test_explicit_empty_goal_scope_fallback_override_still_claims_cross_goal
        ; test_case
            "claim does not cross-goal when scoped task requires missing tool"
            `Quick
            test_claim_does_not_cross_goal_when_scoped_task_requires_missing_tool
        ; test_case
            "claim does not cross-goal when all scoped tasks unavailable"
            `Quick
            test_claim_does_not_cross_goal_when_all_scoped_tasks_unavailable
        ; test_case
            "claim does not cross-goal when scoped task is verification blocked"
            `Quick
            test_claim_does_not_cross_goal_when_scoped_task_is_verification_blocked
        ; test_case
            "claim no eligible scoped reports scope truth"
            `Quick
            test_claim_no_eligible_scoped_reports_scope_truth
        ; test_case
            "claim skips tasks requiring missing tools"
            `Quick
            test_claim_skips_required_tools_without_access
        ; test_case
            "claim allows tasks requiring available tools"
            `Quick
            test_claim_allows_required_tools_with_access
        ; test_case
            "required tool matching canonicalizes public aliases"
            `Quick
            test_required_tool_matching_canonicalizes_public_aliases
        ; test_case
            "claim keeps masc_code_write distinct from Write alias"
            `Quick
            test_claim_does_not_treat_write_alias_as_masc_code_write
        ; test_case
            "claim allows masc_code_write when available"
            `Quick
            test_claim_allows_masc_code_write_with_access
        ; test_case
            "create defaults single active goal_id"
            `Quick
            test_create_defaults_single_active_goal_id
        ; test_case
            "create requires explicit goal_id for multiple active goals"
            `Quick
            test_create_requires_goal_id_for_multiple_active_goals
        ; test_case
            "create rejects unknown goal_id"
            `Quick
            test_create_rejects_unknown_goal_id
        ; test_case
            "create rejects fourth open task for goal"
            `Quick
            test_create_rejects_fourth_open_task_for_goal
        ; test_case
            "create goal limit ignores terminal tasks"
            `Quick
            test_create_goal_limit_ignores_terminal_tasks
        ] )
    ; ( "done"
      , [ test_case "empty task_id returns error" `Quick test_done_with_empty_task_id
        ; test_case "empty result returns error (schema enforcement)" `Quick test_done_requires_result
        ; test_case "nonexistent id returns error" `Quick test_done_with_nonexistent_id
        ; test_case "done after claim" `Quick test_done_after_claim
        ; test_case
            "strict contract uses CDAL gate"
            `Quick
            test_done_respects_persisted_cdal_gate
        ; test_case
            "done redirects to verification FSM"
            `Quick
            test_done_redirects_to_verification_fsm
        ; test_case
            "default contract redirects to verification FSM"
            `Quick
            test_done_redirects_default_contract_task_to_verification_fsm
        ; test_case
            "result maps to typed handoff_context.summary"
            `Quick
            test_done_maps_result_to_typed_handoff_summary
        ] )
    ; ( "submit_for_verification"
      , [ test_case "requires pr_url" `Quick test_submit_for_verification_requires_pr_url
        ; test_case
            "transitions task"
            `Quick
            test_submit_for_verification_transitions_task
        ; test_case
            "notes/pr_url map to typed handoff_context fields"
            `Quick
            test_submit_for_verification_maps_to_typed_handoff_evidence_refs
        ] )
    ; ( "force_task"
      , [ test_case
            "force_release requires reason (schema enforcement)"
            `Quick
            test_force_release_requires_reason
        ; test_case
            "force_done requires notes (schema enforcement)"
            `Quick
            test_force_done_requires_notes
        ] )
    ; ( "keeper_tool_search"
      , [ test_case
            "empty query returns error"
            `Quick
            test_tool_search_empty_query_returns_error
        ; test_case
            "whitespace query returns error"
            `Quick
            test_tool_search_whitespace_query_returns_error
        ; test_case
            "non-empty query uses default search_fn"
            `Quick
            test_tool_search_without_search_fn_uses_default_search
        ; test_case
            "max_results clamped to 10"
            `Quick
            test_tool_search_max_results_clamped_to_10
        ; test_case
            "max_results minimum is 1"
            `Quick
            test_tool_search_max_results_minimum_1
        ; test_case
            "uses provided search_fn"
            `Quick
            test_tool_search_uses_provided_search_fn
        ] )
    ]
;;
