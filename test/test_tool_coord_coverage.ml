(** Coverage tests for Tool_coord *)

open Masc_mcp
open Coord_types

let () = Random.self_init ()

let str_contains s sub =
  let len_s = String.length s in
  let len_sub = String.length sub in
  if len_sub > len_s then false
  else
    let rec loop i =
      if i > len_s - len_sub then false
      else if String.sub s i len_sub = sub then true
      else loop (i + 1)
    in
    loop 0

let assert_contains output expected =
  if not (str_contains output expected) then
    failwith
      (Printf.sprintf "missing expected substring %S in output:\n%s" expected
         output)

let assert_not_contains output unexpected =
  if str_contains output unexpected then
    failwith
      (Printf.sprintf "unexpected substring %S in output:\n%s" unexpected
         output)

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect
    ~finally:restore
    (fun () ->
      (match value_opt with
       | Some value -> Unix.putenv name value
       | None -> Unix.putenv name "");
      f ())

let with_isolated_runtime_env f =
  with_env "MASC_BASE_PATH" None (fun () ->
    with_env "MASC_BASE_PATH_INPUT" None (fun () ->
      with_env "MASC_STORAGE_TYPE" None (fun () ->
        with_env "MASC_POSTGRES_URL" None (fun () ->
          with_env "DATABASE_URL" None (fun () ->
            with_env "SUPABASE_DB_URL" None (fun () ->
              with_env "SB_PG_URL" None f))))))

(* Test registry — each [test] call appends to this list; the final
   [let ()] dispatches the list through Alcotest.run.  Eio scope is
   set up per-test inside the registered thunk. *)
let test_cases : (string * (unit -> unit)) list ref = ref []

let test name f =
  test_cases := (name, fun () ->
    Eio_main.run @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    with_isolated_runtime_env f) :: !test_cases

(* Create test context *)
let test_counter = ref 0
let make_test_ctx () =
  incr test_counter;
  let tmp = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-room-test-%d-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) !test_counter) in
  Unix.mkdir tmp 0o755;
  let config = Coord.default_config tmp in
  Auth.save_auth_config config.base_path
    { Types.default_auth_config with enabled = false; require_token = false };
  { Tool_coord.config; agent_name = "test-agent" }

(* Test dispatch returns None for unknown tool *)
let () = test "dispatch_unknown_tool" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  assert (Tool_coord.dispatch ctx ~name:"unknown_tool" ~args = None)
)

(* Test dispatch init — masc_init was pruned from registry; dispatch returns None. *)
let () = test "dispatch_init" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("agent_name", `String "init-agent")] in
  assert (Tool_coord.dispatch ctx ~name:"masc_init" ~args = None)
)

(* Test dispatch status *)
let () = test "dispatch_status" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  let args = `Assoc [] in
  match Tool_coord.dispatch ctx ~name:"masc_status" ~args with
  | Some { success; message } ->
      assert success;
      assert (str_contains message "⚡ Snapshot:");
      assert (str_contains message "🧭 You:");
      assert (str_contains message "💡 Suggested next:")
  | None -> failwith "dispatch returned None"
)

(* Test dispatch coordination FSM snapshot *)
let () = test "dispatch_coordination_fsm_snapshot" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  let args = `Assoc [] in
  match Tool_coord.dispatch ctx ~name:"masc_coordination_fsm_snapshot" ~args with
  | Some { success; message = result } ->
      assert success;
      let json = Yojson.Safe.from_string result in
      let open Yojson.Safe.Util in
      assert (json |> member "mode" |> to_string = "advisory");
      assert (json |> member "summary" |> member "products" |> to_int >= 0);
      assert (json |> member "summary" |> member "evidence" |> to_int >= 0)
  | None -> failwith "dispatch returned None"
)

(* Test status summary and active task cap *)
let () = test "dispatch_status_summary_and_cap" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  for i = 1 to 35 do
    ignore (Coord.add_task ctx.config ~title:(Printf.sprintf "Task %d" i) ~priority:3 ~description:"")
  done;
  let args = `Assoc [] in
  match Tool_coord.dispatch ctx ~name:"masc_status" ~args with
  | Some { success; message = result } ->
      assert success;
      assert (str_contains result "tasks active=35 todo=35 claimed=0 in_progress=0");
      assert (str_contains result "⚠️ Attention:");
      assert_contains result "35 unclaimed task(s) are available right now.";
      assert (str_contains result "Summary: active=35, done=0, cancelled=0, total=35");
      assert (str_contains result "and 5 more active tasks")
  | None -> failwith "dispatch returned None"
)

(* Test done task aggregation in summary *)
let () = test "dispatch_status_done_summary" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  let _ = Coord.add_task ctx.config ~title:"Done Task" ~priority:2 ~description:"" in
  ignore (Coord.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
  (match
     Coord.transition_task_r ctx.config ~agent_name:"test-agent"
       ~task_id:"task-001" ~action:Types.Done_action ~notes:"ok" ()
   with
  | Ok _ -> ()
  | Error err -> failwith (Types.masc_error_to_string err));
  let args = `Assoc [] in
  match Tool_coord.dispatch ctx ~name:"masc_status" ~args with
  | Some { success; message = result } ->
      assert success;
      assert (str_contains result "owned=-");
      assert (str_contains result "tasks active=0 todo=0 claimed=0 in_progress=0");
      assert (str_contains result "Summary: active=0, done=1, cancelled=0, total=1");
      assert (str_contains result "(no active tasks)")
  | None -> failwith "dispatch returned None"
)

(* Test dispatch reset without confirm *)
let () = test "dispatch_reset_no_confirm" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  let args = `Assoc [] in
  match Tool_coord.dispatch ctx ~name:"masc_reset" ~args with
  | Some { success; message = _result } -> assert (not success) (* Should fail without confirm *)
  | None -> failwith "dispatch returned None"
)

(* Test dispatch reset with confirm *)
let () = test "dispatch_reset_with_confirm" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  let args = `Assoc [("confirm", `Bool true)] in
  match Tool_coord.dispatch ctx ~name:"masc_reset" ~args with
  | Some { success; message = _result } -> assert success
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_removed_named_room_tools" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  assert (Tool_coord.dispatch ctx ~name:"masc_rooms_list" ~args = None);
  assert (Tool_coord.dispatch ctx ~name:"masc_room_create" ~args = None);
  assert (Tool_coord.dispatch ctx ~name:"masc_room_enter" ~args = None)
)

let () = test "dispatch_check_transition_claim_auto_binds_current_task" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  let task_ctx =
    { Tool_task.config = ctx.config; agent_name = ctx.agent_name; sw = None }
  in
  let _ =
    Tool_task.handle_add_task task_ctx
      (`Assoc [("title", `String "Check transition claim")])
  in
  let (_success, _result) =
    Tool_task.handle_transition task_ctx
      (`Assoc [("task_id", `String "task-001"); ("action", `String "claim")])
  in
  match Tool_coord.dispatch ctx ~name:"masc_check"
          ~args:(`Assoc [("assertions", `List [`String "task_claimed"; `String "current_task_set"])]) with
  | Some { success; message = result } ->
      assert success;
      let json = Yojson.Safe.from_string result in
      assert (Yojson.Safe.Util.member "all_passed" json = `Bool true)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_check_claim_next_marks_current_task_set" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  let task_ctx =
    { Tool_task.config = ctx.config; agent_name = ctx.agent_name; sw = None }
  in
  let _ =
    Tool_task.handle_add_task task_ctx
      (`Assoc [("title", `String "Check claim next")])
  in
  let (_success, _result) = Tool_task.handle_claim_next task_ctx (`Assoc []) in
  match Tool_coord.dispatch ctx ~name:"masc_check"
          ~args:(`Assoc [("assertions", `List [`String "task_claimed"; `String "current_task_set"])]) with
  | Some { success; message = result } ->
      assert success;
      let json = Yojson.Safe.from_string result in
      assert (Yojson.Safe.Util.member "all_passed" json = `Bool true)
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_status_multi_assignment_current_requires_disambiguation" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  let _ = Coord.add_task ctx.config ~title:"Primary lane" ~priority:2 ~description:"" in
  let _ = Coord.add_task ctx.config ~title:"Secondary lane" ~priority:2 ~description:"" in
  ignore (Coord.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
  ignore (Coord.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-002");
  Planning_eio.set_current_task ctx.config ~task_id:"task-002";
  (match Tool_coord.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
  | Some { success; message = result } ->
      assert success;
      assert (str_contains result "owned=task-001 | current=task-002");
      assert (str_contains result "assigned_set=[task-001,task-002]");
      assert (str_contains result "primary_owned=task-001");
      assert (str_contains result "planning_current=task-002");
      assert (str_contains result "current_is_assigned=yes");
      assert (str_contains result "effective_current=task-002");
      assert (str_contains result "drift_reason=secondary_assignment");
      assert (str_contains result "claim_first_suppressed=yes");
      assert (not (str_contains result "task-002 is stale focus"))
  | None -> failwith "dispatch returned None");
  match Tool_coord.dispatch ctx ~name:"masc_check"
          ~args:(`Assoc [("assertions", `List [`String "task_claimed"; `String "current_task_set"])]) with
  | Some { success; message = result } ->
      assert success;
      let json = Yojson.Safe.from_string result in
      assert (Yojson.Safe.Util.member "all_passed" json = `Bool false);
      assert (
        Yojson.Safe.Util.member "fix_hint" json
        = `String
            "Call masc_plan_set_task to choose or re-sync the active task when current_task is unset, stale, or ambiguous")
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_check_owned_current_drift_fails_current_task_set" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  ignore (Coord.add_task ctx.config ~title:"Owned task" ~priority:3 ~description:"");
  ignore (Coord.add_task ctx.config ~title:"Stale current task" ~priority:3 ~description:"");
  ignore (Coord.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
  Planning_eio.set_current_task ctx.config ~task_id:"task-002";
  match Tool_coord.dispatch ctx ~name:"masc_check"
          ~args:(`Assoc [("assertions", `List [`String "task_claimed"; `String "current_task_set"])]) with
  | Some { success; message = result } ->
      assert success;
      let json = Yojson.Safe.from_string result in
      assert (Yojson.Safe.Util.member "all_passed" json = `Bool false);
      assert (
        Yojson.Safe.Util.member "fix_hint" json
        = `String
            "Call masc_plan_set_task to choose or re-sync the active task when current_task is unset, stale, or ambiguous")
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_status_surfaces_owned_current_drift" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  ignore (Coord.add_task ctx.config ~title:"Owned task" ~priority:3 ~description:"");
  ignore (Coord.add_task ctx.config ~title:"Stale current task" ~priority:3 ~description:"");
  ignore (Coord.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
  Planning_eio.set_current_task ctx.config ~task_id:"task-002";
  match Tool_coord.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
  | Some { success; message = result } ->
      assert success;
      assert (str_contains result "owned=task-001");
      assert (str_contains result "current=task-002");
      assert_contains result
        "Do not retry generic masc_plan_init from a drifted surface";
      assert (not (str_contains result "💡 Suggested next: masc_plan_init -> masc_status"));
      assert (str_contains result "planning current_task is unset or drifted")
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_status_suppresses_lifecycle_guidance_without_credential" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  ignore (Auth.enable_auth ctx.config.base_path ~require_token:true ~agent_name:"admin");
  ignore (Coord.add_task ctx.config ~title:"Credentialed work" ~priority:3 ~description:"");
  Planning_eio.set_current_task ctx.config ~task_id:"task-001";
  match Tool_coord.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
  | Some { success; message = result } ->
      assert success;
      assert (str_contains result "🔐 Credential: required=yes | available=no | candidates=test-agent");
      assert (str_contains result "Lifecycle actions are credential-blocked for test-agent");
      assert (not (str_contains result "💡 Suggested next: masc_status -> masc_transition"));
      assert (not (str_contains result "💡 Suggested next: masc_claim_next"))
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_status_treats_keeper_internal_auth_as_credential" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = { (make_test_ctx ()) with agent_name = "keeper-sangsu-agent" } in
  let _ = Coord.init ctx.config ~agent_name:(Some "keeper-sangsu-agent") in
  ignore (Auth.enable_auth ctx.config.base_path ~require_token:true ~agent_name:"admin");
  ignore (Auth.ensure_internal_keeper_token ctx.config.base_path);
  ignore (Coord.add_task ctx.config ~title:"Keeper work" ~priority:3 ~description:"");
  Planning_eio.set_current_task ctx.config ~task_id:"task-001";
  match Tool_coord.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
  | Some { success; message = result } ->
      assert success;
      assert (
        str_contains result
          "🔐 Credential: required=yes | available=yes | candidates=keeper-sangsu-agent");
      assert (
        not
          (str_contains result
             "Lifecycle actions are credential-blocked for keeper-sangsu-agent"));
      assert (str_contains result "💡 Suggested next:")
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_status_no_owned_prefers_claim_next_over_transition" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  ignore (Auth.enable_auth ctx.config.base_path ~require_token:true ~agent_name:"test-agent");
  ignore (Coord.add_task ctx.config ~title:"Unclaimed task" ~priority:3 ~description:"");
  Planning_eio.set_current_task ctx.config ~task_id:"task-001";
  match Tool_coord.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
  | Some { success; message = result } ->
      assert success;
      assert (str_contains result "owned=- | current=task-001");
      assert (str_contains result "drift_reason=no_owned");
      assert (str_contains result "claim_first_suppressed=no");
      assert_contains result "💡 Suggested next: masc_claim_next -> masc_status";
      assert_not_contains result "💡 Suggested next: masc_status -> masc_transition"
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_status_surfaces_missing_planning_for_owned_task" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  ignore (Coord.add_task ctx.config ~title:"Claimed without plan" ~priority:3 ~description:"");
  ignore (Coord.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
  Planning_eio.set_current_task ctx.config ~task_id:"task-001";
  match Tool_coord.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
  | Some { success; message = result } ->
      assert success;
      assert (str_contains result "owned=task-001 | current=task-001");
      assert (str_contains result "📝 Planning: missing=yes | task=task-001");
      assert_contains result "Owned task task-001 has no planning context.";
      assert (
        str_contains result
          "Do not retry generic masc_plan_init from a drifted surface");
      assert (str_contains result "handoff/worktree/test logs as the temporary SSOT");
      assert (not (str_contains result "💡 Suggested next: masc_plan_init -> masc_status"));
      assert (not (str_contains result "💡 Suggested next: masc_heartbeat"));
      assert (not (str_contains result "💡 Suggested next: masc_status -> masc_transition"))
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_status_surfaces_completed_deliverable_conflict_for_active_owned_task" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  ignore (Coord.add_task ctx.config ~title:"Claimed with stale deliverable" ~priority:3 ~description:"");
  ignore (Coord.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
  Planning_eio.set_current_task ctx.config ~task_id:"task-001";
  ignore
    (Planning_eio.set_deliverable ctx.config ~task_id:"task-001"
       ~content:"Task-001 completed. stale control-plane artifact.");
  match Tool_coord.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
  | Some { success; message = result } ->
      assert success;
      assert (str_contains result "owned=task-001 | current=task-001");
      assert (str_contains result "📝 Planning: deliverable_conflict=yes | task=task-001");
      assert_contains result
        "Owned task task-001 already has a completed-looking deliverable";
      assert (str_contains result "💡 Suggested next: masc_deliver -> masc_status");
      assert (not (str_contains result "💡 Suggested next: masc_status -> masc_transition"))
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_status_flags_todo_with_completed_deliverable_as_conflict" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  ignore (Coord.add_task ctx.config ~title:"Conflicted todo" ~priority:2 ~description:"");
  ignore (Coord.add_task ctx.config ~title:"Fresh todo" ~priority:2 ~description:"");
  ignore
    (Planning_eio.set_deliverable ctx.config ~task_id:"task-001"
       ~content:"Task-001 completed. Exercised masc_observe_operations.");
  match Tool_coord.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
  | Some { success; message = result } ->
      assert success;
      assert (str_contains result "⚠️ task-001 P2 [todo_conflict] Conflicted todo (unclaimed)");
      assert (str_contains result "📋 task-002 P2 [todo] Fresh todo (unclaimed)");
      assert_contains result
        "1 todo task(s) have completed-looking planning deliverables";
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_check_project_ready_alias" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Coord.init ctx.config ~agent_name:(Some "test-agent") in
  match Tool_coord.dispatch ctx ~name:"masc_check"
          ~args:(`Assoc [("assertions", `List [`String "project_ready"])]) with
  | Some { success; message = result } ->
      assert success;
      let json = Yojson.Safe.from_string result in
      assert (Yojson.Safe.Util.member "all_passed" json = `Bool true)
  | None -> failwith "dispatch returned None"
)

(* Test helper functions *)
let () = test "get_string_present" (fun () ->
  let args = `Assoc [("key", `String "value")] in
  assert (Tool_args.get_string args "key" "default" = "value")
)

let () = test "get_string_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_string args "key" "default" = "default")
)

let () = test "get_bool_true" (fun () ->
  let args = `Assoc [("key", `Bool true)] in
  assert (Tool_args.get_bool args "key" false = true)
)

let () = test "get_bool_false" (fun () ->
  let args = `Assoc [("key", `Bool false)] in
  assert (Tool_args.get_bool args "key" true = false)
)

let () = test "get_bool_missing" (fun () ->
  let args = `Assoc [] in
  assert (Tool_args.get_bool args "key" true = true)
)

(* Issue #7646: valid_next_actions_for_status hint tests. One per
   [Types.task_status] variant. The witness ensures every variant has a
   defined hint AND the ones with content list each action canonically. *)
let next_hint = Coord_task.next_actions_hint

let () = test "next_hint_todo lists claim and cancel" (fun () ->
  let h = next_hint Types.Todo in
  assert (str_contains h "claim");
  assert (str_contains h "cancel");
  assert (str_contains h "valid_next_actions=")
)

let () = test "next_hint_claimed lists start, done, release, cancel" (fun () ->
  let h = next_hint (Types.Claimed { assignee = "a"; claimed_at = "t" }) in
  assert (str_contains h "start");
  assert (str_contains h "done");
  assert (str_contains h "release");
  assert (str_contains h "cancel")
)

let () = test "next_hint_in_progress lists done and release" (fun () ->
  let h = next_hint (Types.InProgress { assignee = "a"; started_at = "t" }) in
  assert (str_contains h "done");
  assert (str_contains h "release");
  assert (not (str_contains h "claim"))  (* Claim is not legal from InProgress *)
)

let () = test "next_hint_awaiting_verification lists approve and reject" (fun () ->
  let h = next_hint (Types.AwaitingVerification {
    assignee = "a"; submitted_at = "t"; verification_id = "v";
    deadline = None }) in
  assert (str_contains h "approve");
  assert (str_contains h "reject")
)

let () = test "next_hint_done is empty (terminal)" (fun () ->
  let h = next_hint (Types.Done { assignee = "a"; completed_at = "t"; notes = None }) in
  assert (h = "")
)

let () = test "next_hint_cancelled is empty (terminal)" (fun () ->
  let h = next_hint (Types.Cancelled { cancelled_by = "a"; cancelled_at = "t"; reason = None }) in
  assert (h = "")
)

let () =
  Alcotest.run "Tool_coord"
    [
      ( "coverage",
        List.rev !test_cases
        |> List.map (fun (name, f) -> Alcotest.test_case name `Quick f) );
    ]
