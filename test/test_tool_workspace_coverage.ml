module Types = Masc_domain

(** Coverage tests for Tool_workspace *)

open Masc
open Workspace_types
module Planning_eio = Masc.Task.Planning_eio

let () = Random.self_init ()
let () = Mirage_crypto_rng_unix.use_default ()
let () = Workspace_metric_hooks.install ()

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

let status_message result =
  match Tool_result.data result with
  | `Assoc fields ->
    (match List.assoc_opt "snapshot" fields with
     | Some (`String snapshot) -> snapshot
     | Some _ | None -> Tool_result.message result)
  | _ -> Tool_result.message result
;;

let set_current_task_ok config ~task_id =
  match Planning_eio.set_current_task config ~task_id with
  | Ok () -> ()
  | Error msg -> failwith msg
;;

let verification_id_for_task config task_id =
  match
    Workspace.get_tasks_raw config
    |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id task_id)
  with
  | Some
      { task_status = Masc_domain.AwaitingVerification { verification_id; _ }; _ } ->
    verification_id
  | Some _ -> failwith (Printf.sprintf "task %s is not awaiting verification" task_id)
  | None -> failwith (Printf.sprintf "task %s not found" task_id)

let complete_task config ~agent_name ~task_id ~notes =
  match
    Workspace.transition_task_r config ~agent_name ~task_id
      ~action:Masc_domain.Submit_for_verification ~notes ()
  with
  | Error error -> failwith (Masc_domain.masc_error_to_string error)
  | Ok _ ->
    (* No peer-keeper claim: the verdict comes from a completion authority. *)
    (match
       Workspace.commit_verdict_r
         config
         ~authority:(Masc_domain.Human_operator { operator_id = "operator-test" })
         ~verdict:Masc_domain.Verdict_approved
         ~task_id
         ~verification_id:(verification_id_for_task config task_id)
         ~notes:("verified: " ^ notes)
         ()
     with
     | Ok _ -> ()
     | Error error -> failwith (Masc_domain.masc_error_to_string error))
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
  let old_last_seen = "2020-01-01T00:00:00Z" in
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
  Workspace.write_backlog config { backlog with tasks }
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
      let message = status_message result in
      assert (str_contains message "Snapshot:");
      assert (str_contains message "🧭 You:");
      assert (not (str_contains message "Suggested next:"))
    | None -> failwith "dispatch returned None")
;;

let snapshot_revision result =
  Tool_result.data result |> Yojson.Safe.Util.member "revision" |> Yojson.Safe.Util.to_string
;;

(* This asserted that masc_status initializes the workspace, and raised
   "MASC not initialized" instead. Initializing is masc_start's job: no tool in
   Tool_workspace calls Workspace.init, and status_summary_string opens with
   ensure_initialized, which is the contract refusing to invent a workspace as
   a side effect of a read.

   So the name described a behaviour that never existed. What is worth pinning
   is the refusal itself, and that the read leaves nothing behind. *)
let () =
  test "dispatch_status_refuses an uninitialized workspace" (fun () ->
    let ctx = make_test_ctx () in
    let raised =
      match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
      | (_ : Tool_result.result option) -> false
      | exception Workspace.Not_initialized -> true
    in
    assert raised;
    (* A read that refuses must not have created the state it was refusing to
       read. *)
    assert (not (Sys.file_exists (Workspace_utils_paths_backend.state_path ctx.config))))
;;

let () =
  test "dispatch_status_revision_covers_rendered_credential_state" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some ctx.agent_name) in
    let first =
      match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
      | Some result -> result
      | None -> failwith "dispatch returned None"
    in
    let revision = snapshot_revision first in
    Auth.save_auth_config
      ctx.config.base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let second =
      match
        Tool_workspace.dispatch
          ctx
          ~name:"masc_status"
          ~args:(`Assoc [ "if_revision", `String revision ])
      with
      | Some result -> result
      | None -> failwith "dispatch returned None"
    in
    assert (Tool_result.is_success second);
    let data = Tool_result.data second in
    assert (Yojson.Safe.Util.(data |> member "kind" |> to_string) = "snapshot");
    assert_contains
      Yojson.Safe.Util.(data |> member "snapshot" |> to_string)
      "Lifecycle actions are credential-blocked")
;;

let () =
  test "dispatch_status_observes_recovered_backlog" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some ctx.agent_name) in
    ignore
      (Workspace.add_task
         ctx.config
         ~title:"Recovered status task"
         ~priority:2
         ~description:"");
    let oc = open_out (Workspace.backlog_path ctx.config) in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc "{not valid json");
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some result ->
      assert (Tool_result.is_success result);
      let data = Tool_result.data result in
      assert_contains (status_message result) "Recovered status task";
      assert_contains (status_message result) "recovery-backed and non-authoritative";
      assert (Yojson.Safe.Util.(data |> member "degraded" |> to_bool));
      assert
        (Yojson.Safe.Util.(data |> member "backlog_authority" |> to_string)
         = "recovery_non_authoritative");
      let revision = Yojson.Safe.Util.(data |> member "revision" |> to_string) in
      (match
         Tool_workspace.dispatch
           ctx
           ~name:"masc_status"
           ~args:(`Assoc [ "if_revision", `String revision ])
       with
       | Some repeated ->
         assert
           (Yojson.Safe.Util.(Tool_result.data repeated |> member "kind" |> to_string)
            = "snapshot")
       | None -> failwith "repeated status dispatch returned None")
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_reports_backlog_read_failure" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some ctx.agent_name) in
    let corrupt path =
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc "{not valid json")
    in
    corrupt (Workspace.backlog_path ctx.config);
    corrupt (Workspace.backlog_recovery_path ctx.config);
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some result ->
      assert (Tool_result.is_failed result);
      assert (Tool_result.failure_class result = Some Tool_result.Runtime_failure);
      assert_contains (Tool_result.message result) "status snapshot unavailable";
      (match Tool_result.data result with
       | `Assoc fields ->
         assert (List.mem_assoc "error_code" fields);
         assert (List.mem_assoc "message" fields)
       | _ -> failwith "expected assoc data envelope")
    | None -> failwith "dispatch returned None")
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
      let message = status_message result in
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
          let message = status_message result in
          assert_contains message "Snapshot: agents=2";
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
      let msg = status_message result in
      assert (str_contains msg "tasks active=35 todo=35 claimed=0 in_progress=0");
      assert (str_contains msg "Attention:");
      assert_contains msg "35 unclaimed task(s) are available right now.";
      assert (str_contains msg "Summary: active=35, done=0, cancelled=0, total=35");
      assert_contains msg "and 5 more active tasks";
      assert_not_contains msg "use keeper_tasks_list for full list";
      (match
         Tool_workspace.dispatch_for_keeper ctx ~name:"masc_status" ~args
       with
       | Some keeper_result ->
         let keeper_message = status_message keeper_result in
         assert (Tool_result.is_success keeper_result);
         assert_contains
           keeper_message
           "and 5 more active tasks";
         assert_not_contains keeper_message "use masc_tasks for full list"
       | None -> failwith "Keeper status dispatch returned None")
    | None -> failwith "dispatch returned None")
;;

(* Test done task aggregation in summary *)
let () =
  test "dispatch_status_done_summary" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    let _ = Workspace.add_task ctx.config ~title:"Done Task" ~priority:2 ~description:"" in
    ignore (Workspace.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
    complete_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001" ~notes:"ok";
    let args = `Assoc [] in
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args with
    | Some r ->
      let result = status_message r in
      assert (Tool_result.is_success r);
      assert (str_contains result "owned=-");
      assert (str_contains result "tasks active=0 todo=0 claimed=0 in_progress=0");
      assert (str_contains result "Summary: active=0, done=1, cancelled=0, total=1");
      assert (str_contains result "(no active tasks)")
    | None -> failwith "dispatch returned None")
;;

(* The other half of the contract: a task with no side-registry link renders
   exactly as it did before goal links existed. Without this, a change that
   suffixed every row — or one that suffixed an empty goal id — would still
   pass the linked-task test above. *)
let () =
  test "dispatch_status_leaves_unlinked_task_unsuffixed" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    ignore
      (Workspace.add_task ctx.config ~title:"Unlinked task" ~priority:2 ~description:"");
    let args = `Assoc [] in
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args with
    | Some result ->
      assert (Tool_result.is_success result);
      let msg = status_message result in
      assert_contains msg "Unlinked task";
      assert_not_contains msg "goal:"
    | None -> failwith "dispatch returned None")
;;

(* Quest Board rendering surfaces a task's goal link from the RFC-0267
   goal_task_links side registry (the task record itself carries no goal_id). *)
let () =
  test "dispatch_status_surfaces_task_goal_link" (fun () ->
    let ctx = make_test_ctx () in
    let _ = Workspace.init ctx.config ~agent_name:(Some "test-agent") in
    ignore
      (Workspace.add_task ctx.config ~title:"Goal-linked task" ~priority:2 ~description:"");
    (match
       Workspace_goal_index.link_task_to_goal_result
         ctx.config
         ~goal_id:"g-1"
         ~task_id:"task-001"
     with
     | Ok () -> ()
     | Error msg -> failwith ("goal link failed: " ^ msg));
    let args = `Assoc [] in
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args with
    | Some result ->
      assert (Tool_result.is_success result);
      let msg = status_message result in
      assert_contains msg "Goal-linked task";
      assert_contains msg "goal:g-1"
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_surfaces_awaiting_verification_assignment" (fun () ->
    (
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
           ~notes:"verification status setup notes"
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
        let result = status_message r in
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
    complete_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001" ~notes:"ok";
    let actual_name = actual_test_agent_name ctx.config in
    write_agent_state ctx.config actual_name (fun agent ->
      { agent with
        status = Masc_domain.Busy
      ; current_task = Some " task-001\nignored-line "
      });
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some r ->
      let result = status_message r in
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
      let result = status_message r in
      assert (Tool_result.is_success r);
      assert_contains result (actual_name ^ " (you) -> task-001");
      assert_not_contains result (actual_name ^ " (you) -> task-002");
      assert_not_contains result (actual_name ^ " (you) -> busy (stale:task-002)")
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
     | Some r -> let result = status_message r in let success = Tool_result.is_success r in
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
      assert (Json_util.assoc_member_opt "fix_hint" json = None);
      let assertions =
        Yojson.Safe.Util.member "assertions" json |> Yojson.Safe.Util.to_list
      in
      assert (
        List.exists
          (fun row ->
             Yojson.Safe.Util.member "assertion" row
             = `String "current_task_set"
             && Yojson.Safe.Util.member "passed" row = `Bool false)
          assertions)
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
      assert (Json_util.assoc_member_opt "fix_hint" json = None);
      let assertions =
        Yojson.Safe.Util.member "assertions" json |> Yojson.Safe.Util.to_list
      in
      assert (
        List.exists
          (fun row ->
             Yojson.Safe.Util.member "assertion" row
             = `String "current_task_set"
             && Yojson.Safe.Util.member "passed" row = `Bool false)
          assertions)
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
    | Some r -> let result = status_message r in let success = Tool_result.is_success r in
      assert success;
      assert (str_contains result "owned=task-001");
      assert (str_contains result "current=task-002");
      assert (not (str_contains result "Suggested next:"));
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
    | Some r -> let result = status_message r in let success = Tool_result.is_success r in
      assert success;
      assert (
        str_contains
          result
          "Credential: required=yes | available=no | candidates=test-agent");
      assert (
        str_contains result "Lifecycle actions are credential-blocked for test-agent");
      assert (not (str_contains result "Suggested next:"))
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_treats_registered_keeper_internal_auth_as_credential" (fun () ->
    let previous = Atomic.get Workspace_hooks.keeper_registered_fn in
    Fun.protect
      ~finally:(fun () ->
        Fs_compat.clear_fs ();
        Atomic.set Workspace_hooks.keeper_registered_fn previous)
    @@ fun () ->
    Eio_main.run
    @@ fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    let ctx = { (make_test_ctx ()) with agent_name = "keeper-alpha-agent" } in
    Atomic.set Workspace_hooks.keeper_registered_fn (fun ~base_path ~agent_name ->
      String.equal base_path ctx.config.base_path
      && String.equal agent_name ctx.agent_name);
    let _ = Workspace.init ctx.config ~agent_name:(Some "keeper-alpha-agent") in
    ignore (Auth.enable_auth ctx.config.base_path ~require_token:true ~agent_name:"admin");
    ignore (Auth.ensure_internal_keeper_token ctx.config.base_path);
    ignore (Workspace.add_task ctx.config ~title:"Keeper work" ~priority:3 ~description:"");
    set_current_task_ok ctx.config ~task_id:"task-001";
    match Tool_workspace.dispatch ctx ~name:"masc_status" ~args:(`Assoc []) with
    | Some r ->
      let result = status_message r in
      let success = Tool_result.is_success r in
      assert success;
      assert (
        str_contains
          result
          "Credential: required=yes | available=yes | candidates=keeper-alpha-agent");
      assert (
        not
          (str_contains
             result
             "Lifecycle actions are credential-blocked for keeper-alpha-agent"));
      assert (not (str_contains result "Suggested next:"))
    | None -> failwith "dispatch returned None")
;;

let () =
  test "dispatch_status_no_owned_reports_drift_without_steering" (fun () ->
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
    | Some r -> let result = status_message r in let success = Tool_result.is_success r in
      assert success;
      assert (str_contains result "owned=- | current=task-001");
      assert (str_contains result "drift_reason=no_owned");
      assert (str_contains result "claim_first_suppressed=no");
      assert_not_contains result "Suggested next:"
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
  test "next_hint_todo lists claim and cancel, not release" (fun () ->
    let h = next_hint Masc_domain.Todo in
    assert (str_contains h "claim");
    assert (str_contains h "cancel");
    (* Release on a Todo is admitted and returns it unchanged -- there is
       nothing held to hand back. The hint lists what moves the Task. *)
    assert (not (str_contains h "release"));
    assert (str_contains h "valid_next_actions="))
;;

let () =
  test "next_hint_claimed lists submit, start, release, cancel" (fun () ->
    let h = next_hint (Masc_domain.Claimed { assignee = "a"; claimed_at = "t" }) in
    assert (str_contains h "start");
    assert (str_contains h "submit_for_verification");
    assert (not (str_contains h "done"));
    assert (str_contains h "release");
    assert (str_contains h "cancel"))
;;

let () =
  test "next_hint_in_progress lists submit and release" (fun () ->
    let h = next_hint (Masc_domain.InProgress { assignee = "a"; started_at = "t" }) in
    assert (str_contains h "submit_for_verification");
    assert (not (str_contains h "done"));
    assert (str_contains h "release");
    assert (not (str_contains h "claim"))
    (* Claim is not legal from InProgress *))
;;

let () =
  test "next_hint_awaiting_verification offers supersede alongside cancel" (fun () ->
    let h =
      next_hint
        (Masc_domain.AwaitingVerification
           { assignee = "a"
           ; started_at = "2026-07-13T00:00:00Z"
           ; submitted_at = "t"
           ; intent = Complete_task
           ; verification_id = "v"
           })
    in
    (* This hint is where an assignee learns the state has an exit other than
       Cancel: the live log carried 16 refused resubmissions while the hint
       read "[cancel]". *)
    assert (str_contains h "submit_for_verification");
    assert (str_contains h "cancel"))
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
