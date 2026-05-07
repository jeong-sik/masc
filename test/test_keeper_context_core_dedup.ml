(** Regression tests for the keeper-context dedup + escape-bomb fix.

    Pins the contract for three changes shipped together in this PR:

    1. [message_to_json] no longer emits the flat ["content"] field;
       [content_blocks] is the single source of truth.
    2. [text_of_history_jsonl_json] reads [content_blocks] first and falls
       back to legacy ["content"] for old history.jsonl lines.
    3. [tool_result_text_of_block] caps json-only results at the existing
       [default_max_checkpoint_tool_result_chars] threshold instead of
       inlining the full [Yojson.Safe.to_string] output. *)

module C = Masc_mcp.Keeper_context_core
module P = Masc_mcp.Prometheus
module T = Agent_sdk.Types

let temp_dir prefix =
  let dir = Filename.temp_file prefix "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else
        Unix.unlink path
  in
  try rm dir with _ -> ()

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let persistence_read_drop_total ~surface ~reason =
  P.metric_value_or_zero P.metric_persistence_read_drops
    ~labels:[ ("surface", surface); ("reason", reason) ]
    ()

let check_persistence_read_drop_delta ~surface ~reason ~before ~delta =
  Alcotest.(check (float 0.0001))
    (Printf.sprintf "%s/%s persistence read drops" surface reason)
    (before +. float_of_int delta)
    (persistence_read_drop_total ~surface ~reason)

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

(* --- message_of_json: legacy checkpoints still load --- *)

let test_message_of_json_legacy_content_only () =
  (* Pre-PR checkpoints had ONLY a flat content field. They must still
     load — text becomes a single Text block. *)
  let legacy : Yojson.Safe.t =
    `Assoc [ ("role", `String "user"); ("content", `String "legacy hi") ]
  in
  let msg = C.message_of_json legacy in
  Alcotest.(check int) "single block" 1 (List.length msg.content);
  match msg.content with
  | [ T.Text s ] -> Alcotest.(check string) "text" "legacy hi" s
  | _ -> Alcotest.fail "expected one Text block"

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

let test_message_of_json_legacy_content_array () =
  (* OAS/OpenAI-style legacy checkpoints may store structured blocks under
     content instead of content_blocks. This must not raise Type_error. *)
  let source : T.message =
    {
      T.role = T.Assistant;
      content = [ T.Text "array payload" ];
      name = None;
      tool_call_id = None;
      metadata = [];
    }
  in
  let content_blocks =
    match C.message_to_json source with
    | `Assoc fields -> List.assoc "content_blocks" fields
    | _ -> Alcotest.fail "expected object"
  in
  let legacy : Yojson.Safe.t =
    `Assoc [ ("role", `String "assistant"); ("content", content_blocks) ]
  in
  let parsed = C.message_of_json legacy in
  match parsed.content with
  | [ T.Text s ] -> Alcotest.(check string) "text" "array payload" s
  | _ -> Alcotest.fail "expected one Text block"

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

let test_history_jsonl_text_legacy_fallback () =
  let legacy : Yojson.Safe.t =
    `Assoc
      [
        ("role", `String "user");
        ("content", `String "legacy payload");
      ]
  in
  let text = C.text_of_history_jsonl_json legacy in
  Alcotest.(check string) "fallback to flat content" "legacy payload" text

let test_history_jsonl_text_legacy_content_array () =
  let source : T.message =
    {
      T.role = T.User;
      content = [ T.Text "array history payload" ];
      name = None;
      tool_call_id = None;
      metadata = [];
    }
  in
  let content_blocks =
    match C.message_to_json source with
    | `Assoc fields -> List.assoc "content_blocks" fields
    | _ -> Alcotest.fail "expected object"
  in
  let legacy : Yojson.Safe.t =
    `Assoc [ ("role", `String "user"); ("content", content_blocks) ]
  in
  let text = C.text_of_history_jsonl_json legacy in
  Alcotest.(check string) "text from array content" "array history payload" text

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

let test_migrate_session_history_logs_counts_malformed_rows () =
  let dir = temp_dir "keeper_context_history_migration" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let history_path = Filename.concat dir "history.jsonl" in
      let internal_path = Filename.concat dir "history.internal.jsonl" in
      write_file history_path
        (String.concat "\n"
           [
             {|{"role":"user","content":"real conversation"}|};
             "[]";
             "{not-json";
           ]
         ^ "\n");
      write_file internal_path
        (String.concat "\n"
           [
             {|{"role":"assistant","source":"internal_assistant","content":"ok"}|};
             "42";
           ]
         ^ "\n");
      let surface = "keeper_context_history_migration" in
      let entry_reason = "entry_load_error" in
      let invalid_reason = "invalid_payload" in
      let before_entry =
        persistence_read_drop_total ~surface ~reason:entry_reason
      in
      let before_invalid =
        persistence_read_drop_total ~surface ~reason:invalid_reason
      in
      let stats = C.migrate_session_history_logs ~session_dir:dir in
      Alcotest.(check int) "malformed lines counted" 3 stats.malformed_lines;
      check_persistence_read_drop_delta ~surface ~reason:entry_reason
        ~before:before_entry ~delta:1;
      check_persistence_read_drop_delta ~surface ~reason:invalid_reason
        ~before:before_invalid ~delta:2)

let () =
  Alcotest.run "keeper_context_core_dedup"
    [
      ( "message_to_json",
        [
          Alcotest.test_case "omits flat content" `Quick
            test_message_to_json_omits_flat_content;
        ] );
      ( "message_of_json backward compat",
        [
          Alcotest.test_case "legacy content-only loads" `Quick
            test_message_of_json_legacy_content_only;
          Alcotest.test_case "new content_blocks-only loads" `Quick
            test_message_of_json_new_content_blocks_only;
          Alcotest.test_case "legacy content array loads" `Quick
            test_message_of_json_legacy_content_array;
          Alcotest.test_case "round-trip text preserved" `Quick
            test_roundtrip_text_preserved;
        ] );
      ( "text_of_history_jsonl_json",
        [
          Alcotest.test_case "blocks first" `Quick
            test_history_jsonl_text_uses_blocks_first;
          Alcotest.test_case "legacy fallback" `Quick
            test_history_jsonl_text_legacy_fallback;
          Alcotest.test_case "legacy content array fallback" `Quick
            test_history_jsonl_text_legacy_content_array;
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
        [
          Alcotest.test_case "counts malformed persisted rows" `Quick
            test_migrate_session_history_logs_counts_malformed_rows;
        ] );
    ]
