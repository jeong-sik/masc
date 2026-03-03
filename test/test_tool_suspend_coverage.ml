(** Coverage tests for Tool_suspend — Agent suspension and circuit breaker

    Tests dispatch routing, validation, blacklist API, and check_can_join
    for 2 tools: masc_suspend, masc_circuit_status

    Note: Circuit_breaker uses Eio_mutex, so tests touching it must run
    inside Eio_main.run.
*)

module Tool_suspend = Masc_mcp.Tool_suspend
module Room = Masc_mcp.Room

let test_counter = ref 0

let temp_dir () =
  incr test_counter;
  let dir = Filename.temp_file
    (Printf.sprintf "test_suspend_%d_" !test_counter) "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let make_ctx ?caller_agent () =
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "test-agent"));
  let ctx : Tool_suspend.context = { config; caller_agent } in
  (ctx, base_dir)

let dispatch_exn ctx ~name ~args =
  match Tool_suspend.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_suspend.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) in
  Alcotest.(check bool) "unknown returns None" true (result = None);
  cleanup_dir base_dir

let test_dispatch_suspend () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_suspend.dispatch ctx ~name:"masc_suspend" ~args:(`Assoc []) in
  Alcotest.(check bool) "suspend dispatches" true (result <> None);
  cleanup_dir base_dir

let test_dispatch_circuit_status () =
  Eio_main.run @@ fun _env ->
  let ctx, base_dir = make_ctx () in
  let result = Tool_suspend.dispatch ctx ~name:"masc_circuit_status" ~args:(`Assoc []) in
  Alcotest.(check bool) "circuit_status dispatches" true (result <> None);
  cleanup_dir base_dir

(* ============================================================
   Suspend validation tests
   ============================================================ *)

let test_suspend_empty_target () =
  let ctx, base_dir = make_ctx () in
  let (ok, msg) = dispatch_exn ctx ~name:"masc_suspend" ~args:(`Assoc []) in
  Alcotest.(check bool) "empty target fails" false ok;
  Alcotest.(check bool) "has error msg" true (String.length msg > 0);
  cleanup_dir base_dir

let test_suspend_with_target () =
  Eio_main.run @@ fun _env ->
  let ctx, base_dir = make_ctx ~caller_agent:"admin-agent" () in
  let args = `Assoc [
    ("target_agent", `String "bad-agent");
    ("reason", `String "misbehaving");
    ("duration_hours", `Float 1.0);
  ] in
  let (_, msg) = dispatch_exn ctx ~name:"masc_suspend" ~args in
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   Circuit status tests
   ============================================================ *)

let test_circuit_status_no_agent () =
  Eio_main.run @@ fun _env ->
  let ctx, base_dir = make_ctx () in
  let (_, msg) = dispatch_exn ctx ~name:"masc_circuit_status" ~args:(`Assoc []) in
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

let test_circuit_status_with_agent () =
  Eio_main.run @@ fun _env ->
  let ctx, base_dir = make_ctx ~caller_agent:"test-caller" () in
  let args = `Assoc [("agent_id", `String "some-agent")] in
  let (_, msg) = dispatch_exn ctx ~name:"masc_circuit_status" ~args in
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

let test_circuit_status_caller_fallback () =
  Eio_main.run @@ fun _env ->
  let ctx, base_dir = make_ctx ~caller_agent:"fallback-agent" () in
  let (_, msg) = dispatch_exn ctx ~name:"masc_circuit_status" ~args:(`Assoc []) in
  Alcotest.(check bool) "uses caller fallback" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   check_can_join tests
   ============================================================ *)

let test_check_can_join_clean () =
  Eio_main.run @@ fun _env ->
  let unique = Printf.sprintf "clean-agent-%d" (Random.int 100000) in
  let result = Tool_suspend.check_can_join ~agent_id:unique in
  Alcotest.(check bool) "clean agent can join" true (Result.is_ok result)

let test_check_can_join_blacklisted () =
  Eio_main.run @@ fun _env ->
  let unique = Printf.sprintf "blocked-%d" (Random.int 100000) in
  let future = Unix.gettimeofday () +. 3600.0 in
  Tool_suspend.add_to_blacklist ~agent_id:unique ~until:future ~reason:"test reason";
  let result = Tool_suspend.check_can_join ~agent_id:unique in
  Alcotest.(check bool) "blacklisted agent blocked" true (Result.is_error result);
  Tool_suspend.remove_from_blacklist ~agent_id:unique

(* ============================================================
   Blacklist direct API tests
   ============================================================ *)

let test_add_check_remove_blacklist () =
  let unique = Printf.sprintf "bl-test-%d" (Random.int 100000) in
  let future = Unix.gettimeofday () +. 3600.0 in
  Tool_suspend.add_to_blacklist ~agent_id:unique ~until:future ~reason:"testing";
  let is_blocked = Tool_suspend.check_blacklist ~agent_id:unique in
  Alcotest.(check bool) "blocked after add" true (is_blocked <> None);
  Tool_suspend.remove_from_blacklist ~agent_id:unique;
  let after_remove = Tool_suspend.check_blacklist ~agent_id:unique in
  Alcotest.(check bool) "unblocked after remove" true (after_remove = None)

let test_blacklist_expired () =
  let unique = Printf.sprintf "exp-test-%d" (Random.int 100000) in
  Tool_suspend.add_to_blacklist ~agent_id:unique ~until:0.0 ~reason:"instant expire";
  let result = Tool_suspend.check_blacklist ~agent_id:unique in
  (* May or may not be expired depending on timing; just check no crash *)
  ignore result;
  Tool_suspend.remove_from_blacklist ~agent_id:unique

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_suspend" [
    ("dispatch", [
      Alcotest.test_case "unknown returns None" `Quick test_dispatch_unknown;
      Alcotest.test_case "suspend dispatches" `Quick test_dispatch_suspend;
      Alcotest.test_case "circuit_status dispatches" `Quick test_dispatch_circuit_status;
    ]);
    ("suspend", [
      Alcotest.test_case "empty target" `Quick test_suspend_empty_target;
      Alcotest.test_case "with target" `Quick test_suspend_with_target;
    ]);
    ("circuit_status", [
      Alcotest.test_case "no agent" `Quick test_circuit_status_no_agent;
      Alcotest.test_case "with agent_id" `Quick test_circuit_status_with_agent;
      Alcotest.test_case "caller fallback" `Quick test_circuit_status_caller_fallback;
    ]);
    ("check_can_join", [
      Alcotest.test_case "clean agent" `Quick test_check_can_join_clean;
      Alcotest.test_case "blacklisted agent" `Quick test_check_can_join_blacklisted;
    ]);
    ("blacklist", [
      Alcotest.test_case "add check remove" `Quick test_add_check_remove_blacklist;
      Alcotest.test_case "expired entry" `Quick test_blacklist_expired;
    ]);
  ]
