open Alcotest

module U = Yojson.Safe.Util

let first_issue quality =
  quality |> U.member "issues" |> U.to_list |> List.hd

let test_timeout_quality_is_error () =
  let quality =
    Masc_mcp.Mcp_server_eio_call_tool.quality_from_result
      ~success:false
      ~message:"Tool timed out after 30s"
      ~attempts:1
  in
  let issue = first_issue quality in
  check string "timeout code" "tool_timeout" (issue |> U.member "code" |> U.to_string);
  check string "timeout severity" "error" (issue |> U.member "severity" |> U.to_string)

let test_generic_failure_quality_is_error () =
  let quality =
    Masc_mcp.Mcp_server_eio_call_tool.quality_from_result
      ~success:false
      ~message:"subprocess exited 1"
      ~attempts:2
  in
  let issue = first_issue quality in
  check string "failure code" "tool_failure" (issue |> U.member "code" |> U.to_string);
  check string "failure severity" "error" (issue |> U.member "severity" |> U.to_string)

let test_success_quality_has_no_issues () =
  let quality =
    Masc_mcp.Mcp_server_eio_call_tool.quality_from_result
      ~success:true
      ~message:"ok"
      ~attempts:1
  in
  check bool "passed" true (quality |> U.member "passed" |> U.to_bool);
  check int "issue count" 0 (quality |> U.member "issues" |> U.to_list |> List.length)

let test_transition_has_no_fixed_timeout () =
  check bool "masc_transition has no fixed timeout"
    true
    (Masc_mcp.Mcp_server_eio_call_tool.tool_timeout_sec_opt
       ~tool_name:"masc_transition"
       ~arguments:(`Assoc [])
     = None)

let test_regular_tool_uses_default_timeout () =
  match
    Masc_mcp.Mcp_server_eio_call_tool.tool_timeout_sec_opt
      ~tool_name:"masc_status"
      ~arguments:(`Assoc [])
  with
  | Some timeout_sec -> check bool "default timeout remains enabled" true (timeout_sec >= 5.)
  | None -> fail "expected masc_status to keep fixed timeout"

let () =
  run "mcp_server_eio_call_tool"
    [
      ( "quality",
        [
          test_case "timeout is error" `Quick test_timeout_quality_is_error;
          test_case "generic failure is error" `Quick test_generic_failure_quality_is_error;
          test_case "success has no issues" `Quick test_success_quality_has_no_issues;
          test_case "transition has no fixed timeout" `Quick test_transition_has_no_fixed_timeout;
          test_case "regular tool keeps default timeout" `Quick test_regular_tool_uses_default_timeout;
        ] );
    ]
