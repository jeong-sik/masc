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
    ]
