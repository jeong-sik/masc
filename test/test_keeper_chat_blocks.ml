module B = Masc.Keeper_chat_blocks

let yojson_testable =
  Alcotest.testable
    (fun fmt json -> Format.fprintf fmt "%s" (Yojson.Safe.to_string json))
    ( = )

let dropped_reason_testable =
  Alcotest.testable
    (fun fmt reason -> Format.pp_print_string fmt (B.dropped_http_url_reason_to_string reason))
    ( = )

let blocks_to_json_list blocks =
  match B.blocks_to_yojson blocks with
  | `List items -> items
  | _ -> []

let test_plain_text_becomes_escaped_text_block () =
  let blocks = B.parse_text_to_blocks "hello <world>" in
  Alcotest.(check int) "one block" 1 (List.length blocks);
  Alcotest.(check (list yojson_testable))
    "escaped html"
    [ `Assoc [ ("t", `String "p"); ("html", `String "hello &lt;world&gt;") ] ]
    (blocks_to_json_list blocks)

let test_markdown_image_and_surrounding_text () =
  let blocks = B.parse_text_to_blocks "before ![alt text](https://example.com/a.png) after" in
  Alcotest.(check (list yojson_testable))
    "image with surrounding text"
    [
      `Assoc [ ("t", `String "p"); ("html", `String "before ") ];
      `Assoc
        [
          ("t", `String "image");
          ("src", `String "https://example.com/a.png");
          ("cap", `String "alt text");
        ];
      `Assoc [ ("t", `String "p"); ("html", `String " after") ];
    ]
    (blocks_to_json_list blocks)

let test_bare_image_url_on_own_line () =
  let blocks = B.parse_text_to_blocks "https://example.com/screen.webp" in
  Alcotest.(check (list yojson_testable))
    "image block"
    [ `Assoc [ ("t", `String "image"); ("src", `String "https://example.com/screen.webp") ] ]
    (blocks_to_json_list blocks)

let test_standalone_non_image_url_becomes_link () =
  let blocks = B.parse_text_to_blocks "https://example.com/post" in
  Alcotest.(check (list yojson_testable))
    "link block"
    [
      `Assoc
        [
          ("t", `String "link");
          ("url", `String "https://example.com/post");
          ("title", `String "example.com");
          ("meta", `String "example.com");
        ];
    ]
    (blocks_to_json_list blocks)

let test_inline_url_stays_in_text () =
  let blocks = B.parse_text_to_blocks "See https://example.com for more." in
  Alcotest.(check (list yojson_testable))
    "text block keeps inline url"
    [ `Assoc [ ("t", `String "p"); ("html", `String "See https://example.com for more.") ] ]
    (blocks_to_json_list blocks)

let test_code_fence_becomes_code_block () =
  let blocks = B.parse_text_to_blocks "before\n```OCaml\nlet x = 1 < 2\n```\nafter" in
  Alcotest.(check (list yojson_testable))
    "code block with surrounding text"
    [
      `Assoc [ ("t", `String "p"); ("html", `String "before") ];
      `Assoc
        [
          ("t", `String "code");
          ("html", `String "let x = 1 &lt; 2");
          ("cap", `String "ocaml");
          ("source", `String "let x = 1 < 2");
        ];
      `Assoc [ ("t", `String "p"); ("html", `String "after") ];
    ]
    (blocks_to_json_list blocks)

let test_code_fence_preserves_markdown_image_literal () =
  let blocks =
    B.parse_text_to_blocks "```md\n![alt](https://example.com/a.png)\n```"
  in
  Alcotest.(check (list yojson_testable))
    "image syntax inside code stays code"
    [
      `Assoc
        [
          ("t", `String "code");
          ("html", `String "![alt](https://example.com/a.png)");
          ("cap", `String "md");
          ("source", `String "![alt](https://example.com/a.png)");
        ];
    ]
    (blocks_to_json_list blocks)

let test_mermaid_fence_becomes_mermaid_block () =
  let blocks = B.parse_text_to_blocks "```mermaid\ngraph TD\nA-->B\n```" in
  Alcotest.(check (list yojson_testable))
    "mermaid block"
    [
      `Assoc
        [
          ("t", `String "mermaid");
          ("source", `String "graph TD\nA-->B");
        ];
    ]
    (blocks_to_json_list blocks)

let test_multiple_images_and_text_lines () =
  let blocks = B.parse_text_to_blocks "intro\n![a](https://x.com/1.jpg)\nhttps://x.com/2.gif\noutro" in
  Alcotest.(check (list yojson_testable))
    "mixed blocks in order"
    [
      `Assoc [ ("t", `String "p"); ("html", `String "intro") ];
      `Assoc [ ("t", `String "image"); ("src", `String "https://x.com/1.jpg"); ("cap", `String "a") ];
      `Assoc [ ("t", `String "image"); ("src", `String "https://x.com/2.gif") ];
      `Assoc [ ("t", `String "p"); ("html", `String "outro") ];
    ]
    (blocks_to_json_list blocks)

let test_empty_lines_ignored () =
  let blocks = B.parse_text_to_blocks "line1\n\nline2" in
  Alcotest.(check int) "two blocks" 2 (List.length blocks);
  Alcotest.(check (list string)) "text order"
    [ "line1"; "line2" ]
    (List.map
       (fun block ->
          match B.block_to_yojson block with
          | `Assoc fields -> (
              match List.assoc_opt "html" fields with
              | Some (`String s) -> s
              | _ -> "")
          | _ -> "")
       blocks)

let test_link_without_www () =
  let blocks = B.parse_text_to_blocks "https://www.example.com/post" in
  Alcotest.(check (list yojson_testable))
    "www stripped"
    [
      `Assoc
        [
          ("t", `String "link");
          ("url", `String "https://www.example.com/post");
          ("title", `String "example.com");
          ("meta", `String "example.com");
        ];
    ]
    (blocks_to_json_list blocks)

let test_blocks_of_yojson_roundtrip () =
  let original = B.parse_text_to_blocks "text\n![a](https://x.com/a.png)\nhttps://x.com/post" in
  let json = B.blocks_to_yojson original in
  match B.blocks_of_yojson json with
  | Some parsed ->
    Alcotest.(check int) "roundtrip length" (List.length original) (List.length parsed);
    Alcotest.(check (list yojson_testable))
      "roundtrip json"
      (blocks_to_json_list original)
      (blocks_to_json_list parsed)
  | None -> Alcotest.fail "blocks_of_yojson rejected valid blocks"

let test_code_block_roundtrip () =
  let original =
    [ B.Code { cap = Some "sh"; html = "echo &lt;ok&gt;"; source = Some "echo <ok>" } ]
  in
  match B.blocks_of_yojson (B.blocks_to_yojson original) with
  | Some parsed ->
    Alcotest.(check (list yojson_testable))
      "code roundtrip json"
      (blocks_to_json_list original)
    (blocks_to_json_list parsed)
  | None -> Alcotest.fail "blocks_of_yojson rejected valid code block"

let test_dashboard_rich_blocks_roundtrip () =
  let original =
    [
      B.Heading { html = "Plan" };
      B.Unordered_list { items = [ "one"; "two" ] };
      B.Callout { severity = Some "warn"; html = "check this" };
      B.Table
        {
          head =
            [
              B.Cell_text "name";
              B.Cell_value { v = "count"; num = Some true; muted = None };
            ];
          rows = [ [ B.Cell_text "alpha"; B.Cell_text "2" ] ];
        };
      B.Mermaid { source = "graph TD\nA-->B"; caption = Some "flow" };
      B.Svg { svg = "<svg></svg>"; cap = Some "mark" };
      B.Voice
        {
          secs = Some 3.5;
          wave = Some [ 0.1; 0.8 ];
          via = Some "tts";
          size = Some "24 KB";
          transcript = Some "hello";
          src = Some "https://example.com/a.mp3";
        };
      B.Attach
        {
          name = "clip.mp4";
          dims = Some "1920x1080";
          src = Some "https://example.com/clip.mp4";
          svg = None;
          ph = None;
          via = Some "gate";
          size = Some "8 MB";
          data = None;
          mime_type = Some "video/mp4";
          size_bytes = Some 42;
          kind = Some "video";
        };
      B.Trace
        {
          trace =
            [
              B.Trace_think
                {
                  text = "checking";
                  ts = Some "2026-07-01T00:00:00Z";
                  oas_block_index = Some 0;
                };
              B.Trace_tool
                {
                  name = "keeper_tasks_list";
                  tool_call_id = Some "exec-1";
                  status = Some B.Trace_tool_ok;
                  dur = Some "2ms";
                  args = Some (`Assoc [ ("limit", `Int 5) ]);
                  result = Some (`Assoc [ ("ok", `Bool true) ]);
                  ts = Some "2026-07-01T00:00:01Z";
                  oas_block_index = Some 1;
                };
              B.Trace_reason
                {
                  text = "done";
                  detail = Some "visible";
                  ts = Some "2026-07-01T00:00:02Z";
                };
            ];
        };
    ]
  in
  match B.blocks_of_yojson (B.blocks_to_yojson original) with
  | Some parsed ->
    Alcotest.(check (list yojson_testable))
      "dashboard rich block json"
      (blocks_to_json_list original)
      (blocks_to_json_list parsed)
  | None -> Alcotest.fail "blocks_of_yojson rejected valid dashboard rich blocks"

let test_trace_decoder_accepts_dashboard_fallbacks () =
  let json =
    `List
      [ `Assoc
          [ ("t", `String "trace")
          ; ( "trace"
            , `List
                [ `Assoc
                    [ ("kind", `String "think")
                    ; ("text", `String "thinking")
                    ; ("oasBlockIndex", `Int 7)
                    ]
                ; `Assoc
                    [ ("kind", `String "tool")
                    ; ("name", `String "keeper_tasks_list")
                    ; ("status", `String "paused")
                    ; ("oasBlockIndex", `Int 8)
                    ]
                ] )
          ]
      ]
  in
  match B.blocks_of_yojson json with
  | Some
      [ B.Trace
          { trace =
              [ B.Trace_think { oas_block_index = Some 7; _ }
              ; B.Trace_tool { status = None; oas_block_index = Some 8; _ }
              ]
          }
      ] -> ()
  | Some _ -> Alcotest.fail "unexpected trace block shape"
  | None -> Alcotest.fail "trace decoder rejected dashboard-compatible fields"

let test_non_http_markdown_image_becomes_text () =
  let blocks = B.parse_text_to_blocks "before ![alt](ftp://example.com/a.png) after" in
  Alcotest.(check (list yojson_testable))
    "non-http markdown image falls back to escaped text fragments"
    [
      `Assoc [ ("t", `String "p"); ("html", `String "before ") ];
      `Assoc [ ("t", `String "p"); ("html", `String "![alt](ftp://example.com/a.png)") ];
      `Assoc [ ("t", `String "p"); ("html", `String " after") ];
    ]
    (blocks_to_json_list blocks)

let test_non_http_bare_url_becomes_text () =
  let blocks = B.parse_text_to_blocks "ftp://example.com/a.png" in
  Alcotest.(check (list yojson_testable))
    "non-http bare url falls back to escaped text"
    [ `Assoc [ ("t", `String "p"); ("html", `String "ftp://example.com/a.png") ] ]
    (blocks_to_json_list blocks)

let test_case_insensitive_standalone_url () =
  let blocks = B.parse_text_to_blocks "HTTPS://EXAMPLE.COM/IMG.PNG" in
  Alcotest.(check (list yojson_testable))
    "uppercase scheme and extension are accepted"
    [ `Assoc [ ("t", `String "image"); ("src", `String "HTTPS://EXAMPLE.COM/IMG.PNG") ] ]
    (blocks_to_json_list blocks)

let test_query_string_stripped_for_extension_check () =
  let blocks = B.parse_text_to_blocks "https://example.com/a.png?w=100" in
  Alcotest.(check (list yojson_testable))
    "query string does not prevent image detection"
    [ `Assoc [ ("t", `String "image"); ("src", `String "https://example.com/a.png?w=100") ] ]
    (blocks_to_json_list blocks)

let test_redacted_http_url_opt_reports_drop_reason () =
  let drops = ref [] in
  let on_drop reason = drops := reason :: !drops in
  Alcotest.(check (option string))
    "http accepted"
    (Some "https://example.com/a.png")
    (B.redacted_http_url_opt ~on_drop "https://example.com/a.png");
  Alcotest.(check (list dropped_reason_testable)) "no drop" [] !drops;
  Alcotest.(check (option string))
    "ftp dropped"
    None
    (B.redacted_http_url_opt ~on_drop "ftp://example.com/a.png");
  Alcotest.(check (list dropped_reason_testable))
    "unsupported scheme recorded"
    [ B.Unsupported_scheme "ftp" ]
    !drops;
  drops := [];
  Alcotest.(check (option string))
    "missing scheme dropped"
    None
    (B.redacted_http_url_opt ~on_drop "example.com/a.png");
  Alcotest.(check (list dropped_reason_testable))
    "missing scheme recorded"
    [ B.Missing_scheme ]
    !drops

let test_blocks_of_yojson_rejects_malformed () =
  Alcotest.(check bool) "not a list" true (B.blocks_of_yojson (`String "x") = None);
  Alcotest.(check bool) "empty list" true (B.blocks_of_yojson (`List []) = None);
  Alcotest.(check bool) "unknown tag"
    true
    (B.blocks_of_yojson (`List [ `Assoc [ ("t", `String "unknown") ] ]) = None)

(* RFC-0252: the fusion block wire shape is the contract the dashboard zod
   schema mirrors (t=fusion, snake_case ids). Pin it so a drift breaks here. *)
let test_fusion_block_roundtrip () =
  let original = [ B.Fusion { board_post_id = "p-abc123"; run_id = "fus-2583b65c" } ] in
  Alcotest.(check (list yojson_testable))
    "fusion block json shape"
    [
      `Assoc
        [
          ("t", `String "fusion");
          ("board_post_id", `String "p-abc123");
          ("run_id", `String "fus-2583b65c");
        ];
    ]
    (blocks_to_json_list original);
  match B.blocks_of_yojson (B.blocks_to_yojson original) with
  | Some parsed ->
    Alcotest.(check (list yojson_testable))
      "fusion roundtrip json"
      (blocks_to_json_list original)
      (blocks_to_json_list parsed)
  | None -> Alcotest.fail "blocks_of_yojson rejected valid fusion block"

let test_fusion_block_requires_board_post_id () =
  Alcotest.(check bool) "missing board_post_id rejected"
    true
    (B.blocks_of_yojson (`List [ `Assoc [ ("t", `String "fusion"); ("run_id", `String "fus-1") ] ])
     = None)

let test_fusion_block_tolerates_missing_run_id () =
  (* run_id is a display convenience; board_post_id alone is a valid card. *)
  match B.blocks_of_yojson (`List [ `Assoc [ ("t", `String "fusion"); ("board_post_id", `String "p-1") ] ]) with
  | Some [ B.Fusion { board_post_id = "p-1"; run_id = "" } ] -> ()
  | _ -> Alcotest.fail "fusion block with board_post_id only should decode with empty run_id"

(* RFC-0302: the thinking block wire shape is the contract the dashboard
   schema mirrors (t=thinking, content required, redacted omitted when
   false). Pin it so a drift breaks here. *)
let test_thinking_block_roundtrip () =
  let original = [ B.Thinking { content = "considering options"; redacted = false } ] in
  Alcotest.(check (list yojson_testable))
    "thinking block json shape (redacted false omitted)"
    [ `Assoc [ ("t", `String "thinking"); ("content", `String "considering options") ] ]
    (blocks_to_json_list original);
  match B.blocks_of_yojson (B.blocks_to_yojson original) with
  | Some parsed ->
    Alcotest.(check (list yojson_testable))
      "thinking roundtrip json"
      (blocks_to_json_list original)
      (blocks_to_json_list parsed)
  | None -> Alcotest.fail "blocks_of_yojson rejected valid thinking block"

let test_redacted_thinking_block_roundtrip () =
  (* Signature-only RedactedThinking: content is [""] and redacted is emitted
     so the dashboard renders a placeholder rather than an empty card. *)
  let original = [ B.Thinking { content = ""; redacted = true } ] in
  Alcotest.(check (list yojson_testable))
    "redacted thinking block json shape"
    [ `Assoc
        [ ("t", `String "thinking"); ("content", `String ""); ("redacted", `Bool true) ]
    ]
    (blocks_to_json_list original);
  (match B.blocks_of_yojson (B.blocks_to_yojson original) with
   | Some [ B.Thinking { content = ""; redacted = true } ] -> ()
   | _ -> Alcotest.fail "redacted thinking block should roundtrip with redacted=true")

let test_thinking_block_requires_content () =
  Alcotest.(check bool) "missing content rejected"
    true
    (B.blocks_of_yojson
       (`List [ `Assoc [ ("t", `String "thinking"); ("redacted", `Bool true) ] ])
     = None)

let () =
  Alcotest.run "keeper_chat_blocks"
    [
      ( "parse",
        [
          Alcotest.test_case "plain text becomes escaped text block" `Quick
            test_plain_text_becomes_escaped_text_block;
          Alcotest.test_case "markdown image and surrounding text" `Quick
            test_markdown_image_and_surrounding_text;
          Alcotest.test_case "bare image url on own line" `Quick
            test_bare_image_url_on_own_line;
          Alcotest.test_case "standalone non-image url becomes link" `Quick
            test_standalone_non_image_url_becomes_link;
          Alcotest.test_case "inline url stays in text" `Quick
            test_inline_url_stays_in_text;
          Alcotest.test_case "code fence becomes code block" `Quick
            test_code_fence_becomes_code_block;
          Alcotest.test_case "code fence preserves markdown image literal" `Quick
            test_code_fence_preserves_markdown_image_literal;
          Alcotest.test_case "mermaid fence becomes mermaid block" `Quick
            test_mermaid_fence_becomes_mermaid_block;
          Alcotest.test_case "multiple images and text lines" `Quick
            test_multiple_images_and_text_lines;
          Alcotest.test_case "empty lines ignored" `Quick
            test_empty_lines_ignored;
          Alcotest.test_case "www stripped from hostname" `Quick
            test_link_without_www;
          Alcotest.test_case "non-http markdown image becomes text" `Quick
            test_non_http_markdown_image_becomes_text;
          Alcotest.test_case "non-http bare url becomes text" `Quick
            test_non_http_bare_url_becomes_text;
          Alcotest.test_case "case-insensitive standalone url" `Quick
            test_case_insensitive_standalone_url;
          Alcotest.test_case "query string stripped for extension check" `Quick
            test_query_string_stripped_for_extension_check;
          Alcotest.test_case "redacted_http_url_opt reports drop reason" `Quick
            test_redacted_http_url_opt_reports_drop_reason;
        ] );
      ( "serialization",
        [
          Alcotest.test_case "blocks roundtrip through yojson" `Quick
            test_blocks_of_yojson_roundtrip;
          Alcotest.test_case "code block roundtrip" `Quick
            test_code_block_roundtrip;
           Alcotest.test_case "dashboard rich blocks roundtrip" `Quick
             test_dashboard_rich_blocks_roundtrip;
           Alcotest.test_case "trace decoder accepts dashboard fallbacks" `Quick
             test_trace_decoder_accepts_dashboard_fallbacks;
           Alcotest.test_case "blocks_of_yojson rejects malformed" `Quick
             test_blocks_of_yojson_rejects_malformed;
          Alcotest.test_case "fusion block roundtrip" `Quick
            test_fusion_block_roundtrip;
          Alcotest.test_case "fusion block requires board_post_id" `Quick
            test_fusion_block_requires_board_post_id;
          Alcotest.test_case "fusion block tolerates missing run_id" `Quick
            test_fusion_block_tolerates_missing_run_id;
          Alcotest.test_case "thinking block roundtrip" `Quick
            test_thinking_block_roundtrip;
          Alcotest.test_case "redacted thinking block roundtrip" `Quick
            test_redacted_thinking_block_roundtrip;
          Alcotest.test_case "thinking block requires content" `Quick
            test_thinking_block_requires_content;
        ] );
    ]
