open Alcotest

module P = Llm_provider.Types
module Keeper_mcp_content = Masc.Keeper_mcp_content

let result ?structured content : Mcp_client.tool_result =
  { is_error = false
  ; text = "preflattened text must not enter the projection"
  ; content = `List content
  ; structured_content = structured
  }

let text value = `Assoc [ "type", `String "text"; "text", `String value ]

let media kind mime bytes =
  `Assoc [ "type", `String kind; "mimeType", `String mime
         ; "data", `String (Base64.encode_string bytes) ]

let audience roles = `Assoc [ "audience", `List (List.map (fun role -> `String role) roles) ]

let annotated annotations = function
  | `Assoc fields -> `Assoc (("annotations", annotations) :: fields)
  | _ -> fail "fixture content must be an object"

let project raw = match Keeper_mcp_content.project raw with
  | Ok projected -> projected
  | Error detail -> fail detail

let items projected = Option.value projected.Keeper_mcp_content.content_blocks ~default:[]

let blocks projected = List.map (function
  | Keeper_mcp_content.Native_block block -> block
  | Keeper_mcp_content.Binary_resource _ -> fail "expected native content") (items projected)

let kind = function
  | P.Text _ -> "text"
  | P.Image _ -> "image"
  | P.Audio _ -> "audio"
  | P.Document _ -> "document"
  | P.Thinking _ | P.RedactedThinking _ | P.ReasoningDetails _ -> "reasoning"
  | P.ToolReference _ -> "tool_reference"
  | P.ToolUse _ | P.ToolResult _ -> "tool"

let text_blocks values = List.filter_map (function
  | P.Text text -> Some text
  | P.Image _ | P.Audio _ | P.Document _ | P.Thinking _ | P.RedactedThinking _
  | P.ReasoningDetails _ | P.ToolUse _ | P.ToolReference _ | P.ToolResult _ -> None) values

let media_payload = function
  | P.Image { media_type; source = P.Base64 data }
  | P.Audio { media_type; source = P.Base64 data }
  | P.Document { media_type; source = P.Base64 data } -> media_type, Base64.decode_exn data
  | P.Image { source = (P.Url _ | P.File_id _); _ }
  | P.Audio { source = (P.Url _ | P.File_id _); _ }
  | P.Document { source = (P.Url _ | P.File_id _); _ }
  | P.Text _ | P.Thinking _ | P.RedactedThinking _ | P.ReasoningDetails _
  | P.ToolUse _ | P.ToolReference _ | P.ToolResult _ -> fail "expected a native base64 media block"

let check_refused raw = match Keeper_mcp_content.project raw with
  | Error _ -> ()
  | Ok _ -> fail "malformed or unsupported result was accepted"

let test_mixed_content_keeps_order_and_structured_output () =
  let raw = result ~structured:(`Assoc [ "answer", `Int 42 ])
    [ text "first"; media "image" "image/png" "image bytes"
    ; media "audio" "audio/wav" "audio bytes"; text "last" ] in
  let before = Yojson.Safe.to_string raw.content in
  let projected = project raw in
  check (list string) "all model blocks in order"
    [ "text"; "image"; "audio"; "text"; "text" ]
    (List.map kind (blocks projected));
  check (list string) "plain text and structured output coexist"
    [ "first"; "last"; "structuredContent: {\"answer\":42}" ]
    (text_blocks (blocks projected));
  let image_mime, image = media_payload (List.nth (blocks projected) 1) in
  let audio_mime, audio = media_payload (List.nth (blocks projected) 2) in
  check string "image MIME" "image/png" image_mime;
  check string "image bytes" "image bytes" image;
  check string "audio MIME" "audio/wav" audio_mime;
  check string "audio bytes" "audio bytes" audio;
  check string "source envelope remains unchanged" before (Yojson.Safe.to_string raw.content)

let test_audience_filters_every_payload_kind () =
  let visible = annotated (audience [ "assistant" ]) (text "assistant-visible") in
  let shared = annotated (audience [ "user"; "assistant" ]) (text "shared") in
  let hidden value = annotated (audience [ "user" ]) value in
  let projected = project (result
    [ text "unrestricted"; visible; shared
    ; hidden (text "private text")
    ; hidden (media "image" "image/png" "private image")
    ; hidden (media "audio" "audio/wav" "private audio")
    ; hidden (`Assoc [ "type", `String "resource_link"; "uri", `String "private:link" ])
    ; hidden (`Assoc [ "type", `String "resource"; "resource", `Assoc
        [ "uri", `String "private:resource"; "text", `String "private resource" ] ])
    ; hidden (`Assoc [ "type", `String "resource"; "resource", `Assoc
        [ "uri", `String "private:binary"; "blob", `String "cHJpdmF0ZQ==" ] ])
    ; annotated (audience []) (text "nobody") ]) in
  check (list string) "only assistant-visible text survives"
    [ "unrestricted"; "assistant-visible"; "shared" ]
    (text_blocks (blocks projected));
  check string "fallback also excludes private payloads"
    "unrestricted\nassistant-visible\nshared" projected.content;
  let hidden_only = project (result [ hidden (text "private") ]) in
  check string "hidden-only fallback is empty" "" hidden_only.content;
  check bool "no block can expose hidden content" true (Option.is_none hidden_only.content_blocks)

let test_malformed_annotations_and_duplicate_keys_fail_closed () =
  List.iter (fun annotations ->
    check_refused (result [ annotated annotations (text "private") ]))
    [ `Null
    ; `Assoc [ "audience", `String "user" ]
    ; `Assoc [ "audience", `List [ `String "assistant"; `String "unknown" ] ]
    ; `Assoc [ "audience", `List [ `String "user" ]; "audience", `List [ `String "assistant" ] ]
    ; `Assoc [ "priority", `String "1" ]
    ; `Assoc [ "priority", `Int 2 ] ];
  check_refused (result [ `Assoc
    [ "type", `String "text"; "text", `String "first"; "text", `String "second" ] ]);
  check_refused (result [ `Assoc
    [ "type", `String "text"; "text", `String "private"
    ; "annotations", audience [ "user" ]; "annotations", audience [ "assistant" ] ] ]);
  check string "integer priority is valid" "visible"
    (project (result [ annotated (`Assoc [ "priority", `Int 1 ]) (text "visible") ])).content

let resource fields = `Assoc [ "type", `String "resource"; "resource", `Assoc fields ]

let test_resources_keep_declared_content_and_links () =
  let text_resource = resource [ "uri", `String "memo:one"; "text", `String "memo body" ] in
  let blob mime = resource [ "uri", `String "resource:one"; "mimeType", `String mime
                          ; "blob", `String (Base64.encode_string "resource bytes") ] in
  List.iter (fun (mime, expected) ->
    check (list string) "resource MIME determines native payload"
      [ "text"; expected ]
      (project (result [ blob mime ]) |> blocks |> List.map kind))
    [ "image/png", "image"; "audio/wav", "audio"; "application/pdf", "document" ];
  let uppercase = project (result [ blob " IMAGE/PNG " ]) |> blocks in
  check string "case-insensitive image MIME is normalized for delivery"
    "image/png" (fst (media_payload (List.nth uppercase 1)));
  let parameterized = project (result [ blob "audio/wav; rate=16000" ]) |> blocks in
  check string "resource classification preserves MIME parameters"
    "audio/wav; rate=16000" (fst (media_payload (List.nth parameterized 1)));
  let texts = project (result [ text_resource ]) |> blocks |> text_blocks in
  check int "resource reference and body stay separate" 2 (List.length texts);
  check string "resource text body" "memo body" (List.nth texts 1);
  let link = `Assoc [ "type", `String "resource_link"; "uri", `String "custom:never-fetch"
                    ; "name", `String "reference"; "mimeType", `String "application/octet-stream" ] in
  check (list string) "a link remains text" [ "text" ]
    (project (result [ link ]) |> blocks |> List.map kind)

let test_generic_binary_resources_preserve_bytes_without_native_guessing () =
  List.iter (fun (mime, bytes) ->
    let mime_fields = match mime with None -> [] | Some value -> [ "mimeType", `String value ] in
    let raw = result [ text "before"; resource
      ([ "uri", `String "archive:one"; "blob", `String (Base64.encode_string bytes) ] @ mime_fields)
      ; text "after" ] in
    match items (project raw) with
    | [ Keeper_mcp_content.Native_block (P.Text "before")
      ; Keeper_mcp_content.Native_block (P.Text _)
      ; Keeper_mcp_content.Binary_resource actual
      ; Keeper_mcp_content.Native_block (P.Text "after") ] ->
      check string "resource URI remains a reference" "archive:one" actual.uri;
      check (option string) "MIME declaration including absence is preserved" mime actual.mime_type;
      check string "exact resource bytes" bytes actual.bytes
    | _ -> fail "binary resource or sibling text was lost or retyped")
    [ Some "application/zip", "PK\003\004archive"
    ; Some "application/octet-stream", "\000\255"
    ; None, "untyped bytes"
    ; None, "" ]

let test_ambiguous_and_malformed_resources_are_refused () =
  List.iter (fun fields -> check_refused (result [ resource fields ]))
    [ [ "uri", `String "r:"; "text", `String "text"; "blob", `String "YQ==" ]
    ; [ "uri", `String "r:"; "blob", `String "not base64" ]
    ; [ "uri", `String "r:"; "blob", `String "YQ=="; "mimeType", `String "application/pdf"
      ; "mime_type", `String "image/png" ]
    ; [ "uri", `String "r:"; "text", `Bool true ] ];
  check_refused (result [ `Assoc [ "type", `String "resource_link"; "uri", `String "r:"
                               ; "name", `Bool false ] ])

let test_invalid_media_and_unknown_items_do_not_echo_source () =
  List.iter (fun data -> check_refused (result [ `Assoc
    [ "type", `String "image"; "mimeType", `String "image/png"; "data", `String data ] ]))
    [ ""; "not base64"; "YQ"; "YQ==\n" ];
  let unknown = result [ `Assoc [ "type", `String "PRIVATE_PAYLOAD"; "text", `String "SECRET" ] ] in
  (match Keeper_mcp_content.project unknown with
   | Ok _ -> fail "unknown item accepted"
   | Error detail -> check string "diagnostic includes no source bytes"
       "MCP content[0]: unsupported or malformed content item" detail);
  check_refused { (result []) with content = `String "not an array" }

let test_structured_only_result_and_hidden_text () =
  let structured = `List [ `Int 1; `String "two" ] in
  let projected = project (result ~structured
    [ annotated (audience [ "user" ]) (text "private") ]) in
  check string "structured-only text" "[1,\"two\"]" projected.content;
  check (list string) "structured output is authoritative content too"
    [ "[1,\"two\"]" ] (text_blocks (blocks projected))

let () = run "Keeper MCP content"
  [ "projection",
    [ test_case "mixed content and structured output" `Quick test_mixed_content_keeps_order_and_structured_output
    ; test_case "audience filtering" `Quick test_audience_filters_every_payload_kind
    ; test_case "strict annotations and duplicate fields" `Quick test_malformed_annotations_and_duplicate_keys_fail_closed
    ; test_case "resources and links" `Quick test_resources_keep_declared_content_and_links
    ; test_case "generic binary resources" `Quick test_generic_binary_resources_preserve_bytes_without_native_guessing
    ; test_case "resource ambiguity and shape" `Quick test_ambiguous_and_malformed_resources_are_refused
    ; test_case "invalid media and safe diagnostics" `Quick test_invalid_media_and_unknown_items_do_not_echo_source
    ; test_case "structured-only after audience filtering" `Quick test_structured_only_result_and_hidden_text
    ] ]
