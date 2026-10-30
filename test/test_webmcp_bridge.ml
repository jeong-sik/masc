open Alcotest

let ok_or_failure = function
  | Ok text -> `Ok text
  | Error failure -> `Failure (Webmcp_bridge.failure_message failure)

let check_ok label expected result =
  match ok_or_failure result with
  | `Ok text -> check string label expected text
  | `Failure message -> failf "%s: unexpected failure %s" label message

let check_failure label expected_fragment result =
  match ok_or_failure result with
  | `Ok text -> failf "%s: unexpected success %s" label text
  | `Failure message ->
    let contains =
      let len_h = String.length message
      and len_n = String.length expected_fragment in
      let rec loop i =
        if i + len_n > len_h then false
        else if String.sub message i len_n = expected_fragment then true
        else loop (i + 1)
      in
      loop 0
    in
    check bool
      (Printf.sprintf "%s: %S in %S" label expected_fragment message)
      true contains

let test_classify_exit_ok () =
  check_ok "exit 0 returns stdout" "payload"
    (Webmcp_bridge.classify_exit (Unix.WEXITED 0) ~stdout:"payload" ~stderr:"")

let test_classify_exit_page_not_found () =
  check_failure "exit 2 is page-not-found" "webmcp page not found"
    (Webmcp_bridge.classify_exit (Unix.WEXITED 2) ~stdout:""
       ~stderr:"page matching \"x\" not found")

let test_classify_exit_surface_missing_prefers_stderr () =
  check_failure "exit 3 carries stderr" "FAIL: masc_status not registered"
    (Webmcp_bridge.classify_exit (Unix.WEXITED 3) ~stdout:"ignored"
       ~stderr:"FAIL: masc_status not registered")

let test_classify_exit_surface_missing_falls_back_to_stdout () =
  check_failure "exit 3 falls back to stdout" "{\"found\":false}"
    (Webmcp_bridge.classify_exit (Unix.WEXITED 3) ~stdout:"{\"found\":false}"
       ~stderr:"  ")

let test_classify_exit_other_code () =
  check_failure "exit 5 is bridge failure" "exit 5"
    (Webmcp_bridge.classify_exit (Unix.WEXITED 5) ~stdout:"" ~stderr:"boom")

let test_classify_exit_timeout () =
  check_failure "timeout status names the budget" "timed out"
    (Webmcp_bridge.classify_exit Process_eio.timed_out_status ~stdout:""
       ~stderr:"")

let test_bridge_argv_shape () =
  let argv =
    Webmcp_bridge.bridge_argv ~script_path:"/tmp/b.mjs" ~cdp_port:9223
      ~page:"8935/dashboard"
      ~subcommand:[ "call"; "masc_status"; "{}" ]
  in
  check (list string) "argv order"
    [ "node"; "/tmp/b.mjs"; "call"; "masc_status"; "{}"; "--port"; "9223";
      "--page"; "8935/dashboard" ]
    argv

let recording_runner ~result recorded ~timeout_sec argv =
  recorded := Some (timeout_sec, argv);
  result

let test_call_tool_runs_bridge () =
  let recorded = ref None in
  let runner =
    recording_runner ~result:(Ok (Unix.WEXITED 0, "{\"found\":true}", ""))
      recorded
  in
  check_ok "call_tool returns bridge stdout" "{\"found\":true}"
    (Webmcp_bridge.call_tool ~runner ~page:"8935/dashboard" ~tool:"masc_status"
       ~args_json:{|{"limit":3}|} ());
  match !recorded with
  | None -> fail "runner not invoked"
  | Some (timeout_sec, argv) ->
    check bool "timeout is positive" true (timeout_sec > 0.);
    check bool "argv carries the tool name" true
      (List.mem "masc_status" argv && List.mem {|{"limit":3}|} argv)

let test_call_tool_rejects_invalid_json () =
  let recorded = ref None in
  let runner =
    recording_runner ~result:(Ok (Unix.WEXITED 0, "", "")) recorded
  in
  check_failure "malformed json is refused" "args_json invalid"
    (Webmcp_bridge.call_tool ~runner ~page:"p" ~tool:"t" ~args_json:"{oops" ());
  check_failure "non-object json is refused" "args_json invalid"
    (Webmcp_bridge.call_tool ~runner ~page:"p" ~tool:"t" ~args_json:"[1,2]" ());
  check bool "runner never ran on invalid input" true (!recorded = None)

let test_spawn_error_is_bridge_unavailable () =
  let runner ~timeout_sec:_ _argv = Error "node: command not found" in
  check_failure "spawn error is typed" "webmcp bridge unavailable"
    (Webmcp_bridge.list_tools ~runner ~page:"p" ())

let () =
  run "webmcp_bridge"
    [ ( "classify_exit",
        [ test_case "exit 0" `Quick test_classify_exit_ok;
          test_case "exit 2" `Quick test_classify_exit_page_not_found;
          test_case "exit 3 stderr" `Quick
            test_classify_exit_surface_missing_prefers_stderr;
          test_case "exit 3 stdout" `Quick
            test_classify_exit_surface_missing_falls_back_to_stdout;
          test_case "other exit" `Quick test_classify_exit_other_code;
          test_case "timeout" `Quick test_classify_exit_timeout ] );
      ( "invocation",
        [ test_case "argv shape" `Quick test_bridge_argv_shape;
          test_case "call_tool" `Quick test_call_tool_runs_bridge;
          test_case "invalid args" `Quick test_call_tool_rejects_invalid_json;
          test_case "spawn error" `Quick test_spawn_error_is_bridge_unavailable
        ] ) ]
