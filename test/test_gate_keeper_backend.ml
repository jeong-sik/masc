open Alcotest
open Masc_mcp

let test_agent_name_for_channel_actor () =
  let agent_name =
    Gate_keeper_backend.agent_name_for_channel_actor
      ~channel:"  discord  " ~channel_room_id:" thread-9 "
      ~channel_user_id:" user-42 "
  in
  check string "stable external actor session key"
    "gate:discord:thread-9:user-42" agent_name

let test_agent_name_for_channel_actor_separates_rooms () =
  let left =
    Gate_keeper_backend.agent_name_for_channel_actor
      ~channel:"discord" ~channel_room_id:"room-a" ~channel_user_id:"user-42"
  in
  let right =
    Gate_keeper_backend.agent_name_for_channel_actor
      ~channel:"discord" ~channel_room_id:"room-b" ~channel_user_id:"user-42"
  in
  check bool "different external rooms should not share keeper session"
    true (left <> right)

let test_contextualize_message_includes_external_metadata () =
  let rendered =
    Gate_keeper_backend.contextualize_message
      ~channel:"discord"
      ~channel_user_id:"user-42"
      ~channel_user_name:"Alice"
      ~channel_room_id:"room-9"
      ~content:"hello keeper"
  in
  check string "message envelope"
    {|[External channel context]
channel: discord
room_id: room-9
user_id: user-42
user_name: Alice

[User message]
hello keeper|}
    rendered

let test_contextualize_message_sanitizes_context_lines () =
  let rendered =
    Gate_keeper_backend.contextualize_message
      ~channel:"discord\nbot"
      ~channel_user_id:"user-42"
      ~channel_user_name:"Alice\tOps"
      ~channel_room_id:"room-9\rthread"
      ~content:"hello keeper"
  in
  check string "sanitized context"
    {|[External channel context]
channel: discord bot
room_id: room-9 thread
user_id: user-42
user_name: Alice Ops

[User message]
hello keeper|}
    rendered

let test_parse_keeper_chat_stream_request_accepts_connector_context () =
  let body =
    {|{"name":"luna","message":"hello","channel":"discord","channel_user_id":"user-42","channel_user_name":"Alice","channel_room_id":"room-9"}|}
  in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok payload ->
      check string "channel" "discord" payload.channel;
      check string "user id" "user-42" payload.channel_user_id;
      check string "user name" "Alice" payload.channel_user_name;
      check string "room id" "room-9" payload.channel_room_id
  | Error err -> fail ("expected connector context to parse: " ^ err)

let test_parse_keeper_chat_stream_request_rejects_partial_connector_context () =
  let body =
    {|{"name":"luna","message":"hello","channel":"discord"}|}
  in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok _ -> fail "expected partial connector context to be rejected"
  | Error err ->
      check string "validation message"
        "channel, channel_user_id, and channel_room_id are required when connector context is supplied"
        err

(* ── Filesystem-safe sanitizer ──────────────────────────────────────── *)

let test_filesystem_safe_normal () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "room-123" in
  check string "safe chars preserved" "room-123" result

let test_filesystem_safe_strips_path_traversal () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "../../etc/passwd" in
  check string "path traversal sanitized" "______etc_passwd" result

let test_filesystem_safe_empty_to_unknown () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "" in
  check string "empty becomes unknown" "unknown" result

let test_filesystem_safe_all_special_to_unknown () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "@@@!!!" in
  check string "all special becomes unknown" "unknown" result

(* ── Response parsing ────────────────────────────────────────────── *)

let test_extract_reply_from_reply_field () =
  let body = {|{"reply":"hello world","model_used":"test"}|} in
  let result = Gate_keeper_backend.extract_reply_text body in
  check string "reply field extracted" "hello world" result

let test_extract_reply_fallback_to_text_field () =
  let body = {|{"text":"fallback content"}|} in
  let result = Gate_keeper_backend.extract_reply_text body in
  check string "text field fallback" "fallback content" result

let test_extract_reply_raw_on_non_json () =
  let body = "not json at all" in
  let result = Gate_keeper_backend.extract_reply_text body in
  check string "raw body returned" "not json at all" result

let test_extract_turn_stats_present () =
  let body = {|{"model_used":"claude-opus","duration_ms":1500,"total_tokens":500}|} in
  match Gate_keeper_backend.extract_turn_stats body with
  | Some { Gate_protocol.model_used; duration_ms; tokens_used } ->
      check string "model" "claude-opus" model_used;
      check int "duration" 1500 duration_ms;
      check int "tokens" 500 tokens_used
  | None -> fail "expected Some stats"

let test_extract_turn_stats_missing_returns_none () =
  let body = {|{"other_field":"value"}|} in
  let result = Gate_keeper_backend.extract_turn_stats body in
  check bool "missing fields returns None" true (result = None)

let () =
  Alcotest.run "Gate_keeper_backend"
    [
      ( "helpers",
        [
          test_case "agent name is stable" `Quick
            test_agent_name_for_channel_actor;
          test_case "agent name separates rooms" `Quick
            test_agent_name_for_channel_actor_separates_rooms;
          test_case "contextualized message keeps external metadata" `Quick
            test_contextualize_message_includes_external_metadata;
          test_case "context envelope sanitizes metadata lines" `Quick
            test_contextualize_message_sanitizes_context_lines;
          test_case "stream request accepts connector context" `Quick
            test_parse_keeper_chat_stream_request_accepts_connector_context;
          test_case "stream request rejects partial connector context" `Quick
            test_parse_keeper_chat_stream_request_rejects_partial_connector_context;
        ] );
      ( "filesystem_safe",
        [
          test_case "safe chars preserved" `Quick test_filesystem_safe_normal;
          test_case "path traversal sanitized" `Quick
            test_filesystem_safe_strips_path_traversal;
          test_case "empty becomes unknown" `Quick
            test_filesystem_safe_empty_to_unknown;
          test_case "all special becomes unknown" `Quick
            test_filesystem_safe_all_special_to_unknown;
        ] );
      ( "response_parsing",
        [
          test_case "reply field extracted" `Quick test_extract_reply_from_reply_field;
          test_case "text field fallback" `Quick test_extract_reply_fallback_to_text_field;
          test_case "raw body on non-json" `Quick test_extract_reply_raw_on_non_json;
          test_case "turn stats present" `Quick test_extract_turn_stats_present;
          test_case "turn stats missing returns None" `Quick
            test_extract_turn_stats_missing_returns_none;
        ] );
    ]
