(** Coverage tests for Tool_relay — all relay tools orphaned and removed. *)

open Masc_mcp

let () = Random.self_init ()

let () = Printf.printf "\n=== Tool_relay Coverage Tests ===\n"

(* Test helper *)
let test name f =
  try
    f ();
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

  (* All relay tools are orphaned — dispatch returns None *)
  test "dispatch_relay_status_returns_none" (fun () ->
    let ctx = make_test_ctx ~sw ~proc_mgr () in
    let args = `Assoc [
      ("messages", `Int 100);
      ("tool_calls", `Int 50);
    ] in
    assert (Tool_relay.dispatch ctx ~name:"masc_relay_status" ~args = None)
  );

  test "schemas_empty" (fun () ->
    assert (Tool_relay.schemas = [])
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
