(** Regression tests for the keeper-context dedup + escape-bomb fix.

    Pins the contract for three changes shipped together in this PR:

    1. [message_to_json] no longer emits the flat ["content"] field;
       [content_blocks] is the write-side source of truth.
    2. Readers consume [content_blocks] as the sole supported history /
       checkpoint content shape.
    3. [tool_result_text_of_block] caps json-only results at the existing
       [default_max_checkpoint_tool_result_chars] threshold instead of
       inlining the full [Yojson.Safe.to_string] output. *)

module C = Masc.Keeper_context_core
module T = Agent_sdk.Types

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

(* --- tool_result_text_of_block: escape-bomb cap --- *)

let test_tool_result_content_preferred () =
  (* When [content] is non-empty, it wins regardless of [json]. *)
  let text =
    C.tool_result_text_of_block ~tool_use_id:"abc"
      ~content:"plain text result"
      ~json:(Some (`Assoc [ ("ignored", `Bool true) ]))
  in
  Alcotest.(check string) "content wins" "plain text result" text

let test_tool_result_small_json_inlined () =
  (* Small json (\u2264 8KB cap) is still inlined verbatim — preserves
     existing behavior for the common case. *)
  let small = `Assoc [ ("ok", `Bool true); ("n", `Int 42) ] in
  let text =
    C.tool_result_text_of_block ~tool_use_id:"abc" ~content:"" ~json:(Some small)
  in
  Alcotest.(check string) "small inlined"
    "{\"ok\":true,\"n\":42}" text

let test_tool_result_large_json_elided () =
  (* Large json must NOT be inlined verbatim. The previous behavior
     stringified the entire payload, which is the escape-depth
     amplifier the artifact-store work was created to remove. *)
  let big_string = String.make 9_000 'x' in
  let big = `Assoc [ ("payload", `String big_string) ] in
  let text =
    C.tool_result_text_of_block ~tool_use_id:"abc-1" ~content:"" ~json:(Some big)
  in
  Alcotest.(check bool)
    "is stub, not full json" true
    (String.length text < 200);
  Alcotest.(check bool)
    "stub mentions tool id" true
    (Astring.String.is_infix ~affix:"abc-1" text);
  Alcotest.(check bool)
    "stub mentions byte count" true
    (Astring.String.is_infix ~affix:"bytes:" text);
  Alcotest.(check bool)
    "stub mentions elided" true
    (Astring.String.is_infix ~affix:"elided" text)

let test_tool_result_no_content_no_json () =
  let text = C.tool_result_text_of_block ~tool_use_id:"xyz" ~content:"" ~json:None in
  Alcotest.(check bool)
    "fallback mentions id" true
    (Astring.String.is_infix ~affix:"xyz" text)

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
    C.create ~eio:false ~system_prompt:"system" ~max_tokens:4096
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
    C.create ~eio:false ~system_prompt:"system" ~max_tokens:4096
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
        C.create ~eio:true ~system_prompt:"system" ~max_tokens:4096
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
       | Error error -> Alcotest.failf "checkpoint save failed: %s" error);
      let _, loaded =
        C.load_context_from_checkpoint
          ~trace_id:session_id
          ~primary_model_max_tokens:4096
          ~base_dir
      in
      match loaded with
      | None -> Alcotest.fail "checkpoint was not loaded"
      | Some loaded_context ->
        Alcotest.(check bool) "load preserves every source message" true
          (C.messages_of_context loaded_context = messages))

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
      ( "tool_result_text_of_block",
        [
          Alcotest.test_case "content preferred" `Quick
            test_tool_result_content_preferred;
          Alcotest.test_case "small json inlined" `Quick
            test_tool_result_small_json_inlined;
          Alcotest.test_case "large json elided to stub" `Quick
            test_tool_result_large_json_elided;
          Alcotest.test_case "no content no json" `Quick
            test_tool_result_no_content_no_json;
        ] );
      ( "checkpoint_projection",
        [
          Alcotest.test_case "preserves every message in source order" `Quick
            test_resume_checkpoint_preserves_all_messages_in_order;
          Alcotest.test_case "preserves full typed tool result" `Quick
            test_resume_checkpoint_preserves_full_tool_result;
          Alcotest.test_case "save/load preserves exact message list" `Quick
            test_checkpoint_save_load_preserves_exact_messages;
        ] );
    ]
