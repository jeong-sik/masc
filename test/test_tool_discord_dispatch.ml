(* RFC-0203 Phase 3 — Discord_tool_helpers unit tests.

   Pure-helper coverage: parse_input contract, MASC_DISCORD_BUILTIN
   flag, failure_class mapping, and the injected-send dispatch core's
   fail-closed branches. No network IO; the real REST path is
   covered end-to-end by Phase 4 dual-run signal.

   Linked through [masc_mcp.gate] only so the executable does not
   transitively pull the pre-existing cascade_capacity_probe cycle in
   [masc_mcp] (MEMORY.md "CI gate skip two-strikes 24h", 2026-05-28
   #19340). The glue module Tool_discord_dispatch is built and
   registered by the main library — its registration is not exercised
   here, only the dispatcher logic it delegates to. *)

open Alcotest
module H = Discord_tool_helpers

let setenv k v = Unix.putenv k v
let unsetenv k = Unix.putenv k ""

let tool_name = "discord_send_message"

(* Reusable stub [send] that records the last call without doing IO. *)
let last_call : (string * string) option ref = ref None
let stub_send_ok ~channel_id ~content =
  last_call := Some (channel_id, content);
  Ok "MSG_FROM_STUB"
let stub_send_err err ~channel_id ~content =
  last_call := Some (channel_id, content);
  Error err

let reset_call () = last_call := None

(* ---------------------------------------------------------------- *)
(* parse_input                                                      *)
(* ---------------------------------------------------------------- *)

let test_parse_happy () =
  let json =
    `Assoc [ "channel_id", `String "12345"; "content", `String "hello" ]
  in
  match H.parse_input json with
  | Ok { channel_id; content } ->
    check string "channel_id" "12345" channel_id;
    check string "content" "hello" content
  | Error e -> failf "expected Ok, got Error %S" e

let test_parse_rejects_non_object () =
  match H.parse_input (`List []) with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for non-object JSON"

let test_parse_missing_channel_id () =
  let json = `Assoc [ "content", `String "hi" ] in
  match H.parse_input json with
  | Error msg ->
    check bool "mentions channel_id" true
      (Astring.String.is_infix ~affix:"channel_id" msg)
  | Ok _ -> fail "expected Error for missing channel_id"

let test_parse_missing_content () =
  let json = `Assoc [ "channel_id", `String "12345" ] in
  match H.parse_input json with
  | Error msg ->
    check bool "mentions content" true
      (Astring.String.is_infix ~affix:"content" msg)
  | Ok _ -> fail "expected Error for missing content"

let test_parse_empty_string_rejected () =
  (* RFC-0203 contract: empty string is not a valid channel_id. *)
  let json =
    `Assoc [ "channel_id", `String ""; "content", `String "hi" ]
  in
  match H.parse_input json with
  | Error _ -> ()
  | Ok _ -> fail "expected Error for empty channel_id"

let test_parse_wrong_type () =
  let json = `Assoc [ "channel_id", `Int 12345; "content", `String "hi" ] in
  match H.parse_input json with
  | Error msg ->
    check bool "mentions string" true
      (Astring.String.is_infix ~affix:"string" msg)
  | Ok _ -> fail "expected Error for non-string channel_id"

(* ---------------------------------------------------------------- *)
(* builtin_enabled                                                  *)
(* ---------------------------------------------------------------- *)

let test_flag_default_false () =
  unsetenv "MASC_DISCORD_BUILTIN";
  check bool "default false" false (H.builtin_enabled ())

let test_flag_truthy () =
  setenv "MASC_DISCORD_BUILTIN" "true";
  check bool "true => enabled" true (H.builtin_enabled ());
  unsetenv "MASC_DISCORD_BUILTIN"

let test_flag_falsy () =
  setenv "MASC_DISCORD_BUILTIN" "false";
  check bool "false => disabled" false (H.builtin_enabled ());
  unsetenv "MASC_DISCORD_BUILTIN"

(* ---------------------------------------------------------------- *)
(* failure_class_of_send_error                                      *)
(* ---------------------------------------------------------------- *)

let cls_label c = Tool_result.tool_failure_class_to_string c

let test_class_missing_token () =
  check string "Missing_token => policy_rejection" "policy_rejection"
    (cls_label
       (H.failure_class_of_send_error Channel_gate_discord_state.Missing_token))

let test_class_network () =
  check string "Network => transient" "transient_error"
    (cls_label
       (H.failure_class_of_send_error
          (Rest_error (Discord_rest_client.Network "dns"))))

let test_class_http_5xx_transient () =
  check string "5xx => transient" "transient_error"
    (cls_label
       (H.failure_class_of_send_error
          (Rest_error
             (Discord_rest_client.Http_status { code = 503; body = "" }))))

let test_class_http_4xx_workflow () =
  check string "4xx => workflow_rejection" "workflow_rejection"
    (cls_label
       (H.failure_class_of_send_error
          (Rest_error
             (Discord_rest_client.Http_status { code = 403; body = "" }))))

let test_class_discord_429_transient () =
  check string "Discord 429 => transient" "transient_error"
    (cls_label
       (H.failure_class_of_send_error
          (Rest_error
             (Discord_rest_client.Discord_api { code = 429; message = "" }))))

let test_class_discord_50007_workflow () =
  check string "Discord 50007 => workflow_rejection" "workflow_rejection"
    (cls_label
       (H.failure_class_of_send_error
          (Rest_error
             (Discord_rest_client.Discord_api
                { code = 50007; message = "cannot send" }))))

let test_class_other_runtime () =
  check string "Other => runtime_failure" "runtime_failure"
    (cls_label
       (H.failure_class_of_send_error
          (Rest_error (Discord_rest_client.Other "weird shape"))))

(* ---------------------------------------------------------------- *)
(* dispatch — fail-closed branches with injected stub               *)
(* ---------------------------------------------------------------- *)

let valid_args =
  `Assoc [ "channel_id", `String "12345"; "content", `String "hi" ]

let expect_class result label =
  match result with
  | None -> fail "dispatch returned None for its own tool name"
  | Some r ->
    (match Tool_result.failure_class r with
     | Some c -> check string "failure class" label (cls_label c)
     | None -> fail "expected Error result, got Ok")

let expect_ok ?(check_data = true) result expected_id =
  match result with
  | None -> fail "dispatch returned None for its own tool name"
  | Some r when Tool_result.is_success r ->
    if check_data then
      let s = Yojson.Safe.to_string (Tool_result.data r) in
      check bool "data carries message_id" true
        (Astring.String.is_infix ~affix:expected_id s)
  | Some r -> failf "expected Ok, got Error %S" (Tool_result.message r)

let test_dispatch_other_name_returns_none () =
  match
    H.dispatch ~send:stub_send_ok ~tool_name ~name:"masc_status"
      ~args:(`Assoc [])
  with
  | None -> ()
  | Some _ -> fail "dispatch should ignore non-discord_send_message names"

let test_dispatch_malformed_args_workflow () =
  reset_call ();
  unsetenv "MASC_DISCORD_BUILTIN";
  let r =
    H.dispatch ~send:stub_send_ok ~tool_name ~name:tool_name
      ~args:(`Assoc [ "channel_id", `String "1" ])
  in
  expect_class r "workflow_rejection";
  check (option (pair string string)) "send not called" None !last_call

let test_dispatch_flag_off_policy () =
  reset_call ();
  unsetenv "MASC_DISCORD_BUILTIN";
  let r =
    H.dispatch ~send:stub_send_ok ~tool_name ~name:tool_name ~args:valid_args
  in
  expect_class r "policy_rejection";
  check (option (pair string string)) "send not called when flag off" None
    !last_call;
  match r with
  | Some r when not (Tool_result.is_success r) ->
    check bool "mentions MASC_DISCORD_BUILTIN" true
      (Astring.String.is_infix ~affix:"MASC_DISCORD_BUILTIN"
         (Tool_result.message r))
  | _ -> fail "unreachable: covered above"

let test_dispatch_flag_on_calls_send_and_returns_ok () =
  reset_call ();
  setenv "MASC_DISCORD_BUILTIN" "true";
  let r =
    H.dispatch ~send:stub_send_ok ~tool_name ~name:tool_name ~args:valid_args
  in
  expect_ok r "MSG_FROM_STUB";
  check (option (pair string string)) "send called with parsed args"
    (Some ("12345", "hi")) !last_call;
  unsetenv "MASC_DISCORD_BUILTIN"

let test_dispatch_flag_on_send_returns_typed_error () =
  reset_call ();
  setenv "MASC_DISCORD_BUILTIN" "true";
  let stub =
    stub_send_err
      (Channel_gate_discord_state.Rest_error
         (Discord_rest_client.Discord_api
            { code = 50007; message = "Cannot send messages to this user" }))
  in
  let r = H.dispatch ~send:stub ~tool_name ~name:tool_name ~args:valid_args in
  expect_class r "workflow_rejection";
  unsetenv "MASC_DISCORD_BUILTIN"

(* ---------------------------------------------------------------- *)
(* Entry                                                            *)
(* ---------------------------------------------------------------- *)

let () =
  run "tool_discord_dispatch"
    [ ( "parse_input"
      , [ test_case "happy path" `Quick test_parse_happy
        ; test_case "rejects non-object" `Quick test_parse_rejects_non_object
        ; test_case "missing channel_id" `Quick test_parse_missing_channel_id
        ; test_case "missing content" `Quick test_parse_missing_content
        ; test_case "empty string rejected" `Quick
            test_parse_empty_string_rejected
        ; test_case "wrong field type" `Quick test_parse_wrong_type
        ] )
    ; ( "builtin_enabled"
      , [ test_case "default false" `Quick test_flag_default_false
        ; test_case "truthy" `Quick test_flag_truthy
        ; test_case "falsy" `Quick test_flag_falsy
        ] )
    ; ( "failure_class"
      , [ test_case "Missing_token" `Quick test_class_missing_token
        ; test_case "Network" `Quick test_class_network
        ; test_case "Http 5xx" `Quick test_class_http_5xx_transient
        ; test_case "Http 4xx" `Quick test_class_http_4xx_workflow
        ; test_case "Discord 429" `Quick test_class_discord_429_transient
        ; test_case "Discord 50007" `Quick test_class_discord_50007_workflow
        ; test_case "Other" `Quick test_class_other_runtime
        ] )
    ; ( "dispatch"
      , [ test_case "ignores other tool names" `Quick
            test_dispatch_other_name_returns_none
        ; test_case "rejects malformed args" `Quick
            test_dispatch_malformed_args_workflow
        ; test_case "flag off => policy_rejection (send not called)" `Quick
            test_dispatch_flag_off_policy
        ; test_case "flag on => send called, Ok wraps message_id" `Quick
            test_dispatch_flag_on_calls_send_and_returns_ok
        ; test_case "flag on, send Error => typed failure class" `Quick
            test_dispatch_flag_on_send_returns_typed_error
        ] )
    ]
