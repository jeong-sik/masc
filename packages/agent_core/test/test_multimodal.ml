(** Tests for Image and Document content block serialization round-trips *)

open Agent_sdk

(* Helper: compare content_block via show string since no eq deriving *)
let check_block msg expected actual =
  Alcotest.(check string)
    msg
    (Types.show_content_block expected)
    (Types.show_content_block actual)
;;

(* ------------------------------------------------------------------ *)
(* Round-trip: Image                                                    *)
(* ------------------------------------------------------------------ *)

let test_image_round_trip () =
  let img =
    Types.Image
      { media_type = "image/png"
      ; data =
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
      ; source_type = Types.Base64
      }
  in
  let json = Llm_provider.Api_common.content_block_to_json img in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some parsed -> check_block "image round-trip" img parsed
  | None -> Alcotest.fail "content_block_of_json returned None for Image"
;;

(* ------------------------------------------------------------------ *)
(* Round-trip: Document                                                 *)
(* ------------------------------------------------------------------ *)

let test_document_round_trip () =
  let doc =
    Types.Document
      { media_type = "application/pdf"
      ; data = "JVBERi0xLjQKMSAwIG9iago8PAovVHlwZSAvQ2F0YWxvZwo+Pg=="
      ; source_type = Types.Base64
      }
  in
  let json = Llm_provider.Api_common.content_block_to_json doc in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some parsed -> check_block "document round-trip" doc parsed
  | None -> Alcotest.fail "content_block_of_json returned None for Document"
;;

let test_image_url_round_trip () =
  let img =
    Types.Image
      { media_type = "image/png"
      ; data = "https://example.invalid/image.png"
      ; source_type = Types.Url
      }
  in
  let json = Llm_provider.Api_common.content_block_to_json img in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some parsed -> check_block "image url round-trip" img parsed
  | None -> Alcotest.fail "content_block_of_json returned None for URL Image"
;;

let test_document_file_id_round_trip () =
  let doc =
    Types.Document
      { media_type = "application/pdf"
      ; data = "file_abc123"
      ; source_type = Types.File_id
      }
  in
  let json = Llm_provider.Api_common.content_block_to_json doc in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some parsed -> check_block "document file_id round-trip" doc parsed
  | None -> Alcotest.fail "content_block_of_json returned None for file_id Document"
;;

(* ------------------------------------------------------------------ *)
(* Parsing: Image with nested source                                    *)
(* ------------------------------------------------------------------ *)

let test_image_parse_nested_source () =
  let json =
    `Assoc
      [ "type", `String "image"
      ; ( "source"
        , `Assoc
            [ "type", `String "base64"
            ; "media_type", `String "image/jpeg"
            ; "data", `String "abc123"
            ] )
      ]
  in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some (Types.Image { media_type; data; source_type }) ->
    Alcotest.(check string) "media_type" "image/jpeg" media_type;
    Alcotest.(check string) "data" "abc123" data;
    Alcotest.(check string)
      "source_type"
      "base64"
      (Types.media_source_kind_to_string source_type)
  | Some _ -> Alcotest.fail "expected Image variant"
  | None -> Alcotest.fail "content_block_of_json returned None"
;;

(* ------------------------------------------------------------------ *)
(* Parsing: Document with nested source                                 *)
(* ------------------------------------------------------------------ *)

let test_document_parse_nested_source () =
  let json =
    `Assoc
      [ "type", `String "document"
      ; ( "source"
        , `Assoc
            [ "type", `String "base64"
            ; "media_type", `String "application/pdf"
            ; "data", `String "pdf_data_here"
            ] )
      ]
  in
  match Llm_provider.Api_common.content_block_of_json json with
  | Some (Types.Document { media_type; data; source_type }) ->
    Alcotest.(check string) "media_type" "application/pdf" media_type;
    Alcotest.(check string) "data" "pdf_data_here" data;
    Alcotest.(check string)
      "source_type"
      "base64"
      (Types.media_source_kind_to_string source_type)
  | Some _ -> Alcotest.fail "expected Document variant"
  | None -> Alcotest.fail "content_block_of_json returned None"
;;

(* ------------------------------------------------------------------ *)
(* Malformed Image/Document JSON                                        *)
(* ------------------------------------------------------------------ *)

let test_malformed_image_missing_source () =
  let json = `Assoc [ "type", `String "image" ] in
  match Llm_provider.Api_common.content_block_of_json json with
  | None -> ()
  | exception _ -> ()
  | Some _ -> Alcotest.fail "expected None or exception for malformed Image"
;;

let test_malformed_document_missing_source () =
  let json = `Assoc [ "type", `String "document" ] in
  match Llm_provider.Api_common.content_block_of_json json with
  | None -> ()
  | exception _ -> ()
  | Some _ -> Alcotest.fail "expected None or exception for malformed Document"
;;

let check_unknown_media_source_kind_fails_closed ~block_type ~media_type ~data =
  let json =
    `Assoc
      [ "type", `String block_type
      ; ( "source"
        , `Assoc
            [ "type", `String "unknown_source"
            ; "media_type", `String media_type
            ; "data", `String data
            ] )
      ]
  in
  match Llm_provider.Api_common.content_block_of_json json with
  | None -> ()
  | Some _ -> Alcotest.failf "unsupported %s media source kind must not parse" block_type
;;

let test_unknown_image_source_kind_fails_closed () =
  check_unknown_media_source_kind_fails_closed
    ~block_type:"image"
    ~media_type:"image/png"
    ~data:"https://example.invalid/image.png"
;;

let test_unknown_document_source_kind_fails_closed () =
  check_unknown_media_source_kind_fails_closed
    ~block_type:"document"
    ~media_type:"application/pdf"
    ~data:"https://example.invalid/document.pdf"
;;

let test_unknown_audio_source_kind_fails_closed () =
  check_unknown_media_source_kind_fails_closed
    ~block_type:"audio"
    ~media_type:"audio/wav"
    ~data:"https://example.invalid/audio.wav"
;;

(* ------------------------------------------------------------------ *)
(* Mixed content: Text + Image + Document                               *)
(* ------------------------------------------------------------------ *)

let test_mixed_content_serialization () =
  let blocks =
    [ Types.Text "Here is an image:"
    ; Types.Image
        { media_type = "image/png"; data = "base64data"; source_type = Types.Base64 }
    ; Types.Document
        { media_type = "application/pdf"; data = "pdfdata"; source_type = Types.Base64 }
    ]
  in
  let json_list = List.map Llm_provider.Api_common.content_block_to_json blocks in
  let parsed = List.filter_map Llm_provider.Api_common.content_block_of_json json_list in
  Alcotest.(check int) "all 3 blocks parsed" 3 (List.length parsed);
  List.iter2
    (fun expected actual -> check_block "mixed content" expected actual)
    blocks
    parsed
;;

let test_multimodal_constructors () =
  let image = Types.image_block ~media_type:"image/png" ~data:"img" () in
  let document = Types.document_block ~media_type:"application/pdf" ~data:"pdf" () in
  let audio = Types.audio_block ~media_type:"audio/wav" ~data:"wav" () in
  let msg =
    Types.user_msg_blocks [ Types.text_block "Describe"; image; document; audio ]
  in
  Alcotest.(check string) "role" "user" (Types.role_to_string msg.role);
  Alcotest.(check int) "blocks" 4 (List.length msg.content);
  match image, document, audio with
  | ( Types.Image { source_type = Types.Base64; media_type = "image/png"; _ }
    , Types.Document { source_type = Types.Base64; media_type = "application/pdf"; _ }
    , Types.Audio { source_type = Types.Base64; media_type = "audio/wav"; _ } ) -> ()
  | _ -> Alcotest.fail "unexpected multimodal constructor shape"
;;

let test_agent_run_blocks_rejects_internal_blocks () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let agent =
    Agent.create ~config:(Types.default_config ~model:"test-model") ~net:env#net ()
  in
  let blocks = [ Types.ToolUse { id = "call-1"; name = "x"; input = `Null } ] in
  (match Agent.run_blocks ~sw agent blocks with
   | Error (Error.Config (Error.InvalidConfig { field = "user_blocks"; _ })) -> ()
   | Ok _ -> Alcotest.fail "expected invalid config"
   | Error err -> Alcotest.fail ("unexpected error: " ^ Error.to_string err));
  Alcotest.(check int) "state unchanged" 0 (List.length (Agent.state agent).messages)
;;

let test_agent_run_with_handoffs_blocks_rejects_internal_blocks () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let agent =
    Agent.create ~config:(Types.default_config ~model:"test-model") ~net:env#net ()
  in
  let blocks =
    [ Types.ToolResult
        { tool_use_id = "call-1"
        ; content = "internal result"
        ; outcome = Tool_succeeded
        ; json = None
        ; content_blocks = None
        }
    ]
  in
  (match Agent.run_with_handoffs_blocks ~sw agent ~targets:[] blocks with
   | Error (Error.Config (Error.InvalidConfig { field = "user_blocks"; _ })) -> ()
   | Ok _ -> Alcotest.fail "expected invalid config"
   | Error err -> Alcotest.fail ("unexpected error: " ^ Error.to_string err));
  Alcotest.(check int) "state unchanged" 0 (List.length (Agent.state agent).messages)
;;

(* ------------------------------------------------------------------ *)
(* JSON structure verification                                          *)
(* ------------------------------------------------------------------ *)

let test_image_json_structure () =
  let img =
    Types.Image
      { media_type = "image/webp"; data = "webpdata"; source_type = Types.Base64 }
  in
  let json = Llm_provider.Api_common.content_block_to_json img in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "top-level type" "image" (json |> member "type" |> to_string);
  let source = json |> member "source" in
  Alcotest.(check string) "source.type" "base64" (source |> member "type" |> to_string);
  Alcotest.(check string)
    "source.media_type"
    "image/webp"
    (source |> member "media_type" |> to_string);
  Alcotest.(check string) "source.data" "webpdata" (source |> member "data" |> to_string)
;;

let test_document_json_structure () =
  let doc =
    Types.Document
      { media_type = "text/plain"; data = "textdata"; source_type = Types.Base64 }
  in
  let json = Llm_provider.Api_common.content_block_to_json doc in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "top-level type" "document" (json |> member "type" |> to_string);
  let source = json |> member "source" in
  Alcotest.(check string) "source.type" "base64" (source |> member "type" |> to_string);
  Alcotest.(check string)
    "source.media_type"
    "text/plain"
    (source |> member "media_type" |> to_string)
;;

(* ------------------------------------------------------------------ *)
(* ToolResult structured content_blocks (WP4)                           *)
(* ------------------------------------------------------------------ *)

let test_tool_result_content_blocks_serialize () =
  let open Yojson.Safe.Util in
  (* content_blocks = None keeps the canonical string content. *)
  let tr_string =
    Types.ToolResult
      { tool_use_id = "t1"
      ; content = "plain"
      ; outcome = Tool_succeeded
      ; json = None
      ; content_blocks = None
      }
  in
  Alcotest.(check string)
    "string content"
    "plain"
    (Llm_provider.Api_common.content_block_to_json tr_string
     |> member "content"
     |> to_string);
  (* content_blocks = Some emits the blocks as the content array. *)
  let tr_blocks =
    Types.ToolResult
      { tool_use_id = "t2"
      ; content = "fallback"
      ; outcome = Tool_succeeded
      ; json = None
      ; content_blocks =
          Some
            [ Types.Text "hi"
            ; Types.Image
                { media_type = "image/png"; data = "d"; source_type = Types.Base64 }
            ]
      }
  in
  let content =
    Llm_provider.Api_common.content_block_to_json tr_blocks |> member "content"
  in
  (match content with
   | `List items -> Alcotest.(check int) "two blocks" 2 (List.length items)
   | _ -> Alcotest.fail "expected content array");
  Alcotest.(check string)
    "first block is text"
    "text"
    (content |> index 0 |> member "type" |> to_string);
  Alcotest.(check string)
    "second block is image"
    "image"
    (content |> index 1 |> member "type" |> to_string)
;;

(* ------------------------------------------------------------------ *)
(* Test runner                                                          *)
(* ------------------------------------------------------------------ *)

let () =
  Alcotest.run
    "Multimodal"
    [ ( "round_trip"
      , [ Alcotest.test_case "image base64 round-trip" `Quick test_image_round_trip
        ; Alcotest.test_case "document pdf round-trip" `Quick test_document_round_trip
        ; Alcotest.test_case "image url round-trip" `Quick test_image_url_round_trip
        ; Alcotest.test_case
            "document file_id round-trip"
            `Quick
            test_document_file_id_round_trip
        ] )
    ; ( "parsing"
      , [ Alcotest.test_case "image nested source" `Quick test_image_parse_nested_source
        ; Alcotest.test_case
            "document nested source"
            `Quick
            test_document_parse_nested_source
        ] )
    ; ( "malformed"
      , [ Alcotest.test_case
            "image missing source"
            `Quick
            test_malformed_image_missing_source
        ; Alcotest.test_case
            "document missing source"
            `Quick
            test_malformed_document_missing_source
        ; Alcotest.test_case
            "unknown image source kind fail-closed"
            `Quick
            test_unknown_image_source_kind_fails_closed
        ; Alcotest.test_case
            "unknown document source kind fail-closed"
            `Quick
            test_unknown_document_source_kind_fails_closed
        ; Alcotest.test_case
            "unknown audio source kind fail-closed"
            `Quick
            test_unknown_audio_source_kind_fails_closed
        ] )
    ; ( "mixed"
      , [ Alcotest.test_case
            "text + image + document"
            `Quick
            test_mixed_content_serialization
        ; Alcotest.test_case "constructors" `Quick test_multimodal_constructors
        ; Alcotest.test_case
            "agent run_blocks rejects internal blocks"
            `Quick
            test_agent_run_blocks_rejects_internal_blocks
        ; Alcotest.test_case
            "agent run_with_handoffs_blocks rejects internal blocks"
            `Quick
            test_agent_run_with_handoffs_blocks_rejects_internal_blocks
        ] )
    ; ( "json_structure"
      , [ Alcotest.test_case "image json structure" `Quick test_image_json_structure
        ; Alcotest.test_case "document json structure" `Quick test_document_json_structure
        ] )
    ; ( "tool_result"
      , [ Alcotest.test_case
            "content_blocks serialize"
            `Quick
            test_tool_result_content_blocks_serialize
        ] )
    ]
;;
