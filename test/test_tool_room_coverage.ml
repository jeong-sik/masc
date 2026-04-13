(** Coverage tests for Tool_room *)

open Masc_mcp

let () = Random.self_init ()

let () = Printf.printf "\n=== Tool_room Coverage Tests ===\n"

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

(* Test helper — wraps in Eio context so dispatch paths that use
   Eio.Mutex, Fs_compat, or structured concurrency work correctly. *)
let test name f =
  try
    Eio_main.run @@ (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      with_isolated_runtime_env f);
    Printf.printf "✓ %s passed\n" name
  with e ->
    Printf.printf "✗ %s FAILED: %s\n" name (Printexc.to_string e);
    exit 1

(* Create test context *)
let test_counter = ref 0
let make_test_ctx () =
  incr test_counter;
  let tmp = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-room-test-%d-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) !test_counter) in
  Unix.mkdir tmp 0o755;
  let config = Room.default_config tmp in
  { Tool_room.config; agent_name = "test-agent" }

(* Test dispatch returns None for unknown tool *)
let () = test "dispatch_unknown_tool" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  assert (Tool_room.dispatch ctx ~name:"unknown_tool" ~args = None)
)

(* Test dispatch init *)
let () = test "dispatch_init" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [("agent_name", `String "init-agent")] in
  match Tool_room.dispatch ctx ~name:"masc_init" ~args with
  | Some (success, _result) -> assert success
  | None -> failwith "dispatch returned None"
)

(* Test dispatch status *)
let () = test "dispatch_status" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Room.init ctx.config ~agent_name:(Some "test-agent") in
  let args = `Assoc [] in
  match Tool_room.dispatch ctx ~name:"masc_status" ~args with
  | Some (success, result) ->
      assert success;
      assert (str_contains result "⚡ Snapshot:");
      assert (str_contains result "🧭 You:");
      assert (str_contains result "💡 Suggested next:")
  | None -> failwith "dispatch returned None"
)

(* Test status summary and active task cap *)
let () = test "dispatch_status_summary_and_cap" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Room.init ctx.config ~agent_name:(Some "test-agent") in
  for i = 1 to 35 do
    ignore (Room.add_task ctx.config ~title:(Printf.sprintf "Task %d" i) ~priority:3 ~description:"")
  done;
  let args = `Assoc [] in
  match Tool_room.dispatch ctx ~name:"masc_status" ~args with
  | Some (success, result) ->
      assert success;
      assert (str_contains result "tasks active=35 todo=35 claimed=0 in_progress=0");
      assert (str_contains result "⚠️ Attention:");
      assert (str_contains result "35 unclaimed task(s) are available right now.");
      assert (str_contains result "Summary: active=35, done=0, cancelled=0, total=35");
      assert (str_contains result "and 5 more active tasks")
  | None -> failwith "dispatch returned None"
)

(* Test done task aggregation in summary *)
let () = test "dispatch_status_done_summary" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Room.init ctx.config ~agent_name:(Some "test-agent") in
  let _ = Room.add_task ctx.config ~title:"Done Task" ~priority:2 ~description:"" in
  ignore (Room.claim_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001");
  ignore (Room.complete_task ctx.config ~agent_name:"test-agent" ~task_id:"task-001" ~notes:"ok");
  let args = `Assoc [] in
  match Tool_room.dispatch ctx ~name:"masc_status" ~args with
  | Some (success, result) ->
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
  let _ = Room.init ctx.config ~agent_name:(Some "test-agent") in
  let args = `Assoc [] in
  match Tool_room.dispatch ctx ~name:"masc_reset" ~args with
  | Some (success, _result) -> assert (not success) (* Should fail without confirm *)
  | None -> failwith "dispatch returned None"
)

(* Test dispatch reset with confirm *)
let () = test "dispatch_reset_with_confirm" (fun () ->
  let ctx = make_test_ctx () in
  let _ = Room.init ctx.config ~agent_name:(Some "test-agent") in
  let args = `Assoc [("confirm", `Bool true)] in
  match Tool_room.dispatch ctx ~name:"masc_reset" ~args with
  | Some (success, _result) -> assert success
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_removed_named_room_tools" (fun () ->
  let ctx = make_test_ctx () in
  let args = `Assoc [] in
  assert (Tool_room.dispatch ctx ~name:"masc_rooms_list" ~args = None);
  assert (Tool_room.dispatch ctx ~name:"masc_room_create" ~args = None);
  assert (Tool_room.dispatch ctx ~name:"masc_room_enter" ~args = None)
)

let () = test "dispatch_check_transition_claim_requires_plan_task" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = make_test_ctx () in
  let _ = Room.init ctx.config ~agent_name:(Some "test-agent") in
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
  match Tool_room.dispatch ctx ~name:"masc_check"
          ~args:(`Assoc [("assertions", `List [`String "task_claimed"; `String "current_task_set"])]) with
  | Some (success, result) ->
      assert success;
      let json = Yojson.Safe.from_string result in
      assert (Yojson.Safe.Util.member "all_passed" json = `Bool false);
      assert (
        Yojson.Safe.Util.member "fix_hint" json
        = `String
            "Call masc_plan_set_task after claim paths that did not auto-bind current_task (for example masc_transition(action=claim))")
  | None -> failwith "dispatch returned None"
)

let () = test "dispatch_check_claim_next_marks_current_task_set" (fun () ->
  Fun.protect ~finally:Fs_compat.clear_fs @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let ctx = make_test_ctx () in
  let _ = Room.init ctx.config ~agent_name:(Some "test-agent") in
  let task_ctx =
    { Tool_task.config = ctx.config; agent_name = ctx.agent_name; sw = None }
  in
  let _ =
    Tool_task.handle_add_task task_ctx
      (`Assoc [("title", `String "Check claim next")])
  in
  let (_success, _result) = Tool_task.handle_claim_next task_ctx (`Assoc []) in
  match Tool_room.dispatch ctx ~name:"masc_check"
          ~args:(`Assoc [("assertions", `List [`String "task_claimed"; `String "current_task_set"])]) with
  | Some (success, result) ->
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

let () = Printf.printf "\n✅ All Tool_room tests passed!\n"
