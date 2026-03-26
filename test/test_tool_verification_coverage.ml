(** Coverage tests for Tool_verification — MCP tool handlers

    Tests dispatch routing, input validation, and handler integration
    for all 5 verification tools:
    - masc_verify_request
    - masc_verify_submit
    - masc_verify_status
    - masc_verify_pending
    - masc_verify_auto
*)

module Tool_verification = Masc_mcp.Tool_verification
module Room = Masc_mcp.Room

(** Case-insensitive substring check for error message assertions. *)
let msg_contains ~needle haystack =
  let lc = String.lowercase_ascii haystack in
  let ln = String.lowercase_ascii needle in
  try ignore (Str.search_forward (Str.regexp_string ln) lc 0); true
  with Not_found -> false

let temp_dir () =
  let dir = Filename.temp_file "test_tool_verify_" "" in
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

let make_config () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "verifier-agent"));
  (config, base_dir)

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown_tool () =
  let config, base_dir = make_config () in
  let (ok, msg) = Tool_verification.dispatch config "agent-a" "unknown_tool" (`Assoc []) in
  Alcotest.(check bool) "unknown tool fails" false ok;
  Alcotest.(check bool) "error mentions unknown" true (msg_contains ~needle:"unknown" msg);
  cleanup_dir base_dir

let test_dispatch_routes_request () =
  let config, base_dir = make_config () in
  let args = `Assoc [("task_id", `String "task-001")] in
  let (ok, _msg) = Tool_verification.dispatch config "agent-a" "masc_verify_request" args in
  Alcotest.(check bool) "verify_request dispatched" true ok;
  cleanup_dir base_dir

let test_dispatch_routes_status () =
  let config, base_dir = make_config () in
  (* First create a request to get a valid ID *)
  let args = `Assoc [("task_id", `String "task-002")] in
  let (_ok, result) = Tool_verification.dispatch config "agent-a" "masc_verify_request" args in
  let json = Yojson.Safe.from_string result in
  let req_id = json |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string in
  (* Now check status *)
  let status_args = `Assoc [("verification_id", `String req_id)] in
  let (ok, _msg) = Tool_verification.dispatch config "agent-a" "masc_verify_status" status_args in
  Alcotest.(check bool) "verify_status dispatched" true ok;
  cleanup_dir base_dir

let test_dispatch_routes_pending () =
  let config, base_dir = make_config () in
  let (ok, msg) = Tool_verification.dispatch config "agent-a" "masc_verify_pending" (`Assoc []) in
  Alcotest.(check bool) "verify_pending dispatched" true ok;
  Alcotest.(check bool) "pending contains count" true (msg_contains ~needle:"pending" msg);
  cleanup_dir base_dir

(* ============================================================
   Input validation tests
   ============================================================ *)

let test_request_missing_task_id () =
  let config, base_dir = make_config () in
  let args = `Assoc [] in
  let (ok, msg) = Tool_verification.dispatch config "agent-a" "masc_verify_request" args in
  Alcotest.(check bool) "missing task_id fails" false ok;
  Alcotest.(check bool) "error mentions task_id" true (msg_contains ~needle:"task_id" msg);
  cleanup_dir base_dir

let test_submit_missing_verification_id () =
  let config, base_dir = make_config () in
  let args = `Assoc [("verdict", `String "pass")] in
  let (ok, msg) = Tool_verification.dispatch config "agent-a" "masc_verify_submit" args in
  Alcotest.(check bool) "missing verification_id fails" false ok;
  Alcotest.(check bool) "error mentions verification_id" true (msg_contains ~needle:"verification_id" msg);
  cleanup_dir base_dir

let test_submit_missing_verdict () =
  let config, base_dir = make_config () in
  let args = `Assoc [("verification_id", `String "req-123")] in
  let (ok, msg) = Tool_verification.dispatch config "agent-a" "masc_verify_submit" args in
  Alcotest.(check bool) "missing verdict fails" false ok;
  Alcotest.(check bool) "error mentions verdict" true (msg_contains ~needle:"verdict" msg);
  cleanup_dir base_dir

let test_status_missing_verification_id () =
  let config, base_dir = make_config () in
  let args = `Assoc [] in
  let (ok, msg) = Tool_verification.dispatch config "agent-a" "masc_verify_status" args in
  Alcotest.(check bool) "missing verification_id fails" false ok;
  Alcotest.(check bool) "error mentions verification_id" true (msg_contains ~needle:"verification_id" msg);
  cleanup_dir base_dir

let test_auto_missing_verification_id () =
  let config, base_dir = make_config () in
  let args = `Assoc [] in
  let (ok, msg) = Tool_verification.dispatch config "agent-a" "masc_verify_auto" args in
  Alcotest.(check bool) "missing verification_id fails" false ok;
  Alcotest.(check bool) "error mentions verification_id" true (msg_contains ~needle:"verification_id" msg);
  cleanup_dir base_dir

(* ============================================================
   Full workflow: request → submit → status
   ============================================================ *)

let test_request_submit_workflow () =
  let config, base_dir = make_config () in
  (* Step 1: Create request *)
  let req_args = `Assoc [
    ("task_id", `String "task-workflow");
    ("output", `String "build succeeded");
  ] in
  let (ok1, result1) = Tool_verification.dispatch config "worker-a" "masc_verify_request" req_args in
  Alcotest.(check bool) "request created" true ok1;
  let json1 = Yojson.Safe.from_string result1 in
  let req_id = json1 |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string in
  Alcotest.(check bool) "request has id" true (String.length req_id > 0);
  (* Step 2: Submit verdict *)
  let submit_args = `Assoc [
    ("verification_id", `String req_id);
    ("verdict", `String "pass");
  ] in
  let (ok2, result2) = Tool_verification.dispatch config "reviewer-b" "masc_verify_submit" submit_args in
  Alcotest.(check bool) "verdict submitted" true ok2;
  let json2 = Yojson.Safe.from_string result2 in
  (* status field is a nested object: { "status": "completed", "verdict": "pass" } *)
  let status_obj = json2 |> Yojson.Safe.Util.member "status" in
  let status_str = status_obj |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string in
  Alcotest.(check string) "status is completed" "completed" status_str;
  let verdict_str = status_obj |> Yojson.Safe.Util.member "verdict" |> Yojson.Safe.Util.to_string in
  Alcotest.(check string) "verdict is pass" "pass" verdict_str;
  (* Step 3: Check status *)
  let status_args = `Assoc [("verification_id", `String req_id)] in
  let (ok3, result3) = Tool_verification.dispatch config "anyone" "masc_verify_status" status_args in
  Alcotest.(check bool) "status check ok" true ok3;
  let json3 = Yojson.Safe.from_string result3 in
  let final_obj = json3 |> Yojson.Safe.Util.member "status" in
  let final_status = final_obj |> Yojson.Safe.Util.member "status" |> Yojson.Safe.Util.to_string in
  Alcotest.(check string) "final status completed" "completed" final_status;
  cleanup_dir base_dir

let test_submit_fail_verdict () =
  let config, base_dir = make_config () in
  let req_args = `Assoc [("task_id", `String "task-fail")] in
  let (ok1, result1) = Tool_verification.dispatch config "worker" "masc_verify_request" req_args in
  Alcotest.(check bool) "request ok" true ok1;
  let json1 = Yojson.Safe.from_string result1 in
  let req_id = json1 |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string in
  let submit_args = `Assoc [
    ("verification_id", `String req_id);
    ("verdict", `String "fail");
    ("reason", `String "tests did not pass");
  ] in
  let (ok2, _result2) = Tool_verification.dispatch config "reviewer" "masc_verify_submit" submit_args in
  Alcotest.(check bool) "fail verdict submitted" true ok2;
  cleanup_dir base_dir

let test_submit_partial_verdict () =
  let config, base_dir = make_config () in
  let req_args = `Assoc [("task_id", `String "task-partial")] in
  let (ok1, result1) = Tool_verification.dispatch config "worker" "masc_verify_request" req_args in
  Alcotest.(check bool) "request ok" true ok1;
  let json1 = Yojson.Safe.from_string result1 in
  let req_id = json1 |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string in
  let submit_args = `Assoc [
    ("verification_id", `String req_id);
    ("verdict", `String "partial");
    ("score", `Float 0.7);
    ("reason", `String "most tests pass");
  ] in
  let (ok2, _result2) = Tool_verification.dispatch config "reviewer" "masc_verify_submit" submit_args in
  Alcotest.(check bool) "partial verdict submitted" true ok2;
  cleanup_dir base_dir

(* ============================================================
   Pending verifications test
   ============================================================ *)

let test_pending_shows_unresolved () =
  let config, base_dir = make_config () in
  (* Create a request assigned to specific verifier *)
  let req_args = `Assoc [
    ("task_id", `String "task-pending");
    ("verifier", `String "reviewer-x");
  ] in
  let (ok1, _) = Tool_verification.dispatch config "worker" "masc_verify_request" req_args in
  Alcotest.(check bool) "request created" true ok1;
  (* Check pending for reviewer-x *)
  let (ok2, msg) = Tool_verification.dispatch config "reviewer-x" "masc_verify_pending" (`Assoc []) in
  Alcotest.(check bool) "pending check ok" true ok2;
  Alcotest.(check bool) "has pending items" true (msg_contains ~needle:"pending" msg);
  cleanup_dir base_dir

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_verification" [
    ("dispatch", [
      Alcotest.test_case "unknown tool" `Quick test_dispatch_unknown_tool;
      Alcotest.test_case "routes request" `Quick test_dispatch_routes_request;
      Alcotest.test_case "routes status" `Quick test_dispatch_routes_status;
      Alcotest.test_case "routes pending" `Quick test_dispatch_routes_pending;
    ]);
    ("validation", [
      Alcotest.test_case "request missing task_id" `Quick test_request_missing_task_id;
      Alcotest.test_case "submit missing verification_id" `Quick test_submit_missing_verification_id;
      Alcotest.test_case "submit missing verdict" `Quick test_submit_missing_verdict;
      Alcotest.test_case "status missing verification_id" `Quick test_status_missing_verification_id;
      Alcotest.test_case "auto missing verification_id" `Quick test_auto_missing_verification_id;
    ]);
    ("workflow", [
      Alcotest.test_case "request-submit-status" `Quick test_request_submit_workflow;
      Alcotest.test_case "fail verdict" `Quick test_submit_fail_verdict;
      Alcotest.test_case "partial verdict" `Quick test_submit_partial_verdict;
      Alcotest.test_case "pending shows unresolved" `Quick test_pending_shows_unresolved;
    ]);
  ]
