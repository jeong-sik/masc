(** Coverage tests for Tool_relay *)

open Masc_mcp

let () = Random.self_init ()

let () = Printf.printf "\n=== Tool_relay Coverage Tests ===\n"

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

(* Test helper *)
let test name f =
  try
    with_isolated_runtime_env f;
    Printf.printf "✓ %s passed\n" name
  with e ->
    Printf.printf "✗ %s FAILED: %s\n" name (Printexc.to_string e);
    exit 1

(* Create test context - use counter for unique directories *)
let test_counter = ref 0
let make_test_ctx ~sw ~proc_mgr () =
  incr test_counter;
  let tmp = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "masc-relay-test-%d-%d" (int_of_float (Unix.gettimeofday () *. 1000.0)) !test_counter) in
  Unix.mkdir tmp 0o755;
  let config = Room.default_config tmp in
  { Tool_relay.config; agent_name = "test-agent"; sw; proc_mgr }

let run ~sw ~proc_mgr =
  (* Test dispatch returns None for unknown tool *)
  test "dispatch_unknown_tool" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [] in
    assert (Tool_relay.dispatch ctx ~name:"unknown_tool" ~args = None)
  );

  (* Test relay_status dispatch *)
  test "dispatch_relay_status" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [
      ("messages", `Int 100);
      ("tool_calls", `Int 50);
      ("model", `String "claude");
    ] in
    match Tool_relay.dispatch ctx ~name:"masc_relay_status" ~args with
    | Some (success, _result) -> assert success
    | None -> failwith "dispatch returned None"
  );

  (* Test handle_relay_status *)
  test "handle_relay_status" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [
      ("messages", `Int 200);
      ("tool_calls", `Int 100);
      ("model", `String "gpt-4");
    ] in
    let (success, result) = Tool_relay.handle_relay_status ctx args in
    assert success;
    assert (String.length result > 0);
    (* Should be JSON output *)
    assert (String.contains result '{')
  );

  (* Test handle_relay_status with required params *)
  test "handle_relay_status_defaults" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [("messages", `Int 10); ("tool_calls", `Int 5)] in
    let (success, _result) = Tool_relay.handle_relay_status ctx args in
    assert success
  );

  (* Test handle_relay_status rejects missing required params *)
  test "handle_relay_status_rejects_missing_params" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [] in
    let (success, _result) = Tool_relay.handle_relay_status ctx args in
    assert (not success)
  );

  (* Test relay_checkpoint dispatch *)
  test "dispatch_relay_checkpoint" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [
      ("summary", `String "Test summary");
      ("messages", `Int 15);
      ("tool_calls", `Int 7);
    ] in
    match Tool_relay.dispatch ctx ~name:"masc_relay_checkpoint" ~args with
    | Some (success, _result) -> assert success
    | None -> failwith "dispatch returned None"
  );

  (* Test handle_relay_checkpoint *)
  test "handle_relay_checkpoint" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [
      ("summary", `String "Completed phase 1");
      ("messages", `Int 20);
      ("tool_calls", `Int 10);
      ("current_task", `String "Implementing feature X");
      ("todos", `List [`String "item1"; `String "item2"]);
      ("pdca_state", `String "do");
      ("relevant_files", `List [`String "file1.ml"; `String "file2.ml"]);
    ] in
    let (success, result) = Tool_relay.handle_relay_checkpoint ctx args in
    assert success;
    assert (String.length result > 0)
  );

  (* Test relay_smart_check dispatch *)
  test "dispatch_relay_smart_check" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [
      ("messages", `Int 50);
      ("tool_calls", `Int 25);
      ("task_hint", `String "simple");
    ] in
    match Tool_relay.dispatch ctx ~name:"masc_relay_smart_check" ~args with
    | Some (success, _result) -> assert success
    | None -> failwith "dispatch returned None"
  );

  (* Test handle_relay_smart_check with various hints *)
  test "handle_relay_smart_check_large_file" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [
      ("messages", `Int 100);
      ("tool_calls", `Int 50);
      ("task_hint", `String "large_file");
      ("file_count", `Int 3);
    ] in
    let (success, result) = Tool_relay.handle_relay_smart_check ctx args in
    assert success;
    assert (String.length result > 0)
  );

  test "handle_relay_smart_check_multi_file" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [
      ("messages", `Int 100);
      ("tool_calls", `Int 50);
      ("task_hint", `String "multi_file");
      ("file_count", `Int 5);
    ] in
    let (success, result) = Tool_relay.handle_relay_smart_check ctx args in
    assert success;
    assert (String.length result > 0)
  );

  test "handle_relay_smart_check_long_running" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [
      ("messages", `Int 100);
      ("tool_calls", `Int 50);
      ("task_hint", `String "long_running");
    ] in
    let (success, result) = Tool_relay.handle_relay_smart_check ctx args in
    assert success;
    assert (String.length result > 0)
  );

  test "handle_relay_smart_check_exploration" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [
      ("messages", `Int 100);
      ("tool_calls", `Int 50);
      ("task_hint", `String "exploration");
    ] in
    let (success, result) = Tool_relay.handle_relay_smart_check ctx args in
    assert success;
    assert (String.length result > 0)
  );

  (* Test get_string helper *)
  test "get_string_present" (fun () ->
    let args = `Assoc [("key", `String "value")] in
    assert (Tool_args.get_string args "key" "default" = "value")
  );

  test "get_string_missing" (fun () ->
    let args = `Assoc [] in
    assert (Tool_args.get_string args "key" "default" = "default")
  );

  (* Test get_int helper *)
  test "get_int_present" (fun () ->
    let args = `Assoc [("key", `Int 42)] in
    assert (Tool_args.get_int args "key" 0 = 42)
  );

  test "get_int_missing" (fun () ->
    let args = `Assoc [] in
    assert (Tool_args.get_int args "key" 99 = 99)
  );

  (* Test get_string_opt helper *)
  test "get_string_opt_present" (fun () ->
    let args = `Assoc [("key", `String "value")] in
    assert (Tool_args.get_string_opt args "key" = Some "value")
  );

  test "get_string_opt_missing" (fun () ->
    let args = `Assoc [] in
    assert (Tool_args.get_string_opt args "key" = None)
  );

  test "get_string_opt_empty" (fun () ->
    let args = `Assoc [("key", `String "")] in
    assert (Tool_args.get_string_opt args "key" = None)
  );

  (* Test get_string_list helper *)
  test "get_string_list_present" (fun () ->
    let args = `Assoc [("key", `List [`String "a"; `String "b"])] in
    assert (Tool_args.get_string_list args "key" = ["a"; "b"])
  );

  test "get_string_list_missing" (fun () ->
    let args = `Assoc [] in
    assert (Tool_args.get_string_list args "key" = [])
  );

  Printf.printf "\n✅ All Tool_relay tests passed!\n"

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let proc_mgr = Some (Eio.Stdenv.process_mgr env) in
  run ~sw ~proc_mgr
