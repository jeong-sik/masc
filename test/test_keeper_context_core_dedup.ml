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

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Sys.rmdir path)
    else Sys.remove path
;;

let with_temp_dir f =
  let path = Filename.temp_dir "keeper-history-migration-" "" in
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let keep_history_line =
  {|{"role":"user","content_blocks":[]}|}
;;

let moved_history_line =
  {|{"role":"assistant","source":"internal_assistant","content_blocks":[]}|}
;;

let write_migration_fixture session_dir =
  let main_path = Filename.concat session_dir "history.jsonl" in
  Fs_compat.save_file
    main_path
    (String.concat "\n" [ keep_history_line; moved_history_line ] ^ "\n");
  main_path, Filename.concat session_dir "history.internal.jsonl"
;;

let not_committed_report detail =
  { Fs_compat.Durable_mutation.progress =
      Fs_compat.Durable_mutation.Not_committed
        { cause = Failure detail
        ; backtrace = Printexc.get_callstack 8
        }
  ; diagnostics = []
  }
;;

let committed_not_durable_report detail =
  { Fs_compat.Durable_mutation.progress =
      Fs_compat.Durable_mutation.Committed_not_durable
        { value = ()
        ; cause = Failure detail
        ; backtrace = Printexc.get_callstack 8
        }
  ; diagnostics = []
  }
;;

let durability_not_confirmed_report detail =
  { Fs_compat.Durable_mutation.confirmation =
      Fs_compat.Durable_mutation.Not_confirmed
        { cause = Failure detail
        ; backtrace = Printexc.get_callstack 8
        }
  ; confirmation_diagnostics = []
  }
;;

let test_history_migration_internal_failure_preserves_main () =
  with_temp_dir (fun session_dir ->
    let main_path, internal_path = write_migration_fixture session_dir in
    let original_main = Fs_compat.load_file main_path in
    let result =
      C.For_testing.migrate_session_history_logs_with
        (fun _path _content -> not_committed_report "injected internal failure")
        ~session_dir
    in
    (match result with
     | Error
         (C.History_write_not_committed
            { stage = C.Internal_history; _ }) -> ()
     | Error error ->
       Alcotest.failf
         "wrong migration error: %s"
         (C.history_migration_error_to_string error)
     | Ok _ -> Alcotest.fail "internal write failure was reported as success");
    Alcotest.(check string)
      "main history remains authoritative"
      original_main
      (Fs_compat.load_file main_path);
    Alcotest.(check bool)
      "internal history was not created"
      false
      (Fs_compat.file_exists internal_path))
;;

let test_history_migration_main_failure_retries_without_internal_rewrite () =
  with_temp_dir (fun session_dir ->
    let main_path, internal_path = write_migration_fixture session_dir in
    let original_main = Fs_compat.load_file main_path in
    let first_attempt_calls = ref 0 in
    let fail_second_write path content =
      incr first_attempt_calls;
      if !first_attempt_calls = 2
      then not_committed_report "injected main failure"
      else Fs_compat.save_file_atomic_blocking path content
    in
    (match
       C.For_testing.migrate_session_history_logs_with
         fail_second_write
         ~session_dir
     with
     | Error
         (C.History_write_not_committed
            { stage = C.Main_history; _ }) -> ()
     | Error error ->
       Alcotest.failf
         "wrong migration error: %s"
         (C.history_migration_error_to_string error)
     | Ok _ -> Alcotest.fail "main write failure was reported as success");
    Alcotest.(check string)
      "failed main write preserves source lines"
      original_main
      (Fs_compat.load_file main_path);
    Alcotest.(check bool)
      "internal copy committed before main removal"
      true
      (String.equal
         (Fs_compat.load_file internal_path)
         (moved_history_line ^ "\n"));
    let retry_calls = ref 0 in
    let counting_writer path content =
      incr retry_calls;
      Fs_compat.save_file_atomic_blocking path content
    in
    let stats =
      match
        C.For_testing.migrate_session_history_logs_with
          counting_writer
          ~session_dir
      with
      | Ok stats -> stats
      | Error error ->
        Alcotest.fail
          ("retry failed: " ^ C.history_migration_error_to_string error)
    in
    Alcotest.(check int)
      "retry skips already-committed internal overwrite"
      1
      !retry_calls;
    Alcotest.(check int) "one line moved" 1 stats.moved_lines;
    Alcotest.(check string)
      "main keeps only public history"
      (keep_history_line ^ "\n")
      (Fs_compat.load_file main_path);
    Alcotest.(check string)
      "internal line remains exactly once"
      (moved_history_line ^ "\n")
         (Fs_compat.load_file internal_path))
;;

let test_history_migration_internal_sync_debt_blocks_main_advance () =
  with_temp_dir (fun session_dir ->
    let main_path, internal_path = write_migration_fixture session_dir in
    let original_main = Fs_compat.load_file main_path in
    let first_attempt_calls = ref 0 in
    let commit_internal_with_sync_debt path content =
      incr first_attempt_calls;
      if not (String.equal path internal_path)
      then Alcotest.fail "main rewrite advanced past internal sync debt";
      let committed = Fs_compat.save_file_atomic_blocking path content in
      (match committed.progress with
       | Fs_compat.Durable_mutation.Durable _ -> ()
       | _ -> Alcotest.fail "fixture internal write did not commit durably");
      committed_not_durable_report "injected internal parent-sync failure"
    in
    (match
       C.For_testing.migrate_session_history_logs_with
         commit_internal_with_sync_debt
         ~session_dir
     with
     | Error
         (C.History_write_committed_not_durable
            { stage = C.Internal_history; _ }) -> ()
     | Error error ->
       Alcotest.failf
         "wrong migration error: %s"
         (C.history_migration_error_to_string error)
     | Ok _ -> Alcotest.fail "internal sync debt was reported as success");
    Alcotest.(check int) "only internal phase ran" 1 !first_attempt_calls;
    Alcotest.(check string)
      "main history remains authoritative until internal is durable"
      original_main
      (Fs_compat.load_file main_path);
    Alcotest.(check string)
      "committed internal copy is available for retry"
      (moved_history_line ^ "\n")
      (Fs_compat.load_file internal_path);
    let unexpected_writer_calls = ref 0 in
    (match
       C.For_testing.migrate_session_history_logs_with
         ~confirm_parent_durable:(fun _ ->
           durability_not_confirmed_report "injected retry sync failure")
         (fun _ _ ->
           incr unexpected_writer_calls;
           not_committed_report "unexpected writer call")
         ~session_dir
     with
     | Error
         (C.History_directory_durability_not_confirmed
            { stage = C.Internal_history; _ }) -> ()
     | Error error ->
       Alcotest.failf
         "wrong confirmation error: %s"
         (C.history_migration_error_to_string error)
     | Ok _ -> Alcotest.fail "failed durability confirmation advanced migration");
    Alcotest.(check int)
      "failed confirmation does not rewrite either history"
      0
      !unexpected_writer_calls;
    Alcotest.(check string)
      "failed confirmation still preserves main"
      original_main
      (Fs_compat.load_file main_path);
    let retry_calls = ref 0 in
    let counting_writer path content =
      incr retry_calls;
      Fs_compat.save_file_atomic_blocking path content
    in
    (match
       C.For_testing.migrate_session_history_logs_with
         counting_writer
         ~session_dir
     with
     | Ok stats -> Alcotest.(check int) "one line moved on retry" 1 stats.moved_lines
     | Error error ->
       Alcotest.fail
         ("retry failed: " ^ C.history_migration_error_to_string error));
    Alcotest.(check int)
      "retry skips the already-committed internal copy"
      1
      !retry_calls;
    Alcotest.(check string)
      "retry rewrites main only after internal equality proof"
      (keep_history_line ^ "\n")
      (Fs_compat.load_file main_path))
;;

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
      ( "history_migration",
        [ Alcotest.test_case
            "internal failure preserves main"
            `Quick
            test_history_migration_internal_failure_preserves_main
        ; Alcotest.test_case
            "main failure retry skips internal rewrite"
            `Quick
            test_history_migration_main_failure_retries_without_internal_rewrite
        ; Alcotest.test_case
            "internal sync debt blocks main advance"
            `Quick
            test_history_migration_internal_sync_debt_blocks_main_advance
        ] );
    ]
