open Alcotest
open Masc

module K = Keeper_chat_store
module KT = Keeper_turn

let stream_payload_exn
      ?(user_blocks = [])
      ?(attachments = [])
      ?turn_instructions
      ?surface_context
      ?(channel = "")
      ?(channel_user_id = "")
      ?(channel_user_name = "")
      ?(channel_workspace_id = "")
      ~name
      ~message
      ()
  =
  let direct_message =
    match
      Keeper_invocation_contract.direct_message
        ~keeper_name:name
        ~prompt:message
        ~direct_reply:true
        ?turn_instructions
        ?surface_context
        ~channel
        ~user_blocks
        ~attachments
        ()
    with
    | Ok message -> message
    | Error error ->
      fail (Keeper_invocation_contract.request_error_to_string error)
  in
  { Server_routes_http_keeper_stream.name = name
  ; request_id =
      (match Keeper_owner.Chat_operation.Operation_id.of_string "kmsg-gate-test" with
       | Ok operation_id -> operation_id
       | Error detail -> fail detail)
  ; message
  ; user_blocks
  ; turn_instructions
  ; surface_context
  ; channel
  ; channel_user_id
  ; channel_user_name
  ; channel_workspace_id
  ; attachments
  ; direct_message
  }

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

let translate_agent_core_stream ?base_dir events =
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
    let occurrence_tracker = Keeper_stream_tool_accum.create () in
    let rec loop bridge_state acc = function
      | [] -> List.rev acc, bridge_state
      | event :: rest ->
          Keeper_stream_tool_accum.on_event occurrence_tracker event;
          let stream_scope =
            Keeper_stream_tool_accum.current_stream_scope occurrence_tracker
          in
          let translated =
            Keeper_chat_agent_core_stream_bridge.translate ~redact_text ~base_dir
              ~stream_scope bridge_state event
          in
          loop translated.bridge_state
            (List.rev_append translated.chat_events acc) rest
    in
    loop (Keeper_chat_agent_core_stream_bridge.empty_state ()) [] events)

let translate_agent_core_stream_events ?base_dir events =
  fst (translate_agent_core_stream ?base_dir events)

let has_stream_protocol_error events =
  List.exists
    (function
      | Keeper_chat_events.Agent_core_stream_protocol_error _ -> true
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
    {|{"request_id":"kmsg-connector","name":"luna","message":"hello","channel":"discord","channel_user_id":"user-42","channel_user_name":"Alice","channel_workspace_id":"workspace-9"}|}
  in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok payload ->
      check string "channel" "discord" payload.channel;
      check string "user id" "user-42" payload.channel_user_id;
      check string "user name" "Alice" payload.channel_user_name;
      check string "workspace id" "workspace-9" payload.channel_workspace_id
  | Error err -> fail ("expected connector context to parse: " ^ err)

let test_parse_keeper_chat_stream_request_rejects_unknown_field () =
  let body = {|{"request_id":"kmsg-unknown","name":"luna","message":"hello","unexpected":true}|} in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok _ -> fail "expected an undeclared field to be rejected"
  | Error err ->
    check bool "unknown field is named" true (string_contains err "unexpected")
;;

let test_parse_keeper_chat_stream_request_requires_request_id () =
  let body = {|{"name":"luna","message":"hello"}|} in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok _ -> fail "expected request_id to be required"
  | Error err -> check string "missing id error" "request_id is required" err
;;

let test_parse_keeper_chat_stream_request_rejects_duplicate_field () =
  let body = {|{"request_id":"kmsg-duplicate","name":"luna","name":"other","message":"hello"}|} in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok _ -> fail "expected duplicate fields to be rejected"
  | Error err ->
    check string "duplicate field error"
      "request body must contain unique fields" err
;;

let test_parse_keeper_chat_stream_request_rejects_wrong_field_type () =
  let body = {|{"request_id":"kmsg-type","name":"luna","message":"hello","channel":42}|} in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok _ -> fail "expected wrong field type to be rejected"
  | Error err -> check string "wrong type error" "channel must be a string" err
;;

let test_parse_keeper_chat_stream_request_rejects_partial_connector_context () =
  let body =
    {|{"request_id":"kmsg-partial","name":"luna","message":"hello","channel":"discord"}|}
  in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok _ -> fail "expected partial connector context to be rejected"
  | Error err ->
      check string "validation message"
        "channel and channel_workspace_id are required when connector context is supplied"
        err

let test_parse_keeper_chat_stream_request_accepts_copilot_context () =
  let body =
    {|{"request_id":"kmsg-copilot","name":"luna","message":"hello","channel":"copilot","channel_workspace_id":"session-7","turn_instructions":"focus on overview"}|}
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
    {|{"request_id":"kmsg-surface","name":"luna","message":"hello","channel":"copilot","channel_workspace_id":"session-7","surface_context":{"label":"Overview","route":"/overview","scene":"fleet view","fields":[{"k":"run","v":"2/5"},{"k":"alert","v":"1"}]}}|}
  in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok payload ->
      check string "channel" "copilot" payload.channel;
      check (option string) "turn instructions" None payload.turn_instructions;
      check bool "surface context present" true (Option.is_some payload.surface_context)
  | Error err -> fail ("expected surface context to parse: " ^ err)

let test_parse_keeper_chat_stream_request_accepts_attachment_only_user_blocks () =
  let body =
    {|{"request_id":"kmsg-attachment","name":"luna","message":"","attachments":[{"id":"att-img","type":"image","name":"screen.png","size":1024,"mime_type":"image/png","data":"data:image/png;base64,abc123"}],"user_blocks":[{"type":"image","attachment_id":"att-img","name":"screen.png","mime_type":"image/png","size":1024}]}|}
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
    {|{"request_id":"kmsg-block","name":"luna","message":"hello","user_blocks":[{"type":"tool_result","text":"nope"}]}|}
  in
  match Server_routes_http_keeper_stream.parse_keeper_chat_stream_request body with
  | Ok _ -> fail "expected unknown user block type to be rejected"
  | Error err ->
      check string "validation message"
        {|unsupported user_blocks type "tool_result": expected text, image, document, or audio|}
        err

let test_parse_keeper_turn_interrupt_target_rejects_blank_name () =
  let parse =
    Server_routes_http_keeper_stream.For_testing
    .parse_keeper_turn_interrupt_target
  in
  check
    (result (pair string (option string)) string)
    "blank Keeper name is a request error"
    (Error "name must be non-blank")
    (parse {|{"name":"  ","request_id":"tui-request"}|});
  check
    (result (pair string (option string)) string)
    "valid target is trimmed"
    (Ok ("alpha", Some "tui-request"))
    (parse {|{"name":" alpha ","request_id":" tui-request "}|})

let test_keeper_multimodal_input_converts_user_blocks_to_agent_core_blocks () =
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
    Keeper_multimodal_input.to_agent_core_blocks ~attachments
      [
        Keeper_multimodal_input.User_image media;
        Keeper_multimodal_input.User_text "describe this";
      ]
  with
  | Ok
      [
        Agent_core.Types.Image { media_type; data; source_type };
        Agent_core.Types.Text text;
      ] ->
      check string "media type" "image/png" media_type;
      check string "data" "abc123" data;
      check bool "source type" true (source_type = Agent_core.Types.Base64);
      check string "text" "describe this" text
  | Ok _ -> fail "expected image then text AGENT_CORE blocks"
  | Error err -> fail ("expected AGENT_CORE block conversion: " ^ err)

(* RFC-0371 B1 regression: each media kind string must select its own
   constructor. The parser used to pick the constructor by re-matching a
   string behind an unreachable arm; a wildcard rewrite there could have
   silently mapped a new kind onto the wrong constructor, which is exactly
   what this pins. *)
let test_keeper_multimodal_parse_maps_each_kind_to_its_constructor () =
  let block kind =
    `Assoc
      [
        ("type", `String kind);
        ("attachment_id", `String ("att-" ^ kind));
        ("name", `String (kind ^ ".bin"));
        ("mime_type", `String ("application/" ^ kind));
      ]
  in
  let request =
    `Assoc [ ("user_blocks", `List [ block "image"; block "document"; block "audio" ]) ]
  in
  match Keeper_multimodal_input.parse_user_blocks request with
  | Ok
      [
        Keeper_multimodal_input.User_image image;
        Keeper_multimodal_input.User_document document;
        Keeper_multimodal_input.User_audio audio;
      ] ->
      check string "image attachment" "att-image" image.Keeper_multimodal_input.attachment_id;
      check string "document attachment" "att-document"
        document.Keeper_multimodal_input.attachment_id;
      check string "audio attachment" "att-audio" audio.Keeper_multimodal_input.attachment_id
  | Ok _ -> fail "expected image, document, audio constructors in order"
  | Error err -> fail ("expected media blocks to parse: " ^ err)

let test_keeper_multimodal_parse_rejects_unknown_kind () =
  let request =
    `Assoc
      [
        ("user_blocks", `List [ `Assoc [ ("type", `String "video") ] ]);
      ]
  in
  match Keeper_multimodal_input.parse_user_blocks request with
  | Ok _ -> fail "unknown media kind must not parse"
  | Error err ->
      check bool "error names the unsupported kind" true
        (String_util.contains_substring err "video")

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
         Keeper_multimodal_input.to_agent_core_blocks ~attachments
           [ Keeper_multimodal_input.User_document media ]
       with
       | Ok [ Agent_core.Types.Text projected ] ->
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
    Keeper_multimodal_input.to_agent_core_blocks ~attachments
      [ Keeper_multimodal_input.User_document media ]
  with
  | Ok [ Agent_core.Types.Document { media_type; data; source_type } ] ->
      check string "media type" "application/pdf" media_type;
      check string "base64 payload" payload data;
      check bool "source type" true (source_type = Agent_core.Types.Base64)
  | Ok _ -> fail "PDF should remain one AGENT_CORE document block"
  | Error err -> fail ("PDF document projection failed: " ^ err)

let test_keeper_multimodal_input_rejects_invalid_text_document_payload () =
  let attachments, media =
    document_input ~mime_type:"text/markdown" ~payload:"%%%"
  in
  (match
     Keeper_multimodal_input.to_agent_core_blocks ~attachments
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
    Keeper_multimodal_input.to_agent_core_blocks ~attachments
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
        Keeper_multimodal_input.to_agent_core_blocks ~attachments
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
    Keeper_multimodal_input.to_agent_core_blocks ~attachments
      [ Keeper_multimodal_input.User_image media ]
  with
  | Ok [ Agent_core.Types.Image { media_type; data; source_type } ] ->
      check string "media type" "image/png" media_type;
      check string "data" "abc123" data;
      check bool "source type" true (source_type = Agent_core.Types.Base64)
  | Ok _ -> fail "expected image AGENT_CORE block"
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
    Keeper_multimodal_input.to_agent_core_blocks ~attachments
      [ Keeper_multimodal_input.User_image media ]
  with
  | Ok [ Agent_core.Types.Image { media_type; data; source_type } ] ->
      check string "media type" "image/png" media_type;
      check string "data" "abc123" data;
      check bool "source type" true (source_type = Agent_core.Types.Base64)
  | Ok _ -> fail "expected image AGENT_CORE block"
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
    Keeper_multimodal_input.to_agent_core_blocks ~attachments
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
    Keeper_multimodal_input.to_agent_core_blocks ~attachments
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
  let user_blocks =
    [ Keeper_multimodal_input.User_text "describe this"
    ; Keeper_multimodal_input.User_image media
    ]
  in
  let attachments =
    [ { K.id = "att-img"
      ; att_type = "image"
      ; name = "screen.png"
      ; size = 1024
      ; mime_type = "image/png"
      ; data = "data:image/png;base64,abc123"
      }
    ]
  in
  let payload =
    stream_payload_exn ~name:"luna" ~message:"describe this" ~user_blocks
      ~attachments ()
  in
  let direct_message =
    Server_routes_http_keeper_stream.For_testing.direct_message_of_request payload
  in
  check int "user blocks" 2
    (List.length
       (Keeper_invocation_contract.direct_message_user_blocks direct_message));
  check int "attachments" 1
    (List.length
       (Keeper_invocation_contract.direct_message_attachments direct_message));
  check int "AGENT_CORE blocks validated at boundary" 2
    (Keeper_invocation_contract.direct_message_user_agent_core_blocks direct_message
     |> Option.map List.length
     |> Option.value ~default:0)

let test_keeper_stream_bridge_preserves_interleaved_thinking_and_tool () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
      [
        ContentBlockDelta { index = 0; delta = ThinkingDelta "think A" };
        ContentBlockStart
          { index = 1;
            content_type = "tool_use";
            tool_id = Some "tc-1";
            tool_name = Some "masc_board_list" };
        ContentBlockDelta { index = 1; delta = InputJsonDelta "{\"limit\":" };
        ContentBlockDelta { index = 1; delta = InputJsonSnapshot "{\"limit\":1}" };
        ContentBlockStop { index = 1 };
        ContentBlockDelta { index = 2; delta = ThinkingDelta "think B" };
      ]
  in
  match events with
  | [ Keeper_chat_events.Agent_core_thinking_delta { index = first_index; delta = first };
      Keeper_chat_events.Agent_core_content_block_start
        { index = tool_index;
          content_type;
          tool_call_id = Some block_tool_id;
          tool_call_name = Some block_tool_name };
      Keeper_chat_events.Tool_call_start { tool_call_id; tool_call_name; _ };
      Keeper_chat_events.Tool_call_args { tool_call_id = args_id_a; delta = args_a; _ };
      Keeper_chat_events.Tool_call_args_snapshot
        { tool_call_id = snapshot_id; snapshot; _ };
      Keeper_chat_events.Agent_core_content_block_stop { index = stop_index };
      Keeper_chat_events.Tool_call_end { tool_call_id = end_id; _ };
      Keeper_chat_events.Agent_core_thinking_delta { index = last_index; delta = last } ] ->
      check int "first thinking index" 0 first_index;
      check string "first thinking" "think A" first;
      check int "tool block index" 1 tool_index;
      check string "content type" "tool_use" content_type;
      check string "block tool id" "tc-1" block_tool_id;
      check string "block tool name" "masc_board_list" block_tool_name;
      check (option string) "tool id" (Some "tc-1") tool_call_id;
      check string "tool name" "masc_board_list" tool_call_name;
      check (option string) "args id a" (Some "tc-1") args_id_a;
      check (option string) "snapshot id" (Some "tc-1") snapshot_id;
      check string "args a" "{\"limit\":" args_a;
      check string "snapshot" "{\"limit\":1}" snapshot;
      check int "tool stop index" 1 stop_index;
      check (option string) "end id" (Some "tc-1") end_id;
      check int "last thinking index" 2 last_index;
      check string "last thinking" "think B" last
  | _ ->
      failf "unexpected stream bridge events: %s"
        (String.concat ", "
           (List.map
              (function
                | Keeper_chat_events.Agent_core_content_block_start _ ->
                    "agent_core_block_start"
                | Keeper_chat_events.Agent_core_content_block_stop _ ->
                    "agent_core_block_stop"
                | Keeper_chat_events.Agent_core_thinking_delta _ -> "agent_core_thinking"
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
  let open Agent_core.Types in
  let detail : reasoning_detail =
    { raw = `Assoc [ "text", `String "detail thinking" ]
    ; text = Some "detail thinking"
    }
  in
  let events =
    translate_agent_core_stream_events
      [ ContentBlockDelta
          { index = 0
          ; delta =
              ReasoningDetailsDelta
                { reasoning_content = None; details = [ detail ] }
          }
      ]
  in
  match events with
  | [ Keeper_chat_events.Agent_core_thinking_delta { index; delta } ] ->
      check int "reasoning details index" 0 index;
      check string "reasoning details thinking" "detail thinking" delta
  | _ ->
      failf "unexpected reasoning details events: %s"
        (String.concat ", "
           (List.map
              (function
                | Keeper_chat_events.Agent_core_thinking_delta _ -> "agent_core_thinking"
                | Keeper_chat_events.Text_delta _ -> "text"
                | Keeper_chat_events.Event_error _ -> "error"
                | _ -> "other")
              events))

let test_keeper_stream_bridge_preserves_tool_args_snapshot () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
      [
        ContentBlockDelta { index = 0; delta = ThinkingDelta "think A" };
        ContentBlockStart
          { index = 1;
            content_type = "tool_use";
            tool_id = Some "tc-snapshot";
            tool_name = Some "masc_board_list" };
        ContentBlockDelta
          { index = 1; delta = InputJsonSnapshot "{\"limit\":1}" };
        ContentBlockDelta
          { index = 1; delta = InputJsonSnapshot "{\"limit\":2}" };
        ContentBlockStop { index = 1 };
        ContentBlockDelta { index = 2; delta = ThinkingDelta "think B" };
      ]
  in
  match events with
  | [ Keeper_chat_events.Agent_core_thinking_delta { index = first_index; delta = first };
      Keeper_chat_events.Agent_core_content_block_start
        { index = tool_index;
          content_type;
          tool_call_id = Some block_tool_id;
          tool_call_name = Some block_tool_name };
      Keeper_chat_events.Tool_call_start { tool_call_id; tool_call_name; _ };
      Keeper_chat_events.Tool_call_args_snapshot
        { tool_call_id = snapshot_id_a; snapshot = snapshot_a; _ };
      Keeper_chat_events.Tool_call_args_snapshot
        { tool_call_id = snapshot_id_b; snapshot = snapshot_b; _ };
      Keeper_chat_events.Agent_core_content_block_stop { index = stop_index };
      Keeper_chat_events.Tool_call_end { tool_call_id = end_id; _ };
      Keeper_chat_events.Agent_core_thinking_delta { index = last_index; delta = last } ] ->
      check int "first thinking index" 0 first_index;
      check string "first thinking" "think A" first;
      check int "tool block index" 1 tool_index;
      check string "content type" "tool_use" content_type;
      check string "block tool id" "tc-snapshot" block_tool_id;
      check string "block tool name" "masc_board_list" block_tool_name;
      check (option string) "tool id" (Some "tc-snapshot") tool_call_id;
      check string "tool name" "masc_board_list" tool_call_name;
      check (option string) "snapshot id a" (Some "tc-snapshot") snapshot_id_a;
      check (option string) "snapshot id b" (Some "tc-snapshot") snapshot_id_b;
      check string "snapshot a" "{\"limit\":1}" snapshot_a;
      check string "snapshot b" "{\"limit\":2}" snapshot_b;
      check int "tool stop index" 1 stop_index;
      check (option string) "end id" (Some "tc-snapshot") end_id;
      check int "last thinking index" 2 last_index;
      check string "last thinking" "think B" last
  | _ ->
      failf "unexpected stream bridge snapshot events: %s"
        (String.concat ", "
           (List.map
              (function
                | Keeper_chat_events.Agent_core_content_block_start _ ->
                    "agent_core_block_start"
                | Keeper_chat_events.Agent_core_content_block_stop _ ->
                    "agent_core_block_stop"
                | Keeper_chat_events.Agent_core_thinking_delta _ -> "agent_core_thinking"
                | Keeper_chat_events.Tool_call_start _ -> "tool_start"
                | Keeper_chat_events.Tool_call_args _ -> "tool_args"
                | Keeper_chat_events.Tool_call_args_snapshot _ ->
                    "tool_args_snapshot"
                | Keeper_chat_events.Tool_call_end _ -> "tool_end"
                | Keeper_chat_events.Text_delta _ -> "text"
                | Keeper_chat_events.Event_error _ -> "error"
                | _ -> "other")
              events))

let provider_kind_label (call : Agent_core.Canonical_tool.provider_tool_call) =
  Option.map Llm_provider.Provider_config.string_of_provider_kind
    call.provider_kind

let check_visible_reasoning label expected_order expected_signature
    (block : Agent_core.Canonical_tool.provider_reasoning_block) =
  check int (label ^ " order") expected_order block.order_index;
  check (option string) (label ^ " signature") expected_signature
    block.signature;
  match block.kind with
  | Agent_core.Canonical_tool.Visible_thinking -> ()
  | Agent_core.Canonical_tool.Redacted_thinking ->
      fail (label ^ " expected visible thinking")

let check_redacted_reasoning label expected_order
    (block : Agent_core.Canonical_tool.provider_reasoning_block) =
  check int (label ^ " order") expected_order block.order_index;
  check (option string) (label ^ " signature") None block.signature;
  match block.kind with
  | Agent_core.Canonical_tool.Redacted_thinking -> ()
  | Agent_core.Canonical_tool.Visible_thinking ->
      fail (label ^ " expected redacted thinking")

let agent_core_interleaving_event_label = function
  | Keeper_chat_events.Agent_core_thinking_delta { delta; _ } ->
      Some ("thinking:" ^ delta)
  | Keeper_chat_events.Agent_core_content_block_start { tool_call_name = Some name; _ } ->
      Some ("block_start:" ^ name)
  | Keeper_chat_events.Agent_core_content_block_stop { index } ->
      Some ("block_stop:" ^ string_of_int index)
  | Keeper_chat_events.Tool_call_start { tool_call_name; _ } ->
      Some ("tool_start:" ^ tool_call_name)
  | Keeper_chat_events.Tool_call_args_snapshot { tool_call_id; _ } ->
      Some ("tool_snapshot:" ^ Option.value ~default:"<provider-id-absent>" tool_call_id)
  | Keeper_chat_events.Tool_call_end { tool_call_id; _ } ->
      Some ("tool_end:" ^ Option.value ~default:"<provider-id-absent>" tool_call_id)
  | _ -> None

let trajectory_interleaving_label = function
  | Trajectory.Withheld_thinking _ -> "thinking:[withheld]"
  | Trajectory.Tool_call entry -> "tool:" ^ entry.Trajectory.tool_name

let receipt_detail_of_provider_call
    (call : Agent_core.Canonical_tool.provider_tool_call)
  : Keeper_agent_result.tool_call_detail =
  let provider =
    match provider_kind_label call with
    | Some provider -> provider
    | None -> "unknown"
  in
  { tool_name = call.name
  ; provider
  ; execution_outcome = Tool_result.Ok
  ; typed_outcome = Some Keeper_tool_outcome.Progress
  ; latency_ms = 1.0
  ; task_id = None
  ; route_evidence = None
  ; input_fingerprint = None
  ; output_fingerprint = None
  }

let trajectory_entry_of_provider_call ~ts ~turn ~round
    (call : Agent_core.Canonical_tool.provider_tool_call)
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
  ; execution_id = Some ("exec-" ^ call.call_id)
  }

let test_agent_core_tool_call_projection_preserves_adjacent_reasoning_groups () =
  let open Agent_core.Types in
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
              name = "masc_board_list";
              input = `Assoc [ ("query", `String "alpha") ];
            };
          Text "visible answer breaks adjacency";
          Thinking { content = "orphan thinking"; signature = None };
          Text "intervening text";
          ToolUse
            {
              id = "tc-2";
              name = "masc_board_fake";
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
  let calls = Agent_core.Canonical_tool.tool_calls_of_response response in
  match calls with
  | [ first; second; third ] ->
      check string "first call id" "tc-1" first.call_id;
      check string "first name" "masc_board_list" first.name;
      check string "first input" {|{"query":"alpha"}|}
        (Yojson.Safe.to_string first.input);
      check int "first order" 0 first.order_index;
      check (option string) "first provider" (Some "openai_compat")
        (provider_kind_label first);
      (match first.adjacent_reasoning with
      | Agent_core.Canonical_tool.Adjacent_reasoning [ r0; r1 ] ->
          check_visible_reasoning "first reasoning 0" 0 None r0;
          check_redacted_reasoning "first reasoning 1" 1 r1
      | _ -> fail "first tool call should carry contiguous adjacent reasoning");
      check string "second call id" "tc-2" second.call_id;
      check int "second order" 1 second.order_index;
      (match second.adjacent_reasoning with
      | Agent_core.Canonical_tool.No_adjacent_reasoning -> ()
      | Agent_core.Canonical_tool.Adjacent_reasoning _ ->
          fail "intervening text must break reasoning adjacency");
      check string "third call id" "tc-3" third.call_id;
      check int "third order" 2 third.order_index;
      (match third.adjacent_reasoning with
      | Agent_core.Canonical_tool.Adjacent_reasoning [ r0 ] ->
          check_visible_reasoning "third reasoning" 7 (Some "sig-2.1") r0
      | _ -> fail "third tool call should carry only its adjacent thinking")
  | _ ->
      failf "expected three projected tool calls, got %d" (List.length calls)

let test_agent_core_interleaving_matches_masc_receipt_and_progress_facts () =
  let open Agent_core.Types in
  let thinking_before_read =
    Thinking { content = "inspect board first"; signature = Some "sig-read" }
  in
  let read_tool =
    ToolUse
      { id = "tc-read"
      ; name = "masc_board_list"
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
    { id = "resp-agent_core-masc-interleaving"
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
    translate_agent_core_stream_events
      [ ContentBlockDelta { index = 0; delta = ThinkingDelta "inspect board first" }
      ; ContentBlockStart
          { index = 1
          ; content_type = "tool_use"
          ; tool_id = Some "tc-read"
          ; tool_name = Some "masc_board_list"
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
    ; "block_start:masc_board_list"
    ; "tool_start:masc_board_list"
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
    (List.filter_map agent_core_interleaving_event_label stream_events);
  let calls = Agent_core.Canonical_tool.tool_calls_of_response response in
  match calls with
  | [ first; second ] ->
      check string "first canonical call" "masc_board_list" first.name;
      check int "first canonical order" 0 first.order_index;
      (match first.adjacent_reasoning with
       | Agent_core.Canonical_tool.Adjacent_reasoning [ r ] ->
           check_visible_reasoning "first adjacent thinking" 0
             (Some "sig-read") r
       | _ -> fail "first call should carry preceding thinking");
      check string "second canonical call" "keeper_task_done" second.name;
      check int "second canonical order" 1 second.order_index;
      (match second.adjacent_reasoning with
       | Agent_core.Canonical_tool.Adjacent_reasoning [ r ] ->
           check_visible_reasoning "second adjacent thinking" 2
             (Some "sig-done") r
       | _ -> fail "second call should carry preceding thinking");
      let receipt_details = List.map receipt_detail_of_provider_call calls in
      check (list string) "MASC receipt detail order matches AGENT_CORE canonical order"
        [ "masc_board_list"; "keeper_task_done" ]
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
      let base_dir = temp_base_path "gate-keeper-agent_core-masc-interleaving" in
      Fun.protect
        ~finally:(fun () -> try remove_tree base_dir with _ -> ())
        (fun () ->
           let keeper_name = "interleave-keeper" in
           let trace_id = "trace-agent_core-masc-interleaving" in
           let turn = 7 in
           let acc =
             Trajectory.create_accumulator ~masc_root:base_dir ~keeper_name
               ~trace_id ()
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
             [ "thinking:[withheld]"
             ; "tool:masc_board_list"
             ; "thinking:[withheld]"
             ; "tool:keeper_task_done"
             ]
             (Trajectory.read_all_lines ~masc_root:base_dir ~keeper_name
                ~trace_id
              |> List.map trajectory_interleaving_label))
  | _ -> failf "expected two projected tool calls, got %d" (List.length calls)

let test_keeper_stream_bridge_ignores_replayed_tool_start () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
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
  | [ Keeper_chat_events.Agent_core_content_block_start
        { index = first_index; tool_call_id = Some first_block_id; _ };
      Keeper_chat_events.Tool_call_start { tool_call_id; tool_call_name; _ };
      Keeper_chat_events.Agent_core_content_block_start
        { index = replay_index; tool_call_id = Some replay_block_id; _ };
      Keeper_chat_events.Tool_call_args { tool_call_id = args_id; delta; _ };
      Keeper_chat_events.Agent_core_content_block_stop { index = stop_index };
      Keeper_chat_events.Tool_call_end { tool_call_id = end_id; _ } ] ->
      check int "first block index" 2 first_index;
      check string "first block tool id" "tc-repeat" first_block_id;
      check (option string) "tool id" (Some "tc-repeat") tool_call_id;
      check string "tool name" "keeper_memory_search" tool_call_name;
      check int "replay block index" 2 replay_index;
      check string "replay block tool id" "tc-repeat" replay_block_id;
      check (option string) "args id" (Some "tc-repeat") args_id;
      check string "args" "{\"q\":\"loop\"}" delta;
      check int "stop index" 2 stop_index;
      check (option string) "end id" (Some "tc-repeat") end_id
  | _ ->
      fail
        "expected replayed block start, one tool start, one args delta, and one end"

let test_keeper_stream_bridge_quarantines_duplicate_start_after_payload () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
      [ ContentBlockStart
          { index = 2
          ; content_type = "tool_use"
          ; tool_id = Some "tc-ambiguous"
          ; tool_name = Some "Read"
          }
      ; ContentBlockDelta { index = 2; delta = InputJsonDelta "{\"path\":" }
      ; ContentBlockStart
          { index = 2
          ; content_type = "tool_use"
          ; tool_id = Some "tc-ambiguous"
          ; tool_name = Some "Read"
          }
      ]
  in
  match List.rev events with
  | Keeper_chat_events.Agent_core_stream_protocol_error error :: _ ->
    check string "typed ambiguous start" "tool_start_duplicate_index"
      (Keeper_chat_events.stream_protocol_error_kind_to_string error.kind);
    (match error.quarantined_occurrence with
     | Some occurrence ->
       check int "ambiguous start scope" 0 occurrence.stream_scope;
       check int "ambiguous start block" 2 occurrence.block_index
     | None -> fail "ambiguous repeated start did not quarantine its occurrence")
  | _ -> fail "ambiguous repeated start emitted no terminal protocol error"

let test_keeper_stream_bridge_quarantines_args_after_stop () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
      [ ContentBlockStart
          { index = 2
          ; content_type = "tool_use"
          ; tool_id = Some "tc-late"
          ; tool_name = Some "Read"
          }
      ; ContentBlockDelta { index = 2; delta = InputJsonSnapshot "{}" }
      ; ContentBlockStop { index = 2 }
      ; ContentBlockDelta
          { index = 2; delta = InputJsonSnapshot "{\"late\":true}" }
      ]
  in
  match List.rev events with
  | Keeper_chat_events.Agent_core_stream_protocol_error error :: _ ->
    check string "typed late args" "tool_args_without_start"
      (Keeper_chat_events.stream_protocol_error_kind_to_string error.kind);
    (match error.quarantined_occurrence with
     | Some occurrence ->
       check int "late args scope" 0 occurrence.stream_scope;
       check int "late args block" 2 occurrence.block_index
     | None -> fail "late args did not quarantine the closed occurrence")
  | _ -> fail "late args emitted no terminal protocol error"

let test_keeper_stream_bridge_terminalizes_superseded_attempt_tool () =
  let open Agent_core.Types in
  let base_dir = temp_base_path "gate-keeper-stream-attempt-boundary" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let redact_text text = text in
       let first =
         Keeper_chat_agent_core_stream_bridge.translate ~redact_text ~base_dir
           ~stream_scope:0
           (Keeper_chat_agent_core_stream_bridge.empty_state ())
           (ContentBlockStart
              { index = 0
              ; content_type = "tool_use"
              ; tool_id = Some "tc-first-attempt"
              ; tool_name = Some "Read"
              })
       in
       let superseded =
         Keeper_chat_agent_core_stream_bridge.start_runtime_attempt
           ~previous_scope:Keeper_chat_events.Abandon_previous_scope
           first.bridge_state
       in
       (match superseded.chat_events with
        | [ Keeper_chat_events.Agent_core_stream_protocol_error error
          ; Keeper_chat_events.Agent_core_runtime_attempt_started
          ] ->
          check string "typed attempt terminal" "tool_attempt_superseded"
            (Keeper_chat_events.stream_protocol_error_kind_to_string error.kind);
          (match error.quarantined_occurrence with
           | Some occurrence ->
             check int "superseded scope" 0 occurrence.stream_scope;
             check int "superseded block" 0 occurrence.block_index
           | None -> fail "superseded attempt did not name its exact occurrence")
        | _ -> fail "attempt boundary did not terminalize the open tool");
       let fallback =
         Keeper_chat_agent_core_stream_bridge.translate ~redact_text ~base_dir
           ~stream_scope:1 superseded.bridge_state
           (ContentBlockStart
              { index = 0
              ; content_type = "tool_use"
              ; tool_id = Some "tc-fallback"
              ; tool_name = Some "Write"
              })
       in
       check bool "fallback scope opens an independent tool" true
         (List.exists
            (function
              | Keeper_chat_events.Tool_call_start
                  { occurrence; tool_call_id = Some "tc-fallback"; _ } ->
                occurrence.stream_scope = 1
              | _ -> false)
            fallback.chat_events))

let test_keeper_stream_bridge_preserves_authoritative_attempt_tool () =
  let open Agent_core.Types in
  let base_dir = temp_base_path "gate-keeper-stream-sealed-attempt-boundary" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let redact_text text = text in
       let translate state event =
         Keeper_chat_agent_core_stream_bridge.translate ~redact_text ~base_dir
           ~stream_scope:0 state event
       in
       let started =
         translate (Keeper_chat_agent_core_stream_bridge.empty_state ())
           (ContentBlockStart
              { index = 0
              ; content_type = "tool_use"
              ; tool_id = Some "tc-sealed-attempt"
              ; tool_name = Some "Read"
              })
       in
       let finalized =
         translate started.bridge_state (ContentBlockStop { index = 0 })
       in
       let preserved =
         Keeper_chat_agent_core_stream_bridge.start_runtime_attempt
           ~previous_scope:Keeper_chat_events.Preserve_previous_scope
           finalized.bridge_state
       in
       match preserved.chat_events with
       | [ Keeper_chat_events.Agent_core_runtime_attempt_started ] -> ()
       | _ -> fail "authoritative prior tool was quarantined at fallback boundary")

let test_keeper_stream_bridge_does_not_requarantine_failed_attempt_tool () =
  let open Agent_core.Types in
  let base_dir = temp_base_path "gate-keeper-stream-failed-attempt-boundary" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let redact_text text = text in
       let translate state event =
         Keeper_chat_agent_core_stream_bridge.translate ~redact_text ~base_dir
           ~stream_scope:0 state event
       in
       List.iter
         (fun (label, failure_event) ->
            let started =
              translate (Keeper_chat_agent_core_stream_bridge.empty_state ())
                (ContentBlockStart
                   { index = 0
                   ; content_type = "tool_use"
                   ; tool_id = Some ("tc-" ^ label)
                   ; tool_name = Some "Read"
                   })
            in
            let finalized =
              translate started.bridge_state (ContentBlockStop { index = 0 })
            in
            let failed = translate finalized.bridge_state failure_event in
            let quarantines =
              List.filter
                (function
                  | Keeper_chat_events.Agent_core_stream_protocol_error
                      { quarantined_occurrence = Some _; _ } -> true
                  | _ -> false)
                failed.chat_events
            in
            check int (label ^ " first quarantine count") 1
              (List.length quarantines);
            let fallback =
              Keeper_chat_agent_core_stream_bridge.start_runtime_attempt
                ~previous_scope:Keeper_chat_events.Abandon_previous_scope
                failed.bridge_state
            in
            match fallback.chat_events with
            | [ Keeper_chat_events.Agent_core_runtime_attempt_started ] -> ()
            | _ -> fail (label ^ " re-quarantined the same occurrence"))
         [ ( "sse-error"
           , SSEError
               { message = "provider failed"
               ; error_type = Some "server_error"
               ; raw = {|{"error":"provider failed"}|}
               } )
         ; "incomplete", StreamIncomplete { reason = "max_output_tokens" }
         ])

let test_keeper_stream_bridge_freezes_late_events_after_incomplete () =
  let open Agent_core.Types in
  let base_dir = temp_base_path "gate-keeper-stream-incomplete-late-events" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let redact_text text = text in
       let translate ~stream_scope state event =
         Keeper_chat_agent_core_stream_bridge.translate ~redact_text ~base_dir
           ~stream_scope state event
       in
       let started =
         translate ~stream_scope:0
           (Keeper_chat_agent_core_stream_bridge.empty_state ())
           (ContentBlockStart
              { index = 0
              ; content_type = "tool_use"
              ; tool_id = Some "tc-incomplete"
              ; tool_name = Some "Read"
              })
       in
       let finalized =
         translate ~stream_scope:0 started.bridge_state
           (ContentBlockStop { index = 0 })
       in
       let failed =
         translate ~stream_scope:0 finalized.bridge_state
           (StreamIncomplete { reason = "max_output_tokens" })
       in
       let first_quarantine =
         List.find_map
           (function
             | Keeper_chat_events.Agent_core_stream_protocol_error
                 ({ quarantined_occurrence = Some _; _ } as error) -> Some error
             | _ -> None)
           failed.chat_events
       in
       (match first_quarantine with
        | Some { kind = Keeper_chat_events.Sse_stream_incomplete; _ } -> ()
        | Some _ -> fail "incomplete stream recorded the wrong first quarantine kind"
        | None -> fail "incomplete stream did not quarantine the finalized tool");
       let terminalized =
         translate ~stream_scope:0 failed.bridge_state
           (MessageDelta { stop_reason = Some EndTurn; usage = None })
       in
       let late_events =
         [ ContentBlockDelta
             { index = 0; delta = InputJsonDelta {|{"late":true}|} }
         ; ContentBlockStart
             { index = 0
             ; content_type = "tool_use"
             ; tool_id = Some "tc-incomplete"
             ; tool_name = Some "Read"
             }
         ; ContentBlockDelta { index = 0; delta = TextDelta "late" }
         ; ContentBlockStop { index = 0 }
         ]
       in
       let after_late =
         List.fold_left
           (fun state event ->
              let rejected = translate ~stream_scope:0 state event in
              check int "late event is suppressed after first quarantine" 0
                (List.length rejected.chat_events);
              rejected.bridge_state)
           terminalized.bridge_state late_events
       in
       let fallback =
         Keeper_chat_agent_core_stream_bridge.start_runtime_attempt
           ~previous_scope:Keeper_chat_events.Abandon_previous_scope after_late
       in
       (match fallback.chat_events with
        | [ Keeper_chat_events.Agent_core_runtime_attempt_started ] -> ()
        | _ -> fail "fallback re-quarantined an already frozen occurrence");
       let fresh =
         translate ~stream_scope:1 fallback.bridge_state
           (ContentBlockStart
              { index = 0
              ; content_type = "tool_use"
              ; tool_id = Some "tc-fallback-fresh"
              ; tool_name = Some "Write"
              })
       in
       check bool "fallback scope reuses the index independently" true
         (List.exists
            (function
              | Keeper_chat_events.Tool_call_start
                  { occurrence; tool_call_id = Some "tc-fallback-fresh"; _ } ->
                occurrence.stream_scope = 1 && occurrence.block_index = 0
              | _ -> false)
            fresh.chat_events))

let test_keeper_stream_bridge_terminal_quarantine_is_write_once () =
  let open Agent_core.Types in
  let base_dir = temp_base_path "gate-keeper-stream-terminal-quarantine" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let redact_text text = text in
       let translate state event =
         Keeper_chat_agent_core_stream_bridge.translate ~redact_text ~base_dir
           ~stream_scope:0 state event
       in
       let started =
         translate (Keeper_chat_agent_core_stream_bridge.empty_state ())
           (ContentBlockStart
              { index = 0
              ; content_type = "tool_use"
              ; tool_id = Some "tc-terminal"
              ; tool_name = Some "Read"
              })
       in
       let finalized =
         translate started.bridge_state (ContentBlockStop { index = 0 })
       in
       let terminal =
         translate finalized.bridge_state
           (MessageDelta { stop_reason = Some EndTurn; usage = None })
       in
       let first_late =
         translate terminal.bridge_state
           (ContentBlockDelta
              { index = 0; delta = InputJsonDelta {|{"late":true}|} })
       in
       (match first_late.chat_events with
        | [ Keeper_chat_events.Agent_core_stream_protocol_error
                { kind = Keeper_chat_events.Stream_event_after_terminal
                ; quarantined_occurrence = Some occurrence
                ; _
                }
          ] ->
          check int "terminal quarantine scope" 0 occurrence.stream_scope;
          check int "terminal quarantine block" 0 occurrence.block_index
        | _ -> fail "first terminal violation did not quarantine exactly once");
       let second_late =
         translate first_late.bridge_state (ContentBlockStop { index = 0 })
       in
       check int "second terminal violation is frozen" 0
         (List.length second_late.chat_events))

let test_keeper_stream_bridge_quarantines_transport_failed_scope () =
  let open Agent_core.Types in
  let base_dir = temp_base_path "gate-keeper-stream-transport-failure" in
  Fun.protect
    ~finally:(fun () -> try remove_tree base_dir with _ -> ())
    (fun () ->
       let redact_text text = text in
       let run events =
         List.fold_left
           (fun state event ->
              (Keeper_chat_agent_core_stream_bridge.translate ~redact_text
                 ~base_dir ~stream_scope:0 state event).bridge_state)
           (Keeper_chat_agent_core_stream_bridge.empty_state ())
           events
       in
       List.iter
         (fun (label, events) ->
            let failed =
              Keeper_chat_agent_core_stream_bridge.fail_stream (run events)
                ~reason:"transport failed"
            in
            match failed.chat_events with
            | [ Keeper_chat_events.Agent_core_stream_protocol_error error ] ->
              check string (label ^ " kind") "sse_stream_incomplete"
                (Keeper_chat_events.stream_protocol_error_kind_to_string
                   error.kind);
              check bool (label ^ " exact occurrence") true
                (Option.exists
                   (fun
                     (occurrence : Keeper_chat_events.tool_stream_occurrence)
                     -> occurrence.block_index = 0)
                   error.quarantined_occurrence)
            | _ -> fail (label ^ " did not quarantine one exact occurrence"))
         [ ( "active"
           , [ ContentBlockStart
                 { index = 0
                 ; content_type = "tool_use"
                 ; tool_id = Some "active"
                 ; tool_name = Some "Read"
                 }
             ] )
         ; ( "finalized"
           , [ ContentBlockStart
                 { index = 0
                 ; content_type = "tool_use"
                 ; tool_id = Some "finalized"
                 ; tool_name = Some "Read"
                 }
             ; ContentBlockStop { index = 0 }
             ] )
         ])

let test_keeper_stream_bridge_terminalizes_conflicting_message_tool () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
      [ MessageStart { id = "message-a"; model = "m"; usage = None }
      ; ContentBlockStart
          { index = 0
          ; content_type = "tool_use"
          ; tool_id = Some "tc-message"
          ; tool_name = Some "Read"
          }
      ; ContentBlockDelta { index = 0; delta = InputJsonDelta "{\"path\":" }
      ; MessageStart { id = "message-b"; model = "m"; usage = None }
      ]
  in
  let error =
    List.find_map
      (function
        | Keeper_chat_events.Agent_core_stream_protocol_error error
          when error.kind = Keeper_chat_events.Tool_message_start_conflict ->
          Some error.quarantined_occurrence
        | _ -> None)
      events
  in
  match error with
  | None -> fail "conflicting MessageStart left its open tool unterminated"
  | Some quarantined_occurrence ->
    (match quarantined_occurrence with
     | Some occurrence ->
       check int "message conflict scope" 0 occurrence.stream_scope;
       check int "message conflict block" 0 occurrence.block_index
     | None -> fail "message conflict did not name the exact tool occurrence")

let test_keeper_stream_bridge_rejects_replayed_tool_name_drift () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
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
            tool_name = Some "masc_board_list" };
      ]
  in
  match events with
  | [ Keeper_chat_events.Agent_core_content_block_start
        { tool_call_id = Some first_block_id;
          tool_call_name = Some first_block_name;
          _ };
      Keeper_chat_events.Tool_call_start
        { tool_call_id = first_start_id; tool_call_name = first_start_name; _ };
      Keeper_chat_events.Agent_core_content_block_start
        { tool_call_id = Some replay_block_id;
          tool_call_name = Some replay_block_name;
          _ };
      Keeper_chat_events.Agent_core_stream_protocol_error
        { kind;
          index = Some index;
          tool_call_id = Some error_tool_id;
          reason = Some reason;
          _ } ] ->
      check string "first block id" "tc-repeat" first_block_id;
      check string "first block name" "keeper_memory_search" first_block_name;
      check (option string) "first start id" (Some "tc-repeat") first_start_id;
      check string "first start name" "keeper_memory_search" first_start_name;
      check string "replay block id" "tc-repeat" replay_block_id;
      check string "replay block name" "masc_board_list" replay_block_name;
      check string "kind" "tool_start_duplicate_index"
        (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
      check int "index" 2 index;
      check string "error tool id" "tc-repeat" error_tool_id;
      check bool "reason names original tool" true
        (string_contains reason "existing tool tc-repeat/keeper_memory_search");
      check bool "reason names incoming tool" true
        (string_contains reason "incoming tool tc-repeat/masc_board_list")
  | _ ->
      fail
        "expected same-id different-name tool start replay to fail closed"

let test_keeper_stream_bridge_rejects_conflicting_tool_index_reuse () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
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
  | [ Keeper_chat_events.Agent_core_content_block_start
        { index = first_block_index; tool_call_id = Some first_block_id; _ };
      Keeper_chat_events.Tool_call_start { tool_call_id = first_start; _ };
      Keeper_chat_events.Tool_call_args { tool_call_id = first_args; delta = args_a; _ };
      Keeper_chat_events.Agent_core_content_block_start
        { index = second_block_index; tool_call_id = Some second_block_id; _ };
      Keeper_chat_events.Agent_core_stream_protocol_error
        { kind = duplicate_kind;
          index = Some duplicate_index;
          tool_call_id = Some duplicate_tool_id;
          reason = Some duplicate_reason;
          _ } ] ->
      check int "first block index" 2 first_block_index;
      check string "first block id" "tc-first" first_block_id;
      check (option string) "first start" (Some "tc-first") first_start;
      check (option string) "first args id" (Some "tc-first") first_args;
      check string "first args" "{\"q\":\"first\"}" args_a;
      check int "second block index" 2 second_block_index;
      check string "second block id" "tc-second" second_block_id;
      check string "duplicate kind" "tool_start_duplicate_index"
        (Keeper_chat_events.stream_protocol_error_kind_to_string
           duplicate_kind);
      check int "duplicate index" 2 duplicate_index;
      check string "duplicate tool id" "tc-first" duplicate_tool_id;
      check bool "duplicate reason names incoming tool" true
        (string_contains duplicate_reason "incoming tool tc-second")
  | _ ->
      fail
        "expected conflicting reused-index tool start to fail closed without forged tool events"

let test_keeper_stream_bridge_isolates_tool_blocks_across_messages () =
  let open Agent_core.Types in
  (* Block indices may restart only after Agent Core successfully seals the
     provider call. [stream_scope = 1] below is that exact boundary; MessageStop
     alone does not mint it. *)
  let events =
    let base_dir = temp_base_path "gate-keeper-stream-scope" in
    Fun.protect ~finally:(fun () -> try remove_tree base_dir with _ -> ())
      (fun () ->
         let redact_text text = text in
         let scoped_events =
           [ 0, ContentBlockStart
          { index = 2;
            content_type = "tool_use";
            tool_id = Some "call_first";
            tool_name = Some "keeper_tasks_audit" }
           ; 0, ContentBlockDelta
               { index = 2; delta = InputJsonDelta "{\"a\":1}" }
           ; 0, MessageDelta { stop_reason = Some StopToolUse; usage = None }
           ; 0, MessageStop
           ; 1, ContentBlockStart
          { index = 2;
            content_type = "tool_use";
            tool_id = Some "call_second";
            tool_name = Some "keeper_tasks_audit" }
           ; 1, ContentBlockDelta
               { index = 2; delta = InputJsonDelta "{\"b\":2}" }
           ]
         in
         let _, reversed =
           List.fold_left
             (fun (state, reversed) (stream_scope, event) ->
                let translated =
                  Keeper_chat_agent_core_stream_bridge.translate ~redact_text
                    ~base_dir ~stream_scope state event
                in
                translated.bridge_state,
                List.rev_append translated.chat_events reversed)
             (Keeper_chat_agent_core_stream_bridge.empty_state (), [])
             scoped_events
         in
         List.rev reversed)
  in
  check bool "no protocol error across message boundary" false
    (has_stream_protocol_error events);
  let tool_starts =
    List.filter_map
      (function
        | Keeper_chat_events.Tool_call_start { tool_call_id; _ } -> tool_call_id
        | _ -> None)
      events
  in
  check (list string) "both messages start their tool cleanly"
    [ "call_first"; "call_second" ] tool_starts;
  let tool_ends =
    List.filter_map
      (function
        | Keeper_chat_events.Tool_call_end { tool_call_id; _ } -> tool_call_id
        | _ -> None)
      events
  in
  check bool "message-1 tool closed at MessageStop" true
    (List.mem "call_first" tool_ends);
  let second_args =
    List.filter_map
      (function
        | Keeper_chat_events.Tool_call_args
            { tool_call_id = Some "call_second"; delta; _ } ->
            Some delta
        | _ -> None)
      events
  in
  check (list string) "message-2 args routed to its own fresh block"
    [ "{\"b\":2}" ] second_args

let stream_text_deltas events =
  List.filter_map
    (function Keeper_chat_events.Text_delta text -> Some text | _ -> None)
    events

let resolve_canonical_agent_core_stream_events events =
  let acc = Agent_core.Llm_provider.Complete_stream_acc.create_stream_acc () in
  let canonical =
    List.filter_map
      (fun event ->
         match Agent_core.Llm_provider.Complete_stream_acc.resolve_event acc event with
         | Agent_core.Types.Stream_event_accepted event -> Some event
         | Agent_core.Types.Stream_event_suppressed -> None
         | Agent_core.Types.Stream_event_rejected _ ->
           fail "text fixture was rejected by canonical stream state")
      events
  in
  acc, canonical

let translate_canonical_agent_core_stream_events events =
  let _, canonical = resolve_canonical_agent_core_stream_events events in
  translate_agent_core_stream_events canonical

let test_keeper_stream_bridge_text_delta_passthrough_incremental () =
  let open Agent_core.Types in
  let events =
    translate_canonical_agent_core_stream_events
      [
        ContentBlockStart
          { index = 0; content_type = "text"; tool_id = None; tool_name = None };
        ContentBlockDelta { index = 0; delta = TextDelta "Hello" };
        ContentBlockDelta { index = 0; delta = TextDelta "" };
        ContentBlockDelta { index = 0; delta = TextDelta " world" };
        ContentBlockStart
          { index = 1; content_type = "text"; tool_id = None; tool_name = None };
        ContentBlockDelta { index = 1; delta = TextDelta "second block" };
      ]
  in
  check (list string) "incremental deltas pass through in order"
    [ "Hello"; ""; " world"; "second block" ]
    (stream_text_deltas events)

let test_keeper_stream_pipeline_reconciles_cumulative_snapshot_once () =
  let open Agent_core.Types in
  (* Canonical normalization happens before the bridge. The repeated suffix
     value intentionally equals the first accepted delta ("ha") so a second
     normalization would incorrectly drop it. *)
  let acc, canonical =
    resolve_canonical_agent_core_stream_events
      [ ContentBlockStart
          { index = 0; content_type = "text"; tool_id = None; tool_name = None }
      ; ContentBlockDelta { index = 0; delta = TextDelta "ha" }
      ; ContentBlockDelta { index = 0; delta = TextSnapshot "haha" }
      ]
  in
  let events = translate_agent_core_stream_events canonical in
  check (list string) "cumulative snapshots forward only the new suffix"
    [ "ha"; "ha" ]
    (stream_text_deltas events);
  Agent_core.Llm_provider.Complete_stream_acc.accumulate_event acc
    (MessageDelta { stop_reason = Some EndTurn; usage = None });
  (match Agent_core.Llm_provider.Complete_stream_acc.finalize_stream_acc acc with
   | Ok { content = [ Text "haha" ]; _ } -> ()
   | Ok _ -> fail "canonical final response did not retain both accepted suffixes"
   | Error _ -> fail "canonical cumulative stream failed to finalize")

let test_keeper_stream_pipeline_drops_text_retransmission () =
  let open Agent_core.Types in
  (* A producer explicitly labels reconnect snapshots. Older/equal snapshots
     are safe to suppress; ordinary repeated TextDelta values still append. *)
  let events =
    translate_canonical_agent_core_stream_events
      [
        ContentBlockStart
          { index = 0; content_type = "text"; tool_id = None; tool_name = None };
        ContentBlockDelta { index = 0; delta = TextDelta "Hello" };
        ContentBlockDelta { index = 0; delta = TextDelta " world" };
        ContentBlockDelta { index = 0; delta = TextSnapshot "Hello" };
        ContentBlockDelta { index = 0; delta = TextSnapshot "Hello world" };
        ContentBlockDelta { index = 0; delta = TextDelta " again" };
      ]
  in
  check (list string) "retransmitted prefixes drop, new text still flows"
    [ "Hello"; " world"; " again" ]
    (stream_text_deltas events)

let test_keeper_stream_text_normalization_resets_per_response () =
  let open Agent_core.Types in
  (* Every provider response owns a fresh canonical accumulator. Reusing block
     index 0 in the next response cannot alias the first response's text. *)
  let events =
    translate_canonical_agent_core_stream_events
      [ ContentBlockStart
          { index = 0; content_type = "text"; tool_id = None; tool_name = None }
      ; ContentBlockDelta { index = 0; delta = TextDelta "abcdef" }
      ]
    @ translate_canonical_agent_core_stream_events
        [ ContentBlockStart
            { index = 0; content_type = "text"; tool_id = None; tool_name = None }
        ; ContentBlockDelta { index = 0; delta = TextDelta "abc" }
        ]
  in
  check (list string) "normalization state is response-scoped"
    [ "abcdef"; "abc" ]
    (stream_text_deltas events)

let test_keeper_stream_bridge_text_delta_appends_unrelated_overlap () =
  let open Agent_core.Types in
  (* A delta that shares neither an exact-prefix relation with the accumulated
     text is new content by the deterministic rule and passes through — the
     canonical state never guesses at partial overlaps. *)
  let events =
    translate_canonical_agent_core_stream_events
      [
        ContentBlockStart
          { index = 0; content_type = "text"; tool_id = None; tool_name = None };
        ContentBlockDelta { index = 0; delta = TextDelta "abc" };
        ContentBlockDelta { index = 0; delta = TextDelta "bcd" };
      ]
  in
  check (list string) "non-prefix delta appends verbatim"
    [ "abc"; "bcd" ]
    (stream_text_deltas events)

let test_keeper_stream_bridge_surfaces_agent_core_message_metadata () =
  let open Agent_core.Types in
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
    translate_agent_core_stream_events
      [
        MessageStart
          { id = "msg-agent_core-1"; model = "gpt-5.5"; usage = Some usage_start };
        MessageDelta
          { stop_reason = Some EndTurn
          ; usage = Some (Agent_core.Types.delta_usage_of_api_usage usage_delta)
          };
        MessageStop;
        Ping;
      ]
  in
  match events with
  | [ Keeper_chat_events.Agent_core_stream_message_start
        { provider_message_id; model; usage = Some start_usage };
      Keeper_chat_events.Agent_core_stream_message_delta
        { stop_reason = Some stop_reason; usage = Some delta_usage };
      Keeper_chat_events.Agent_core_stream_message_stop;
      Keeper_chat_events.Agent_core_stream_ping ] ->
      check string "provider message id" "msg-agent_core-1" provider_message_id;
      check string "model" "gpt-5.5" model;
      check int "start input tokens" 10 start_usage.input_tokens;
      check int "start total tokens" 11
        (Agent_core.Types.total_tokens start_usage);
      check int "cache creation tokens" 3
        start_usage.cache_creation_input_tokens;
      check string "stop reason" "end_turn"
        (Agent_core.Types.stop_reason_to_string stop_reason);
      check (option int) "delta output tokens" (Some 2) delta_usage.output_tokens;
      check (option int) "delta input tokens" (Some 10) delta_usage.input_tokens;
      check (option int) "delta cache read tokens" (Some 4)
        delta_usage.cache_read_input_tokens
  | _ -> fail "expected AGENT_CORE message lifecycle metadata events"

let test_keeper_stream_bridge_terminal_text_state_is_message_scoped () =
  let open Agent_core.Types in
  let message_start id =
    MessageStart { id; model = "provider-model"; usage = None }
  in
  let text_start =
    ContentBlockStart
      { index = 0; content_type = "text"; tool_id = None; tool_name = None }
  in
  let terminal = MessageDelta { stop_reason = Some EndTurn; usage = None } in
  let translate_scoped scoped_events =
    let base_dir = temp_base_path "gate-keeper-terminal-text-scope" in
    Fun.protect ~finally:(fun () -> try remove_tree base_dir with _ -> ())
      (fun () ->
         List.fold_left
           (fun state (stream_scope, event) ->
              (Keeper_chat_agent_core_stream_bridge.translate ~redact_text:Fun.id
                 ~base_dir ~stream_scope state event).bridge_state)
           (Keeper_chat_agent_core_stream_bridge.empty_state ())
           scoped_events)
  in
  let no_final_text =
    translate_scoped
      [ 0, message_start "intermediate"
      ; 0, text_start
      ; 0, ContentBlockDelta { index = 0; delta = TextDelta "working" }
      ; 0, terminal
      ; 0, MessageStop
      ; 1, message_start "terminal"
      ; 1, terminal
      ; 1, MessageStop
      ]
  in
  check bool "intermediate narration is not terminal text" false
    (Keeper_chat_agent_core_stream_bridge.terminal_message_had_text no_final_text);
  let _, open_final_text =
    translate_agent_core_stream
      [ message_start "terminal-open"
      ; text_start
      ; ContentBlockDelta { index = 0; delta = TextDelta "approved" }
      ]
  in
  check bool "open terminal message text is observable" true
    (Keeper_chat_agent_core_stream_bridge.terminal_message_had_text open_final_text);
  let open_final_without_text =
    translate_scoped
      [ 0, message_start "intermediate"
      ; 0, text_start
      ; 0, ContentBlockDelta { index = 0; delta = TextDelta "working" }
      ; 0, terminal
      ; 0, MessageStop
      ; 1, message_start "terminal-open-empty"
      ]
  in
  check bool "new open message resets prior text state" false
    (Keeper_chat_agent_core_stream_bridge.terminal_message_had_text
       open_final_without_text);
  let final_text =
    translate_scoped
      [ 0, message_start "intermediate"
      ; 0, text_start
      ; 0, ContentBlockDelta { index = 0; delta = TextDelta "working" }
      ; 0, terminal
      ; 0, MessageStop
      ; 1, message_start "terminal"
      ; 1, text_start
      ; 1, ContentBlockDelta { index = 0; delta = TextDelta "approved" }
      ; 1, terminal
      ; 1, MessageStop
      ]
  in
  check bool "terminal message text suppresses terminal resend" true
    (Keeper_chat_agent_core_stream_bridge.terminal_message_had_text final_text)

let test_keeper_stream_bridge_preserves_typed_media_source () =
  let open Agent_core.Types in
  let raw_media = "raw image bytes" in
  let encoded_media = Base64.encode_string raw_media in
  (* RFC-0301: media chunks are accumulated and surfaced as a single
     [Agent_core_media_delta] carrying the persisted media URL at the block stop, not a
     per-chunk byte count. A lone [MediaDelta] therefore emits nothing until its
     [ContentBlockStop] closes the block. *)
  let events =
    translate_agent_core_stream_events
      [
        ContentBlockStart
          { index = 0;
            content_type = "image";
            tool_id = None;
            tool_name = None };
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
      Keeper_chat_events.Agent_core_content_block_start
        { index = start_index; content_type = "image"; _ };
      Keeper_chat_events.Agent_core_content_block_stop { index = stop_index };
      Keeper_chat_events.Agent_core_media_delta
        { index; media_type; source_type; media_ref };
    ] ->
      check int "block start index" 0 start_index;
      check int "block stop index" 0 stop_index;
      check int "block index" 0 index;
      check string "media type" "image/png" media_type;
      check bool "source type" true (source_type = Base64);
      check string "media ref is the persisted URL" expected_ref media_ref
  | _ -> fail "expected typed AGENT_CORE media delta carrying the persisted URL"

let test_keeper_stream_bridge_rejects_media_delta_for_tool_block () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
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
  let errors =
    List.filter_map
      (function
        | Keeper_chat_events.Agent_core_stream_protocol_error error ->
          Some
            ( Keeper_chat_events.stream_protocol_error_kind_to_string error.kind
            , error.quarantined_occurrence )
        | _ -> None)
      events
  in
  check (list string) "tool occurrence remains invalid after media mismatch"
    [ "tool_delta_invalid_kind" ]
    (List.map fst errors);
  (match errors with
   | (_, quarantined_occurrence) :: _ ->
     (match quarantined_occurrence with
      | Some occurrence ->
        check int "media conflict scope" 0 occurrence.stream_scope;
        check int "media conflict block" 2 occurrence.block_index
      | None -> fail "media conflict did not quarantine the exact occurrence")
   | [] -> fail "media conflict emitted no protocol error");
  check bool "invalid tool emits no later args or end" false
    (List.exists
       (function
         | Keeper_chat_events.Tool_call_args _
         | Keeper_chat_events.Tool_call_args_snapshot _
         | Keeper_chat_events.Tool_call_end _ -> true
         | _ -> false)
       events)

let test_keeper_stream_bridge_surfaces_bad_media_base64 () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
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
  | [ Keeper_chat_events.Agent_core_content_block_stop { index = stop_index };
      Keeper_chat_events.Agent_core_stream_protocol_error
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
    let open Agent_core.Types in
    let oversized = String.make (Keeper_chat_media_store.max_wire_bytes () + 1) 'A' in
    let events =
      translate_agent_core_stream_events
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
    | [ Keeper_chat_events.Agent_core_stream_protocol_error
          { kind; index = Some error_index; raw_bytes = Some raw_bytes; reason = Some reason; _ };
        Keeper_chat_events.Agent_core_content_block_stop { index = stop_index } ] ->
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
    let open Agent_core.Types in
    let oversized = String.make (Keeper_chat_media_store.max_wire_bytes () + 1) 'A' in
    let events =
      translate_agent_core_stream_events
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
          | Keeper_chat_events.Agent_core_media_delta _ -> true
          | _ -> false)
        events
    in
    check bool "oversize block suppresses later media ref" false has_media_ref;
    match events with
    | [ Keeper_chat_events.Agent_core_stream_protocol_error
          { kind; index = Some error_index; raw_bytes = Some raw_bytes; reason = Some reason; _ };
        Keeper_chat_events.Agent_core_content_block_stop { index = stop_index } ] ->
        check string "oversize media kind" "media_payload_too_large"
          (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
        check int "oversize media index" 0 error_index;
        check int "oversize media bytes" (String.length oversized) raw_bytes;
        check bool "oversize media reason" true
          (string_contains reason "generated media payload too large");
        check int "block stop index" 0 stop_index
    | _ -> fail "expected oversize media block to remain suppressed until stop")

let test_keeper_stream_bridge_rejects_unsupported_media_source () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
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
  | [ Keeper_chat_events.Agent_core_content_block_stop { index = stop_index };
      Keeper_chat_events.Agent_core_stream_protocol_error
        { kind; index = Some error_index; reason = Some reason; _ } ] ->
      check int "block stop index" 0 stop_index;
      check string "unsupported media source kind" "media_source_unsupported"
        (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
      check int "unsupported media source index" 0 error_index;
      check bool "unsupported media source reason" true
        (string_contains reason "unsupported media source_type: url")
  | _ -> fail "expected unsupported media source to surface as a protocol error"

let test_keeper_stream_bridge_masks_media_write_failure_reason () =
  let open Agent_core.Types in
  let base_file = temp_base_path "gate-keeper-stream-bridge-base-file" in
  let oc = open_out_bin base_file in
  close_out_noerr oc;
  Fun.protect
    ~finally:(fun () -> try remove_tree base_file with _ -> ())
    (fun () ->
      let events =
        translate_agent_core_stream_events ~base_dir:base_file
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
      | [ Keeper_chat_events.Agent_core_content_block_stop { index = stop_index };
          Keeper_chat_events.Agent_core_stream_protocol_error
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
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
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
  | [ Keeper_chat_events.Agent_core_content_block_start
        { index = start_index; content_type; tool_call_id; tool_call_name };
      Keeper_chat_events.Agent_core_content_block_stop { index = stop_index } ] ->
      check int "start index" 4 start_index;
      check string "content type" "text" content_type;
      check (option string) "tool id" None tool_call_id;
      check (option string) "tool name" None tool_call_name;
      check int "stop index" 4 stop_index
  | _ -> fail "expected non-tool AGENT_CORE block start and stop events"

let test_keeper_stream_bridge_rejects_tool_start_missing_identity () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
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
      Keeper_chat_events.Agent_core_content_block_start
        { index = block_index; content_type; tool_call_id; tool_call_name };
      Keeper_chat_events.Agent_core_stream_protocol_error
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
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
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
      Keeper_chat_events.Agent_core_content_block_start
        { index = block_index; content_type; tool_call_id; tool_call_name };
      Keeper_chat_events.Agent_core_stream_protocol_error
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

let test_keeper_stream_bridge_preserves_native_tool_origin () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
      [ ContentBlockStart
          { index = 7
          ; content_type = Runtime_native_tools.stream_content_type
          ; tool_id = Some "native-1"
          ; tool_name = Some "commandExecution"
          }
      ; ContentBlockStop { index = 7 }
      ]
  in
  let has_dynamic_tool_event =
    List.exists
      (function
        | Keeper_chat_events.Tool_call_start _
        | Keeper_chat_events.Tool_call_end _ -> true
        | _ -> false)
      events
  in
  check bool "native observation is not a MASC tool call" false has_dynamic_tool_event;
  match events with
  | [ Keeper_chat_events.Agent_core_content_block_start
        { index = 7
        ; content_type
        ; tool_call_id = Some "native-1"
        ; tool_call_name = Some "commandExecution"
        }
    ; Agent_core_content_block_stop { index = 7 }
    ] ->
    check string
      "typed native content origin"
      Runtime_native_tools.stream_content_type
      content_type
  | _ -> fail "native tool origin was rejected or promoted to a MASC tool"

let test_keeper_stream_bridge_rejects_tool_args_without_start () =
  let open Agent_core.Types in
  let events =
    translate_agent_core_stream_events
      [ ContentBlockDelta { index = 7; delta = InputJsonSnapshot "{\"x\":1}" } ]
  in
  match events with
  | [ Keeper_chat_events.Agent_core_stream_protocol_error
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
  let error : Keeper_chat_events.stream_protocol_error =
    { kind = Keeper_chat_events.Tool_args_without_start
    ; quarantined_occurrence =
        Some
          { stream_scope = 3
          ; provider_message_id = None
          ; block_index = 2
          }
    ; index = Some 2
    ; tool_call_id = Some "tc-1"
    ; event_type = Some "response.future"
    ; reason = Some "tool argument delta arrived before tool start"
    ; raw_bytes = Some 7
    }
  in
  let summary = Keeper_chat_events.stream_protocol_error_summary error in
  check bool "kind" true (string_contains summary "tool_args_without_start");
  check bool "quarantined occurrence" true
    (string_contains summary "quarantined_occurrence=3/2");
  check bool "index" true (string_contains summary "index=2");
  check bool "tool id" true (string_contains summary "tool_call_id=tc-1");
  check bool "event type" true
    (string_contains summary "event_type=response.future");
  check bool "reason" true
    (string_contains summary "tool argument delta arrived before tool start");
  check bool "raw bytes" true (string_contains summary "raw_bytes=7");
  match Keeper_chat_events.stream_protocol_error_to_json error with
  | `Assoc fields ->
    (match List.assoc_opt "quarantined_occurrence" fields with
     | Some (`Assoc occurrence) ->
       check (option int) "wire scope" (Some 3)
         (match List.assoc_opt "toolStreamScope" occurrence with
          | Some (`Int value) -> Some value
          | Some _ | None -> None);
       check (option int) "wire block" (Some 2)
         (match List.assoc_opt "toolCallBlockIndex" occurrence with
          | Some (`Int value) -> Some value
          | Some _ | None -> None)
     | Some _ | None -> fail "typed quarantine was missing from protocol JSON")
  | _ -> fail "stream protocol error JSON is not an object"

let test_keeper_stream_bridge_surfaces_unknown_and_incomplete_events () =
  let open Agent_core.Types in
  let unknown_then_incomplete =
    translate_agent_core_stream_events
      [
        SSEUnknownEventType { event_type = "response.future"; raw = "{\"x\":1}" };
        StreamIncomplete { reason = "max_output_tokens" };
      ]
  in
  (match unknown_then_incomplete with
  | [ Keeper_chat_events.Agent_core_stream_protocol_error
        { kind = unknown_kind; event_type = Some event_type; _ } ] ->
      check string "unknown kind" "sse_unknown_event_type"
        (Keeper_chat_events.stream_protocol_error_kind_to_string unknown_kind);
      check string "unknown event type" "response.future" event_type
  | _ -> fail "expected the first unknown provider event to freeze its stream");
  let incomplete =
    translate_agent_core_stream_events
      [ StreamIncomplete { reason = "max_output_tokens" } ]
  in
  match incomplete with
  | [ Keeper_chat_events.Agent_core_stream_protocol_error
        { kind = incomplete_kind; _ };
      Keeper_chat_events.Event_error { message } ] ->
      check string "incomplete kind" "sse_stream_incomplete"
        (Keeper_chat_events.stream_protocol_error_kind_to_string incomplete_kind);
      check string "incomplete is visible error"
        "Provider stream incomplete: max_output_tokens" message
  | _ -> fail "expected visible events for unknown/incomplete provider stream"

let test_keeper_stream_bridge_surfaces_unsupported_provider_shapes () =
  let open Agent_core.Types in
  let provider_kind = Agent_core.Llm_provider.Provider_kind.Gemini in
  let part_raw = "{\"inlineData\":{}}" in
  let response_raw = "{\"promptFeedback\":{}}" in
  let part_events =
    translate_agent_core_stream_events
      [ SSEUnsupportedPart
          { provider_kind; part = "inline_data"; raw = part_raw }
      ]
  in
  (match part_events with
  | [ Keeper_chat_events.Agent_core_stream_protocol_error
        { kind = part_kind
        ; event_type = Some "inline_data"
        ; reason = Some "gemini.part.inline_data"
        ; raw_bytes = Some part_bytes
        ; _
        }
    ; Keeper_chat_events.Event_error { message = part_message }
    ] ->
      check string "unsupported part kind" "sse_unsupported_part"
        (Keeper_chat_events.stream_protocol_error_kind_to_string part_kind);
      check int "unsupported part raw bytes" (String.length part_raw) part_bytes;
      check string "unsupported part is visible"
        "Provider stream capability unsupported: gemini.part.inline_data"
        part_message
  | _ -> fail "expected a typed visible unsupported provider part");
  let response_events =
    translate_agent_core_stream_events
      [ SSEUnsupportedResponse
          { provider_kind; response = "prompt_feedback"; raw = response_raw }
      ]
  in
  match response_events with
  | [ Keeper_chat_events.Agent_core_stream_protocol_error
        { kind = response_kind
        ; event_type = Some "prompt_feedback"
        ; reason = Some "gemini.response.prompt_feedback"
        ; raw_bytes = Some response_bytes
        ; _
        }
    ; Keeper_chat_events.Event_error { message = response_message }
    ] ->
      check string "unsupported response kind" "sse_unsupported_response"
        (Keeper_chat_events.stream_protocol_error_kind_to_string response_kind);
      check int "unsupported response raw bytes" (String.length response_raw)
        response_bytes;
      check string "unsupported response is visible"
        "Provider stream capability unsupported: gemini.response.prompt_feedback"
        response_message
  | _ -> fail "expected a typed visible unsupported provider response"

let test_keeper_stream_bridge_preserves_ndjson_parse_failure () =
  let open Agent_core.Types in
  let raw = "not-json" in
  let reason = "ollama_ndjson_chunk_parse_failure" in
  let events =
    translate_agent_core_stream_events [ NDJSONParseFailed { raw; reason } ]
  in
  match events with
  | [ Keeper_chat_events.Agent_core_stream_protocol_error
        { kind; reason = Some actual_reason; raw_bytes = Some actual_bytes; _ };
      Keeper_chat_events.Event_error { message } ] ->
      check string "NDJSON kind" "ndjson_parse_failed"
        (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
      check string "NDJSON reason" reason actual_reason;
      check int "NDJSON raw bytes" (String.length raw) actual_bytes;
      check string "NDJSON visible error"
        ("Provider NDJSON stream parse failed: " ^ reason)
        message
  | _ -> fail "expected NDJSON parse failure to remain a typed visible error"

let test_keeper_stream_bridge_preserves_ndjson_provider_error () =
  let open Agent_core.Types in
  let message = "request rejected" in
  let raw = "{\"error\":\"request rejected\"}" in
  let events =
    translate_agent_core_stream_events
      [ NDJSONError
          { message; error_type = Some "rate_limit_exceeded"; raw } ]
  in
  match events with
  | [ Keeper_chat_events.Agent_core_stream_protocol_error
        { kind
        ; event_type = Some actual_error_type
        ; reason = Some actual_reason
        ; raw_bytes = Some actual_bytes
        ; _
        }
    ; Keeper_chat_events.Event_error { message = actual_message } ] ->
      check string "NDJSON provider error kind" "ndjson_error"
        (Keeper_chat_events.stream_protocol_error_kind_to_string kind);
      check string "NDJSON provider error type" "rate_limit_exceeded"
        actual_error_type;
      check string "NDJSON provider error reason" message actual_reason;
      check int "NDJSON provider error raw bytes" (String.length raw) actual_bytes;
      check string "NDJSON provider visible error"
        "Provider NDJSON stream error: rate_limit_exceeded: request rejected"
        actual_message
  | _ -> fail "expected NDJSON provider error to remain typed and visible"

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

let test_runtime_run_blocks_appends_multimodal_input_to_agent_core_agent () =
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
      Agent_core.Types.Text "Inspect this";
      Agent_core.Types.image_block ~media_type:"image/png" ~data:"img" ();
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
   | Error err -> ignore (Agent_core.Error.to_string err));
  match !agent_ref with
  | None -> fail "expected Runtime_agent.run_blocks to expose built AGENT_CORE agent"
  | Some agent -> (
      match List.rev (Agent_core.Agent.state agent).messages with
      | { Agent_core.Types.role = User; content; _ } :: _ -> (
          check int "stored blocks" 2 (List.length content);
          match content with
          | [
              Agent_core.Types.Text text;
              Agent_core.Types.Image { media_type; data; source_type };
            ] ->
              check string "text preserved" "Inspect this" text;
              check string "image media type" "image/png" media_type;
              check string "image data" "img" data;
              check bool "source type" true (source_type = Agent_core.Types.Base64)
          | _ -> fail "stored user input lost multimodal block shape")
      | _ -> fail "missing appended AGENT_CORE user message")

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
    [ Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" () ]
  in
  match
    Runtime_agent.For_testing.validate_content_blocks_against_capabilities
      ~provider_label:"runtime:deepseek"
      effective
      blocks
  with
  | Ok () -> fail "expected runtime model capability to veto image input"
  | Error
      (Agent_core.Error.Config
         (Agent_core.Error.InvalidConfig { detail; _ })) ->
      check bool "mentions unsupported image" true
        (String_util.string_contains_substring
           ~needle:"unsupported image input"
           detail)
  | Error err -> fail ("unexpected error shape: " ^ Agent_core.Error.to_string err)

let test_runtime_multimodal_gate_lists_required_modalities () =
  let blocks =
    [
      Agent_core.Types.Text "describe these";
      Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" ();
      Agent_core.Types.audio_block ~media_type:"audio/wav" ~data:"def" ();
    ]
  in
  check (list string) "required modalities" [ "image"; "audio" ]
    (Runtime_agent.For_testing.required_modalities_of_content_blocks blocks)

let test_runtime_multimodal_gate_includes_initial_messages () =
  let initial_messages =
    [
      { Agent_core.Types.role = Agent_core.Types.User;
        content =
          [
            Agent_core.Types.Text "previous image turn";
            Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" ();
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
       ~goal_blocks:[ Agent_core.Types.Text "text-only follow-up" ]);
  let blocks =
    Runtime_agent.For_testing.content_blocks_for_run
      ~initial_messages
      ~goal_blocks:[ Agent_core.Types.Text "text-only follow-up" ]
  in
  match
    Runtime_agent.For_testing.validate_content_blocks_against_capabilities
      ~provider_label:"test:text-only"
      (multimodal_caps ())
      blocks
  with
  | Ok () -> fail "expected image retained in history to be rejected"
  | Error
      (Agent_core.Error.Config
         (Agent_core.Error.InvalidConfig { detail; _ })) ->
      check bool "mentions unsupported history image" true
        (String_util.string_contains_substring
           ~needle:"unsupported image input"
           detail)
  | Error err -> fail ("unexpected error shape: " ^ Agent_core.Error.to_string err)

let test_runtime_multimodal_gate_rejects_unsupported_image () =
  let blocks =
    [ Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" () ]
  in
  match
    Runtime_agent.For_testing.validate_content_blocks_against_capabilities
      ~provider_label:"test:text-only"
      (multimodal_caps ())
      blocks
  with
  | Ok () -> fail "expected image input to be rejected for text-only provider"
  | Error
      (Agent_core.Error.Config
         (Agent_core.Error.InvalidConfig { field; detail })) ->
      check string "field" "multimodal_input" field;
      check bool "mentions image" true
        (String_util.string_contains_substring
           ~needle:"unsupported image input"
           detail);
      check bool "mentions provider" true
        (String_util.string_contains_substring
           ~needle:"test:text-only"
           detail)
  | Error err -> fail ("unexpected error shape: " ^ Agent_core.Error.to_string err)

let test_runtime_multimodal_gate_allows_supported_image () =
  let blocks =
    [
      Agent_core.Types.Text "describe this";
      Agent_core.Types.image_block ~media_type:"image/png" ~data:"abc" ();
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
                       ^ Agent_core.Error.to_string err)

let test_runtime_multimodal_gate_requires_multimodal_for_document () =
  let blocks =
    [
      Agent_core.Types.document_block
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
       (Agent_core.Error.Config
          (Agent_core.Error.InvalidConfig { detail; _ })) ->
       check bool "mentions document" true
         (String_util.string_contains_substring
            ~needle:"unsupported document input"
            detail)
   | Ok () -> fail "expected document to require multimodal capability"
   | Error err -> fail ("unexpected error shape: " ^ Agent_core.Error.to_string err));
  match accepted with
  | Ok () -> ()
  | Error err -> fail ("expected multimodal provider to accept document: "
                       ^ Agent_core.Error.to_string err)

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
    stream_payload_exn ~name:"luna" ~message:"hello" ~channel:"copilot"
      ~channel_workspace_id:"session-7" ()
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
    stream_payload_exn ~name:"luna" ~message:"hello" ~channel:"copilot"
      ~channel_workspace_id:"session-7" ()
  in
  let speaker = Server_routes_http_keeper_stream.For_testing.chat_speaker_of_request payload in
  check (option string) "copilot speaker id" None speaker.speaker_id;
  check (option string) "copilot speaker name" None speaker.speaker_name;
  check bool "copilot speaker authority is owner" true
    (speaker.speaker_authority = Keeper_chat_store.Owner)

let test_chat_speaker_of_request_connector_is_external () =
  let payload =
    stream_payload_exn ~name:"luna" ~message:"hello" ~channel:"discord"
      ~channel_user_id:"user-42" ~channel_user_name:"Alice"
      ~channel_workspace_id:"workspace-9" ()
  in
  let speaker = Server_routes_http_keeper_stream.For_testing.chat_speaker_of_request payload in
  check (option string) "connector speaker id" (Some "user-42") speaker.speaker_id;
  check (option string) "connector speaker name" (Some "Alice") speaker.speaker_name;
  check bool "connector speaker authority is external" true
    (speaker.speaker_authority = Keeper_chat_store.External)

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
          test_case "context envelope includes channel metadata" `Quick
            test_contextualize_message_includes_channel_metadata;
          test_case "stream request accepts connector context" `Quick
            test_parse_keeper_chat_stream_request_accepts_connector_context;
          test_case "stream request rejects unknown fields" `Quick
            test_parse_keeper_chat_stream_request_rejects_unknown_field;
          test_case "stream request requires request id" `Quick
            test_parse_keeper_chat_stream_request_requires_request_id;
          test_case "stream request rejects duplicate fields" `Quick
            test_parse_keeper_chat_stream_request_rejects_duplicate_field;
          test_case "stream request rejects wrong field types" `Quick
            test_parse_keeper_chat_stream_request_rejects_wrong_field_type;
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
          test_case "interrupt target rejects blank Keeper name" `Quick
            test_parse_keeper_turn_interrupt_target_rejects_blank_name;
          test_case "multimodal input converts user blocks to AGENT_CORE blocks" `Quick
            test_keeper_multimodal_input_converts_user_blocks_to_agent_core_blocks;
          test_case "multimodal parse maps each kind to its constructor" `Quick
            test_keeper_multimodal_parse_maps_each_kind_to_its_constructor;
          test_case "multimodal parse rejects an unknown kind" `Quick
            test_keeper_multimodal_parse_rejects_unknown_kind;
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
          test_case "AGENT_CORE tool-call projection preserves adjacent reasoning" `Quick
            test_agent_core_tool_call_projection_preserves_adjacent_reasoning_groups;
          test_case "AGENT_CORE interleaving matches MASC receipt/progress facts" `Quick
            test_agent_core_interleaving_matches_masc_receipt_and_progress_facts;
          test_case "stream bridge accepts duplicate start before payload" `Quick
            test_keeper_stream_bridge_ignores_replayed_tool_start;
          test_case "stream bridge quarantines duplicate start after payload" `Quick
            test_keeper_stream_bridge_quarantines_duplicate_start_after_payload;
          test_case "stream bridge quarantines args after stop" `Quick
            test_keeper_stream_bridge_quarantines_args_after_stop;
          test_case "stream bridge terminalizes superseded attempt tool" `Quick
            test_keeper_stream_bridge_terminalizes_superseded_attempt_tool;
          test_case "stream bridge preserves authoritative attempt tool" `Quick
            test_keeper_stream_bridge_preserves_authoritative_attempt_tool;
          test_case "stream bridge does not re-quarantine failed attempt tool"
            `Quick
            test_keeper_stream_bridge_does_not_requarantine_failed_attempt_tool;
          test_case "stream bridge freezes late events after incomplete" `Quick
            test_keeper_stream_bridge_freezes_late_events_after_incomplete;
          test_case "stream bridge terminal quarantine is write-once" `Quick
            test_keeper_stream_bridge_terminal_quarantine_is_write_once;
          test_case "stream bridge quarantines transport-failed scope" `Quick
            test_keeper_stream_bridge_quarantines_transport_failed_scope;
          test_case "stream bridge terminalizes conflicting message tool" `Quick
            test_keeper_stream_bridge_terminalizes_conflicting_message_tool;
          test_case "stream bridge rejects replayed tool name drift" `Quick
            test_keeper_stream_bridge_rejects_replayed_tool_name_drift;
          test_case "stream bridge rejects conflicting tool index reuse" `Quick
            test_keeper_stream_bridge_rejects_conflicting_tool_index_reuse;
          test_case "stream bridge isolates tool blocks across messages" `Quick
            test_keeper_stream_bridge_isolates_tool_blocks_across_messages;
          test_case "stream bridge passes through incremental text deltas" `Quick
            test_keeper_stream_bridge_text_delta_passthrough_incremental;
          test_case "stream pipeline normalizes cumulative text once" `Quick
            test_keeper_stream_pipeline_reconciles_cumulative_snapshot_once;
          test_case "stream pipeline drops retransmitted text" `Quick
            test_keeper_stream_pipeline_drops_text_retransmission;
          test_case "stream text normalization resets per response" `Quick
            test_keeper_stream_text_normalization_resets_per_response;
          test_case "stream bridge appends non-prefix text deltas verbatim" `Quick
            test_keeper_stream_bridge_text_delta_appends_unrelated_overlap;
          test_case "stream bridge surfaces AGENT_CORE message metadata" `Quick
            test_keeper_stream_bridge_surfaces_agent_core_message_metadata;
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
          test_case "stream bridge preserves native tool origin" `Quick
            test_keeper_stream_bridge_preserves_native_tool_origin;
          test_case "stream bridge rejects tool args without start" `Quick
            test_keeper_stream_bridge_rejects_tool_args_without_start;
          test_case "stream protocol error summary includes diagnostics" `Quick
            test_stream_protocol_error_summary_includes_diagnostics;
          test_case "stream bridge surfaces unknown and incomplete events" `Quick
            test_keeper_stream_bridge_surfaces_unknown_and_incomplete_events;
          test_case "stream bridge surfaces unsupported provider shapes" `Quick
            test_keeper_stream_bridge_surfaces_unsupported_provider_shapes;
          test_case "stream bridge preserves NDJSON parse failure" `Quick
            test_keeper_stream_bridge_preserves_ndjson_parse_failure;
          test_case "stream bridge preserves NDJSON provider error" `Quick
            test_keeper_stream_bridge_preserves_ndjson_provider_error;
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
          test_case "runtime run_blocks appends multimodal input to AGENT_CORE agent" `Quick
            test_runtime_run_blocks_appends_multimodal_input_to_agent_core_agent;
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
    ]
