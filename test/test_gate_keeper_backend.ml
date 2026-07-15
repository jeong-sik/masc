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

let json_string_field key = function
  | Some (`Assoc fields) ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> value
     | _ -> "")
  | Some _ | None -> ""

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let with_env key value f =
  let previous = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some previous -> Unix.putenv key previous
      | None -> Unix.putenv key "")
    (fun () ->
      Unix.putenv key value;
      f ())

let translate_oas_stream ?base_dir events =
  let redact_text text = text in
  (* RFC-0301: [translate] persists model-generated media under [base_dir]; the
     unique temp dir keeps generated media from leaking across test runs. *)
  let cleanup, base_dir =
    match base_dir with
    | Some base_dir -> (Fun.id, base_dir)
    | None ->
        let base_dir = temp_base_path "gate-keeper-stream-bridge" in
        ((fun () -> try remove_tree base_dir with _ -> ()), base_dir)
  in
  Fun.protect ~finally:cleanup (fun () ->
    let rec loop bridge_state acc = function
      | [] -> List.rev acc, bridge_state
      | event :: rest ->
          let translated =
            Keeper_chat_oas_stream_bridge.translate ~redact_text ~base_dir
              bridge_state event
          in
          loop translated.bridge_state
            (List.rev_append translated.chat_events acc) rest
    in
    loop Keeper_chat_oas_stream_bridge.empty_state [] events)

let translate_oas_stream_events ?base_dir events =
  fst (translate_oas_stream ?base_dir events)

let has_stream_protocol_error events =
  List.exists
    (function
      | Keeper_chat_events.Oas_stream_protocol_error _ -> true
      | _ -> false)
    events

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
      let surface =
        Surface_ref.Discord
          {
            guild_id = Some "guild-1";
            channel_id = "chan-9";
            parent_channel_id = None;
            thread_id = None;
          }
      in
      K.append_user_message ~base_dir ~keeper_name
        ~content:"<@bot> factorio?"
        ~surface
        ~conversation_id:"discord:guild-1:channel:chan-9" ();
      Gate_keeper_backend.persist_connector_assistant_reply ~base_dir
        ~keeper_name ~source:"discord" ~surface
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
          check bool "assistant keeps typed surface" true
            (match assistant.K.surface with
             | Some actual -> Surface_ref.equal surface actual
             | None -> false);
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

let test_parse_keeper_run_ref_body_is_exact_and_typed () =
  let valid =
    {|{"run_ref":{"run_id":"typed-run-1","target":{"kind":"keeper","name":"luna"},"capability":"invoke_turn"}}|}
  in
  let reference =
    match Server_routes_http_keeper_stream.parse_keeper_run_ref_body valid with
    | Ok reference -> reference
    | Error error ->
      fail
        (Keeper_invocation_contract.request_error_to_string error)
  in
  check string "typed run id" "typed-run-1"
    (Keeper_invocation_contract.run_id reference);
  check string "typed target" "luna"
    (Keeper_invocation_contract.run_ref_target_name reference);
  let rejects_removed_shape label body =
    match Server_routes_http_keeper_stream.parse_keeper_run_ref_body body with
    | Error (Keeper_invocation_contract.Invalid_wire_value _) -> ()
    | Error error ->
      failf "%s: unexpected error: %s" label
        (Keeper_invocation_contract.request_error_to_string error)
    | Ok _ -> failf "%s: removed raw request shape decoded" label
  in
  rejects_removed_shape "raw request id" {|{"request_id":"typed-run-1"}|};
  rejects_removed_shape
    "extra operation field"
    {|{"run_ref":{"run_id":"typed-run-1","target":{"kind":"keeper","name":"luna"},"capability":"invoke_turn"},"status":"running"}|};
  rejects_removed_shape "malformed json" {|{"run_ref":|}
;;

let test_keeper_run_terminal_payload_is_typed () =
  let reference =
    match
      Keeper_invocation_contract.run_ref_of_json
        (`Assoc
           [ "run_id", `String "typed-run-1"
           ; "target", `Assoc [ "kind", `String "keeper"; "name", `String "luna" ]
           ; "capability", `String "invoke_turn"
           ])
    with
    | Ok reference -> reference
    | Error error -> fail (Keeper_invocation_contract.request_error_to_string error)
  in
  match
    Server_routes_http_keeper_stream.For_testing.keeper_run_terminal_payload
      reference
      ~result_contract:Keeper_invocation_contract.Yielded
      ()
  with
  | `Assoc fields ->
    check bool "typed run ref emitted" true (List.mem_assoc "run_ref" fields);
    check (option string) "typed result emitted" (Some "yielded")
      (Option.bind
         (List.assoc_opt "result_contract" fields)
         Yojson.Safe.Util.to_string_option);
    List.iter
      (fun field -> check bool ("removed " ^ field) false (List.mem_assoc field fields))
      [ "request_id"; "keeper_name"; "status"; "ok" ]
  | _ -> fail "typed terminal payload must be an object"
;;

let test_parse_keeper_chat_stream_request_rejects_removed_timeout () =
  let body = {|{"name":"luna","message":"hello","timeout_sec":1200.5}|} in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok _ -> fail "expected the retired request timeout to be rejected"
  | Error err ->
    check string
      "removed field is named explicitly"
      "removed keeper message args for masc_keeper_msg: timeout_sec \
       (request-level whole-turn deadline is retired; use explicit operator \
       cancellation, provider progress deadlines, or tool-local deadlines)."
      err
;;

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
      check bool "source type" true (source_type = Agent_sdk.Types.Base64);
      check string "text" "describe this" text
  | Ok _ -> fail "expected image then text OAS blocks"
  | Error err -> fail ("expected OAS block conversion: " ^ err)

let document_input ~mime_type ~payload =
  let attachment_id = "att-doc" in
  let name = "notes.md" in
  let attachments =
    [
      {
        K.id = attachment_id;
        att_type = "file";
        name;
        size = String.length payload;
        mime_type;
        data = Printf.sprintf "data:%s;base64,%s" mime_type payload;
      };
    ]
  in
  let media =
    {
      Keeper_multimodal_input.attachment_id;
      name;
      mime_type;
      size = Some (String.length payload);
    }
  in
  attachments, media

let test_keeper_multimodal_input_projects_text_documents_as_text () =
  let cases =
    [ "text/plain", "plain body"
    ; "text/markdown", "# heading"
    ; "text/html", "<h1>heading</h1>"
    ; "application/json", {|{"ok":true}|}
    ; "text/csv", "name,value\nalpha,1"
    ]
  in
  List.iter
    (fun (mime_type, body) ->
       let attachments, media =
         document_input ~mime_type ~payload:(Base64.encode_string body)
       in
       match
         Keeper_multimodal_input.to_oas_blocks ~attachments
           [ Keeper_multimodal_input.User_document media ]
       with
       | Ok [ Agent_sdk.Types.Text projected ] ->
           let metadata =
             Yojson.Safe.to_string
               (`Assoc
                 [ "kind", `String "user_attachment"
                 ; "name", `String "notes.md"
                 ; "media_type", `String mime_type
                 ])
           in
           check string (mime_type ^ " exact projection")
             (Printf.sprintf
                "User-provided attachment metadata: %s\n\n%s"
                metadata
                body)
             projected
       | Ok _ -> fail (mime_type ^ " should project as one text block")
       | Error err -> fail (mime_type ^ " projection failed: " ^ err))
    cases

let test_keeper_multimodal_input_preserves_binary_document () =
  let payload = Base64.encode_string "%PDF-1.7" in
  let attachments, media = document_input ~mime_type:"application/pdf" ~payload in
  match
    Keeper_multimodal_input.to_oas_blocks ~attachments
      [ Keeper_multimodal_input.User_document media ]
  with
  | Ok [ Agent_sdk.Types.Document { media_type; data; source_type } ] ->
      check string "media type" "application/pdf" media_type;
      check string "base64 payload" payload data;
      check bool "source type" true (source_type = Agent_sdk.Types.Base64)
  | Ok _ -> fail "PDF should remain one OAS document block"
  | Error err -> fail ("PDF document projection failed: " ^ err)

let test_keeper_multimodal_input_rejects_invalid_text_document_payload () =
  let attachments, media =
    document_input ~mime_type:"text/markdown" ~payload:"%%%"
  in
  (match
     Keeper_multimodal_input.to_oas_blocks ~attachments
       [ Keeper_multimodal_input.User_document media ]
   with
   | Ok _ -> fail "invalid textual document base64 should be rejected"
   | Error err ->
       check bool "base64 error is explicit" true
         (string_contains err "invalid base64 payload"));
  let invalid_utf8 = String.make 1 (Char.chr 0xff) |> Base64.encode_string in
  let attachments, media =
    document_input ~mime_type:"text/html" ~payload:invalid_utf8
  in
  match
    Keeper_multimodal_input.to_oas_blocks ~attachments
      [ Keeper_multimodal_input.User_document media ]
  with
  | Ok _ -> fail "invalid UTF-8 textual document should be rejected"
  | Error err ->
      check bool "UTF-8 error is explicit" true
        (string_contains err "not valid UTF-8 text");
      let unsupported_control = Base64.encode_string "before\x00after" in
      let attachments, media =
        document_input ~mime_type:"text/plain" ~payload:unsupported_control
      in
      match
        Keeper_multimodal_input.to_oas_blocks ~attachments
          [ Keeper_multimodal_input.User_document media ]
      with
      | Ok _ -> fail "text control characters should not be silently repaired"
      | Error control_err ->
          check bool "control character error is explicit" true
            (string_contains control_err "unsupported control characters")

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
      check bool "source type" true (source_type = Agent_sdk.Types.Base64)
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
      check bool "source type" true (source_type = Agent_sdk.Types.Base64)
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
        ContentBlockDelta { index = 1; delta = InputJsonSnapshot "{\"limit\":1}" };
        ContentBlockStop { index = 1 };
        ContentBlockDelta { index = 2; delta = ThinkingDelta "think B" };
      ]
  in
  match events with
  | [ Keeper_chat_events.Oas_thinking_delta { index = first_index; delta = first };
      Keeper_chat_events.Oas_content_block_start
        { index = tool_index;
          content_type;
          tool_call_id = Some block_tool_id;
          tool_call_name = Some block_tool_name };
      Keeper_chat_events.Tool_call_start { tool_call_id; tool_call_name };
      Keeper_chat_events.Tool_call_args { tool_call_id = args_id_a; delta = args_a };
      Keeper_chat_events.Tool_call_args_snapshot
        { tool_call_id = snapshot_id; snapshot };
      Keeper_chat_events.Oas_content_block_stop { index = stop_index };
      Keeper_chat_events.Tool_call_end { tool_call_id = end_id };
      Keeper_chat_events.Oas_thinking_delta { index = last_index; delta = last } ] ->
      check int "first thinking index" 0 first_index;
      check string "first thinking" "think A" first;
      check int "tool block index" 1 tool_index;
      check string "content type" "tool_use" content_type;
      check string "block tool id" "tc-1" block_tool_id;
      check string "block tool name" "keeper_board_list" block_tool_name;
      check string "tool id" "tc-1" tool_call_id;
      check string "tool name" "keeper_board_list" tool_call_name;
      check string "args id a" "tc-1" args_id_a;
      check string "snapshot id" "tc-1" snapshot_id;
      check string "args a" "{\"limit\":" args_a;
      check string "snapshot" "{\"limit\":1}" snapshot;
      check int "tool stop index" 1 stop_index;
      check string "end id" "tc-1" end_id;
      check int "last thinking index" 2 last_index;
      check string "last thinking" "think B" last
  | _ ->
      failf "unexpected stream bridge events: %s"
        (String.concat ", "
           (List.map
              (function
                | Keeper_chat_events.Custom { name; _ } -> "custom:" ^ name
                | Keeper_chat_events.Oas_content_block_start _ ->
                    "oas_block_start"
                | Keeper_chat_events.Oas_content_block_stop _ ->
                    "oas_block_stop"
                | Keeper_chat_events.Oas_thinking_delta _ -> "oas_thinking"
                | Keeper_chat_events.Tool_call_start _ -> "tool_start"
                | Keeper_chat_events.Tool_call_args _ -> "tool_args"
                | Keeper_chat_events.Tool_call_args_snapshot _ ->
                    "tool_args_snapshot"
                | Keeper_chat_events.Tool_call_end _ -> "tool_end"
                | Keeper_chat_events.Text_delta _ -> "text"
                | Keeper_chat_events.Event_error _ -> "error"
                | _ -> "other")
              events))

let test_keeper_stream_bridge_projects_reasoning_details_delta () =
  let open Agent_sdk.Types in
  let detail : reasoning_detail =
    { raw = `Assoc [ "text", `String "detail thinking" ]
    ; text = Some "detail thinking"
    }
  in
  let events =
    translate_oas_stream_events
      [ ContentBlockDelta
          { index = 0
          ; delta =
              ReasoningDetailsDelta
                { reasoning_content = None; details = [ detail ] }
          }
      ]
  in
  match events with
  | [ Keeper_chat_events.Oas_thinking_delta { index; delta } ] ->
      check int "reasoning details index" 0 index;
      check string "reasoning details thinking" "detail thinking" delta
  | _ ->
      failf "unexpected reasoning details events: %s"
        (String.concat ", "
           (List.map
              (function
                | Keeper_chat_events.Oas_thinking_delta _ -> "oas_thinking"
                | Keeper_chat_events.Text_delta _ -> "text"
                | Keeper_chat_events.Event_error _ -> "error"
                | _ -> "other")
              events))

let test_keeper_stream_bridge_preserves_tool_args_snapshot () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [
        ContentBlockDelta { index = 0; delta = ThinkingDelta "think A" };
        ContentBlockStart
          { index = 1;
            content_type = "tool_use";
            tool_id = Some "tc-snapshot";
            tool_name = Some "keeper_board_list" };
        ContentBlockDelta
          { index = 1; delta = InputJsonSnapshot "{\"limit\":1}" };
        ContentBlockDelta
          { index = 1; delta = InputJsonSnapshot "{\"limit\":2}" };
        ContentBlockStop { index = 1 };
        ContentBlockDelta { index = 2; delta = ThinkingDelta "think B" };
      ]
  in
  match events with
  | [ Keeper_chat_events.Oas_thinking_delta { index = first_index; delta = first };
      Keeper_chat_events.Oas_content_block_start
        { index = tool_index;
          content_type;
          tool_call_id = Some block_tool_id;
          tool_call_name = Some block_tool_name };
      Keeper_chat_events.Tool_call_start { tool_call_id; tool_call_name };
      Keeper_chat_events.Tool_call_args_snapshot
        { tool_call_id = snapshot_id_a; snapshot = snapshot_a };
      Keeper_chat_events.Tool_call_args_snapshot
        { tool_call_id = snapshot_id_b; snapshot = snapshot_b };
      Keeper_chat_events.Oas_content_block_stop { index = stop_index };
      Keeper_chat_events.Tool_call_end { tool_call_id = end_id };
      Keeper_chat_events.Oas_thinking_delta { index = last_index; delta = last } ] ->
      check int "first thinking index" 0 first_index;
      check string "first thinking" "think A" first;
      check int "tool block index" 1 tool_index;
      check string "content type" "tool_use" content_type;
      check string "block tool id" "tc-snapshot" block_tool_id;
      check string "block tool name" "keeper_board_list" block_tool_name;
      check string "tool id" "tc-snapshot" tool_call_id;
      check string "tool name" "keeper_board_list" tool_call_name;
      check string "snapshot id a" "tc-snapshot" snapshot_id_a;
      check string "snapshot id b" "tc-snapshot" snapshot_id_b;
      check string "snapshot a" "{\"limit\":1}" snapshot_a;
      check string "snapshot b" "{\"limit\":2}" snapshot_b;
      check int "tool stop index" 1 stop_index;
      check string "end id" "tc-snapshot" end_id;
      check int "last thinking index" 2 last_index;
      check string "last thinking" "think B" last
  | _ ->
      failf "unexpected stream bridge snapshot events: %s"
        (String.concat ", "
           (List.map
              (function
                | Keeper_chat_events.Custom { name; _ } -> "custom:" ^ name
                | Keeper_chat_events.Oas_content_block_start _ ->
                    "oas_block_start"
                | Keeper_chat_events.Oas_content_block_stop _ ->
                    "oas_block_stop"
                | Keeper_chat_events.Oas_thinking_delta _ -> "oas_thinking"
                | Keeper_chat_events.Tool_call_start _ -> "tool_start"
                | Keeper_chat_events.Tool_call_args _ -> "tool_args"
                | Keeper_chat_events.Tool_call_args_snapshot _ ->
                    "tool_args_snapshot"
                | Keeper_chat_events.Tool_call_end _ -> "tool_end"
                | Keeper_chat_events.Text_delta _ -> "text"
                | Keeper_chat_events.Event_error _ -> "error"
                | _ -> "other")
              events))

let provider_kind_label (call : Agent_sdk.Canonical_tool.provider_tool_call) =
  Option.map Llm_provider.Provider_config.string_of_provider_kind
    call.provider_kind

let check_visible_reasoning label expected_order expected_signature
    (block : Agent_sdk.Canonical_tool.provider_reasoning_block) =
  check int (label ^ " order") expected_order block.order_index;
  check (option string) (label ^ " signature") expected_signature
    block.signature;
  match block.kind with
  | Agent_sdk.Canonical_tool.Visible_thinking -> ()
  | Agent_sdk.Canonical_tool.Redacted_thinking ->
      fail (label ^ " expected visible thinking")

let check_redacted_reasoning label expected_order
    (block : Agent_sdk.Canonical_tool.provider_reasoning_block) =
  check int (label ^ " order") expected_order block.order_index;
  check (option string) (label ^ " signature") None block.signature;
  match block.kind with
  | Agent_sdk.Canonical_tool.Redacted_thinking -> ()
  | Agent_sdk.Canonical_tool.Visible_thinking ->
      fail (label ^ " expected redacted thinking")

let oas_interleaving_event_label = function
  | Keeper_chat_events.Oas_thinking_delta { delta; _ } ->
      Some ("thinking:" ^ delta)
  | Keeper_chat_events.Oas_content_block_start { tool_call_name = Some name; _ } ->
      Some ("block_start:" ^ name)
  | Keeper_chat_events.Oas_content_block_stop { index } ->
      Some ("block_stop:" ^ string_of_int index)
  | Keeper_chat_events.Tool_call_start { tool_call_name; _ } ->
      Some ("tool_start:" ^ tool_call_name)
  | Keeper_chat_events.Tool_call_args_snapshot { tool_call_id; _ } ->
      Some ("tool_snapshot:" ^ tool_call_id)
  | Keeper_chat_events.Tool_call_end { tool_call_id } ->
      Some ("tool_end:" ^ tool_call_id)
  | _ -> None

let trajectory_interleaving_label = function
  | Trajectory.Thinking entry -> "thinking:" ^ entry.Trajectory.content
  | Trajectory.Tool_call entry -> "tool:" ^ entry.Trajectory.tool_name

let receipt_detail_of_provider_call
    (call : Agent_sdk.Canonical_tool.provider_tool_call)
  : Keeper_agent_result.tool_call_detail =
  let provider =
    match provider_kind_label call with
    | Some provider -> provider
    | None -> "unknown"
  in
  { tool_name = call.name
  ; provider
  ; outcome = "ok"
  ; execution_outcome = Tool_result.Ok
  ; typed_outcome = Some Keeper_tool_outcome.Progress
  ; latency_ms = 1.0
  ; task_id = None
  ; route_evidence = None
  ; input_fingerprint = None
  ; output_fingerprint = None
  }

let trajectory_entry_of_provider_call ~ts ~turn ~round
    (call : Agent_sdk.Canonical_tool.provider_tool_call)
  : Trajectory.tool_call_entry =
  { ts
  ; ts_iso = Types_core.iso8601_of_unix_seconds ts
  ; turn
  ; round
  ; tool_name = call.name
  ; args_json = Yojson.Safe.to_string call.input
  ; gate_decision = Trajectory.Pass
  ; result = Some {|{"ok":true}|}
  ; duration_ms = 1
  ; error = None
  ; cost_usd = Trajectory.tool_cost_estimate call.name
  ; execution_id = Some ("exec-" ^ call.call_id)
  }

let test_oas_tool_call_projection_preserves_adjacent_reasoning_groups () =
  let open Agent_sdk.Types in
  let response : api_response =
    {
      id = "resp-interleaving";
      model = "runtime_lane";
      stop_reason = StopToolUse;
      content =
        [
          Thinking { content = "think 1.1"; signature = None };
          RedactedThinking "sealed 1.2";
          ToolUse
            {
              id = "tc-1";
              name = "keeper_board_list";
              input = `Assoc [ ("query", `String "alpha") ];
            };
          Text "visible answer breaks adjacency";
          Thinking { content = "orphan thinking"; signature = None };
          Text "intervening text";
          ToolUse
            {
              id = "tc-2";
              name = "keeper_board_read";
              input = `Assoc [ ("id", `String "post-2") ];
            };
          Thinking { content = "think 2.1"; signature = Some "sig-2.1" };
          ToolUse
            {
              id = "tc-3";
              name = "keeper_task_update";
              input = `Assoc [ ("id", `String "task-3") ];
            };
        ];
      usage = None;
      telemetry =
        Some
          {
            default_inference_telemetry with
            provider_kind = Some Llm_provider.Provider_config.OpenAI_compat;
          };
    }
  in
  let calls = Agent_sdk.Canonical_tool.tool_calls_of_response response in
  match calls with
  | [ first; second; third ] ->
      check string "first call id" "tc-1" first.call_id;
      check string "first name" "keeper_board_list" first.name;
      check string "first input" {|{"query":"alpha"}|}
        (Yojson.Safe.to_string first.input);
      check int "first order" 0 first.order_index;
      check (option string) "first provider" (Some "openai_compat")
        (provider_kind_label first);
      (match first.adjacent_reasoning with
      | Agent_sdk.Canonical_tool.Adjacent_reasoning [ r0; r1 ] ->
          check_visible_reasoning "first reasoning 0" 0 None r0;
          check_redacted_reasoning "first reasoning 1" 1 r1
      | _ -> fail "first tool call should carry contiguous adjacent reasoning");
      check string "second call id" "tc-2" second.call_id;
      check int "second order" 1 second.order_index;
      (match second.adjacent_reasoning with
      | Agent_sdk.Canonical_tool.No_adjacent_reasoning -> ()
      | Agent_sdk.Canonical_tool.Adjacent_reasoning _ ->
          fail "intervening text must break reasoning adjacency");
      check string "third call id" "tc-3" third.call_id;
      check int "third order" 2 third.order_index;
      (match third.adjacent_reasoning with
      | Agent_sdk.Canonical_tool.Adjacent_reasoning [ r0 ] ->
          check_visible_reasoning "third reasoning" 7 (Some "sig-2.1") r0
      | _ -> fail "third tool call should carry only its adjacent thinking")
  | _ ->
      failf "expected three projected tool calls, got %d" (List.length calls)

let test_oas_interleaving_matches_masc_receipt_and_progress_facts () =
  let open Agent_sdk.Types in
  let thinking_before_read =
    Thinking { content = "inspect board first"; signature = Some "sig-read" }
  in
  let read_tool =
    ToolUse
      { id = "tc-read"
      ; name = "keeper_board_list"
      ; input = `Assoc [ "limit", `Int 1 ]
      }
  in
  let thinking_before_done =
    Thinking { content = "complete after evidence"; signature = Some "sig-done" }
  in
  let done_tool =
    ToolUse
      { id = "tc-done"
      ; name = "keeper_task_done"
      ; input =
          `Assoc
            [ "task_id", `String "task-1"
            ; "result", `String "evidence captured"
            ]
      }
  in
  let response : api_response =
    { id = "resp-oas-masc-interleaving"
    ; model = "runtime_lane"
    ; stop_reason = StopToolUse
    ; content = [ thinking_before_read; read_tool; thinking_before_done; done_tool ]
    ; usage = None
    ; telemetry =
        Some
          { default_inference_telemetry with
            provider_kind = Some Llm_provider.Provider_config.OpenAI_compat
          }
    }
  in
  let stream_events =
    translate_oas_stream_events
      [ ContentBlockDelta { index = 0; delta = ThinkingDelta "inspect board first" }
      ; ContentBlockStart
          { index = 1
          ; content_type = "tool_use"
          ; tool_id = Some "tc-read"
          ; tool_name = Some "keeper_board_list"
          }
      ; ContentBlockDelta
          { index = 1; delta = InputJsonSnapshot {|{"limit":1}|} }
      ; ContentBlockStop { index = 1 }
      ; ContentBlockDelta
          { index = 2; delta = ThinkingDelta "complete after evidence" }
      ; ContentBlockStart
          { index = 3
          ; content_type = "tool_use"
          ; tool_id = Some "tc-done"
          ; tool_name = Some "keeper_task_done"
          }
      ; ContentBlockDelta
          { index = 3
          ; delta =
              InputJsonSnapshot
                {|{"task_id":"task-1","result":"evidence captured"}|}
          }
      ; ContentBlockStop { index = 3 }
      ]
  in
  check (list string) "stream bridge keeps Thinking -> ToolUse order"
    [ "thinking:inspect board first"
    ; "block_start:keeper_board_list"
    ; "tool_start:keeper_board_list"
    ; "tool_snapshot:tc-read"
    ; "block_stop:1"
    ; "tool_end:tc-read"
    ; "thinking:complete after evidence"
    ; "block_start:keeper_task_done"
    ; "tool_start:keeper_task_done"
    ; "tool_snapshot:tc-done"
    ; "block_stop:3"
    ; "tool_end:tc-done"
    ]
    (List.filter_map oas_interleaving_event_label stream_events);
  let calls = Agent_sdk.Canonical_tool.tool_calls_of_response response in
  match calls with
  | [ first; second ] ->
      check string "first canonical call" "keeper_board_list" first.name;
      check int "first canonical order" 0 first.order_index;
      (match first.adjacent_reasoning with
       | Agent_sdk.Canonical_tool.Adjacent_reasoning [ r ] ->
           check_visible_reasoning "first adjacent thinking" 0
             (Some "sig-read") r
       | _ -> fail "first call should carry preceding thinking");
      check string "second canonical call" "keeper_task_done" second.name;
      check int "second canonical order" 1 second.order_index;
      (match second.adjacent_reasoning with
       | Agent_sdk.Canonical_tool.Adjacent_reasoning [ r ] ->
           check_visible_reasoning "second adjacent thinking" 2
             (Some "sig-done") r
       | _ -> fail "second call should carry preceding thinking");
      let receipt_details = List.map receipt_detail_of_provider_call calls in
      check (list string) "MASC receipt detail order matches OAS canonical order"
        [ "keeper_board_list"; "keeper_task_done" ]
        (Keeper_agent_result.tool_names_of_calls receipt_details);
      check (list string) "typed receipt outcome survives JSON projection"
        [ "Progress"; "Progress" ]
        (List.map
           (fun detail ->
              let open Yojson.Safe.Util in
              Keeper_agent_result.tool_call_detail_to_json detail
              |> member "typed_outcome"
              |> member "kind"
              |> to_string)
           receipt_details);
      let base_dir = temp_base_path "gate-keeper-oas-masc-interleaving" in
      Fun.protect
        ~finally:(fun () -> try remove_tree base_dir with _ -> ())
        (fun () ->
           let keeper_name = "interleave-keeper" in
           let trace_id = "trace-oas-masc-interleaving" in
           let turn = 7 in
           let acc =
             Trajectory.create_accumulator ~masc_root:base_dir ~keeper_name
               ~trace_id ~generation:0 ()
           in
           Keeper_agent_run_thinking_trajectory.persist_response_content
             ~keeper_name ~trajectory_acc:(Some acc) ~turn
             [ thinking_before_read ];
           Trajectory.record_entry acc
             (trajectory_entry_of_provider_call ~ts:1.1 ~turn ~round:1 first);
           Trajectory.flush_pending acc;
           Keeper_agent_run_thinking_trajectory.persist_response_content
             ~keeper_name ~trajectory_acc:(Some acc) ~turn
             [ thinking_before_done ];
           Trajectory.record_entry acc
             (trajectory_entry_of_provider_call ~ts:1.3 ~turn ~round:2 second);
           Trajectory.flush_pending acc;
           check (list string) "MASC trajectory JSONL keeps interleaved facts"
             [ "thinking:inspect board first"
             ; "tool:keeper_board_list"
             ; "thinking:complete after evidence"
             ; "tool:keeper_task_done"
             ]
             (Trajectory.read_all_lines ~masc_root:base_dir ~keeper_name
                ~trace_id
              |> List.map trajectory_interleaving_label))
  | _ -> failf "expected two projected tool calls, got %d" (List.length calls)

let test_keeper_stream_bridge_ignores_replayed_tool_start () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [
        ContentBlockStart
          { index = 2;
            content_type = "tool_use";
            tool_id = Some "tc-repeat";
            tool_name = Some "keeper_memory_search" };
        ContentBlockStart
          { index = 2;
            content_type = "tool_use";
            tool_id = Some "tc-repeat";
            tool_name = Some "keeper_memory_search" };
        ContentBlockDelta { index = 2; delta = InputJsonDelta "{\"q\":\"loop\"}" };
        ContentBlockStop { index = 2 };
      ]
  in
  check bool "no protocol error for replayed start" false
    (has_stream_protocol_error events);
  match events with
  | [ Keeper_chat_events.Oas_content_block_start
        { index = first_index; tool_call_id = Some first_block_id; _ };
      Keeper_chat_events.Tool_call_start { tool_call_id; tool_call_name };
      Keeper_chat_events.Oas_content_block_start
        { index = replay_index; tool_call_id = Some replay_block_id; _ };
      Keeper_chat_events.Tool_call_args { tool_call_id = args_id; delta };
      Keeper_chat_events.Oas_content_block_stop { index = stop_index };
      Keeper_chat_events.Tool_call_end { tool_call_id = end_id } ] ->
      check int "first block index" 2 first_index;
      check string "first block tool id" "tc-repeat" first_block_id;
      check string "tool id" "tc-repeat" tool_call_id;
      check string "tool name" "keeper_memory_search" tool_call_name;
      check int "replay block index" 2 replay_index;
      check string "replay block tool id" "tc-repeat" replay_block_id;
      check string "args id" "tc-repeat" args_id;
      check string "args" "{\"q\":\"loop\"}" delta;
      check int "stop index" 2 stop_index;
      check string "end id" "tc-repeat" end_id
  | _ ->
      fail
        "expected replayed block start, one tool start, one args delta, and one end"

let test_keeper_stream_bridge_rejects_replayed_tool_name_drift () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [
        ContentBlockStart
          { index = 2;
            content_type = "tool_use";
            tool_id = Some "tc-repeat";
            tool_name = Some "keeper_memory_search" };
        ContentBlockStart
          { index = 2;
            content_type = "tool_use";
            tool_id = Some "tc-repeat";
            tool_name = Some "keeper_board_list" };
      ]
  in
  match events with
  | [ Keeper_chat_events.Oas_content_block_start
        { tool_call_id = Some first_block_id;
          tool_call_name = Some first_block_name;
          _ };
      Keeper_chat_events.Tool_call_start
        { tool_call_id = first_start_id; tool_call_name = first_start_name };
      Keeper_chat_events.Oas_content_block_start
        { tool_call_id = Some replay_block_id;
          tool_call_name = Some replay_block_name;
          _ };
      Keeper_chat_events.Oas_stream_protocol_error
        { kind;
          index = Some index;
          tool_call_id = Some error_tool_id;
          reason = Some reason;
          _ } ] ->
      check string "first block id" "tc-repeat" first_block_id;
      check string "first block name" "keeper_memory_search" first_block_name;
      check string "first start id" "tc-repeat" first_start_id;
      check string "first start name" "keeper_memory_search" first_start_name;
      check string "replay block id" "tc-repeat" replay_block_id;
      check string "replay block name" "keeper_board_list" replay_block_name;
      check string "kind" "tool_start_duplicate_index"
        (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
      check int "index" 2 index;
      check string "error tool id" "tc-repeat" error_tool_id;
      check bool "reason names original tool" true
        (string_contains reason "existing tool tc-repeat/keeper_memory_search");
      check bool "reason names incoming tool" true
        (string_contains reason "incoming tool tc-repeat/keeper_board_list")
  | _ ->
      fail
        "expected same-id different-name tool start replay to fail closed"

let test_keeper_stream_bridge_rejects_conflicting_tool_index_reuse () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [
        ContentBlockStart
          { index = 2;
            content_type = "tool_use";
            tool_id = Some "tc-first";
            tool_name = Some "keeper_memory_search" };
        ContentBlockDelta { index = 2; delta = InputJsonDelta "{\"q\":\"first\"}" };
        ContentBlockStart
          { index = 2;
            content_type = "tool_use";
            tool_id = Some "tc-second";
            tool_name = Some "keeper_memory_search" };
        ContentBlockDelta { index = 2; delta = InputJsonDelta "{\"q\":\"second\"}" };
        ContentBlockStop { index = 2 };
      ]
  in
  check bool "protocol error for conflicting reused index" true
    (has_stream_protocol_error events);
  match events with
  | [ Keeper_chat_events.Oas_content_block_start
        { index = first_block_index; tool_call_id = Some first_block_id; _ };
      Keeper_chat_events.Tool_call_start { tool_call_id = first_start; _ };
      Keeper_chat_events.Tool_call_args { tool_call_id = first_args; delta = args_a };
      Keeper_chat_events.Oas_content_block_start
        { index = second_block_index; tool_call_id = Some second_block_id; _ };
      Keeper_chat_events.Oas_stream_protocol_error
        { kind = duplicate_kind;
          index = Some duplicate_index;
          tool_call_id = Some duplicate_tool_id;
          reason = Some duplicate_reason;
          _ };
      Keeper_chat_events.Oas_stream_protocol_error
        { kind = args_kind;
          index = Some args_index;
          tool_call_id = Some args_tool_id;
          reason = Some args_reason;
          _ };
      Keeper_chat_events.Oas_content_block_stop { index = stop_index };
      Keeper_chat_events.Oas_stream_protocol_error
        { kind = stop_kind;
          index = Some stop_error_index;
          tool_call_id = Some stop_tool_id;
          reason = Some stop_reason;
          _ } ] ->
      check int "first block index" 2 first_block_index;
      check string "first block id" "tc-first" first_block_id;
      check string "first start" "tc-first" first_start;
      check string "first args id" "tc-first" first_args;
      check string "first args" "{\"q\":\"first\"}" args_a;
      check int "second block index" 2 second_block_index;
      check string "second block id" "tc-second" second_block_id;
      check string "duplicate kind" "tool_start_duplicate_index"
        (Keeper_chat_events.stream_protocol_error_kind_to_string
           duplicate_kind);
      check int "duplicate index" 2 duplicate_index;
      check string "duplicate tool id" "tc-first" duplicate_tool_id;
      check bool "duplicate reason names incoming tool" true
        (string_contains duplicate_reason "incoming tool tc-second");
      check string "args kind" "tool_args_without_start"
        (Keeper_chat_events.stream_protocol_error_kind_to_string args_kind);
      check int "args index" 2 args_index;
      check string "args error tool id" "tc-first" args_tool_id;
      check string "args reason"
        "tool argument event arrived after invalid tool block start" args_reason;
      check int "stop index" 2 stop_index;
      check string "stop kind" "tool_stop_without_start"
        (Keeper_chat_events.stream_protocol_error_kind_to_string stop_kind);
      check int "stop error index" 2 stop_error_index;
      check string "stop error tool id" "tc-first" stop_tool_id;
      check string "stop reason"
        "content block stop arrived for invalid tool block" stop_reason
  | _ ->
      fail
        "expected conflicting reused-index tool start to fail closed without forged tool events"

let test_keeper_stream_bridge_isolates_tool_blocks_across_messages () =
  let open Agent_sdk.Types in
  (* A keeper dispatch is a multi-turn tool loop: each OAS call is a SEPARATE
     provider message whose block indices restart at 0, and the OpenAI-compat
     path carries no wire content_block_stop. The MessageStop ending message 1
     must clear the per-message block table so message 2's tool start at the SAME
     reused index opens a fresh Active_tool instead of colliding with message 1's
     still-open block — otherwise the args delta surfaces a spurious
     tool_args_without_start. Live regression: deepseek-v4-flash via ollama_cloud.
     Contrast with the within-message reuse test above, which MUST still fail
     closed (no MessageStop separates the two starts there). *)
  let events =
    translate_oas_stream_events
      [
        ContentBlockStart
          { index = 2;
            content_type = "tool_use";
            tool_id = Some "call_first";
            tool_name = Some "keeper_tasks_audit" };
        ContentBlockDelta { index = 2; delta = InputJsonDelta "{\"a\":1}" };
        MessageStop;
        ContentBlockStart
          { index = 2;
            content_type = "tool_use";
            tool_id = Some "call_second";
            tool_name = Some "keeper_tasks_audit" };
        ContentBlockDelta { index = 2; delta = InputJsonDelta "{\"b\":2}" };
      ]
  in
  check bool "no protocol error across message boundary" false
    (has_stream_protocol_error events);
  let tool_starts =
    List.filter_map
      (function
        | Keeper_chat_events.Tool_call_start { tool_call_id; _ } -> Some tool_call_id
        | _ -> None)
      events
  in
  check (list string) "both messages start their tool cleanly"
    [ "call_first"; "call_second" ] tool_starts;
  let tool_ends =
    List.filter_map
      (function
        | Keeper_chat_events.Tool_call_end { tool_call_id } -> Some tool_call_id
        | _ -> None)
      events
  in
  check bool "message-1 tool closed at MessageStop" true
    (List.mem "call_first" tool_ends);
  let second_args =
    List.filter_map
      (function
        | Keeper_chat_events.Tool_call_args { tool_call_id = "call_second"; delta } ->
            Some delta
        | _ -> None)
      events
  in
  check (list string) "message-2 args routed to its own fresh block"
    [ "{\"b\":2}" ] second_args

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
  | [ Keeper_chat_events.Oas_stream_message_start
        { provider_message_id; model; usage = Some start_usage };
      Keeper_chat_events.Oas_stream_message_delta
        { stop_reason = Some stop_reason; usage = Some delta_usage };
      Keeper_chat_events.Oas_stream_message_stop;
      Keeper_chat_events.Oas_stream_ping ] ->
      check string "provider message id" "msg-oas-1" provider_message_id;
      check string "model" "gpt-5.5" model;
      check int "start input tokens" 10 start_usage.input_tokens;
      check int "start total tokens" 11
        (Agent_sdk.Types.total_tokens start_usage);
      check int "cache creation tokens" 3
        start_usage.cache_creation_input_tokens;
      check string "stop reason" "end_turn"
        (Agent_sdk.Types.stop_reason_to_string stop_reason);
      check int "delta output tokens" 2 delta_usage.output_tokens;
      check int "delta total tokens" 12
        (Agent_sdk.Types.total_tokens delta_usage)
  | _ -> fail "expected OAS message lifecycle metadata events"

let test_keeper_stream_bridge_terminal_text_state_is_message_scoped () =
  let open Agent_sdk.Types in
  let message_start id =
    MessageStart { id; model = "provider-model"; usage = None }
  in
  let _, no_final_text =
    translate_oas_stream
      [ message_start "intermediate"
      ; ContentBlockDelta { index = 0; delta = TextDelta "working" }
      ; MessageStop
      ; message_start "terminal"
      ; MessageStop
      ]
  in
  check bool "intermediate narration is not terminal text" false
    (Keeper_chat_oas_stream_bridge.terminal_message_had_text no_final_text);
  let _, open_final_text =
    translate_oas_stream
      [ message_start "terminal-open"
      ; ContentBlockDelta { index = 0; delta = TextDelta "approved" }
      ]
  in
  check bool "open terminal message text is observable" true
    (Keeper_chat_oas_stream_bridge.terminal_message_had_text open_final_text);
  let _, open_final_without_text =
    translate_oas_stream
      [ message_start "intermediate"
      ; ContentBlockDelta { index = 0; delta = TextDelta "working" }
      ; MessageStop
      ; message_start "terminal-open-empty"
      ]
  in
  check bool "new open message resets prior text state" false
    (Keeper_chat_oas_stream_bridge.terminal_message_had_text
       open_final_without_text);
  let _, final_text =
    translate_oas_stream
      [ message_start "intermediate"
      ; ContentBlockDelta { index = 0; delta = TextDelta "working" }
      ; MessageStop
      ; message_start "terminal"
      ; ContentBlockDelta { index = 0; delta = TextDelta "approved" }
      ; MessageStop
      ]
  in
  check bool "terminal message text suppresses terminal resend" true
    (Keeper_chat_oas_stream_bridge.terminal_message_had_text final_text)

let test_keeper_stream_bridge_preserves_typed_media_source () =
  let open Agent_sdk.Types in
  let raw_media = "raw image bytes" in
  let encoded_media = Base64.encode_string raw_media in
  (* RFC-0301: media chunks are accumulated and surfaced as a single
     [Oas_media_delta] carrying the persisted media URL at the block stop, not a
     per-chunk byte count. A lone [MediaDelta] therefore emits nothing until its
     [ContentBlockStop] closes the block. *)
  let events =
    translate_oas_stream_events
      [
        ContentBlockDelta
          {
            index = 0;
            delta =
              MediaDelta
                {
                  media_type = "image/png";
                  source_type = Base64;
                  data = encoded_media;
                };
          };
        ContentBlockStop { index = 0 };
      ]
  in
  let expected_ref =
    "/api/v1/media/"
    ^ Digestif.SHA256.(digest_string ("image/png\000" ^ raw_media) |> to_hex)
  in
  match events with
  | [
      Keeper_chat_events.Oas_content_block_stop { index = stop_index };
      Keeper_chat_events.Oas_media_delta
        { index; media_type; source_type; media_ref };
    ] ->
      check int "block stop index" 0 stop_index;
      check int "block index" 0 index;
      check string "media type" "image/png" media_type;
      check bool "source type" true (source_type = Base64);
      check string "media ref is the persisted URL" expected_ref media_ref
  | _ -> fail "expected typed OAS media delta carrying the persisted URL"

let test_keeper_stream_bridge_rejects_media_delta_for_tool_block () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [
        ContentBlockStart
          { index = 2;
            content_type = "tool_use";
            tool_id = Some "tc-media-conflict";
            tool_name = Some "keeper_memory_search" };
        ContentBlockDelta
          {
            index = 2;
            delta =
              MediaDelta
                {
                  media_type = "image/png";
                  source_type = Base64;
                  data = Base64.encode_string "image";
                };
          };
        ContentBlockDelta { index = 2; delta = InputJsonDelta "{\"q\":\"ok\"}" };
        ContentBlockStop { index = 2 };
      ]
  in
  match events with
  | [ Keeper_chat_events.Oas_content_block_start _;
      Keeper_chat_events.Tool_call_start _;
      Keeper_chat_events.Oas_stream_protocol_error
        { kind; index = Some index; tool_call_id = Some tool_call_id; reason = Some reason; _ };
      Keeper_chat_events.Tool_call_args { tool_call_id = args_id; delta };
      Keeper_chat_events.Oas_content_block_stop { index = stop_index };
      Keeper_chat_events.Tool_call_end { tool_call_id = end_id } ] ->
      check string "media conflict kind" "media_delta_invalid_block"
        (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
      check int "media conflict index" 2 index;
      check string "media conflict tool id" "tc-media-conflict" tool_call_id;
      check string "media conflict reason"
        "media delta arrived for an active tool block" reason;
      check string "tool args preserved" "tc-media-conflict" args_id;
      check string "tool args payload" "{\"q\":\"ok\"}" delta;
      check int "tool stop preserved" 2 stop_index;
      check string "tool end preserved" "tc-media-conflict" end_id
  | _ -> fail "expected media delta to error without clobbering the tool block"

let test_keeper_stream_bridge_surfaces_bad_media_base64 () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [
        ContentBlockDelta
          {
            index = 0;
            delta =
              MediaDelta
                { media_type = "image/png"; source_type = Base64; data = "not base64!" };
          };
        ContentBlockStop { index = 0 };
      ]
  in
  match events with
  | [ Keeper_chat_events.Oas_content_block_stop { index = stop_index };
      Keeper_chat_events.Oas_stream_protocol_error
        { kind; index = Some error_index; raw_bytes = Some raw_bytes; reason = Some reason; _ } ] ->
      check int "block stop index" 0 stop_index;
      check string "bad base64 kind" "media_decode_failed"
        (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
      check int "bad base64 index" 0 error_index;
      check int "bad base64 bytes" (String.length "not base64!") raw_bytes;
      check bool "bad base64 reason" true
        (string_contains reason "invalid base64 media payload")
  | _ -> fail "expected bad media base64 to surface as a protocol error"

let test_keeper_stream_bridge_rejects_oversize_media_payload () =
  with_env "MASC_KEEPER_GENERATED_MEDIA_MAX_BYTES" "4" (fun () ->
    let open Agent_sdk.Types in
    let oversized = String.make (Keeper_chat_media_store.max_wire_bytes () + 1) 'A' in
    let events =
      translate_oas_stream_events
        [
          ContentBlockDelta
            {
              index = 0;
              delta =
                MediaDelta
                  {
                    media_type = "image/png";
                    source_type = Base64;
                    data = oversized;
                  };
            };
          ContentBlockStop { index = 0 };
        ]
    in
    match events with
    | [ Keeper_chat_events.Oas_stream_protocol_error
          { kind; index = Some error_index; raw_bytes = Some raw_bytes; reason = Some reason; _ };
        Keeper_chat_events.Oas_content_block_stop { index = stop_index } ] ->
        check string "oversize media kind" "media_payload_too_large"
          (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
        check int "oversize media index" 0 error_index;
        check int "oversize media bytes" (String.length oversized) raw_bytes;
        check bool "oversize media reason" true
          (string_contains reason "generated media payload too large");
        check int "block stop index" 0 stop_index
    | _ -> fail "expected oversize media payload to fail before accumulation")

let test_keeper_stream_bridge_suppresses_media_after_oversize () =
  with_env "MASC_KEEPER_GENERATED_MEDIA_MAX_BYTES" "4" (fun () ->
    let open Agent_sdk.Types in
    let oversized = String.make (Keeper_chat_media_store.max_wire_bytes () + 1) 'A' in
    let events =
      translate_oas_stream_events
        [
          ContentBlockDelta
            {
              index = 0;
              delta =
                MediaDelta
                  {
                    media_type = "image/png";
                    source_type = Base64;
                    data = oversized;
                  };
            };
          ContentBlockDelta
            {
              index = 0;
              delta =
                MediaDelta
                  {
                    media_type = "image/png";
                    source_type = Base64;
                    data = "QQ==";
                  };
            };
          ContentBlockStop { index = 0 };
        ]
    in
    let has_media_ref =
      List.exists
        (function
          | Keeper_chat_events.Oas_media_delta _ -> true
          | _ -> false)
        events
    in
    check bool "oversize block suppresses later media ref" false has_media_ref;
    match events with
    | [ Keeper_chat_events.Oas_stream_protocol_error
          { kind; index = Some error_index; raw_bytes = Some raw_bytes; reason = Some reason; _ };
        Keeper_chat_events.Oas_content_block_stop { index = stop_index } ] ->
        check string "oversize media kind" "media_payload_too_large"
          (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
        check int "oversize media index" 0 error_index;
        check int "oversize media bytes" (String.length oversized) raw_bytes;
        check bool "oversize media reason" true
          (string_contains reason "generated media payload too large");
        check int "block stop index" 0 stop_index
    | _ -> fail "expected oversize media block to remain suppressed until stop")

let test_keeper_stream_bridge_rejects_unsupported_media_source () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [
        ContentBlockDelta
          {
            index = 0;
            delta =
              MediaDelta
                {
                  media_type = "image/png";
                  source_type = Url;
                  data = "https://example.invalid/image.png";
                };
          };
        ContentBlockStop { index = 0 };
      ]
  in
  match events with
  | [ Keeper_chat_events.Oas_content_block_stop { index = stop_index };
      Keeper_chat_events.Oas_stream_protocol_error
        { kind; index = Some error_index; reason = Some reason; _ } ] ->
      check int "block stop index" 0 stop_index;
      check string "unsupported media source kind" "media_source_unsupported"
        (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
      check int "unsupported media source index" 0 error_index;
      check bool "unsupported media source reason" true
        (string_contains reason "unsupported media source_type: url")
  | _ -> fail "expected unsupported media source to surface as a protocol error"

let test_keeper_stream_bridge_masks_media_write_failure_reason () =
  let open Agent_sdk.Types in
  let base_file = temp_base_path "gate-keeper-stream-bridge-base-file" in
  let oc = open_out_bin base_file in
  close_out_noerr oc;
  Fun.protect
    ~finally:(fun () -> try remove_tree base_file with _ -> ())
    (fun () ->
      let events =
        translate_oas_stream_events ~base_dir:base_file
          [ ContentBlockDelta
              { index = 0;
                delta =
                  MediaDelta
                    { media_type = "image/png";
                      source_type = Base64;
                      data = Base64.encode_string "image" } };
            ContentBlockStop { index = 0 } ]
      in
      match events with
      | [ Keeper_chat_events.Oas_content_block_stop { index = stop_index };
          Keeper_chat_events.Oas_stream_protocol_error
            { kind; index = Some error_index; reason = Some reason; _ } ] ->
          check int "block stop index" 0 stop_index;
          check string "write failure kind" "media_persist_failed"
            (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
          check int "write failure index" 0 error_index;
          check string "write failure reason is generic"
            "failed to persist generated media" reason;
          check bool "internal base path not leaked" false
            (string_contains reason base_file)
      | _ -> fail "expected media write failure to surface with a masked reason")

let test_keeper_stream_bridge_preserves_non_tool_block_lifecycle () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [
        ContentBlockStart
          { index = 4;
            content_type = "text";
            tool_id = None;
            tool_name = None };
        ContentBlockStop { index = 4 };
      ]
  in
  check bool "no protocol error for non-tool block stop" false
    (has_stream_protocol_error events);
  match events with
  | [ Keeper_chat_events.Oas_content_block_start
        { index = start_index; content_type; tool_call_id; tool_call_name };
      Keeper_chat_events.Oas_content_block_stop { index = stop_index } ] ->
      check int "start index" 4 start_index;
      check string "content type" "text" content_type;
      check (option string) "tool id" None tool_call_id;
      check (option string) "tool name" None tool_call_name;
      check int "stop index" 4 stop_index
  | _ -> fail "expected non-tool OAS block start and stop events"

let test_keeper_stream_bridge_rejects_tool_start_missing_identity () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [
        ContentBlockStart
          { index = 5;
            content_type = "tool_use";
            tool_id = None;
            tool_name = None };
      ]
  in
  match events with
  | [
      Keeper_chat_events.Oas_content_block_start
        { index = block_index; content_type; tool_call_id; tool_call_name };
      Keeper_chat_events.Oas_stream_protocol_error
        { kind; index = Some error_index; reason = Some reason; _ };
    ] ->
      check int "block index" 5 block_index;
      check string "content type" "tool_use" content_type;
      check (option string) "tool id" None tool_call_id;
      check (option string) "tool name" None tool_call_name;
      check string "kind" "tool_start_missing_identity"
        (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
      check int "error index" 5 error_index;
      check string "reason" "tool-use block start missed tool id or name" reason
  | _ -> fail "expected tool-use start without identity to fail closed"

let test_keeper_stream_bridge_rejects_non_tool_start_with_tool_identity () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [
        ContentBlockStart
          { index = 6;
            content_type = "text";
            tool_id = Some "tc-not-tool";
            tool_name = Some "keeper_memory_search" };
      ]
  in
  let has_tool_start =
    List.exists
      (function
        | Keeper_chat_events.Tool_call_start _ -> true
        | _ -> false)
      events
  in
  check bool "non-tool block is not promoted to tool call" false has_tool_start;
  match events with
  | [
      Keeper_chat_events.Oas_content_block_start
        { index = block_index; content_type; tool_call_id; tool_call_name };
      Keeper_chat_events.Oas_stream_protocol_error
        { kind; index = Some error_index; reason = Some reason; _ };
    ] ->
      check int "block index" 6 block_index;
      check string "content type" "text" content_type;
      check (option string) "tool id" (Some "tc-not-tool") tool_call_id;
      check (option string) "tool name" (Some "keeper_memory_search")
        tool_call_name;
      check string "kind" "tool_start_missing_identity"
        (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
      check int "error index" 6 error_index;
      check string "reason" "non-tool content block carried tool id or name"
        reason
  | _ -> fail "expected non-tool start with tool identity to fail closed"

let test_keeper_stream_bridge_rejects_tool_args_without_start () =
  let open Agent_sdk.Types in
  let events =
    translate_oas_stream_events
      [ ContentBlockDelta { index = 7; delta = InputJsonSnapshot "{\"x\":1}" } ]
  in
  match events with
  | [ Keeper_chat_events.Oas_stream_protocol_error
        { kind; index = Some index; event_type = _; reason = _; raw_bytes = _ }
    ] ->
      check string "kind" "tool_args_without_start"
        (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
      check int "index" 7 index;
      check bool "no tool event forged" true
        (not
           (List.exists
              (function
                | Keeper_chat_events.Tool_call_args _ -> true
                | Keeper_chat_events.Tool_call_args_snapshot _ -> true
                | _ -> false)
              events))
  | _ -> fail "expected a stream protocol error for missing tool start"

let test_stream_protocol_error_summary_includes_diagnostics () =
  let summary =
    Keeper_chat_events.stream_protocol_error_summary
      {
        kind = Keeper_chat_events.Tool_args_without_start;
        index = Some 2;
        tool_call_id = Some "tc-1";
        event_type = Some "response.future";
        reason = Some "tool argument delta arrived before tool start";
        raw_bytes = Some 7;
      }
  in
  check bool "kind" true (string_contains summary "tool_args_without_start");
  check bool "index" true (string_contains summary "index=2");
  check bool "tool id" true (string_contains summary "tool_call_id=tc-1");
  check bool "event type" true
    (string_contains summary "event_type=response.future");
  check bool "reason" true
    (string_contains summary "tool argument delta arrived before tool start");
  check bool "raw bytes" true (string_contains summary "raw_bytes=7")

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
  | [ Keeper_chat_events.Oas_stream_protocol_error
        { kind = unknown_kind; event_type = Some event_type; _ };
      Keeper_chat_events.Oas_stream_protocol_error
        { kind = incomplete_kind; _ };
      Keeper_chat_events.Event_error { message } ] ->
      check string "unknown kind" "sse_unknown_event_type"
        (Keeper_chat_events.stream_protocol_error_kind_to_string unknown_kind);
      check string "unknown event type" "response.future" event_type;
      check string "incomplete kind" "sse_stream_incomplete"
        (Keeper_chat_events.stream_protocol_error_kind_to_string incomplete_kind);
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

let test_canonical_reply_payload_keeps_empty_typed_reply () =
  let turn_ref =
    Ids.Turn_ref.make ~trace_id:"canonical-empty" ~absolute_turn:1
    |> Ids.Turn_ref.to_string
  in
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("runtime_class", `String "keeper");
          ("turn_outcome", `String "visible_reply");
          ("turn_ref", `String turn_ref);
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
  match
    Server_routes_http_keeper_stream.For_testing.canonical_reply_payload_of_body
      ~redact_text:Fun.id body
  with
  | Error error ->
    fail
      (Server_routes_http_keeper_stream.canonical_reply_payload_error_to_string
         error)
  | Ok canonical ->
    check string "empty reply stays empty" "" canonical.visible_reply;
    check bool "typed visible outcome is preserved" true
      (Keeper_turn_outcome.equal canonical.turn_outcome
         Keeper_turn_outcome.Visible_reply)

let test_canonical_reply_payload_redacts_reply_and_preserves_evidence () =
  let turn_ref =
    Ids.Turn_ref.make ~trace_id:"canonical-visible" ~absolute_turn:9
  in
  let tool_evidence =
    `List
      [ `Assoc
          [ "name", `String "keeper_context_status"
          ; "status", `String "ok"
          ]
      ]
  in
  let body =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("runtime_class", `String "keeper");
          ("turn_outcome", `String "visible_reply");
          ("turn_ref", Ids.Turn_ref.to_yojson turn_ref);
          ("reply", `String "api_key=secret Done.");
          ("tool_call_evidence", tool_evidence);
          ("runtime_note", `String "must not be user-visible");
        ])
  in
  let redact_text = function
    | "api_key=secret Done." -> "api_key=[redacted] Done."
    | text -> text
  in
  match
    Server_routes_http_keeper_stream.For_testing.canonical_reply_payload_of_body
      ~redact_text body
  with
  | Error error ->
    fail
      (Server_routes_http_keeper_stream.canonical_reply_payload_error_to_string
         error)
  | Ok canonical ->
    check string "visible reply is redacted once" "api_key=[redacted] Done."
      canonical.visible_reply;
    check bool "turn_ref identity is preserved" true
      (Ids.Turn_ref.equal turn_ref canonical.turn_ref);
    check string "turn outcome label is unchanged" "visible_reply"
      (json_string_field Keeper_turn_outcome.wire_key
         (Some canonical.payload_json));
    check string "non-reply field is preserved" "must not be user-visible"
      (json_string_field "runtime_note" (Some canonical.payload_json));
    check bool "tool evidence is preserved semantically" true
      (match canonical.payload_json with
       | `Assoc fields ->
         Option.equal Yojson.Safe.equal
           (Some tool_evidence)
           (List.assoc_opt "tool_call_evidence" fields)
       | _ -> false);
    check bool "raw reply secret is absent from poll body" false
      (string_contains canonical.poll_body "api_key=secret")

let test_canonical_reply_payload_rejects_noncanonical_success_bodies () =
  let parse body =
    Server_routes_http_keeper_stream.For_testing.canonical_reply_payload_of_body
      ~redact_text:Fun.id body
  in
  let assert_error label accepts body =
    match parse body with
    | Error error when accepts error -> ()
    | Error error ->
      failf "%s: unexpected error %s" label
        (Server_routes_http_keeper_stream.canonical_reply_payload_error_to_string
           error)
    | Ok _ -> failf "%s: malformed success body was accepted" label
  in
  assert_error "invalid JSON"
    (function
      | Server_routes_http_keeper_stream.Malformed_reply_json _ -> true
      | _ -> false)
    "not-json";
  assert_error "non-object JSON"
    (function
      | Server_routes_http_keeper_stream.Reply_payload_not_object -> true
      | _ -> false)
    {|"raw text"|};
  assert_error "duplicate reply field"
    (function
      | Server_routes_http_keeper_stream.Duplicate_payload_field "reply" -> true
      | _ -> false)
    {|{"reply":"a","reply":"b","turn_outcome":"visible_reply","turn_ref":"trace#1"}|};
  assert_error "unknown outcome"
    (function
      | Server_routes_http_keeper_stream.Unknown_turn_outcome -> true
      | _ -> false)
    {|{"reply":"ok","turn_outcome":"guessed","turn_ref":"trace#1"}|};
  assert_error "invalid turn ref"
    (function
      | Server_routes_http_keeper_stream.Invalid_turn_ref -> true
      | _ -> false)
    {|{"reply":"ok","turn_outcome":"visible_reply","turn_ref":"invalid"}|}

let test_direct_reply_terminal_error_rejects_no_visible_reply () =
  let payload_json =
    `Assoc
      [
        ("runtime_class", `String "keeper");
        ("turn_outcome", `String "no_visible_reply");
        ("reply", `String "");
      ]
  in
  let err =
    Server_routes_http_keeper_stream.For_testing.direct_reply_terminal_error
      (Some payload_json) ""
  in
  check bool "thinking-only direct reply is terminal error" true
    (Option.is_some err)

let test_direct_reply_terminal_error_allows_checkpoint () =
  let payload_json =
    `Assoc
      [
        ("runtime_class", `String "keeper");
        ("turn_outcome", `String "continuation_checkpoint");
        ("reply", `String "");
      ]
  in
  let err =
    Server_routes_http_keeper_stream.For_testing.direct_reply_terminal_error
      (Some payload_json) ""
  in
  check bool "checkpoint can stay user-only" true (Option.is_none err)

let test_keeper_tool_failure_log_details_include_preview_and_class () =
  let error_body = String.make 260 'x' in
  let details =
    Server_routes_http_keeper_stream.For_testing.keeper_tool_failure_log_details
      ~tool_name:"masc_keeper_msg"
      ~agent_name:"agent-1"
      ~duration_ms:123
      ~streaming:true
      ~error_body
      ~failure_class:Tool_result.Policy_rejection
  in
  check string "event_family" "tool_call_failure"
    (json_string_field "event_family" (Some details));
  check string "failure_class" "policy_rejection"
    (json_string_field "failure_class" (Some details));
  check string "error_body_preview" (String.make 197 'x' ^ "...")
    (json_string_field "error_body_preview" (Some details));
  check string "tool_name" "masc_keeper_msg"
    (json_string_field "tool_name" (Some details));
  check string "agent_name" "agent-1"
    (json_string_field "agent_name" (Some details));
  match details with
  | `Assoc fields ->
      (match List.assoc_opt "streaming" fields with
      | Some (`Bool true) -> ()
      | _ -> fail "expected streaming=true");
      (match List.assoc_opt "error_body_truncated" fields with
       | Some (`Bool true) -> ()
       | _ -> fail "expected error_body_truncated=true");
      (match List.assoc_opt "error_body_bytes" fields with
       | Some (`Int 260) -> ()
       | _ -> fail "expected error_body_bytes=260");
      Alcotest.(check bool)
        "full error body omitted from log details"
        false
        (List.mem_assoc "error_body" fields)
  | _ -> fail "expected Assoc"

let canonical_empty_reply_for_outcome outcome =
  let body =
    `Assoc
      [
        ("runtime_class", `String "keeper");
        ("turn_outcome", `String outcome);
        ("turn_ref", `String "canonical-outcome#1");
        ("reply", `String "");
      ]
    |> Yojson.Safe.to_string
  in
  match
    Server_routes_http_keeper_stream.For_testing.canonical_reply_payload_of_body
      ~redact_text:Fun.id body
  with
  | Ok canonical -> canonical
  | Error error ->
    fail
      (Server_routes_http_keeper_stream.canonical_reply_payload_error_to_string
         error)

let test_redacted_reply_rewrite_preserves_typed_no_visible_outcome () =
  let canonical = canonical_empty_reply_for_outcome "no_visible_reply" in
  let rewritten = Some canonical.payload_json in
  check string "redacted reply remains empty" "" canonical.visible_reply;
  check string "typed no-visible outcome remains unchanged" "no_visible_reply"
    (json_string_field Keeper_turn_outcome.wire_key rewritten);
  let err =
    Server_routes_http_keeper_stream.For_testing.direct_reply_terminal_error
      rewritten canonical.visible_reply
  in
  check bool "stream projection cannot override no-visible terminal contract" true
    (Option.is_some err)

let test_redacted_reply_rewrite_preserves_checkpoint_payload () =
  let canonical = canonical_empty_reply_for_outcome "continuation_checkpoint" in
  let rewritten = Some canonical.payload_json in
  check string "checkpoint outcome is semantic" "continuation_checkpoint"
    (json_string_field Keeper_turn_outcome.wire_key rewritten);
  check string "checkpoint reply remains hidden" "" canonical.visible_reply

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
      session_id = Some "multimodal-runtime-proof-session";
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
       | Runtime_agent.Completed -> fail "invalid provider endpoint completed"
       | stop_reason ->
           failf "unexpected stop reason after exit-condition proof: %s"
             (Keeper_execution_receipt_types.stop_reason_to_string stop_reason))
   | Error err -> ignore (Agent_sdk.Error.to_string err));
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
              check bool "source type" true (source_type = Agent_sdk.Types.Base64)
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
  check string "copilot surface label" "copilot" (Surface_ref.lane_label surface);
  check bool "copilot surface keeps route address" true
    (Surface_ref.equal surface
       (Surface_ref.Gate
          {
            label = "copilot";
            address = [ ("connector", "copilot"); ("workspace_id", "session-7") ];
          }))

let test_chat_speaker_of_request_copilot_is_owner () =
  let payload =
    { Server_routes_http_keeper_stream.name = "luna";
      message = "hello";
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

let parse_keeper_ack body =
  Gate_keeper_backend.extract_message_request_ack ~channel:"discord"
    ~channel_user_id:"user-1" ~keeper_name:"luna" ~metadata:[] body

let test_typed_keeper_ack () =
  let body =
    {|{"run_ref":{"run_id":"run-1","target":{"kind":"keeper","name":"luna"},"capability":"invoke_turn"},"result_contract":"awaiting_execution"}|}
  in
  match parse_keeper_ack body with
  | Ok { tracking = Gate_protocol.Keeper_run { run_ref; result_contract }; _ } ->
    check string "run id" "run-1" (Keeper_invocation_contract.run_id run_ref);
    check bool "contract" true
      (result_contract = Keeper_invocation_contract.Awaiting_execution)
  | Ok _ | Error _ -> fail "expected typed Keeper-run ACK"

let test_keeper_ack_rejects_retargeting () =
  let body =
    {|{"run_ref":{"run_id":"run-1","target":{"kind":"keeper","name":"other"},"capability":"invoke_turn"},"result_contract":"awaiting_execution"}|}
  in
  match parse_keeper_ack body with
  | Error (Gate_keeper_backend.Run_ref_target_mismatch _) -> ()
  | Ok _ | Error _ -> fail "expected exact Keeper target rejection"

(* ── RFC-connector-deferred-reply-via-chat-queue connector deferred-reply routing ───────────────── *)

let test_route_busy_discord_enqueues () =
  match
    Gate_keeper_backend.route_busy_connector Gate_keeper_backend.Discord
      ~channel_id:"123456789" ~user_id:"u-42"
      ~user_name:"discord-user" ~team_id:None ~thread_ts:None
  with
  | `Enqueue_chat_queue (Keeper_chat_queue.Discord { channel_id; user_id }) ->
      check string "discord channel_id threaded" "123456789" channel_id;
      check string "discord user_id threaded" "u-42" user_id
  | `Enqueue_chat_queue _ ->
      fail "Discord must map to a Discord message_source, not another variant"
  | `Async_poll -> fail "Discord has an outbound adapter; must enqueue, not poll"


let test_route_busy_slack_enqueues () =
  match
    Gate_keeper_backend.route_busy_connector Gate_keeper_backend.Slack
      ~channel_id:"C0SLACK" ~user_id:"U-99"
      ~user_name:"slack-user" ~team_id:(Some "T0SLACK")
      ~thread_ts:(Some "171.001")
  with
  | `Enqueue_chat_queue
      (Keeper_chat_queue.Slack
         { channel_id; user_id; user_name; team_id; thread_ts }) ->
      check string "slack channel threaded" "C0SLACK" channel_id;
      check string "slack user_id threaded" "U-99" user_id;
      check string "slack user name threaded" "slack-user" user_name;
      check (option string) "slack team threaded" (Some "T0SLACK") team_id;
      check (option string) "slack reply thread threaded" (Some "171.001") thread_ts
  | `Enqueue_chat_queue _ ->
      fail "Slack must map to a Slack message_source, not another variant"
  | `Async_poll -> fail "Slack has an outbound adapter; must enqueue, not poll"

let test_route_busy_generic_falls_back () =
  match
    Gate_keeper_backend.route_busy_connector Gate_keeper_backend.Generic
      ~channel_id:"x" ~user_id:"y"
      ~user_name:"generic-user" ~team_id:None ~thread_ts:None
  with
  | `Async_poll -> check bool "generic falls back to async poll" true true
  | `Enqueue_chat_queue _ ->
      fail "Generic has no in-process outbound adapter; must not enqueue (RFC-connector-deferred-reply-via-chat-queue §3.3a)"

let () =
  Alcotest.run "Gate_keeper_backend"
    [
      ( "route_busy_connector",
        [
          test_case "Discord enqueues with channel_id/user_id" `Quick
            test_route_busy_discord_enqueues;
          test_case "Slack enqueues with channel/user_id" `Quick
            test_route_busy_slack_enqueues;
          test_case "Generic falls back to async poll" `Quick
            test_route_busy_generic_falls_back;
        ] );
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
          test_case "run operation body is exact and typed" `Quick
            test_parse_keeper_run_ref_body_is_exact_and_typed;
          test_case "run terminal payload is exact and typed" `Quick
            test_keeper_run_terminal_payload_is_typed;
          test_case "stream request rejects removed request timeout" `Quick
            test_parse_keeper_chat_stream_request_rejects_removed_timeout;
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
          test_case "multimodal input projects text documents as text" `Quick
            test_keeper_multimodal_input_projects_text_documents_as_text;
          test_case "multimodal input preserves binary documents" `Quick
            test_keeper_multimodal_input_preserves_binary_document;
          test_case "multimodal input rejects invalid text document payload" `Quick
            test_keeper_multimodal_input_rejects_invalid_text_document_payload;
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
          test_case "stream bridge projects reasoning details delta" `Quick
            test_keeper_stream_bridge_projects_reasoning_details_delta;
          test_case "stream bridge preserves tool args snapshots" `Quick
            test_keeper_stream_bridge_preserves_tool_args_snapshot;
          test_case "OAS tool-call projection preserves adjacent reasoning" `Quick
            test_oas_tool_call_projection_preserves_adjacent_reasoning_groups;
          test_case "OAS interleaving matches MASC receipt/progress facts" `Quick
            test_oas_interleaving_matches_masc_receipt_and_progress_facts;
          test_case "stream bridge ignores replayed tool starts" `Quick
            test_keeper_stream_bridge_ignores_replayed_tool_start;
          test_case "stream bridge rejects replayed tool name drift" `Quick
            test_keeper_stream_bridge_rejects_replayed_tool_name_drift;
          test_case "stream bridge rejects conflicting tool index reuse" `Quick
            test_keeper_stream_bridge_rejects_conflicting_tool_index_reuse;
          test_case "stream bridge isolates tool blocks across messages" `Quick
            test_keeper_stream_bridge_isolates_tool_blocks_across_messages;
          test_case "stream bridge surfaces OAS message metadata" `Quick
            test_keeper_stream_bridge_surfaces_oas_message_metadata;
          test_case "stream bridge scopes terminal text to final message" `Quick
            test_keeper_stream_bridge_terminal_text_state_is_message_scoped;
          test_case "stream bridge preserves typed media source" `Quick
            test_keeper_stream_bridge_preserves_typed_media_source;
          test_case "stream bridge rejects media delta for tool block" `Quick
            test_keeper_stream_bridge_rejects_media_delta_for_tool_block;
          test_case "stream bridge surfaces bad media base64" `Quick
            test_keeper_stream_bridge_surfaces_bad_media_base64;
          test_case "stream bridge rejects oversize media payload" `Quick
            test_keeper_stream_bridge_rejects_oversize_media_payload;
          test_case "stream bridge suppresses media after oversize" `Quick
            test_keeper_stream_bridge_suppresses_media_after_oversize;
          test_case "stream bridge rejects unsupported media source" `Quick
            test_keeper_stream_bridge_rejects_unsupported_media_source;
          test_case "stream bridge masks media write failure reason" `Quick
            test_keeper_stream_bridge_masks_media_write_failure_reason;
          test_case "stream bridge preserves non-tool block lifecycle" `Quick
            test_keeper_stream_bridge_preserves_non_tool_block_lifecycle;
          test_case "stream bridge rejects tool start missing identity" `Quick
            test_keeper_stream_bridge_rejects_tool_start_missing_identity;
          test_case "stream bridge rejects non-tool start with tool identity" `Quick
            test_keeper_stream_bridge_rejects_non_tool_start_with_tool_identity;
          test_case "stream bridge rejects tool args without start" `Quick
            test_keeper_stream_bridge_rejects_tool_args_without_start;
          test_case "stream protocol error summary includes diagnostics" `Quick
            test_stream_protocol_error_summary_includes_diagnostics;
          test_case "stream bridge surfaces unknown and incomplete events" `Quick
            test_keeper_stream_bridge_surfaces_unknown_and_incomplete_events;
          test_case "chat history persists attachment refs not raw media" `Quick
            test_keeper_chat_history_persists_attachment_refs_not_raw_media;
          test_case "user-only chat history persists attachment refs not raw media" `Quick
            test_keeper_chat_user_only_persists_attachment_refs_not_raw_media;
          test_case "canonical reply keeps empty typed reply" `Quick
            test_canonical_reply_payload_keeps_empty_typed_reply;
          test_case "canonical reply redacts text and preserves evidence" `Quick
            test_canonical_reply_payload_redacts_reply_and_preserves_evidence;
          test_case "canonical reply rejects malformed success bodies" `Quick
            test_canonical_reply_payload_rejects_noncanonical_success_bodies;
          test_case "tool failure log details include error body and failure_class"
            `Quick test_keeper_tool_failure_log_details_include_preview_and_class;
          test_case "direct reply rejects no visible reply" `Quick
            test_direct_reply_terminal_error_rejects_no_visible_reply;
          test_case "direct reply allows continuation checkpoint" `Quick
            test_direct_reply_terminal_error_allows_checkpoint;
          test_case "redacted reply rewrite preserves no-visible outcome" `Quick
            test_redacted_reply_rewrite_preserves_typed_no_visible_outcome;
          test_case "redacted reply rewrite preserves checkpoint payload" `Quick
            test_redacted_reply_rewrite_preserves_checkpoint_payload;
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
      ( "typed_ack",
        [ test_case "accepts exact run_ref" `Quick test_typed_keeper_ack
        ; test_case "rejects retargeting" `Quick test_keeper_ack_rejects_retargeting
        ] );
    ]
