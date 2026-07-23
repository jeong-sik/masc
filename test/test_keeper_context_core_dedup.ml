(** Regression tests for the keeper-context checkpoint projection.

    1. [message_to_json] no longer emits the flat ["content"] field;
       [content_blocks] is the write-side source of truth.
    2. Readers consume [content_blocks] as the sole supported history /
       checkpoint content shape. *)

module C = Masc.Keeper_context_core
module T = Agent_sdk.Types

let checkpoint_write_error_to_string =
  C.checkpoint_write_error_to_string ~persistence_error_to_string:Fun.id

(* --- message_to_json: no flat [content] field --- *)

let test_message_to_json_omits_flat_content () =
  let msg : T.message =
    {
      T.role = T.User;
      content = [ T.Text "hello" ];
      name = None;
      tool_call_id = None;
      metadata = [];
    }
  in
  let json = C.message_to_json msg in
  match json with
  | `Assoc fields ->
      Alcotest.(check bool)
        "no flat content field" false
        (List.mem_assoc "content" fields);
      Alcotest.(check bool)
        "content_blocks present" true
        (List.mem_assoc "content_blocks" fields)
  | _ -> Alcotest.fail "expected `Assoc"

(* --- message_of_json: canonical content_blocks only --- *)

let test_message_of_json_new_content_blocks_only () =
  (* New checkpoints have only content_blocks — must load as before. *)
  let new_msg : T.message =
    {
      T.role = T.Assistant;
      content = [ T.Text "world" ];
      name = None;
      tool_call_id = None;
      metadata = [];
    }
  in
  let json = C.message_to_json new_msg in
  let parsed = C.message_of_json json in
  match parsed.content with
  | [ T.Text s ] -> Alcotest.(check string) "text" "world" s
  | _ -> Alcotest.fail "expected one Text block"

let test_message_of_json_rejects_unknown_role () =
  let json : Yojson.Safe.t =
    `Assoc [ ("role", `String "operator"); ("content_blocks", `List []) ]
  in
  Alcotest.check_raises
    "unknown role rejected"
    (Invalid_argument "keeper_context_core: unknown role \"operator\"")
    (fun () -> C.message_of_json json |> ignore)

let test_message_of_json_rejects_flat_content () =
  let json : Yojson.Safe.t =
    `Assoc
      [
        ("role", `String "tool");
        ("content", `String "legacy tool output");
        ("tool_call_id", `String "call_old");
      ]
  in
  Alcotest.check_raises
    "flat content rejected"
    (Invalid_argument "keeper_context_core: missing or invalid content_blocks")
    (fun () -> C.message_of_json json |> ignore)

(* --- text_of_history_jsonl_json --- *)

let test_history_jsonl_text_uses_blocks_first () =
  let new_format : Yojson.Safe.t =
    C.message_to_json
      {
        T.role = T.User;
        content = [ T.Text "structured payload" ];
        name = None;
        tool_call_id = None;
      metadata = [];
      }
  in
  let text = C.text_of_history_jsonl_json new_format in
  Alcotest.(check string) "text from blocks" "structured payload" text

let test_history_jsonl_text_empty_when_neither () =
  let empty : Yojson.Safe.t = `Assoc [ ("role", `String "user") ] in
  let text = C.text_of_history_jsonl_json empty in
  Alcotest.(check string) "empty when neither field" "" text

(* --- Round-trip: message_to_json then message_of_json then equality on text --- *)

let test_roundtrip_text_preserved () =
  let original : T.message =
    {
      T.role = T.Assistant;
      content = [ T.Text "alpha"; T.Text "beta" ];
      name = None;
      tool_call_id = None;
      metadata = [];
    }
  in
  let json = C.message_to_json original in
  let reparsed = C.message_of_json json in
  let text_of (m : T.message) =
    String.concat "\n"
      (List.filter_map
         (function T.Text s -> Some s | _ -> None)
         m.content)
  in
  Alcotest.(check string) "text preserved"
    (text_of original) (text_of reparsed)

let test_roundtrip_preserves_thinking_signature () =
  let original : T.message =
    {
      T.role = T.Assistant;
      content =
        [
          T.Thinking { signature = None; content = "chain" };
          T.Thinking { signature = Some "anthropic-signature"; content = "signed" };
          T.RedactedThinking "encrypted";
          T.Text "done";
        ];
      name = None;
      tool_call_id = None;
      metadata = [];
    }
  in
  let json = C.message_to_json original in
  let reparsed = C.message_of_json json in
  match reparsed.content with
  | [
   T.Thinking { signature = first_signature; content = first_content };
   T.Thinking { signature = second_signature; content = second_content };
   T.RedactedThinking blob;
   T.Text text;
  ] ->
      Alcotest.(check (option string)) "first thinking signature" None
        first_signature;
      Alcotest.(check string) "first thinking content" "chain" first_content;
      Alcotest.(check (option string))
        "second thinking signature" (Some "anthropic-signature")
        second_signature;
      Alcotest.(check string) "second thinking content" "signed" second_content;
      Alcotest.(check string) "redacted thinking" "encrypted" blob;
      Alcotest.(check string) "text" "done" text
  | _ -> Alcotest.fail "expected thinking, thinking, redacted thinking, text"

let test_thinking_block_json_uses_oas_signature () =
  let original : T.message =
    {
      T.role = T.Assistant;
      content =
        [ T.Thinking { signature = Some "anthropic-signature"; content = "signed" } ];
      name = None;
      tool_call_id = None;
      metadata = [];
    }
  in
  match C.message_to_json original with
  | `Assoc fields -> (
      match List.assoc_opt "content_blocks" fields with
      | Some (`List [ `Assoc block_fields ]) ->
          Alcotest.(check bool)
            "uses OAS canonical signature carrier" true
            (List.mem_assoc "signature" block_fields);
          Alcotest.(check bool)
            "does not emit legacy thinking_type carrier" false
            (List.mem_assoc "thinking_type" block_fields);
          Alcotest.(check string)
            "signature preserved"
            "anthropic-signature"
            (Yojson.Safe.Util.member "signature" (`Assoc block_fields)
             |> Yojson.Safe.Util.to_string)
      | _ -> Alcotest.fail "expected one content block")
  | _ -> Alcotest.fail "expected message object"

let test_legacy_thinking_type_is_not_promoted_to_signature () =
  let json : Yojson.Safe.t =
    `Assoc
      [
        ("role", `String "assistant");
        ( "content_blocks",
          `List
            [
              `Assoc
                [
                  ("type", `String "thinking");
                  ("thinking", `String "signed");
                  ("thinking_type", `String "legacy-signature");
                ];
            ] );
      ]
  in
  let parsed = C.message_of_json json in
  match parsed.content with
  | [ T.Thinking { signature; content } ] ->
      Alcotest.(check (option string)) "legacy thinking type ignored" None
        signature;
      Alcotest.(check string) "content" "signed" content
  | _ -> Alcotest.fail "expected legacy thinking block"

(* --- checkpoint projection: exact message preservation --- *)

let text_message text : T.message =
  {
    T.role = T.User;
    content = [ T.Text text ];
    name = None;
    tool_call_id = None;
    metadata = [];
  }

let test_resume_checkpoint_preserves_all_messages_in_order () =
  let messages =
    List.init 130 (fun index -> text_message (Printf.sprintf "message-%03d" index))
  in
  let context =
    C.create ~eio:false ~system_prompt:"system"
    |> fun context -> C.append_many context messages
  in
  let resumed = C.resume_checkpoint_of_context context in
  Alcotest.(check int)
    "no fixed checkpoint message window"
    (List.length messages)
    (List.length resumed.Agent_sdk.Checkpoint.messages);
  Alcotest.(check bool)
    "source order and oldest messages are preserved"
    true
    (resumed.Agent_sdk.Checkpoint.messages = messages)

let test_resume_checkpoint_preserves_full_tool_result () =
  let content = String.make 20_000 'x' in
  let json = `Assoc [ "payload", `String (String.make 20_000 'y') ] in
  let tool_result : T.message =
    {
      T.role = T.Tool;
      content =
        [
          T.ToolResult
            {
              tool_use_id = "call-exact";
              content;
              outcome = T.Tool_succeeded;
              json = Some json;
              content_blocks = None;
            };
        ];
      name = None;
      tool_call_id = Some "call-exact";
      metadata = [];
    }
  in
  let context =
    C.create ~eio:false ~system_prompt:"system"
    |> fun context -> C.append context tool_result
  in
  let resumed = C.resume_checkpoint_of_context context in
  match resumed.Agent_sdk.Checkpoint.messages with
  | [ { T.content = [ T.ToolResult result ]; _ } ] ->
      Alcotest.(check string) "tool-result content is not stubbed" content
        result.content;
      Alcotest.(check bool) "typed JSON is preserved" true (result.json = Some json)
  | _ -> Alcotest.fail "expected one exact ToolResult message"

let test_checkpoint_save_load_preserves_exact_messages () =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = Filename.temp_dir "keeper-checkpoint-exact-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_dir)
    (fun () ->
      let session_id = "checkpoint-exact" in
      let session = C.create_session ~session_id ~base_dir in
      let messages =
        List.init 130 (fun index ->
          text_message (Printf.sprintf "persisted-%03d" index))
      in
      let context =
        C.create ~eio:true ~system_prompt:"system"
        |> fun context -> C.append_many context messages
      in
      (match
         C.save_oas_checkpoint
           ~multimodal_policy:Masc.Keeper_types_profile.Mm_inherit
           ~keeper_name:"checkpoint-exact"
           ~session
           ~agent_name:"checkpoint-exact"
           ~ctx:context
           ~generation:1
       with
       | Ok checkpoint ->
         Alcotest.(check bool) "save returns exact source messages" true
           (checkpoint.Agent_sdk.Checkpoint.messages = messages)
       | Error error ->
         Alcotest.failf
           "checkpoint save failed: %s"
           (checkpoint_write_error_to_string error));
      let _, loaded =
        C.load_context_from_checkpoint
          ~trace_id:session_id
          ~base_dir
      in
      match loaded with
      | None -> Alcotest.fail "checkpoint was not loaded"
      | Some loaded_context ->
        Alcotest.(check bool) "load preserves every source message" true
          (C.messages_of_context loaded_context = messages))

let test_checkpoint_write_accepts_exact_open_tool_cycle () =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = Filename.temp_dir "keeper-checkpoint-open-cycle-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_dir)
    (fun () ->
      let session =
        C.create_session ~session_id:"checkpoint-open-cycle" ~base_dir
      in
      let open_tool_use : T.message =
        { role = T.Assistant
        ; content =
            [ T.ToolUse { id = "open-call"; name = "test"; input = `Null } ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      in
      let context =
        C.create ~eio:true ~system_prompt:"system"
        |> fun context -> C.append context open_tool_use
      in
      match
        C.save_oas_checkpoint
          ~multimodal_policy:Masc.Keeper_types_profile.Mm_inherit
          ~keeper_name:"checkpoint-open-cycle"
          ~session
          ~agent_name:"checkpoint-open-cycle"
          ~ctx:context
          ~generation:1
      with
      | Ok checkpoint ->
        Alcotest.(check bool) "open cycle is persisted exactly" true
          (checkpoint.Agent_sdk.Checkpoint.messages = [ open_tool_use ])
      | Error error ->
        Alcotest.failf
          "open tool cycle was rejected: %s"
          (checkpoint_write_error_to_string error))

let test_checkpoint_write_rejects_orphan_tool_result () =
  Eio_main.run @@ fun env ->
  if not (Fs_compat.has_fs ()) then Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = Filename.temp_dir "keeper-checkpoint-orphan-result-" "" in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_dir)
    (fun () ->
      let session_id = "checkpoint-orphan-result" in
      let session = C.create_session ~session_id ~base_dir in
      let orphan : T.message =
        { role = T.User
        ; content =
            [ T.ToolResult
                { tool_use_id = "orphan"
                ; content = "must remain exact"
                ; outcome = T.Tool_succeeded
                ; json = None
                ; content_blocks = None
                }
            ]
        ; name = None
        ; tool_call_id = None
        ; metadata = []
        }
      in
      let context =
        C.create ~eio:true ~system_prompt:"system"
        |> fun context -> C.append context orphan
      in
      (match
         C.save_oas_checkpoint
           ~multimodal_policy:Masc.Keeper_types_profile.Mm_inherit
           ~keeper_name:session_id
           ~session
           ~agent_name:session_id
           ~ctx:context
           ~generation:1
       with
       | Error
           (C.Tool_history_invalid
              (Masc.Keeper_compaction_unit.Orphan_tool_result
                 { message_index = 0; tool_use_id = "orphan" })) ->
         ()
       | Error error ->
         Alcotest.failf
           "wrong checkpoint write error: %s"
           (checkpoint_write_error_to_string error)
       | Ok _ -> Alcotest.fail "orphan ToolResult checkpoint was persisted");
      match
        Masc.Keeper_checkpoint_store.load_oas
          ~session_dir:session.session_dir
          ~session_id
      with
      | Error Masc.Keeper_checkpoint_store.Not_found -> ()
      | Error
          (Masc.Keeper_checkpoint_store.Store_error detail
          | Parse_error detail
          | Io_error detail
          | Sdk_other_error detail) ->
        Alcotest.failf
          "invalid checkpoint produced an unexpected store result: %s"
          detail
      | Ok _ -> Alcotest.fail "invalid checkpoint created a durable file")

let () =
  Alcotest.run "keeper_context_core_dedup"
    [
      ( "message_to_json",
        [
          Alcotest.test_case "omits flat content" `Quick
            test_message_to_json_omits_flat_content;
        ] );
      ( "message_of_json",
        [
          Alcotest.test_case "new content_blocks-only loads" `Quick
            test_message_of_json_new_content_blocks_only;
          Alcotest.test_case "unknown role rejected" `Quick
            test_message_of_json_rejects_unknown_role;
          Alcotest.test_case "flat legacy content rejected" `Quick
            test_message_of_json_rejects_flat_content;
          Alcotest.test_case "round-trip text preserved" `Quick
            test_roundtrip_text_preserved;
          Alcotest.test_case "round-trip thinking signature preserved" `Quick
            test_roundtrip_preserves_thinking_signature;
          Alcotest.test_case "thinking block JSON uses OAS signature" `Quick
            test_thinking_block_json_uses_oas_signature;
          Alcotest.test_case "legacy thinking_type is not promoted" `Quick
            test_legacy_thinking_type_is_not_promoted_to_signature;
        ] );
      ( "text_of_history_jsonl_json",
        [
          Alcotest.test_case "blocks first" `Quick
            test_history_jsonl_text_uses_blocks_first;
          Alcotest.test_case "empty when neither" `Quick
            test_history_jsonl_text_empty_when_neither;
        ] );
      ( "checkpoint_projection",
        [
          Alcotest.test_case "preserves every message in source order" `Quick
            test_resume_checkpoint_preserves_all_messages_in_order;
          Alcotest.test_case "preserves full typed tool result" `Quick
            test_resume_checkpoint_preserves_full_tool_result;
          Alcotest.test_case "save/load preserves exact message list" `Quick
            test_checkpoint_save_load_preserves_exact_messages;
          Alcotest.test_case "write accepts exact open tool cycle" `Quick
            test_checkpoint_write_accepts_exact_open_tool_cycle;
          Alcotest.test_case "write rejects orphan tool result" `Quick
            test_checkpoint_write_rejects_orphan_tool_result;
        ] );
    ]
