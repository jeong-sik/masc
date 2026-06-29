open Alcotest
open Masc

module K = Keeper_chat_store
module KT = Keeper_turn

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let temp_base_path prefix =
  Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let string_contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else if needle_len > haystack_len then false
  else
    let rec loop index =
      if index + needle_len > haystack_len then false
      else if String.sub haystack index needle_len = needle then true
      else loop (index + 1)
    in
    loop 0

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let translate_oas_stream_events events =
  let redact_text text = text in
  let text_accum = Keeper_stream_text_accum.create () in
  let rec loop bridge_state acc = function
    | [] -> List.rev acc
    | event :: rest ->
        let translated =
          Server_routes_http_keeper_stream.For_testing.translate_oas_stream_event
            ~redact_text ~text_accum bridge_state event
        in
        loop translated.bridge_state
          (List.rev_append translated.chat_events acc) rest
  in
  loop
    Server_routes_http_keeper_stream.For_testing.empty_stream_bridge_state []
    events

let assoc_string key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> Some value
  | _ -> None

let assoc_int key fields =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Some value
  | _ -> None

let assoc_assoc key fields =
  match List.assoc_opt key fields with
  | Some (`Assoc value) -> Some value
  | _ -> None

let test_agent_name_for_channel_actor () =
  let agent_name =
    Gate_keeper_backend.agent_name_for_channel_actor
      ~channel:"  discord  " ~channel_workspace_id:" thread-9 "
      ~channel_user_id:" user-42 "
  in
  check string "stable external actor session key"
    "gate:discord:thread-9:user-42" agent_name

let test_agent_name_for_channel_actor_separates_workspaces () =
  let left =
    Gate_keeper_backend.agent_name_for_channel_actor
      ~channel:"discord" ~channel_workspace_id:"workspace-a" ~channel_user_id:"user-42"
  in
  let right =
    Gate_keeper_backend.agent_name_for_channel_actor
      ~channel:"discord" ~channel_workspace_id:"workspace-b" ~channel_user_id:"user-42"
  in
  check bool "different external workspaces should not share keeper session"
    true (left <> right)

let test_contextualize_message_includes_external_metadata () =
  let rendered =
    Gate_keeper_backend.contextualize_message
      ~channel:"discord"
      ~channel_user_id:"user-42"
      ~channel_user_name:"Alice"
      ~channel_workspace_id:"workspace-9"
      ~metadata:[]
      ~content:"hello keeper"
  in
  check string "message envelope"
    {|[External channel context]
channel: discord
workspace_id: workspace-9
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
      ~channel_workspace_id:"workspace-9\rthread"
      ~metadata:[]
      ~content:"hello keeper"
  in
  check string "sanitized context"
    {|[External channel context]
channel: discord bot
workspace_id: workspace-9 thread
user_id: user-42
user_name: Alice Ops

[User message]
hello keeper|}
    rendered

let test_persist_connector_assistant_reply_records_lane_reply () =
  let base_dir = temp_base_path "gate-keeper-reply" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "discord-reply-keeper" in
      K.append_user_message ~base_dir ~keeper_name
        ~content:"<@bot> factorio?"
        ~surface:(Masc.Surface_ref.Gate { label = "discord"; address = [] })
        ~conversation_id:"discord:guild-1:channel:chan-9" ();
      Gate_keeper_backend.persist_connector_assistant_reply ~base_dir
        ~keeper_name ~source:"discord"
        ~conversation_id:"discord:guild-1:channel:chan-9"
        ~reply:"already answered" ();
      match K.load ~base_dir ~keeper_name with
      | [ user; assistant ] ->
          check string "user line first" "user" (K.Role.to_label user.K.role);
          check string "assistant reply persisted" "assistant" (K.Role.to_label assistant.K.role);
          check string "assistant lane" "discord"
            (Option.value assistant.K.source ~default:"");
          check string "assistant conversation id"
            "discord:guild-1:channel:chan-9"
            (Option.value assistant.K.conversation_id ~default:"");
          check string "assistant content" "already answered" assistant.K.content
      | messages ->
          failf "expected 2 chat messages, got %d" (List.length messages))

let test_persist_connector_assistant_reply_ignores_empty_reply () =
  let base_dir = temp_base_path "gate-keeper-empty-reply" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "discord-empty-reply-keeper" in
      Gate_keeper_backend.persist_connector_assistant_reply ~base_dir
        ~keeper_name ~source:"discord" ~reply:"   " ();
      check int "empty reply does not create chat file" 0
        (List.length (K.load ~base_dir ~keeper_name)))

let test_contextualize_message_includes_channel_metadata () =
  let rendered =
    Gate_keeper_backend.contextualize_message
      ~channel:"discord"
      ~channel_user_id:"user-42"
      ~channel_user_name:"Alice"
      ~channel_workspace_id:"thread-9"
      ~metadata:
        [
          ("discord.guild_id", "guild-1");
          ("discord.bound_channel_id", "parent-1");
          ("discord.binding_via_parent", "true");
        ]
      ~content:"hello from a thread"
  in
  check string "metadata envelope"
    {|[External channel context]
channel: discord
workspace_id: thread-9
user_id: user-42
user_name: Alice

[External channel metadata]
discord.guild_id: guild-1
discord.bound_channel_id: parent-1
discord.binding_via_parent: true

[User message]
hello from a thread|}
    rendered

let test_parse_keeper_chat_stream_request_accepts_connector_context () =
  let body =
    {|{"name":"luna","message":"hello","channel":"discord","channel_user_id":"user-42","channel_user_name":"Alice","channel_workspace_id":"workspace-9"}|}
  in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok payload ->
      check string "channel" "discord" payload.channel;
      check string "user id" "user-42" payload.channel_user_id;
      check string "user name" "Alice" payload.channel_user_name;
      check string "workspace id" "workspace-9" payload.channel_workspace_id
  | Error err -> fail ("expected connector context to parse: " ^ err)

let test_parse_keeper_chat_stream_request_rejects_partial_connector_context () =
  let body =
    {|{"name":"luna","message":"hello","channel":"discord"}|}
  in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok _ -> fail "expected partial connector context to be rejected"
  | Error err ->
      check string "validation message"
        "channel and channel_workspace_id are required when connector context is supplied"
        err

let test_parse_keeper_chat_stream_request_accepts_copilot_context () =
  let body =
    {|{"name":"luna","message":"hello","channel":"copilot","channel_workspace_id":"session-7","turn_instructions":"focus on overview"}|}
  in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok payload ->
      check string "channel" "copilot" payload.channel;
      check string "workspace id" "session-7" payload.channel_workspace_id;
      check string "user id optional" "" payload.channel_user_id;
      check (option string) "turn instructions" (Some "focus on overview") payload.turn_instructions;
      check bool "surface context absent" true (Option.is_none payload.surface_context)
  | Error err -> fail ("expected copilot context to parse: " ^ err)

let test_parse_keeper_chat_stream_request_formats_surface_context () =
  let body =
    {|{"name":"luna","message":"hello","channel":"copilot","channel_workspace_id":"session-7","surface_context":{"label":"Overview","route":"/overview","scene":"fleet view","fields":[{"k":"run","v":"2/5"},{"k":"alert","v":"1"}]}}|}
  in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok payload ->
      check string "channel" "copilot" payload.channel;
      check (option string) "turn instructions" None payload.turn_instructions;
      check bool "surface context present" true (Option.is_some payload.surface_context)
  | Error err -> fail ("expected surface context to parse: " ^ err)

let test_parse_keeper_chat_stream_request_accepts_attachment_only_user_blocks () =
  let body =
    {|{"name":"luna","message":"","attachments":[{"id":"att-img","type":"image","name":"screen.png","size":1024,"mime_type":"image/png","data":"data:image/png;base64,abc123"}],"user_blocks":[{"type":"image","attachment_id":"att-img","name":"screen.png","mime_type":"image/png","size":1024}]}|}
  in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok payload -> (
      check string "fallback message" "[image attached: screen.png]" payload.message;
      check int "attachment preserved" 1 (List.length payload.attachments);
      match payload.user_blocks with
      | [ Server_routes_http_keeper_stream.User_image media ] ->
          check string "attachment id" "att-img" media.attachment_id;
          check string "mime type" "image/png" media.mime_type;
          check (option int) "size" (Some 1024) media.size
      | _ -> fail "expected one image user block")
  | Error err -> fail ("expected attachment-only user_blocks to parse: " ^ err)

let test_parse_keeper_chat_stream_request_rejects_unknown_user_block_type () =
  let body =
    {|{"name":"luna","message":"hello","user_blocks":[{"type":"tool_result","text":"nope"}]}|}
  in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok _ -> fail "expected unknown user block type to be rejected"
  | Error err ->
      check string "validation message"
        {|unsupported user_blocks type "tool_result": expected text, image, document, or audio|}
        err

let test_keeper_multimodal_input_converts_user_blocks_to_oas_blocks () =
  let attachments =
    [
      {
        K.id = "att-img";
        att_type = "image";
        name = "screen.png";
        size = 1024;
        mime_type = "image/png";
        data = "data:image/png;base64,abc123";
      };
    ]
  in
  let media =
    {
      Keeper_multimodal_input.attachment_id = "att-img";
      name = "screen.png";
      mime_type = "image/png";
      size = Some 1024;
    }
  in
  match
    Keeper_multimodal_input.to_oas_blocks ~attachments
      [
        Keeper_multimodal_input.User_image media;
        Keeper_multimodal_input.User_text "describe this";
      ]
  with
  | Ok
      [
        Agent_sdk.Types.Image { media_type; data; source_type };
        Agent_sdk.Types.Text text;
      ] ->
      check string "media type" "image/png" media_type;
      check string "data" "abc123" data;
      check string "source type" "base64" source_type;
      check string "text" "describe this" text
  | Ok _ -> fail "expected image then text OAS blocks"
  | Error err -> fail ("expected OAS block conversion: " ^ err)

let test_keeper_multimodal_input_accepts_mixed_case_data_url () =
  let attachments =
    [
      {
        K.id = "att-img";
        att_type = "image";
        name = "screen.png";
        size = 1024;
        mime_type = "image/png";
        data = "DATA:IMAGE/PNG;BASE64,abc123";
      };
    ]
  in
  let media =
    {
      Keeper_multimodal_input.attachment_id = "att-img";
      name = "screen.png";
      mime_type = "image/png";
      size = Some 1024;
    }
  in
  match
    Keeper_multimodal_input.to_oas_blocks ~attachments
      [ Keeper_multimodal_input.User_image media ]
  with
  | Ok [ Agent_sdk.Types.Image { media_type; data; source_type } ] ->
      check string "media type" "image/png" media_type;
      check string "data" "abc123" data;
      check string "source type" "base64" source_type
  | Ok _ -> fail "expected image OAS block"
  | Error err -> fail ("expected mixed-case data URL conversion: " ^ err)

let test_keeper_multimodal_input_normalizes_inferred_data_url_mime () =
  let attachments =
    [
      {
        K.id = "att-img";
        att_type = "image";
        name = "screen.png";
        size = 1024;
        mime_type = "";
        data = "DATA:IMAGE/PNG;BASE64,abc123";
      };
    ]
  in
  let media =
    {
      Keeper_multimodal_input.attachment_id = "att-img";
      name = "screen.png";
      mime_type = "";
      size = Some 1024;
    }
  in
  match
    Keeper_multimodal_input.to_oas_blocks ~attachments
      [ Keeper_multimodal_input.User_image media ]
  with
  | Ok [ Agent_sdk.Types.Image { media_type; data; source_type } ] ->
      check string "media type" "image/png" media_type;
      check string "data" "abc123" data;
      check string "source type" "base64" source_type
  | Ok _ -> fail "expected image OAS block"
  | Error err -> fail ("expected inferred data URL MIME conversion: " ^ err)

let test_keeper_multimodal_input_rejects_mismatched_data_url_mime () =
  let attachments =
    [
      {
        K.id = "att-img";
        att_type = "image";
        name = "screen.png";
        size = 1024;
        mime_type = "image/png";
        data = "data:image/png;base64,abc123";
      };
    ]
  in
  let media =
    {
      Keeper_multimodal_input.attachment_id = "att-img";
      name = "screen.png";
      mime_type = "image/jpeg";
      size = Some 1024;
    }
  in
  match
    Keeper_multimodal_input.to_oas_blocks ~attachments
      [ Keeper_multimodal_input.User_image media ]
  with
  | Ok _ -> fail "expected mismatched data URL MIME to be rejected"
  | Error err ->
      check string "validation message"
        {|attachment MIME mismatch for image user block "att-img": declared image/jpeg but data URL is image/png|}
        err

let test_keeper_multimodal_input_rejects_malformed_data_url () =
  let attachments =
    [
      {
        K.id = "att-img";
        att_type = "image";
        name = "screen.png";
        size = 1024;
        mime_type = "image/png";
        data = "data:image/png,abc123";
      };
    ]
  in
  let media =
    {
      Keeper_multimodal_input.attachment_id = "att-img";
      name = "screen.png";
      mime_type = "image/png";
      size = Some 1024;
    }
  in
  match
    Keeper_multimodal_input.to_oas_blocks ~attachments
      [ Keeper_multimodal_input.User_image media ]
  with
  | Ok _ -> fail "expected malformed data URL to be rejected"
  | Error err ->
      check string "validation message"
        {|malformed data URL for image user block "att-img": expected data:<mime>;base64,<payload>|}
        err

let test_keeper_stream_args_preserve_user_blocks () =
  let media =
    {
      Keeper_multimodal_input.attachment_id = "att-img";
      name = "screen.png";
      mime_type = "image/png";
      size = Some 1024;
    }
  in
  let payload =
    { Server_routes_http_keeper_stream.name = "luna";
      message = "describe this";
      user_blocks =
        [
          Keeper_multimodal_input.User_text "describe this";
          Keeper_multimodal_input.User_image media;
        ];
      timeout_sec = None;
      turn_instructions = None;
      surface_context = None;
      channel = "";
      channel_user_id = "";
      channel_user_name = "";
      channel_workspace_id = "";
      attachments =
        [
          {
            K.id = "att-img";
            att_type = "image";
            name = "screen.png";
            size = 1024;
            mime_type = "image/png";
            data = "abc123";
          };
        ];
    }
  in
  match Server_routes_http_keeper_stream.For_testing.args_of_request payload with
  | `Assoc fields -> (
      match List.assoc_opt "user_blocks" fields, List.assoc_opt "attachments" fields with
      | Some (`List [ `Assoc text_fields; `Assoc image_fields ]),
        Some (`List [ `Assoc attachment_fields ]) ->
          check (option string) "text block type" (Some "text")
            (match List.assoc_opt "type" text_fields with
             | Some (`String value) -> Some value
             | _ -> None);
          check (option string) "image block ref" (Some "att-img")
            (match List.assoc_opt "attachment_id" image_fields with
             | Some (`String value) -> Some value
             | _ -> None);
          check (option string) "attachment payload" (Some "abc123")
            (match List.assoc_opt "data" attachment_fields with
             | Some (`String value) -> Some value
             | _ -> None)
      | _ -> fail "expected user_blocks and attachment payload in keeper args")
  | _ -> fail "expected keeper args object"

let test_keeper_stream_bridge_preserves_interleaved_thinking_and_tool () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [
        ContentBlockDelta { index = 0; delta = ThinkingDelta "think A" };
        ContentBlockStart
          { index = 1;
            content_type = "tool_use";
            tool_id = Some "tc-1";
            tool_name = Some "keeper_board_list" };
        ContentBlockDelta { index = 1; delta = InputJsonDelta "{\"limit\":" };
        ContentBlockDelta { index = 1; delta = InputJsonDelta "1}" };
        ContentBlockStop { index = 1 };
        ContentBlockDelta { index = 2; delta = ThinkingDelta "think B" };
      ]
  in
  match events with
  | [ Keeper_chat_events.Custom
        { name = "KEEPER_THINKING_DELTA"; value = `Assoc first };
      Keeper_chat_events.Tool_call_start { tool_call_id; tool_call_name };
      Keeper_chat_events.Tool_call_args { tool_call_id = args_id_a; delta = args_a };
      Keeper_chat_events.Tool_call_args { tool_call_id = args_id_b; delta = args_b };
      Keeper_chat_events.Tool_call_end { tool_call_id = end_id };
      Keeper_chat_events.Custom
        { name = "KEEPER_THINKING_DELTA"; value = `Assoc last } ] ->
      check (option string) "first thinking" (Some "think A")
        (assoc_string "delta" first);
      check string "tool id" "tc-1" tool_call_id;
      check string "tool name" "keeper_board_list" tool_call_name;
      check string "args id a" "tc-1" args_id_a;
      check string "args id b" "tc-1" args_id_b;
      check string "args a" "{\"limit\":" args_a;
      check string "args b" "1}" args_b;
      check string "end id" "tc-1" end_id;
      check (option string) "last thinking" (Some "think B")
        (assoc_string "delta" last)
  | _ ->
      failf "unexpected stream bridge events: %s"
        (String.concat ", "
           (List.map
              (function
                | Keeper_chat_events.Custom { name; _ } -> "custom:" ^ name
                | Keeper_chat_events.Tool_call_start _ -> "tool_start"
                | Keeper_chat_events.Tool_call_args _ -> "tool_args"
                | Keeper_chat_events.Tool_call_end _ -> "tool_end"
                | Keeper_chat_events.Text_delta _ -> "text"
                | Keeper_chat_events.Event_error _ -> "error"
                | _ -> "other")
              events))

let test_keeper_stream_bridge_surfaces_oas_message_metadata () =
  let open Agent_sdk.Types in
  let usage_start =
    { input_tokens = 10;
      output_tokens = 1;
      cache_creation_input_tokens = 3;
      cache_read_input_tokens = 4;
      cost_usd = None }
  in
  let usage_delta =
    { usage_start with output_tokens = 2; cost_usd = Some 0.125 }
  in
  let events =
    translate_oas_stream_events
      [
        MessageStart
          { id = "msg-oas-1"; model = "gpt-5.5"; usage = Some usage_start };
        MessageDelta { stop_reason = Some EndTurn; usage = Some usage_delta };
        MessageStop;
        Ping;
      ]
  in
  match events with
  | [ Keeper_chat_events.Custom
        { name = "KEEPER_STREAM_MESSAGE_START"; value = `Assoc start };
      Keeper_chat_events.Custom
        { name = "KEEPER_STREAM_MESSAGE_DELTA"; value = `Assoc delta };
      Keeper_chat_events.Custom
        { name = "KEEPER_STREAM_MESSAGE_STOP"; value = `Null };
      Keeper_chat_events.Custom { name = "KEEPER_STREAM_PING"; value = `Null } ] ->
      let start_usage =
        assoc_assoc "usage" start |> Option.value ~default:[]
      in
      let delta_usage =
        assoc_assoc "usage" delta |> Option.value ~default:[]
      in
      check (option string) "provider message id" (Some "msg-oas-1")
        (assoc_string "provider_message_id" start);
      check (option string) "model" (Some "gpt-5.5")
        (assoc_string "model" start);
      check (option int) "start input tokens" (Some 10)
        (assoc_int "input_tokens" start_usage);
      check (option int) "start total tokens" (Some 11)
        (assoc_int "total_tokens" start_usage);
      check (option int) "cache creation tokens" (Some 3)
        (assoc_int "cache_creation_input_tokens" start_usage);
      check (option string) "stop reason" (Some "end_turn")
        (assoc_string "stop_reason" delta);
      check (option int) "delta output tokens" (Some 2)
        (assoc_int "output_tokens" delta_usage);
      check (option int) "delta total tokens" (Some 12)
        (assoc_int "total_tokens" delta_usage)
  | _ -> fail "expected OAS message lifecycle metadata events"

let test_keeper_stream_bridge_rejects_tool_args_without_start () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [ ContentBlockDelta { index = 7; delta = InputJsonDelta "{\"x\":1}" } ]
  in
  match events with
  | [ Keeper_chat_events.Custom
        { name = "KEEPER_STREAM_PROTOCOL_ERROR"; value = `Assoc fields } ] ->
      check (option string) "kind" (Some "tool_args_without_start")
        (assoc_string "kind" fields);
      check (option int) "index" (Some 7) (assoc_int "index" fields);
      check bool "no tool event forged" true
        (not
           (List.exists
              (function
                | Keeper_chat_events.Tool_call_args _ -> true
                | _ -> false)
              events))
  | _ -> fail "expected a stream protocol error for missing tool start"

let test_keeper_stream_bridge_surfaces_unknown_and_incomplete_events () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [
        SSEUnknownEventType { event_type = "response.future"; raw = "{\"x\":1}" };
        StreamIncomplete { reason = "max_output_tokens" };
      ]
  in
  match events with
  | [ Keeper_chat_events.Custom
        { name = "KEEPER_STREAM_PROTOCOL_ERROR"; value = `Assoc unknown };
      Keeper_chat_events.Custom
        { name = "KEEPER_STREAM_PROTOCOL_ERROR"; value = `Assoc incomplete };
      Keeper_chat_events.Event_error { message } ] ->
      check (option string) "unknown kind" (Some "sse_unknown_event_type")
        (assoc_string "kind" unknown);
      check (option string) "unknown event type" (Some "response.future")
        (assoc_string "event_type" unknown);
      check (option string) "incomplete kind" (Some "sse_stream_incomplete")
        (assoc_string "kind" incomplete);
      check string "incomplete is visible error"
        "Provider stream incomplete: max_output_tokens" message
  | _ -> fail "expected visible events for unknown/incomplete provider stream"

let test_keeper_chat_history_persists_attachment_refs_not_raw_media () =
  let base_dir = temp_base_path "gate-keeper-media-history" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "multimodal-history-keeper" in
      let raw_media = "data:image/png;base64,SECRET_RAW_MEDIA" in
      K.append_turn ~base_dir ~keeper_name
        ~user_content:"describe this"
        ~user_attachments:
          [
            {
              K.id = "att-img";
              att_type = "image";
              name = "screen.png";
              size = 1024;
              mime_type = "image/png";
              data = raw_media;
            };
          ]
        ~assistant_content:"looks like a dashboard"
        ();
      let path =
        Filename.concat
          (Filename.concat
             (Common.masc_dir_from_base_path ~base_path:base_dir)
             "keeper_chat")
          (keeper_name ^ ".jsonl")
      in
      let persisted = read_file path in
      check bool "raw media omitted from jsonl" false
        (string_contains persisted raw_media);
      check bool "attachment ref persisted" true
        (string_contains persisted "masc://attachment/att-img/");
      match K.load ~base_dir ~keeper_name with
      | user :: _ -> (
          match user.K.attachments with
          | Some [ att ] ->
              check bool "loaded attachment omits raw media" false
                (String.equal raw_media att.K.data);
              check bool "loaded attachment has ref" true
                (string_contains att.K.data "masc://attachment/att-img/")
          | _ -> fail "expected one persisted attachment")
      | [] -> fail "expected persisted chat messages")

let test_keeper_chat_user_only_persists_attachment_refs_not_raw_media () =
  let base_dir = temp_base_path "gate-keeper-media-user-only-history" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
      let keeper_name = "multimodal-user-only-history-keeper" in
      let raw_media = "data:image/png;base64,SECRET_RAW_MEDIA" in
      K.append_user_message ~base_dir ~keeper_name
        ~content:"inspect this"
        ~attachments:
          [
            {
              K.id = "att-img";
              att_type = "image";
              name = "screen.png";
              size = 1024;
              mime_type = "image/png";
              data = raw_media;
            };
          ]
        ();
      let path =
        Filename.concat
          (Filename.concat
             (Common.masc_dir_from_base_path ~base_path:base_dir)
             "keeper_chat")
          (keeper_name ^ ".jsonl")
      in
      let persisted = read_file path in
      check bool "raw media omitted from user-only jsonl" false
        (string_contains persisted raw_media);
      check bool "attachment ref persisted on user-only row" true
        (string_contains persisted "masc://attachment/att-img/");
      match K.load ~base_dir ~keeper_name with
      | [ user ] -> (
          match user.K.attachments with
          | Some [ att ] ->
              check bool "loaded user-only attachment omits raw media" false
                (String.equal raw_media att.K.data);
              check bool "loaded user-only attachment has ref" true
                (string_contains att.K.data "masc://attachment/att-img/")
          | _ -> fail "expected one persisted user-only attachment")
      | _ -> fail "expected one persisted user message")

let test_extract_visible_reply_drops_empty_structured_envelope () =
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("runtime_class", `String "keeper");
          ("turn_outcome", `String "visible_reply");
          ("reply", `String "");
          ( "tool_call_evidence",
            `List
              [
                `Assoc
                  [
                    ("name", `String "keeper_context_status");
                    ("status", `String "ok");
                  ];
              ] );
        ])
  in
  let payload_json_opt, visible_reply =
    Server_routes_http_keeper_stream.For_testing.extract_visible_reply body
  in
  check bool "structured envelope parsed" true (Option.is_some payload_json_opt);
  check string "empty reply does not fall back to envelope" "" visible_reply

let test_extract_visible_reply_uses_typed_reply_field_only () =
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("runtime_class", `String "keeper");
          ("turn_outcome", `String "visible_reply");
          ("reply", `String "Done.\n\n[STATE]\n{}\n[/STATE]");
          ("runtime_note", `String "must not be user-visible");
        ])
  in
  let payload_json_opt, visible_reply =
    Server_routes_http_keeper_stream.For_testing.extract_visible_reply body
  in
  check bool "structured envelope parsed" true (Option.is_some payload_json_opt);
  check string "visible reply comes from reply field" "Done." visible_reply

let vision_provider_cfg () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id:"minimax-m3"
    ~base_url:"http://127.0.0.1.invalid"
    ()

let test_runtime_run_blocks_appends_multimodal_input_to_oas_agent () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let config =
    Runtime_agent.default_config
      ~name:"multimodal-runtime-proof"
      ~provider_cfg:(vision_provider_cfg ())
      ~system_prompt:""
      ~tools:[]
  in
  let config =
    { config with
      max_turns = 1;
      session_id = Some "multimodal-runtime-proof-session";
      exit_condition = Some (fun _turn -> true);
      exit_condition_result =
        Some (fun _turn -> Runtime_agent.Completed, Some "exit proof");
    }
  in
  let agent_ref = ref None in
  let blocks =
    [
      Agent_sdk.Types.Text "Inspect this";
      Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"img" ();
    ]
  in
  (match
     Runtime_agent.run_blocks ~sw ~net:env#net ~config ~agent_ref blocks
   with
   | Ok result -> (
       match result.Runtime_agent.stop_reason with
       | Runtime_agent.Completed -> ()
       | stop_reason ->
           failf "unexpected stop reason after exit-condition proof: %s"
             (Keeper_execution_receipt_types.stop_reason_to_string stop_reason))
   | Error err ->
       fail ("expected exit-condition checkpoint result: "
             ^ Agent_sdk.Error.to_string err));
  match !agent_ref with
  | None -> fail "expected Runtime_agent.run_blocks to expose built OAS agent"
  | Some agent -> (
      match List.rev (Agent_sdk.Agent.state agent).messages with
      | { Agent_sdk.Types.role = User; content; _ } :: _ -> (
          check int "stored blocks" 2 (List.length content);
          match content with
          | [
              Agent_sdk.Types.Text text;
              Agent_sdk.Types.Image { media_type; data; source_type };
            ] ->
              check string "text preserved" "Inspect this" text;
              check string "image media type" "image/png" media_type;
              check string "image data" "img" data;
              check string "source type" "base64" source_type
          | _ -> fail "stored user input lost multimodal block shape")
      | _ -> fail "missing appended OAS user message")

let multimodal_caps ?(image = false) ?(audio = false) ?(multimodal = false) () =
  { Llm_provider.Capabilities.default_capabilities with
    supports_image_input = image;
    supports_audio_input = audio;
    supports_multimodal_inputs = multimodal;
  }

let test_runtime_multimodal_gate_model_caps_fail_closed () =
  let provider_caps = multimodal_caps ~image:true ~multimodal:true () in
  let model_caps =
    { Runtime_schema.model_capabilities_default with
      supports_image_input = false;
      supports_multimodal_inputs = false;
    }
  in
  let effective =
    Runtime_agent.For_testing.apply_runtime_model_input_capabilities
      provider_caps
      model_caps
  in
  let blocks =
    [ Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"abc" () ]
  in
  match
    Runtime_agent.For_testing.validate_content_blocks_against_capabilities
      ~provider_label:"runtime:deepseek"
      effective
      blocks
  with
  | Ok () -> fail "expected runtime model capability to veto image input"
  | Error
      (Agent_sdk.Error.Config
         (Agent_sdk.Error.InvalidConfig { detail; _ })) ->
      check bool "mentions unsupported image" true
        (String_util.string_contains_substring
           ~needle:"unsupported image input"
           detail)
  | Error err -> fail ("unexpected error shape: " ^ Agent_sdk.Error.to_string err)

let test_runtime_multimodal_gate_lists_required_modalities () =
  let blocks =
    [
      Agent_sdk.Types.Text "describe these";
      Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"abc" ();
      Agent_sdk.Types.audio_block ~media_type:"audio/wav" ~data:"def" ();
    ]
  in
  check (list string) "required modalities" [ "image"; "audio" ]
    (Runtime_agent.For_testing.required_modalities_of_content_blocks blocks)

let test_runtime_multimodal_gate_includes_initial_messages () =
  let initial_messages =
    [
      { Agent_sdk.Types.role = Agent_sdk.Types.User;
        content =
          [
            Agent_sdk.Types.Text "previous image turn";
            Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"abc" ();
          ];
        name = None;
        tool_call_id = None;
        metadata = [] };
    ]
  in
  check (list string) "history required modalities" [ "image" ]
    (Runtime_agent.For_testing.required_modalities_of_messages initial_messages);
  check (list string) "run required modalities" [ "image" ]
    (Runtime_agent.For_testing.required_modalities_for_run
       ~initial_messages
       ~goal_blocks:[ Agent_sdk.Types.Text "text-only follow-up" ]);
  let blocks =
    Runtime_agent.For_testing.content_blocks_for_run
      ~initial_messages
      ~goal_blocks:[ Agent_sdk.Types.Text "text-only follow-up" ]
  in
  match
    Runtime_agent.For_testing.validate_content_blocks_against_capabilities
      ~provider_label:"test:text-only"
      (multimodal_caps ())
      blocks
  with
  | Ok () -> fail "expected image retained in history to be rejected"
  | Error
      (Agent_sdk.Error.Config
         (Agent_sdk.Error.InvalidConfig { detail; _ })) ->
      check bool "mentions unsupported history image" true
        (String_util.string_contains_substring
           ~needle:"unsupported image input"
           detail)
  | Error err -> fail ("unexpected error shape: " ^ Agent_sdk.Error.to_string err)

let test_runtime_multimodal_gate_rejects_unsupported_image () =
  let blocks =
    [ Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"abc" () ]
  in
  match
    Runtime_agent.For_testing.validate_content_blocks_against_capabilities
      ~provider_label:"test:text-only"
      (multimodal_caps ())
      blocks
  with
  | Ok () -> fail "expected image input to be rejected for text-only provider"
  | Error
      (Agent_sdk.Error.Config
         (Agent_sdk.Error.InvalidConfig { field; detail })) ->
      check string "field" "multimodal_input" field;
      check bool "mentions image" true
        (String_util.string_contains_substring
           ~needle:"unsupported image input"
           detail);
      check bool "mentions provider" true
        (String_util.string_contains_substring
           ~needle:"test:text-only"
           detail)
  | Error err -> fail ("unexpected error shape: " ^ Agent_sdk.Error.to_string err)

let test_runtime_multimodal_gate_allows_supported_image () =
  let blocks =
    [
      Agent_sdk.Types.Text "describe this";
      Agent_sdk.Types.image_block ~media_type:"image/png" ~data:"abc" ();
    ]
  in
  match
    Runtime_agent.For_testing.validate_content_blocks_against_capabilities
      ~provider_label:"test:image"
      (multimodal_caps ~image:true ())
      blocks
  with
  | Ok () -> ()
  | Error err -> fail ("expected image-capable provider to pass: "
                       ^ Agent_sdk.Error.to_string err)

let test_runtime_multimodal_gate_requires_multimodal_for_document () =
  let blocks =
    [
      Agent_sdk.Types.document_block
        ~media_type:"application/pdf"
        ~data:"abc"
        ();
    ]
  in
  let rejected =
    Runtime_agent.For_testing.validate_content_blocks_against_capabilities
      ~provider_label:"test:image-only"
      (multimodal_caps ~image:true ())
      blocks
  in
  let accepted =
    Runtime_agent.For_testing.validate_content_blocks_against_capabilities
      ~provider_label:"test:multimodal"
      (multimodal_caps ~multimodal:true ())
      blocks
  in
  (match rejected with
   | Error
       (Agent_sdk.Error.Config
          (Agent_sdk.Error.InvalidConfig { detail; _ })) ->
       check bool "mentions document" true
         (String_util.string_contains_substring
            ~needle:"unsupported document input"
            detail)
   | Ok () -> fail "expected document to require multimodal capability"
   | Error err -> fail ("unexpected error shape: " ^ Agent_sdk.Error.to_string err));
  match accepted with
  | Ok () -> ()
  | Error err -> fail ("expected multimodal provider to accept document: "
                       ^ Agent_sdk.Error.to_string err)

let test_surface_context_to_instructions_formats_copilot_context () =
  let ctx =
    Yojson.Safe.from_string
      {|{"label":"Overview","route":"/overview","scene":"fleet view","fields":{"run":"2/5","alert":"1"}}|}
  in
  match Server_routes_http_keeper_stream.For_testing.surface_context_to_instructions ctx with
  | Some instructions ->
      check bool "includes label" true
        (String_util.string_contains_substring ~needle:"Surface label: Overview" instructions);
      check bool "includes route" true
        (String_util.string_contains_substring ~needle:"Route: /overview" instructions);
      check bool "includes scene" true
        (String_util.string_contains_substring ~needle:"Scene: fleet view" instructions);
      check bool "includes fields" true
        (String_util.string_contains_substring ~needle:"Fields:" instructions)
  | None -> fail "expected surface_context to format into instructions"

let test_surface_context_to_instructions_ignores_empty () =
  let ctx = `Assoc [ ("label", `String "  "); ("fields", `Assoc []) ] in
  check (option string) "empty surface_context" None
    (Server_routes_http_keeper_stream.For_testing.surface_context_to_instructions ctx)

(* Regression for #21465: the keeper_turn (MCP tool path) formatter must render
   the dashboard's `List of {k,v} fields shape rather than silently dropping it,
   and must agree byte-for-byte with the HTTP copilot route now that both share
   one SSOT formatter (Keeper_turn.surface_context_to_instructions). *)
let test_surface_context_mcp_path_renders_list_fields () =
  let ctx =
    Yojson.Safe.from_string
      {|{"label":"Overview","route":"/overview","scene":"fleet view","fields":[{"k":"run","v":"2/5"},{"k":"alert","v":"1"}]}|}
  in
  match KT.For_testing.surface_context_to_instructions ctx with
  | Some instructions ->
      check bool "renders list-shaped field key" true
        (String_util.string_contains_substring ~needle:"run: 2/5" instructions);
      check bool "renders second list-shaped field" true
        (String_util.string_contains_substring ~needle:"alert: 1" instructions);
      check bool "includes co-view header" true
        (String_util.string_contains_substring ~needle:"[Co-view context]" instructions);
      check (option string) "http route matches mcp formatter (single SSOT)"
        (Some instructions)
        (Server_routes_http_keeper_stream.For_testing.surface_context_to_instructions
           ctx)
  | None -> fail "expected list-shaped surface_context to format into instructions"

let test_chat_surface_of_request_labels_copilot_gate () =
  let payload =
    { Server_routes_http_keeper_stream.name = "luna";
      message = "hello";
      timeout_sec = None;
      turn_instructions = None;
      surface_context = None;
      user_blocks = [];
      channel = "copilot";
      channel_user_id = "";
      channel_user_name = "";
      channel_workspace_id = "session-7";
      attachments = [] }
  in
  let surface = Server_routes_http_keeper_stream.For_testing.chat_surface_of_request payload in
  check string "copilot surface label" "copilot" (Surface_ref.lane_label surface)

let test_chat_speaker_of_request_copilot_is_owner () =
  let payload =
    { Server_routes_http_keeper_stream.name = "luna";
      message = "hello";
      timeout_sec = None;
      turn_instructions = None;
      surface_context = None;
      user_blocks = [];
      channel = "copilot";
      channel_user_id = "";
      channel_user_name = "";
      channel_workspace_id = "session-7";
      attachments = [] }
  in
  let speaker = Server_routes_http_keeper_stream.For_testing.chat_speaker_of_request payload in
  check (option string) "copilot speaker id" None speaker.speaker_id;
  check (option string) "copilot speaker name" None speaker.speaker_name;
  check bool "copilot speaker authority is owner" true
    (speaker.speaker_authority = Keeper_chat_store.Owner)

let test_chat_speaker_of_request_connector_is_external () =
  let payload =
    { Server_routes_http_keeper_stream.name = "luna";
      message = "hello";
      timeout_sec = None;
      turn_instructions = None;
      surface_context = None;
      user_blocks = [];
      channel = "discord";
      channel_user_id = "user-42";
      channel_user_name = "Alice";
      channel_workspace_id = "workspace-9";
      attachments = [] }
  in
  let speaker = Server_routes_http_keeper_stream.For_testing.chat_speaker_of_request payload in
  check (option string) "connector speaker id" (Some "user-42") speaker.speaker_id;
  check (option string) "connector speaker name" (Some "Alice") speaker.speaker_name;
  check bool "connector speaker authority is external" true
    (speaker.speaker_authority = Keeper_chat_store.External)

let test_parse_keeper_chat_stream_request_rejects_legacy_model_args () =
  let cases =
    [
      ( "models",
        {|{"name":"luna","message":"hello","models":["glm:legacy"]}|} );
      ( "allowed_models",
        {|{"name":"luna","message":"hello","allowed_models":["glm:legacy"]}|} );
      ( "active_model",
        {|{"name":"luna","message":"hello","active_model":"glm:legacy"}|} );
    ]
  in
  List.iter
    (fun (field, body) ->
      match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
      | Ok _ -> fail ("expected legacy field to be rejected: " ^ field)
      | Error err ->
          check string ("legacy field rejected: " ^ field)
            (Printf.sprintf
               "removed keeper model args for masc_keeper_msg: %s. Use runtime_id; concrete provider/model identity is resolved from the default runtime."
               field)
            err)
    cases

(* ── Filesystem-safe sanitizer ──────────────────────────────────────── *)

let test_filesystem_safe_normal () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "workspace-123" in
  check string "safe chars preserved" "workspace-123" result

let test_filesystem_safe_strips_path_traversal () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "../../etc/passwd" in
  check string "path traversal sanitized" "______etc_passwd" result

let test_filesystem_safe_empty_to_unknown () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "" in
  check string "empty becomes unknown" "unknown" result

let test_filesystem_safe_all_special_to_unknown () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "@@@!!!" in
  check string "all special becomes unknown" "unknown" result

let test_filesystem_safe_whitespace_only () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "   " in
  check string "whitespace only becomes unknown" "unknown" result

let test_filesystem_safe_with_spaces () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "my channel" in
  check string "spaces replaced with underscore" "my_channel" result

let test_filesystem_safe_with_dots () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "channel.name" in
  check string "dots replaced with underscore" "channel_name" result

let test_filesystem_safe_newline_and_tab () =
  let result =
    Gate_keeper_backend.filesystem_safe_or_unknown
      ("chan" ^ "\n" ^ "nel" ^ "\t" ^ "name")
  in
  check string "newline and tab replaced" "chan_nel_name" result

let test_filesystem_safe_underscore_only () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "___" in
  check string "underscore only becomes unknown" "unknown" result

let test_filesystem_safe_mixed_safe_unsafe () =
  let result = Gate_keeper_backend.filesystem_safe_or_unknown "a-b.c/d e" in
  check string "mixed safe and unsafe chars" "a-b_c_d_e" result

(* ── Agent name security ──────────────────────────────────────────── *)

let test_agent_name_blocks_path_traversal () =
  let agent_name =
    Gate_keeper_backend.agent_name_for_channel_actor
      ~channel:"../etc"
      ~channel_workspace_id:"../../../tmp"
      ~channel_user_id:"attack"
  in
  let has_slash = String.contains agent_name '/' in
  let has_dot = String.contains agent_name '.' in
  check bool "no slash in agent name" false has_slash;
  check bool "no dot in agent name" false has_dot

let test_agent_name_normal_values_unchanged () =
  let agent_name =
    Gate_keeper_backend.agent_name_for_channel_actor
      ~channel:"discord" ~channel_workspace_id:"123" ~channel_user_id:"456"
  in
  check string "normal values pass through" "gate:discord:123:456" agent_name

let test_agent_name_special_chars_sanitized () =
  let agent_name =
    Gate_keeper_backend.agent_name_for_channel_actor
      ~channel:"my chan"
      ~channel_workspace_id:"thread#1"
      ~channel_user_id:"user@2"
  in
  check string "special chars become underscore"
    "gate:my_chan:thread_1:user_2" agent_name

(* ── Response parsing ────────────────────────────────────────────── *)

let test_extract_reply_from_reply_field () =
  let body = {|{"reply":"hello world","model_used":"test"}|} in
  let result = Gate_keeper_backend.extract_reply_text body in
  check string "reply field extracted" "hello world" result

let test_extract_reply_does_not_fallback_to_text_field () =
  let body = {|{"text":"fallback content"}|} in
  let result = Gate_keeper_backend.extract_reply_text body in
  check string "text field is not reply" body result

let test_extract_reply_raw_on_non_json () =
  let body = "not json at all" in
  let result = Gate_keeper_backend.extract_reply_text body in
  check string "raw body returned" "not json at all" result

let test_extract_turn_stats_present () =
  let body = {|{"model_used":"claude-opus","duration_ms":1500,"total_tokens":500}|} in
  match Gate_keeper_backend.extract_turn_stats body with
  | Some { Gate_protocol.model_used; duration_ms; tokens_used } ->
      check string "model redacted to runtime lane" "runtime" model_used;
      check int "duration" 1500 duration_ms;
      check int "tokens" 500 tokens_used
  | None -> fail "expected Some stats"

let test_extract_turn_stats_ignores_model_only_payload () =
  let body = {|{"model_used":"claude-opus"}|} in
  let result = Gate_keeper_backend.extract_turn_stats body in
  check bool "model-only fields are not stats" true (result = None)

let test_extract_turn_stats_missing_returns_none () =
  let body = {|{"other_field":"value"}|} in
  let result = Gate_keeper_backend.extract_turn_stats body in
  check bool "missing fields returns None" true (result = None)

(* ── ACK envelope parse (regression for #22569 blocker) ───────────────
   The previous [Safe_ops.protect ~default:None] wrapper collapsed two
   distinct failure modes into a single [None]: the keeper legitimately
   returned no ACK fields vs the backend could not parse what the keeper
   sent. These tests pin the typed [Result.t] so the dispatch site can
   surface a deliberate degraded path instead of silently substituting
   the keeper's reply body. *)

let expect_error expected actual =
  match actual with
  | Ok _ -> failf "expected Error %s, got Ok _" expected
  | Error failure ->
      let got = Gate_keeper_backend.ack_parse_failure_to_string failure in
      check bool
        (Printf.sprintf "expected Error %s, got Error %s" expected got)
        true
        (String_util.string_contains_substring ~needle:expected got)

let test_extract_message_request_ack_accepts_well_formed_envelope () =
  let body =
    {|{"request_id":"req-1","status":"queued","keeper_name":"luna"}|}
  in
  match
    Gate_keeper_backend.extract_message_request_ack ~channel:"discord"
      ~channel_user_id:"user-1" ~keeper_name:"luna" ~metadata:[] body
  with
  | Ok request ->
      check string "request_id" "req-1" request.request_id;
      check string "destination_id" "luna" request.destination_id;
      check string "channel" "discord" request.channel;
      (match request.status with
       | Gate_protocol.Queued -> ()
       | _ -> fail "expected Queued status")
  | Error failure ->
      fail
        ("expected Ok request: "
         ^ Gate_keeper_backend.ack_parse_failure_to_string failure)

let test_extract_message_request_ack_rejects_missing_request_id () =
  let body = {|{"status":"queued"}|} in
  expect_error "missing request_id"
    (Gate_keeper_backend.extract_message_request_ack ~channel:"discord"
       ~channel_user_id:"user-1" ~keeper_name:"luna" ~metadata:[] body)

let test_extract_message_request_ack_rejects_empty_request_id () =
  let body = {|{"request_id":"   ","status":"queued"}|} in
  expect_error "empty request_id"
    (Gate_keeper_backend.extract_message_request_ack ~channel:"discord"
       ~channel_user_id:"user-1" ~keeper_name:"luna" ~metadata:[] body)

let test_extract_message_request_ack_rejects_missing_status () =
  let body = {|{"request_id":"req-1"}|} in
  expect_error "missing status"
    (Gate_keeper_backend.extract_message_request_ack ~channel:"discord"
       ~channel_user_id:"user-1" ~keeper_name:"luna" ~metadata:[] body)

let test_extract_message_request_ack_rejects_unknown_status () =
  let body = {|{"request_id":"req-1","status":"frobnicated"}|} in
  expect_error "unknown status"
    (Gate_keeper_backend.extract_message_request_ack ~channel:"discord"
       ~channel_user_id:"user-1" ~keeper_name:"luna" ~metadata:[] body)

let test_extract_message_request_ack_rejects_invalid_json () =
  let body = "{not valid json" in
  expect_error "invalid json"
    (Gate_keeper_backend.extract_message_request_ack ~channel:"discord"
       ~channel_user_id:"user-1" ~keeper_name:"luna" ~metadata:[] body)

let test_extract_message_request_ack_normalizes_status_case () =
  (* The wire contract lowercases the status before consulting the closed
     sum. A mixed-case envelope from a future keeper should still be
     accepted, not rejected as unknown. *)
  let body = {|{"request_id":"req-1","status":"Running"}|} in
  match
    Gate_keeper_backend.extract_message_request_ack ~channel:"discord"
      ~channel_user_id:"user-1" ~keeper_name:"luna" ~metadata:[] body
  with
  | Ok request ->
      (match request.status with
       | Gate_protocol.Running -> ()
       | _ -> fail "expected Running status after case normalization")
  | Error failure ->
      fail
        ("expected Ok after case normalization: "
         ^ Gate_keeper_backend.ack_parse_failure_to_string failure)

let test_extract_message_request_ack_falls_back_to_keeper_name () =
  let body = {|{"request_id":"req-1","status":"done"}|} in
  match
    Gate_keeper_backend.extract_message_request_ack ~channel:"discord"
      ~channel_user_id:"user-1" ~keeper_name:"luna" ~metadata:[] body
  with
  | Ok request ->
      check string "destination_id falls back to keeper_name" "luna"
        request.destination_id
  | Error failure ->
      fail
        ("expected Ok with fallback keeper_name: "
         ^ Gate_keeper_backend.ack_parse_failure_to_string failure)

let () =
  Alcotest.run "Gate_keeper_backend"
    [
      ( "helpers",
        [
          test_case "agent name is stable" `Quick
            test_agent_name_for_channel_actor;
          test_case "agent name separates workspaces" `Quick
            test_agent_name_for_channel_actor_separates_workspaces;
          test_case "contextualized message keeps external metadata" `Quick
            test_contextualize_message_includes_external_metadata;
          test_case "context envelope sanitizes metadata lines" `Quick
            test_contextualize_message_sanitizes_context_lines;
          test_case "persists connector assistant reply" `Quick
            test_persist_connector_assistant_reply_records_lane_reply;
          test_case "skips empty connector assistant reply" `Quick
            test_persist_connector_assistant_reply_ignores_empty_reply;
          test_case "context envelope includes channel metadata" `Quick
            test_contextualize_message_includes_channel_metadata;
          test_case "stream request accepts connector context" `Quick
            test_parse_keeper_chat_stream_request_accepts_connector_context;
          test_case "stream request rejects partial connector context" `Quick
            test_parse_keeper_chat_stream_request_rejects_partial_connector_context;
          test_case "stream request accepts copilot context" `Quick
            test_parse_keeper_chat_stream_request_accepts_copilot_context;
          test_case "stream request formats surface context" `Quick
            test_parse_keeper_chat_stream_request_formats_surface_context;
          test_case "stream request accepts attachment-only user blocks" `Quick
            test_parse_keeper_chat_stream_request_accepts_attachment_only_user_blocks;
          test_case "stream request rejects unknown user block type" `Quick
            test_parse_keeper_chat_stream_request_rejects_unknown_user_block_type;
          test_case "multimodal input converts user blocks to OAS blocks" `Quick
            test_keeper_multimodal_input_converts_user_blocks_to_oas_blocks;
          test_case "multimodal input accepts mixed-case data URL" `Quick
            test_keeper_multimodal_input_accepts_mixed_case_data_url;
          test_case "multimodal input normalizes inferred data URL MIME" `Quick
            test_keeper_multimodal_input_normalizes_inferred_data_url_mime;
          test_case "multimodal input rejects mismatched data URL MIME" `Quick
            test_keeper_multimodal_input_rejects_mismatched_data_url_mime;
          test_case "multimodal input rejects malformed data URL" `Quick
            test_keeper_multimodal_input_rejects_malformed_data_url;
          test_case "stream args preserve user blocks" `Quick
            test_keeper_stream_args_preserve_user_blocks;
          test_case "stream bridge preserves interleaved thinking and tool" `Quick
            test_keeper_stream_bridge_preserves_interleaved_thinking_and_tool;
          test_case "stream bridge surfaces OAS message metadata" `Quick
            test_keeper_stream_bridge_surfaces_oas_message_metadata;
          test_case "stream bridge rejects tool args without start" `Quick
            test_keeper_stream_bridge_rejects_tool_args_without_start;
          test_case "stream bridge surfaces unknown and incomplete events" `Quick
            test_keeper_stream_bridge_surfaces_unknown_and_incomplete_events;
          test_case "chat history persists attachment refs not raw media" `Quick
            test_keeper_chat_history_persists_attachment_refs_not_raw_media;
          test_case "user-only chat history persists attachment refs not raw media" `Quick
            test_keeper_chat_user_only_persists_attachment_refs_not_raw_media;
          test_case "visible reply drops empty structured envelope" `Quick
            test_extract_visible_reply_drops_empty_structured_envelope;
          test_case "visible reply uses typed reply field only" `Quick
            test_extract_visible_reply_uses_typed_reply_field_only;
          test_case "runtime run_blocks appends multimodal input to OAS agent" `Quick
            test_runtime_run_blocks_appends_multimodal_input_to_oas_agent;
          test_case "runtime multimodal gate lists required modalities" `Quick
            test_runtime_multimodal_gate_lists_required_modalities;
          test_case "runtime multimodal gate includes initial messages" `Quick
            test_runtime_multimodal_gate_includes_initial_messages;
          test_case "runtime multimodal gate model caps fail closed" `Quick
            test_runtime_multimodal_gate_model_caps_fail_closed;
          test_case "runtime multimodal gate rejects unsupported image" `Quick
            test_runtime_multimodal_gate_rejects_unsupported_image;
          test_case "runtime multimodal gate allows supported image" `Quick
            test_runtime_multimodal_gate_allows_supported_image;
          test_case "runtime multimodal gate requires multimodal for document" `Quick
            test_runtime_multimodal_gate_requires_multimodal_for_document;
          test_case "surface context formats into instructions" `Quick
            test_surface_context_to_instructions_formats_copilot_context;
          test_case "surface context ignores empty fields" `Quick
            test_surface_context_to_instructions_ignores_empty;
          test_case "surface context mcp path renders list fields" `Quick
            test_surface_context_mcp_path_renders_list_fields;
          test_case "copilot request labels gate surface" `Quick
            test_chat_surface_of_request_labels_copilot_gate;
          test_case "copilot request speaker is owner" `Quick
            test_chat_speaker_of_request_copilot_is_owner;
          test_case "connector request speaker is external" `Quick
            test_chat_speaker_of_request_connector_is_external;
          test_case "stream request rejects legacy model args" `Quick
            test_parse_keeper_chat_stream_request_rejects_legacy_model_args;
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
          test_case "whitespace only becomes unknown" `Quick
            test_filesystem_safe_whitespace_only;
          test_case "spaces replaced with underscore" `Quick
            test_filesystem_safe_with_spaces;
          test_case "dots replaced with underscore" `Quick
            test_filesystem_safe_with_dots;
          test_case "newline and tab replaced" `Quick
            test_filesystem_safe_newline_and_tab;
          test_case "underscore only becomes unknown" `Quick
            test_filesystem_safe_underscore_only;
          test_case "mixed safe and unsafe chars" `Quick
            test_filesystem_safe_mixed_safe_unsafe;
        ] );
      ( "agent_name_security",
        [
          test_case "blocks path traversal" `Quick
            test_agent_name_blocks_path_traversal;
          test_case "normal values unchanged" `Quick
            test_agent_name_normal_values_unchanged;
          test_case "special chars sanitized" `Quick
            test_agent_name_special_chars_sanitized;
        ] );
      ( "response_parsing",
        [
          test_case "reply field extracted" `Quick test_extract_reply_from_reply_field;
          test_case "text field is not reply" `Quick
            test_extract_reply_does_not_fallback_to_text_field;
          test_case "raw body on non-json" `Quick test_extract_reply_raw_on_non_json;
          test_case "turn stats present" `Quick test_extract_turn_stats_present;
          test_case "turn stats ignore model-only payload" `Quick
            test_extract_turn_stats_ignores_model_only_payload;
          test_case "turn stats missing returns None" `Quick
            test_extract_turn_stats_missing_returns_none;
        ] );
      ( "ack_envelope_parse",
        [
          test_case "accepts well-formed envelope" `Quick
            test_extract_message_request_ack_accepts_well_formed_envelope;
          test_case "rejects missing request_id" `Quick
            test_extract_message_request_ack_rejects_missing_request_id;
          test_case "rejects empty request_id" `Quick
            test_extract_message_request_ack_rejects_empty_request_id;
          test_case "rejects missing status" `Quick
            test_extract_message_request_ack_rejects_missing_status;
          test_case "rejects unknown status" `Quick
            test_extract_message_request_ack_rejects_unknown_status;
          test_case "rejects invalid json" `Quick
            test_extract_message_request_ack_rejects_invalid_json;
          test_case "normalizes status case" `Quick
            test_extract_message_request_ack_normalizes_status_case;
          test_case "falls back to keeper_name" `Quick
            test_extract_message_request_ack_falls_back_to_keeper_name;
        ] );
    ]
