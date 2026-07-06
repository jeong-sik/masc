module Types = Masc_domain

(** Coverage tests for Tool_workspace *)

open Masc
open Workspace_types
module Planning_eio = Masc.Task.Planning_eio

let () = Random.self_init ()
let () = Mirage_crypto_rng_unix.use_default ()

let str_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  if len_sub > len_s
  then false
  else (
    let rec loop i =
      if i > len_s - len_sub
      then false
      else if String.sub s i len_sub = sub
      then true
      else loop (i + 1)
    in
    loop 0)
;;

let assert_contains output expected =
  if not (str_contains output expected)
  then
    failwith
      (Printf.sprintf "missing expected substring %S in output:\n%s" expected output)
;;

let assert_not_contains output unexpected =
  if str_contains output unexpected
  then
    failwith (Printf.sprintf "unexpected substring %S in output:\n%s" unexpected output)
;;

let set_current_task_ok config ~task_id =
  match Planning_eio.set_current_task config ~task_id with
  | Ok () -> ()
  | Error msg -> failwith msg
;;

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect ~finally:restore (fun () ->
    (match value_opt with
     | Some value -> Unix.putenv name value
     | None -> Unix.putenv name "");
    f ())
;;

let with_isolated_runtime_env f =
  with_env "MASC_BASE_PATH" None (fun () ->
    with_env "MASC_BASE_PATH_INPUT" None f)
;;

(* Test registry — each [test] call appends to this list; the final
   [let ()] dispatches the list through Alcotest.run.  Eio scope is
   set up per-test inside the registered thunk. *)
let test_cases : (string * (unit -> unit)) list ref = ref []

let test name f =
  test_cases
  := ( name
     , fun () ->
         Eio_main.run
         @@ fun env ->
         Fs_compat.set_fs (Eio.Stdenv.fs env);
         with_isolated_runtime_env f )
     :: !test_cases
;;

(* Create test context *)
let test_counter = ref 0

let make_test_ctx () =
  incr test_counter;
  let tmp =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf
         "masc-workspace-test-%d-%d"
         (int_of_float (Unix.gettimeofday () *. 1000.0))
         !test_counter)
  in
  Unix.mkdir tmp 0o755;
  let config = Workspace.default_config tmp in
  Auth.save_auth_config
    config.base_path
    { Masc_domain.default_auth_config with enabled = false; require_token = false };
  { Tool_workspace.config; agent_name = "test-agent" }
;;

let agent_file ctx =
  let agent_name = Workspace.resolve_agent_name ctx.config ctx.agent_name in
  Filename.concat (Workspace.agents_dir ctx.config) (Workspace.safe_filename agent_name ^ ".json")
;;

let read_agent ctx =
  match Types.agent_of_yojson (Workspace.read_json ctx.config (agent_file ctx)) with
  | Ok agent -> agent
  | Error msg -> failwith ("agent decode failed: " ^ msg)
;;

let write_agent ctx agent =
  Workspace.write_json ctx.config (agent_file ctx) (Types.agent_to_yojson agent)
;;

let seed_stale_current_task ctx =
  let old_last_seen = Masc_domain.iso8601_of_unix_seconds (Time_compat.now () -. 10.0) in
  let agent = read_agent ctx in
  write_agent
    ctx
    { agent with
      status = Busy
    ; current_task = Some "task-missing"
    ; last_seen = old_last_seen
    };
  old_last_seen
;;

let runtime_agent name : Masc_domain.agent =
  let now = Masc_domain.now_iso () in
  let meta : Masc_domain.agent_meta =
    { session_id = "runtime-hook:" ^ name
    ; agent_type = "keeper"
    ; pid = None
    ; hostname = None
    ; tty = None
    ; parent_task = None
    ; keeper_name = Some name
    ; keeper_id = None
    }
  in
  { id = None
  ; name
  ; agent_type = "keeper"
  ; status = Masc_domain.Active
  ; capabilities = []
  ; current_task = None
  ; session_bound_at = now
  ; last_seen = now
  ; meta = Some meta
  }
;;

let write_agent_state config agent_name f =
  let agent_file =
    Filename.concat (Workspace.agents_dir config) (Workspace.safe_filename agent_name ^ ".json")
  in
  let agent =
    match Workspace.read_json config agent_file |> Masc_domain.agent_of_yojson with
    | Ok agent -> agent
    | Error msg -> failwith ("agent parse failed: " ^ msg)
  in
  Workspace.write_json config agent_file (Masc_domain.agent_to_yojson (f agent))
;;

let actual_test_agent_name config = Workspace.resolve_agent_name config "test-agent"

let force_claim_task config ~agent_name ~task_id =
  let backlog = Workspace.read_backlog config in
  let tasks =
    List.map
      (fun (task : Types.task) ->
        if String.equal task.id task_id
        then
          { task with
            task_status = Types.Claimed { assignee = agent_name; claimed_at = "test" }
          }
        else task)
      backlog.tasks
  in
  Workspace.write_backlog config { backlog with tasks; version = backlog.version + 1 }
;;

(* Test dispatch returns None for unknown tool *)
let () =
  test "dispatch_unknown_tool" (fun () ->
    let ctx = make_test_ctx () in
    let args = `Assoc [] in
    assert (Tool_workspace.dispatch ctx ~name:"unknown_tool" ~args = None))
;;

(* Test dispatch init — masc_init was pruned from registry; dispatch returns None. *)
let () =
  test "dispatch_init" (fun () ->
    let ctx = make_test_ctx () in
    let args = `Assoc [ "agent_name", `String "init-agent" ] in
    assert (Tool_workspace.dispatch ctx ~name:"masc_init" ~args = None))
;;

(* Test dispatch status *)
let () =
  test "dispatch_status" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    let args = `Assoc [] in
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args with
    | Some result ->
      assert (Tool_result.is_success result);
      let message = (Tool_result.message result) in
      assert (str_contains message "Snapshot:");
      assert (str_contains message "🧭 You:");
      assert (str_contains message "Suggested next:")
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_reports_state_read_failure" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    let state_path = Workspace.state_path ctx.config in
    Unix.unlink state_path;
    Unix.mkdir state_path 0o755;
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some result ->
      assert (not (Tool_result.is_success result));
      assert (Tool_result.failure_class result = Some Tool_result.Runtime_failure);
      assert
        (String.starts_with
           ~prefix:"masc_status state read failed:"
           (Tool_result.message result))
    | None -> Alcotest.fail "dispatch returned None")
;;

let () =
  test "dispatch_status_reports_backlog_read_failure" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    let backlog_path = Workspace.backlog_path ctx.config in
    Fs_compat.save_file backlog_path "{not-json";
    Fs_compat.save_file (backlog_path ^ ".last-good") "{not-json";
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some result ->
      assert (not (Tool_result.is_success result));
      assert (Tool_result.failure_class result = Some Tool_result.Runtime_failure);
      assert (String.starts_with ~prefix:"masc_status backlog read failed:" (Tool_result.message result))
    | None -> Alcotest.fail "dispatch returned None")
;;

let () =
  test "dispatch_status_hides_stale_current_task_without_writing" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some ctx.agent_name) in
    let old_last_seen = seed_stale_current_task ctx in
    let actual_name = Workspace.resolve_agent_name ctx.config ctx.agent_name in
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some result ->
      assert (Tool_result.is_success result);
      let message = (Tool_result.message result) in
      assert_contains message (Printf.sprintf "%s (you) -> active" actual_name);
      let agent = read_agent ctx in
      assert (agent.current_task = Some "task-missing");
      assert (agent.last_seen = old_last_seen)
    | None -> failwith "dispatch returned None")
;;

let () =
  test "workspace_status_hides_stale_current_task_without_writing" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some ctx.agent_name) in
    let old_last_seen = seed_stale_current_task ctx in
    let actual_name = Workspace.resolve_agent_name ctx.config ctx.agent_name in
    let output = Workspace.status ctx.config in
    assert_contains output (Printf.sprintf "%s → idle" actual_name);
    let agent = read_agent ctx in
    assert (agent.current_task = Some "task-missing");
    assert (agent.last_seen = old_last_seen))
;;

let () =
  test "dispatch_status_includes_runtime_agents_without_workspace_files" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some ctx.agent_name) in
    let previous = Atomic.get Workspace_hooks.runtime_agents_fn in
    Fun.protect
      ~finally:(fun () -> Atomic.set Workspace_hooks.runtime_agents_fn previous)
      (fun () ->
        Atomic.set Workspace_hooks.runtime_agents_fn (fun config ->
          if String.equal config.base_path ctx.config.base_path
          then [ runtime_agent "keeper-runtime-visible-agent" ]
          else []);
        let agent_file =
          Filename.concat
            (Workspace.agents_dir ctx.config)
            (Workspace.safe_filename "keeper-runtime-visible-agent" ^ ".json")
        in
        assert (not (Sys.file_exists agent_file));
        match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
        | Some result ->
          assert (Tool_result.is_success result);
          let message = Tool_result.message result in
          assert_contains message "Snapshot: agents=2 zombies=0";
          assert_contains message "keeper-runtime-visible-agent -> active"
        | None -> failwith "dispatch returned None"))
;;

(* Test status summary and active task cap *)
let () =
  test "dispatch_status_summary_and_cap" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    for i = 1 to 35 do
      ignore
        (Workspace.add_task
           ctx.config
           ~title:(Printf.sprintf "Task %d" i)
           ~priority:3
           ~description:"")
    done;
    let args = `Assoc [] in
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args with
    | Some result ->
      assert (Tool_result.is_success result);
      let msg = (Tool_result.message result) in
      assert (str_contains msg "tasks active=35 todo=35 claimed=0 in_progress=0");
      assert (str_contains msg "Attention:");
      assert_contains msg "35 unclaimed task(s) are available right now.";
      assert (str_contains msg "Summary: active=35, done=0, cancelled=0, total=35");
      assert (str_contains msg "and 5 more active tasks")
    | None -> failwith "dispatch returned None")
;;

(* Test done task aggregation in summary *)
let () =
  test "dispatch_status_done_summary" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    let _ = Workspace.add_task ctx.config ~title:"Done Task" ~priority:2 ~description:"" in
    ignore (Workspace.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
    (match
       Workspace.transition_task_r
         ctx.config
         ~agent_name:"test-agent"
         ~task_id:"task-001"
         ~action:Masc_domain.Done_action
         ~notes:"ok"
         ()
     with
     | Ok _ -> ()
     | Error err -> failwith (Masc_domain.masc_error_to_string err));
    let args = `Assoc [] in
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args with
    | Some r ->
      let result = Tool_result.message r in
      assert (Tool_result.is_success r);
      assert (str_contains result "owned=-");
      assert (str_contains result "tasks active=0 todo=0 claimed=0 in_progress=0");
      assert (str_contains result "Summary: active=0, done=1, cancelled=0, total=1");
      assert (str_contains result "(no active tasks)")
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_surfaces_awaiting_verification_assignment" (fun () ->
    with_env "MASC_VERIFICATION_FSM_ENABLED" (Some "true") (fun () ->
      let ctx = make_test_ctx () in
      let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
      let actual_name = Workspace.resolve_agent_name ctx.config "test-agent" in
      ignore
        (Workspace.add_task ctx.config ~title:"Awaiting verifier" ~priority:2 ~description:"");
      ignore (Workspace.claim_task ctx.config ~agent_name:actual_name ~task_id:"task-001");
      (match
         Workspace.transition_task_r
           ctx.config
           ~agent_name:actual_name
           ~task_id:"task-001"
           ~action:Masc_domain.Submit_for_verification
           ()
       with
       | Ok _ -> ()
       | Error err -> failwith (Masc_domain.masc_error_to_string err));
      let agent_file =
        Filename.concat
          (Workspace.agents_dir ctx.config)
          (Workspace.safe_filename actual_name ^ ".json")
      in
      let stale_agent =
        match Workspace.read_json ctx.config agent_file |> Masc_domain.agent_of_yojson with
        | Ok agent ->
          { agent with status = Masc_domain.Busy; current_task = Some "task-001" }
        | Error msg -> failwith ("agent parse failed: " ^ msg)
      in
      Workspace.write_json ctx.config agent_file (Masc_domain.agent_to_yojson stale_agent);
      match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
      | Some r ->
        let result = Tool_result.message r in
        assert (Tool_result.is_success r);
        assert_contains result (actual_name ^ " (you) -> task-001");
        let agent_after =
          match Workspace.read_json ctx.config agent_file |> Masc_domain.agent_of_yojson with
          | Ok agent -> agent
          | Error msg -> failwith ("agent parse failed after status: " ^ msg)
        in
        assert (agent_after.current_task = Some "task-001");
        assert (agent_after.status = Masc_domain.Busy)
      | None -> failwith "dispatch returned None"))
;;

let () =
  test "dispatch_status_hides_completed_stale_agent_current_task_label" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    let _ =
      Workspace.add_task ctx.config ~title:"Completed elsewhere" ~priority:2 ~description:""
    in
    ignore (Workspace.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
    (match
       Workspace.transition_task_r
         ctx.config
         ~agent_name:"test-agent"
         ~task_id:"task-001"
         ~action:Masc_domain.Done_action
         ~notes:"ok"
         ()
     with
     | Ok _ -> ()
     | Error err -> failwith (Masc_domain.masc_error_to_string err));
    let actual_name = actual_test_agent_name ctx.config in
    write_agent_state ctx.config actual_name (fun agent ->
      { agent with
        status = Masc_domain.Busy
      ; current_task = Some " task-001\nignored-line "
      });
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some r ->
      let result = Tool_result.message r in
      assert (Tool_result.is_success r);
      assert_not_contains result (actual_name ^ " (you) -> task-001");
      assert_contains result (actual_name ^ " (you) -> active");
      assert_not_contains result (actual_name ^ " (you) -> busy (stale:task-001)");
      assert_not_contains result "busy (stale:task-001)";
      assert_not_contains result "ignored-line";
      assert_contains result "Summary: active=0, done=1, cancelled=0, total=1"
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_players_prefer_live_board_assignment" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    ignore
      (Workspace.add_task ctx.config ~title:"Live assignment" ~priority:2 ~description:"");
    ignore
      (Workspace.add_task ctx.config ~title:"Old registry focus" ~priority:2 ~description:"");
    ignore (Workspace.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
    let actual_name = actual_test_agent_name ctx.config in
    write_agent_state ctx.config actual_name (fun agent ->
      { agent with status = Masc_domain.Busy; current_task = Some "task-002" });
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some r ->
      let result = Tool_result.message r in
      assert (Tool_result.is_success r);
      assert_contains result (actual_name ^ " (you) -> task-001");
      assert_not_contains result (actual_name ^ " (you) -> task-002");
      assert_not_contains result (actual_name ^ " (you) -> busy (stale:task-002)")
    | None -> failwith "dispatch returned None")
;;

(* Test dispatch reset without confirm *)
let () =
  test "dispatch_reset_no_confirm" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    let args = `Assoc [] in
    match Tool_workspace.dispatch ctx ~name:"masc_reset" ~args with
    | Some r -> let success = Tool_result.is_success r in
      assert (not success) (* Should fail without confirm *)
    | None -> failwith "dispatch returned None")
;;

(* Test dispatch reset with confirm *)
let () =
  test "dispatch_reset_with_confirm" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    let args = `Assoc [ "confirm", `Bool true ] in
    match Tool_workspace.dispatch ctx ~name:"masc_reset" ~args with
    | Some r -> let success = Tool_result.is_success r in assert success
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_removed_named_workspace_tools" (fun () ->
    let ctx = make_test_ctx () in
    let args = `Assoc [] in
    assert (Tool_workspace.dispatch ctx ~name:"masc_workspaces_list" ~args = None);
    assert (Tool_workspace.dispatch ctx ~name:"masc_workspace_create" ~args = None);
    assert (Tool_workspace.dispatch ctx ~name:"masc_workspace_enter" ~args = None))
;;

let () =
  test "dispatch_check_reports_backlog_read_failure" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    let backlog_path = Workspace.backlog_path ctx.config in
    Fs_compat.save_file backlog_path "{not-json";
    Fs_compat.save_file (backlog_path ^ ".last-good") "{not-json";
    match Tool_workspace.dispatch ctx ~name:"masc_check" ~args:(`Assoc []) with
    | Some result ->
      assert (not (Tool_result.is_success result));
      assert (Tool_result.failure_class result = Some Tool_result.Runtime_failure);
      assert
        (String.starts_with
           ~prefix:"masc_check backlog read failed:"
           (Tool_result.message result))
    | None -> Alcotest.fail "dispatch returned None")
;;

let () =
  test "dispatch_check_transition_claim_auto_binds_current_task" (fun () ->
    Fun.protect ~finally:Fs_compat.clear_fs
    @@ fun () ->
    Eio_main.run
    @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    let task_ctx =
      { Task.Tool.config = ctx.config; agent_name = ctx.agent_name; sw = None }
    in
    let _ =
      Task.Tool.handle_add_task
        ~tool_name:"test_tool"
        ~start_time:0.0
        task_ctx
        (`Assoc [ "title", `String "Check transition claim" ])
    in
    let _ =
      Task.Tool.handle_transition
        ~tool_name:"test_tool"
        ~start_time:0.0
        task_ctx
        (`Assoc [ "task_id", `String "task-001"; "action", `String "claim" ])
    in
    match
      Tool_workspace.dispatch
        ctx
        ~name:"masc_check"
        ~args:
          (`Assoc
              [ "assertions", `List [ `String "task_claimed"; `String "current_task_set" ]
              ])
    with
    | Some result ->
      assert (Tool_result.is_success result);
      let message = (Tool_result.message result) in
      let json = Yojson.Safe.from_string message in
      assert (Yojson.Safe.Util.member "all_passed" json = `Bool true)
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_check_claim_next_marks_current_task_set" (fun () ->
    Fun.protect ~finally:Fs_compat.clear_fs
    @@ fun () ->
    Eio_main.run
    @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    let task_ctx =
      { Task.Tool.config = ctx.config; agent_name = ctx.agent_name; sw = None }
    in
    let _ =
      Task.Tool.handle_add_task
        ~tool_name:"test_tool"
        ~start_time:0.0
        task_ctx
        (`Assoc [ "title", `String "Check claim next" ])
    in
    let _ =
      Task.Tool.handle_claim_next
        ~tool_name:"test_tool"
        ~start_time:0.0
        task_ctx
        (`Assoc [])
    in
    match
      Tool_workspace.dispatch
        ctx
        ~name:"masc_check"
        ~args:
          (`Assoc
              [ "assertions", `List [ `String "task_claimed"; `String "current_task_set" ]
              ])
    with
    | Some result ->
      assert (Tool_result.is_success result);
      let message = (Tool_result.message result) in
      let json = Yojson.Safe.from_string message in
      assert (Yojson.Safe.Util.member "all_passed" json = `Bool true)
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_multi_assignment_current_requires_disambiguation" (fun () ->
    Fun.protect ~finally:Fs_compat.clear_fs
    @@ fun () ->
    Eio_main.run
    @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    let _ = Workspace.add_task ctx.config ~title:"Primary lane" ~priority:2 ~description:"" in
    let _ =
      Workspace.add_task ctx.config ~title:"Secondary lane" ~priority:2 ~description:""
    in
    ignore (Workspace.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
    let actual_name = actual_test_agent_name ctx.config in
    force_claim_task ctx.config ~agent_name:actual_name ~task_id:"task-002";
    set_current_task_ok ctx.config ~task_id:"task-002";
    (match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
     | Some r -> let result = Tool_result.message r in let success = Tool_result.is_success r in
       assert success;
       assert_contains result "owned=task-001 | current=task-002";
       assert_contains result "assigned_set=[task-001,task-002]";
       assert_contains result "primary_owned=task-001";
       assert_contains result "planning_current=task-002";
       assert_contains result "current_is_assigned=yes";
       assert_contains result "effective_current=task-002";
       assert_contains result "drift_reason=secondary_assignment";
       assert_contains result "claim_first_suppressed=yes";
       assert (not (str_contains result "task-002 is stale focus"))
     | None -> failwith "dispatch returned None");
    match
      Tool_workspace.dispatch
        ctx
        ~name:"masc_check"
        ~args:
          (`Assoc
              [ "assertions", `List [ `String "task_claimed"; `String "current_task_set" ]
              ])
    with
    | Some result ->
      assert (Tool_result.is_success result);
      let message = (Tool_result.message result) in
      let json = Yojson.Safe.from_string message in
      assert (Yojson.Safe.Util.member "all_passed" json = `Bool false);
      assert (
        Yojson.Safe.Util.member "fix_hint" json
        = `String
            "Call masc_plan_set_task to choose or re-sync the active task when \
             current_task is unset, stale, or ambiguous")
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_check_owned_current_drift_fails_current_task_set" (fun () ->
    Fun.protect ~finally:Fs_compat.clear_fs
    @@ fun () ->
    Eio_main.run
    @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    ignore (Workspace.add_task ctx.config ~title:"Owned task" ~priority:3 ~description:"");
    ignore
      (Workspace.add_task ctx.config ~title:"Stale current task" ~priority:3 ~description:"");
    ignore (Workspace.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
    set_current_task_ok ctx.config ~task_id:"task-002";
    match
      Tool_workspace.dispatch
        ctx
        ~name:"masc_check"
        ~args:
          (`Assoc
              [ "assertions", `List [ `String "task_claimed"; `String "current_task_set" ]
              ])
    with
    | Some result ->
      assert (Tool_result.is_success result);
      let message = (Tool_result.message result) in
      let json = Yojson.Safe.from_string message in
      assert (Yojson.Safe.Util.member "all_passed" json = `Bool false);
      assert (
        Yojson.Safe.Util.member "fix_hint" json
        = `String
            "Call masc_plan_set_task to choose or re-sync the active task when \
             current_task is unset, stale, or ambiguous")
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_surfaces_owned_current_drift" (fun () ->
    Fun.protect ~finally:Fs_compat.clear_fs
    @@ fun () ->
    Eio_main.run
    @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    ignore (Workspace.add_task ctx.config ~title:"Owned task" ~priority:3 ~description:"");
    ignore
      (Workspace.add_task ctx.config ~title:"Stale current task" ~priority:3 ~description:"");
    ignore (Workspace.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
    set_current_task_ok ctx.config ~task_id:"task-002";
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some r -> let result = Tool_result.message r in let success = Tool_result.is_success r in
      assert success;
      assert (str_contains result "owned=task-001");
      assert (str_contains result "current=task-002");
      assert_contains result "Do not retry generic masc_plan_init from a drifted surface";
      assert (not (str_contains result "Suggested next: masc_plan_init -> masc_status"));
      assert (str_contains result "planning current_task is unset or drifted")
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_suppresses_lifecycle_guidance_without_credential" (fun () ->
    Fun.protect ~finally:Fs_compat.clear_fs
    @@ fun () ->
    Eio_main.run
    @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    ignore (Auth.enable_auth ctx.config.base_path ~require_token:true ~agent_name:"admin");
    ignore
      (Workspace.add_task ctx.config ~title:"Credentialed work" ~priority:3 ~description:"");
    set_current_task_ok ctx.config ~task_id:"task-001";
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some r -> let result = Tool_result.message r in let success = Tool_result.is_success r in
      assert success;
      assert (
        str_contains
          result
          "Credential: required=yes | available=no | candidates=test-agent");
      assert (
        str_contains result "Lifecycle actions are credential-blocked for test-agent");
      assert (not (str_contains result "Suggested next: masc_status -> masc_transition"));
      assert (not (str_contains result "Suggested next: keeper_task_claim"))
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_treats_keeper_internal_auth_as_credential" (fun () ->
    Fun.protect ~finally:Fs_compat.clear_fs
    @@ fun () ->
    Eio_main.run
    @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let ctx = { (make_test_ctx ()) with agent_name = "keeper-sangsu-agent" } in
    let _ = Workspace.init ctx.config ~agent_name:(Some "keeper-sangsu-agent") in
    ignore (Auth.enable_auth ctx.config.base_path ~require_token:true ~agent_name:"admin");
    ignore (Auth.ensure_internal_keeper_token ctx.config.base_path);
    ignore (Workspace.add_task ctx.config ~title:"Keeper work" ~priority:3 ~description:"");
    set_current_task_ok ctx.config ~task_id:"task-001";
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some r -> let result = Tool_result.message r in let success = Tool_result.is_success r in
      assert success;
      assert (
        str_contains
          result
          "Credential: required=yes | available=yes | candidates=keeper-sangsu-agent");
      assert (
        not
          (str_contains
             result
             "Lifecycle actions are credential-blocked for keeper-sangsu-agent"));
      assert (str_contains result "Suggested next:")
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_no_owned_prefers_claim_next_over_transition" (fun () ->
    Fun.protect ~finally:Fs_compat.clear_fs
    @@ fun () ->
    Eio_main.run
    @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    ignore
      (Auth.enable_auth ctx.config.base_path ~require_token:true ~agent_name:"test-agent");
    ignore (Workspace.add_task ctx.config ~title:"Unclaimed task" ~priority:3 ~description:"");
    set_current_task_ok ctx.config ~task_id:"task-001";
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some r -> let result = Tool_result.message r in let success = Tool_result.is_success r in
      assert success;
      assert (str_contains result "owned=- | current=task-001");
      assert (str_contains result "drift_reason=no_owned");
      assert (str_contains result "claim_first_suppressed=no");
      assert_contains result "Suggested next: keeper_task_claim -> masc_status";
      assert_not_contains result "Suggested next: masc_status -> masc_transition"
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_surfaces_missing_planning_for_owned_task" (fun () ->
    Fun.protect ~finally:Fs_compat.clear_fs
    @@ fun () ->
    Eio_main.run
    @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    ignore
      (Workspace.add_task
         ctx.config
         ~title:"Claimed without plan"
         ~priority:3
         ~description:"");
    ignore (Workspace.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
    set_current_task_ok ctx.config ~task_id:"task-001";
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some r -> let result = Tool_result.message r in let success = Tool_result.is_success r in
      assert success;
      assert (str_contains result "owned=task-001 | current=task-001");
      assert (str_contains result "Planning: missing=yes | task=task-001");
      assert_contains result "Owned task task-001 has no planning context.";
      assert (
        str_contains result "Do not retry generic masc_plan_init from a drifted surface");
      assert (str_contains result "handoff/worktree/test logs as the temporary SSOT");
      assert (not (str_contains result "Suggested next: masc_plan_init -> masc_status"));
      assert (not (str_contains result "Suggested next: masc_heartbeat"));
      assert (not (str_contains result "Suggested next: masc_status -> masc_transition"))
    | None -> failwith "dispatch returned None")
;;

let () =
  test
    "dispatch_status_surfaces_completed_deliverable_conflict_for_active_owned_task"
    (fun () ->
       Fun.protect ~finally:Fs_compat.clear_fs
       @@ fun () ->
       Eio_main.run
       @@ fun env ->
       Fs_compat.set_fs (Eio.Stdenv.fs env);
       let ctx = make_test_ctx () in
       let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
       ignore
         (Workspace.add_task
            ctx.config
            ~title:"Claimed with stale deliverable"
            ~priority:3
            ~description:"");
       ignore (Workspace.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
       set_current_task_ok ctx.config ~task_id:"task-001";
       ignore
         (Planning_eio.set_deliverable
            ctx.config
            ~task_id:"task-001"
            ~content:"Task-001 completed. stale control-plane artifact.");
       match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
       | Some r -> let result = Tool_result.message r in let success = Tool_result.is_success r in
         assert success;
         assert (str_contains result "owned=task-001 | current=task-001");
         assert (str_contains result "Planning: deliverable_conflict=yes | task=task-001");
         assert_contains
           result
           "Owned task task-001 already has a completed-looking deliverable";
         assert (str_contains result "Suggested next: masc_deliver -> masc_status");
         assert (
           not (str_contains result "Suggested next: masc_status -> masc_transition"))
       | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_flags_todo_with_completed_deliverable_as_conflict" (fun () ->
    Fun.protect ~finally:Fs_compat.clear_fs
    @@ fun () ->
    Eio_main.run
    @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    ignore
      (Workspace.add_task ctx.config ~title:"Conflicted todo" ~priority:2 ~description:"");
    ignore (Workspace.add_task ctx.config ~title:"Fresh todo" ~priority:2 ~description:"");
    ignore
      (Planning_eio.set_deliverable
         ctx.config
         ~task_id:"task-001"
         ~content:"Task-001 completed. Exercised masc_operator_snapshot.");
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some r -> let result = Tool_result.message r in let success = Tool_result.is_success r in
      assert success;
      assert (
        str_contains
          result
          "warning task-001 P2 [todo_conflict] Conflicted todo (unclaimed)");
      assert (str_contains result "📋 task-002 P2 [todo] Fresh todo (unclaimed)");
      assert_contains result "1 todo task(s) have completed-looking planning deliverables"
    | None -> failwith "dispatch returned None")
;;

(* Test helper functions *)
let () =
  test "get_string_present" (fun () ->
    let args = `Assoc [ "key", `String "value" ] in
    assert (Tool_args.get_string args "key" "default" = "value"))
;;

let () =
  test "get_string_missing" (fun () ->
    let args = `Assoc [] in
    assert (Tool_args.get_string args "key" "default" = "default"))
;;

let () =
  test "get_bool_true" (fun () ->
    let args = `Assoc [ "key", `Bool true ] in
    assert (Tool_args.get_bool args "key" false = true))
;;

let () =
  test "get_bool_false" (fun () ->
    let args = `Assoc [ "key", `Bool false ] in
    assert (Tool_args.get_bool args "key" true = false))
;;

let () =
  test "get_bool_missing" (fun () ->
    let args = `Assoc [] in
    assert (Tool_args.get_bool args "key" true = true))
;;

(* Issue #7646: valid_next_actions_for_status hint tests. One per
   [Masc_domain.task_status] variant. The witness ensures every variant has a
   defined hint AND the ones with content list each action canonically. *)
let next_hint = Workspace_task.next_actions_hint

let () =
  test "next_hint_todo lists claim, release, and cancel" (fun () ->
    let h = next_hint Masc_domain.Todo in
    assert (str_contains h "claim");
    assert (str_contains h "release");
    assert (str_contains h "cancel");
    assert (str_contains h "valid_next_actions="))
;;

let () =
  test "next_hint_claimed lists start, done, release, cancel" (fun () ->
    let h = next_hint (Masc_domain.Claimed { assignee = "a"; claimed_at = "t" }) in
    assert (str_contains h "start");
    assert (str_contains h "done");
    assert (str_contains h "release");
    assert (str_contains h "cancel"))
;;

let () =
  test "next_hint_in_progress lists done and release" (fun () ->
    let h = next_hint (Masc_domain.InProgress { assignee = "a"; started_at = "t" }) in
    assert (str_contains h "done");
    assert (str_contains h "release");
    assert (not (str_contains h "claim"))
    (* Claim is not legal from InProgress *))
;;

let () =
  test "next_hint_awaiting_verification lists approve and reject" (fun () ->
    let h =
      next_hint
        (Masc_domain.AwaitingVerification
           { assignee = "a"; submitted_at = "t"; verification_id = "v"; phase = Masc_domain.Awaiting_verifier })
    in
    assert (str_contains h "approve");
    assert (str_contains h "reject"))
;;

let () =
  test "next_hint_done is empty (terminal)" (fun () ->
    let h =
      next_hint (Masc_domain.Done { assignee = "a"; completed_at = "t"; notes = None })
    in
    assert (h = ""))
;;

let () =
  test "next_hint_cancelled is empty (terminal)" (fun () ->
    let h =
      next_hint
        (Masc_domain.Cancelled { cancelled_by = "a"; cancelled_at = "t"; reason = None })
    in
    assert (h = ""))
;;

let () =
  Alcotest.run
    "Tool_workspace"
    [ ( "coverage"
      , List.rev !test_cases
        |> List.map (fun (name, f) -> Alcotest.test_case name `Quick f) )
    ]
;;
