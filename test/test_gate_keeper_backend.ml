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

let test_chat_surface_of_request_labels_copilot_gate () =
  let payload =
    { Server_routes_http_keeper_stream.name = "luna";
      message = "hello";
      timeout_sec = None;
      turn_instructions = None;
      surface_context = None;
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
          test_case "surface context formats into instructions" `Quick
            test_surface_context_to_instructions_formats_copilot_context;
          test_case "surface context ignores empty fields" `Quick
            test_surface_context_to_instructions_ignores_empty;
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
    ]
