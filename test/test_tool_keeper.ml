open Alcotest

let with_temp_file contents f =
  let path = Filename.temp_file "keeper-tail" ".log" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      let oc = open_out_bin path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc contents);
      f path)

let test_read_file_tail_lines_drops_partial_first_line () =
  let contents = "AAAAA\nBBBBB\nCCCCC\nDDDDD\n" in
  let len = String.length contents in
  let b_index = String.index contents 'B' in
  let start = b_index + 2 in
  let max_bytes = len - start in
  with_temp_file contents (fun path ->
    let lines = Masc_mcp.Tool_keeper.read_file_tail_lines path ~max_bytes ~max_lines:10 in
    check (list string) "drops partial fragment" ["CCCCC"; "DDDDD"] lines)

let test_read_file_tail_lines_keeps_line_boundary_start () =
  let contents = "AAAAA\nBBBBB\nCCCCC\nDDDDD\n" in
  let len = String.length contents in
  let b_index = String.index contents 'B' in
  let max_bytes = len - b_index in
  with_temp_file contents (fun path ->
    let lines = Masc_mcp.Tool_keeper.read_file_tail_lines path ~max_bytes ~max_lines:10 in
    check (list string) "keeps full first line" ["BBBBB"; "CCCCC"; "DDDDD"] lines)

let with_env name value f =
  let original = Sys.getenv_opt name in
  Fun.protect
    ~finally:(fun () ->
      match original with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    (fun () ->
      Unix.putenv name value;
      f ())

let string_is_valid_utf8 s =
  let len = String.length s in
  let rec loop i =
    if i >= len then true
    else
      let dec = String.get_utf_8_uchar s i in
      let dlen = Uchar.utf_decode_length dec in
      dlen > 0 && Uchar.utf_decode_is_valid dec && loop (i + dlen)
  in
  loop 0

let test_keeper_fallback_model_labels_prefers_available_remote_models () =
  with_env "ZAI_API_KEY" "zai-test" (fun () ->
      with_env "ANTHROPIC_API_KEY" "" (fun () ->
          with_env "GEMINI_API_KEY" "" (fun () ->
              let labels = Masc_mcp.Tool_keeper.keeper_fallback_model_labels () in
              check (list string) "glm fallback only" ["glm:glm-4.7"] labels)))

let test_maybe_append_keeper_fallback_models_adds_glm_when_local_only () =
  with_env "ZAI_API_KEY" "zai-test" (fun () ->
      let labels =
        Masc_mcp.Tool_keeper.maybe_append_keeper_fallback_models
          ["ollama:glm-4.7-flash"]
      in
      let ollama_listening =
        Sys.command "lsof -iTCP:11434 -sTCP:LISTEN -t >/dev/null 2>&1" = 0
      in
      let expected =
        if ollama_listening then
          ["ollama:glm-4.7-flash"]
        else
          ["ollama:glm-4.7-flash"; "glm:glm-4.7"]
      in
      check (list string) "append glm fallback only when local runtime unavailable"
        expected labels)

let test_llm_client_sanitize_message_utf8_repairs_invalid_fields () =
  let raw =
    {
      Masc_mcp.Llm_client.role = Masc_mcp.Llm_client.User;
      content = "hello\x80.world";
      name = Some "to\xFFol";
      tool_call_id = Some "id\x80";
    }
  in
  let sanitized = Masc_mcp.Llm_client.sanitize_message_utf8 raw in
  check bool "role preserved" true (sanitized.role = raw.role);
  check bool "content valid utf8" true (string_is_valid_utf8 sanitized.content);
  check bool "content changed" true (sanitized.content <> raw.content);
  check bool "name valid utf8" true
    (match sanitized.name with Some v -> string_is_valid_utf8 v | None -> false);
  check bool "tool_call_id valid utf8" true
    (match sanitized.tool_call_id with Some v -> string_is_valid_utf8 v | None -> false);
  check bool "name kept present" true (Option.is_some sanitized.name);
  check bool "tool_call_id kept present" true (Option.is_some sanitized.tool_call_id)

let test_llm_client_sanitize_messages_utf8_preserves_message_count () =
  let msgs =
    [
      Masc_mcp.Llm_client.user_msg "ok\x80";
      Masc_mcp.Llm_client.assistant_msg "fine\xFF";
    ]
  in
  let sanitized = Masc_mcp.Llm_client.sanitize_messages_utf8 msgs in
  check int "count preserved" 2 (List.length sanitized);
  check bool "all valid utf8" true
    (List.for_all
       (fun (msg : Masc_mcp.Llm_client.message) -> string_is_valid_utf8 msg.content)
       sanitized)

let () =
  run "Tool_keeper" [
    ("read_file_tail_lines", [
         test_case "drops partial first line" `Quick test_read_file_tail_lines_drops_partial_first_line;
         test_case "keeps line-boundary start" `Quick test_read_file_tail_lines_keeps_line_boundary_start;
         test_case "fallback labels prefer available remote models" `Quick
           test_keeper_fallback_model_labels_prefers_available_remote_models;
         test_case "append glm fallback for local only model" `Quick
           test_maybe_append_keeper_fallback_models_adds_glm_when_local_only;
         test_case "llm client repairs invalid utf8 fields" `Quick
           test_llm_client_sanitize_message_utf8_repairs_invalid_fields;
         test_case "llm client preserves message list size" `Quick
           test_llm_client_sanitize_messages_utf8_preserves_message_count;
       ]);
  ]
