(* Tests for dashboard Copilot Dock -> keeper chat stream wiring.

   Verifies the shared contract from the HTTP parser down to the
   [masc_keeper_msg] args that [Keeper_tool_surface.dispatch_stream]
   receives:
   - copilot channel label + operator workspace id parse without requiring
     an external user id;
   - [turn_instructions] and [surface_context] are forwarded as turn
     instructions;
   - the chat history surface is recorded as [Surface_ref.Gate];
   - external connector traffic still gets contextualized messages and
     External speaker authority. *)

open Alcotest
open Masc

module Stream = Server_routes_http_keeper_stream

let surface : Masc.Surface_ref.t testable =
  testable
    (fun fmt t -> Format.pp_print_string fmt (Masc.Surface_ref.lane_label t))
    Masc.Surface_ref.equal

let parse_ok body =
  match Stream.For_testing.parse_request body with
  | Ok payload -> payload
  | Error err -> fail ("expected parse to succeed: " ^ err)

let args_assoc args =
  match args with
  | `Assoc fields -> fields
  | _ -> fail "expected args to be a JSON object"

let get_string_field key args =
  match List.assoc_opt key (args_assoc args) with
  | Some (`String s) -> s
  | _ -> ""

let get_bool_field key args =
  match List.assoc_opt key (args_assoc args) with
  | Some (`Bool b) -> b
  | _ -> false

let has_field key args = Option.is_some (List.assoc_opt key (args_assoc args))

let contains needle haystack = Astring.String.is_infix ~affix:needle haystack

let test_copilot_parse_accepts_operator_workspace () =
  let body =
    {|{"name":"luna","message":"hello","channel":"copilot","channel_workspace_id":"session-7","turn_instructions":"focus on overview"}|}
  in
  let payload = parse_ok body in
  check string "channel" "copilot" payload.channel;
  check string "workspace id" "session-7" payload.channel_workspace_id;
  check string "user id optional" "" payload.channel_user_id;
  check (option string) "turn instructions" (Some "focus on overview")
    payload.turn_instructions;
  check bool "connector context" true
    (Stream.For_testing.has_connector_context payload);
  check bool "external speaker" false
    (Stream.For_testing.has_external_speaker payload)

let test_copilot_surface_is_gate_label () =
  let payload =
    parse_ok
      {|{"name":"luna","message":"hello","channel":"copilot","channel_workspace_id":"session-7"}|}
  in
  let chat_surface = Stream.For_testing.chat_surface_of_request payload in
  check surface "chat surface"
    (Masc.Surface_ref.Gate
       {
         label = "copilot";
         address = [ ("connector", "copilot"); ("workspace_id", "session-7") ];
       })
    chat_surface;
  let speaker = Stream.For_testing.chat_speaker_of_request payload in
  check string "authority label" "owner"
    (Keeper_chat_store.authority_label speaker.speaker_authority);
  check (option string) "speaker id" None speaker.speaker_id

let test_copilot_message_is_not_contextualized () =
  let payload =
    parse_ok
      {|{"name":"luna","message":"hello","channel":"copilot","channel_workspace_id":"session-7"}|}
  in
  let message = Stream.For_testing.message_for_request payload in
  check bool "no external channel envelope" false
    (contains "[External channel context]" message);
  check string "message verbatim" "hello" message

let test_copilot_args_carry_turn_instructions () =
  let payload =
    parse_ok
      {|{"name":"luna","message":"hello","channel":"copilot","channel_workspace_id":"session-7","turn_instructions":"focus on overview"}|}
  in
  let args = Stream.For_testing.args_of_request payload in
  check string "name" "luna" (get_string_field "name" args);
  check string "message" "hello" (get_string_field "message" args);
  check bool "direct_reply" true (get_bool_field "direct_reply" args);
  check string "turn_instructions" "focus on overview"
    (get_string_field "turn_instructions" args);
  check string "channel" "copilot" (get_string_field "channel" args);
  check string "channel_workspace_id" "session-7"
    (get_string_field "channel_workspace_id" args);
  check bool "no channel_user_id" false (has_field "channel_user_id" args);
  check bool "no channel_user_name" false (has_field "channel_user_name" args)

let test_surface_context_is_formatted_as_turn_instructions () =
  let payload =
    parse_ok
      {|{"name":"luna","message":"hello","channel":"copilot","channel_workspace_id":"session-7","surface_context":{"label":"Overview","route":"/overview","scene":"fleet view","fields":[{"k":"run","v":"2/5"},{"k":"alert","v":"1"}]}}|}
  in
  let instructions = Stream.For_testing.turn_instructions_for_request payload in
  check bool "instructions produced" true (Option.is_some instructions);
  let text = Option.value ~default:"" instructions in
  check bool "contains label" true (contains "Surface label: Overview" text);
  check bool "contains route" true (contains "Route: /overview" text);
  check bool "contains scene" true (contains "Scene: fleet view" text);
  check bool "contains field" true (contains "run: 2/5" text);
  let args = Stream.For_testing.args_of_request payload in
  check bool "turn_instructions in args" true (has_field "turn_instructions" args)

let test_turn_instructions_and_surface_context_combine () =
  let payload =
    parse_ok
      {|{"name":"luna","message":"hello","channel":"copilot","channel_workspace_id":"session-7","turn_instructions":"focus","surface_context":{"label":"Overview","route":"/overview","scene":"fleet view","fields":[]}}|}
  in
  let instructions = Stream.For_testing.turn_instructions_for_request payload in
  let text = Option.value ~default:"" instructions in
  check bool "starts with explicit instructions" true
    (Astring.String.is_prefix ~affix:"focus" text);
  check bool "includes formatted surface context" true
    (contains "[Co-view context]" text)

let test_external_connector_still_contextualized () =
  let payload =
    parse_ok
      {|{"name":"luna","message":"hello","channel":"discord","channel_user_id":"user-42","channel_user_name":"Alice","channel_workspace_id":"workspace-9"}|}
  in
  check bool "has external speaker" true
    (Stream.For_testing.has_external_speaker payload);
  let chat_surface = Stream.For_testing.chat_surface_of_request payload in
  check surface "surface"
    (Masc.Surface_ref.Gate
       {
         label = "discord";
         address = [ ("connector", "discord"); ("workspace_id", "workspace-9") ];
       })
    chat_surface;
  let speaker = Stream.For_testing.chat_speaker_of_request payload in
  check string "authority" "external"
    (Keeper_chat_store.authority_label speaker.speaker_authority);
  check (option string) "speaker id" (Some "user-42") speaker.speaker_id;
  let message = Stream.For_testing.message_for_request payload in
  check bool "context envelope present" true
    (contains "[External channel context]" message);
  let args = Stream.For_testing.args_of_request payload in
  check string "channel_user_id" "user-42"
    (get_string_field "channel_user_id" args);
  check string "channel_user_name" "Alice"
    (get_string_field "channel_user_name" args)

let test_dashboard_without_channel_is_owner () =
  let payload = parse_ok {|{"name":"luna","message":"hello"}|} in
  check bool "no connector context" false
    (Stream.For_testing.has_connector_context payload);
  let chat_surface = Stream.For_testing.chat_surface_of_request payload in
  check surface "surface" (Masc.Surface_ref.Dashboard { session_id = None }) chat_surface;
  let speaker = Stream.For_testing.chat_speaker_of_request payload in
  check string "authority" "owner"
    (Keeper_chat_store.authority_label speaker.speaker_authority);
  let args = Stream.For_testing.args_of_request payload in
  check bool "no channel in args" false (has_field "channel" args)

let () =
  run "copilot_dock_channel_wiring"
    [
      ( "parse",
        [
          test_case "copilot context parses without user id" `Quick
            test_copilot_parse_accepts_operator_workspace;
        ] );
      ( "surface",
        [
          test_case "copilot records Gate surface and Owner speaker" `Quick
            test_copilot_surface_is_gate_label;
          test_case "external connector keeps External speaker" `Quick
            test_external_connector_still_contextualized;
          test_case "dashboard without channel records Dashboard surface" `Quick
            test_dashboard_without_channel_is_owner;
        ] );
      ( "prompt",
        [
          test_case "copilot message is not contextualized" `Quick
            test_copilot_message_is_not_contextualized;
          test_case "turn_instructions forwarded to args" `Quick
            test_copilot_args_carry_turn_instructions;
          test_case "surface_context formatted as turn instructions" `Quick
            test_surface_context_is_formatted_as_turn_instructions;
          test_case "turn_instructions and surface_context combine" `Quick
            test_turn_instructions_and_surface_context_combine;
        ] );
    ]
