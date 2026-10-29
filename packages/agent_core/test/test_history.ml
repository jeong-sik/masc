(** History content types: media by reference (RFC-0476 §3.4, D5). *)

module H = Agent_core_base.History
module P = Llm_provider.Types

let block = Alcotest.testable H.pp_content_block ( = )
let message = Alcotest.testable H.pp_message ( = )
let wire_block = Alcotest.testable P.pp_content_block ( = )
let wire_message = Alcotest.testable P.pp_message ( = )
let stored = Alcotest.testable H.pp_stored ( = )

let media_result value =
  Alcotest.result value (Alcotest.testable H.pp_media_error ( = ))
;;

let decode_result value =
  Alcotest.result value (Alcotest.testable H.pp_decode_error ( = ))
;;

let ok_media what = function
  | Ok value -> value
  | Error error -> Alcotest.failf "%s: %s" what (H.show_media_error error)
;;

let ok_stored what = function
  | Ok value -> value
  | Error error -> Alcotest.failf "%s: %s" what (H.show_stored_error error)
;;

(* A store that refuses every call: a conversion that succeeds with it never
   touched the store. *)
let refusing_store : H.media_store =
  { H.put = (fun ~media_type:_ ~raw:_ -> Error (H.Store_failed { detail = "put refused" }))
  ; get = (fun _ -> Error (H.Store_failed { detail = "get refused" }))
  }
;;

let png_bytes = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" ^ String.init 256 Char.chr
let pdf_bytes = "%PDF-1.4\n1 0 obj\n<<>>\nendobj\n"
let wav_bytes = "RIFF\x24\x00\x00\x00WAVEfmt \x10\x00\x00\x00"
let base64 raw = P.Base64 (Base64.encode_string raw)
let wire_image = P.Image { media_type = "image/png"; source = base64 png_bytes }

let wire_document =
  P.Document { media_type = "application/pdf"; source = base64 pdf_bytes }
;;

let wire_audio = P.Audio { media_type = "audio/wav"; source = base64 wav_bytes }

let wire_tool_result ?(outcome = P.Tool_succeeded) ~content content_blocks =
  P.ToolResult { tool_use_id = "call_1"; content; outcome; json = None; content_blocks }
;;

let wire_nested =
  wire_tool_result
    ~content:"page 1"
    (Some
       [ P.Text "page 1"
       ; wire_image
       ; wire_tool_result ~content:"" (Some [ wire_audio; wire_document ])
       ])
;;

let stored_of raw = H.Stored (H.stored_of_raw raw)

(* ------------------------------------------------------------------ *)
(* Stored reference                                                   *)
(* ------------------------------------------------------------------ *)

let abc_sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

let test_stored_of_raw () =
  let reference = H.stored_of_raw "abc" in
  Alcotest.(check string) "sha256 of the raw bytes" abc_sha256 reference.H.sha256;
  Alcotest.(check int) "raw length" 3 reference.H.bytes;
  Alcotest.check
    stored
    "stored accepts what stored_of_raw builds"
    reference
    (ok_stored "stored" (H.stored ~sha256:abc_sha256 ~bytes:3))
;;

let test_stored_rejects () =
  let rejected = Alcotest.testable H.pp_stored_error ( = ) in
  let check name expected ~sha256 ~bytes =
    Alcotest.(check (result stored rejected)) name (Error expected) (H.stored ~sha256 ~bytes)
  in
  let upper = String.uppercase_ascii abc_sha256 in
  check "uppercase hex" (H.Sha256_not_lowercase_hex upper) ~sha256:upper ~bytes:3;
  let short = String.sub abc_sha256 0 63 in
  check "63 characters" (H.Sha256_not_lowercase_hex short) ~sha256:short ~bytes:3;
  let non_hex = "g" ^ String.sub abc_sha256 1 63 in
  check "non-hex character" (H.Sha256_not_lowercase_hex non_hex) ~sha256:non_hex ~bytes:3;
  check "negative length" (H.Negative_byte_count (-1)) ~sha256:abc_sha256 ~bytes:(-1)
;;

(* ------------------------------------------------------------------ *)
(* Provider conversions                                               *)
(* ------------------------------------------------------------------ *)

let test_base64_round_trip () =
  List.iter
    (fun (name, original) ->
       let store = H.Memory_store.create () in
       let history = ok_media "of_wire_block" (H.of_wire_block store original) in
       Alcotest.check
         (media_result wire_block)
         name
         (Ok original)
         (H.to_wire_block store history))
    [ "image", wire_image
    ; "document", wire_document
    ; "audio", wire_audio
    ; "nested tool result", wire_nested
    ]
;;

let test_base64_becomes_stored () =
  let store = H.Memory_store.create () in
  Alcotest.check
    (media_result block)
    "image holds the digest and length of the decoded bytes"
    (Ok (H.Image { media_type = "image/png"; source = stored_of png_bytes }))
    (H.of_wire_block store wire_image);
  Alcotest.check
    (media_result block)
    "nested media is stored too"
    (Ok
       (H.ToolResult
          { tool_use_id = "call_1"
          ; content = "page 1"
          ; outcome = P.Tool_succeeded
          ; json = None
          ; content_blocks =
              Some
                [ H.Text "page 1"
                ; H.Image { media_type = "image/png"; source = stored_of png_bytes }
                ; H.ToolResult
                    { tool_use_id = "call_1"
                    ; content = ""
                    ; outcome = P.Tool_succeeded
                    ; json = None
                    ; content_blocks =
                        Some
                          [ H.Audio { media_type = "audio/wav"; source = stored_of wav_bytes }
                          ; H.Document
                              { media_type = "application/pdf"
                              ; source = stored_of pdf_bytes
                              }
                          ]
                    }
                ]
          }))
    (H.of_wire_block store wire_nested)
;;

let test_message_round_trip () =
  let store = H.Memory_store.create () in
  let original =
    { P.role = P.User
    ; origin = P.Conversation
    ; content = [ P.Text "look"; wire_image; wire_document ]
    ; name = Some "operator"
    ; tool_call_id = None
    ; metadata = [ "turn", `Int 3 ]
    }
  in
  let history = ok_media "of_wire_message" (H.of_wire_message store original) in
  Alcotest.(check int) "same block count" 3 (List.length history.H.content);
  Alcotest.check
    (media_result wire_message)
    "message round trip"
    (Ok original)
    (H.to_wire_message store history)
;;

let test_same_bytes_same_reference () =
  let store = H.Memory_store.create () in
  let first = ok_media "first" (H.of_wire_block store wire_image) in
  let second = ok_media "second" (H.of_wire_block store wire_image) in
  Alcotest.check block "one reference for one payload" first second
;;

let test_references_pass_through () =
  List.iter
    (fun (name, original, expected) ->
       Alcotest.check
         (media_result block)
         (name ^ " into history")
         (Ok expected)
         (H.of_wire_block refusing_store original);
       Alcotest.check
         (media_result wire_block)
         (name ^ " back to the provider")
         (Ok original)
         (H.to_wire_block refusing_store expected))
    [ ( "image url"
      , P.Image { media_type = "image/png"; source = P.Url "https://example.test/a.png" }
      , H.Image { media_type = "image/png"; source = H.Url "https://example.test/a.png" } )
    ; ( "document file id"
      , P.Document { media_type = "application/pdf"; source = P.File_id "file-123" }
      , H.Document { media_type = "application/pdf"; source = H.File_id "file-123" } )
    ; ( "audio url"
      , P.Audio { media_type = "audio/wav"; source = P.Url "https://example.test/a.wav" }
      , H.Audio { media_type = "audio/wav"; source = H.Url "https://example.test/a.wav" } )
    ]
;;

let test_invalid_base64 () =
  let check name payload =
    match
      H.of_wire_block
        refusing_store
        (wire_tool_result
           ~content:""
           (Some [ P.Image { media_type = "image/png"; source = P.Base64 payload } ]))
    with
    | Error (H.Invalid_base64 { media_type; _ }) ->
      Alcotest.(check string) (name ^ " names the media type") "image/png" media_type
    | Ok _ -> Alcotest.failf "%s: accepted" name
    | Error error -> Alcotest.failf "%s: %s" name (H.show_media_error error)
  in
  check "not base64" "not base64!";
  check "missing padding" "aGVsbG8"
;;

let test_put_failure_propagates () =
  Alcotest.check
    (media_result block)
    "the store's error comes back"
    (Error (H.Store_failed { detail = "put refused" }))
    (H.of_wire_block refusing_store wire_image)
;;

let test_missing_bytes () =
  let store = H.Memory_store.create () in
  let absent = H.stored_of_raw "never put" in
  Alcotest.check
    (media_result Alcotest.string)
    "get"
    (Error (H.Missing_bytes absent))
    (store.H.get absent);
  Alcotest.check
    (media_result wire_block)
    "to_wire_block"
    (Error (H.Missing_bytes absent))
    (H.to_wire_block store (H.Image { media_type = "image/png"; source = H.Stored absent }))
;;

let test_digest_mismatch () =
  let store = H.Memory_store.create () in
  let actual = ok_media "put" (store.H.put ~media_type:"image/png" ~raw:"hello") in
  let forged = ok_stored "forged" (H.stored ~sha256:actual.H.sha256 ~bytes:99) in
  Alcotest.check
    (media_result Alcotest.string)
    "length that does not match the bytes"
    (Error (H.Digest_mismatch { expected = forged; actual }))
    (store.H.get forged)
;;

let test_media_bytes () =
  let image = H.Image { media_type = "image/png"; source = stored_of png_bytes } in
  let url = "https://example.test/a.png" in
  Alcotest.(check int)
    "stored counts raw bytes"
    (String.length png_bytes)
    (H.media_bytes image);
  Alcotest.(check int)
    "url counts its length"
    (String.length url)
    (H.media_bytes (H.Image { media_type = "image/png"; source = H.Url url }));
  Alcotest.(check int)
    "file id counts its length"
    (String.length "file-123")
    (H.media_source_bytes (H.File_id "file-123"));
  Alcotest.(check int) "text has none" 0 (H.media_bytes (H.Text "hello"));
  Alcotest.(check int)
    "nested media is summed"
    (String.length png_bytes + String.length url)
    (H.media_bytes
       (H.ToolResult
          { tool_use_id = "call_1"
          ; content = ""
          ; outcome = P.Tool_succeeded
          ; json = None
          ; content_blocks =
              Some
                [ image
                ; H.Text "between"
                ; H.Document { media_type = "application/pdf"; source = H.Url url }
                ]
          }))
;;

(* ------------------------------------------------------------------ *)
(* JSON                                                               *)
(* ------------------------------------------------------------------ *)

let failed ?error_class failure_kind = P.Tool_failed { failure_kind; error_class }

let history_tool_result ?(outcome = P.Tool_succeeded) ~content content_blocks =
  H.ToolResult { tool_use_id = "call_7"; content; outcome; json = None; content_blocks }
;;

(* Blocks without media, each with a provider twin. *)
let non_media_blocks =
  [ "text", H.Text "hello ✓"
  ; "signed thinking", H.Thinking { content = "plan"; signature = Some "sig==" }
  ; "unsigned thinking", H.Thinking { content = "plan"; signature = None }
  ; ( "reasoning details with content"
    , H.ReasoningDetails
        { reasoning_content = Some "why"
        ; details =
            [ { P.raw = `Assoc [ "type", `String "reasoning.text"; "text", `String "step" ]
              ; text = Some "step"
              }
            ]
        } )
  ; ( "reasoning details without content"
    , H.ReasoningDetails
        { reasoning_content = None
        ; details =
            [ { P.raw = `Assoc [ "type", `String "reasoning.encrypted"; "data", `String "xx" ]
              ; text = None
              }
            ]
        } )
  ; "redacted thinking", H.RedactedThinking "opaque"
  ; ( "tool use"
    , H.ToolUse
        { id = "call_7"; name = "read"; input = `Assoc [ "path", `String "/tmp/x" ] } )
  ; "tool result", history_tool_result ~content:"done" None
  ; ( "failed tool result with class"
    , history_tool_result
        ~outcome:(failed ~error_class:P.Transient P.Recoverable_tool_error)
        ~content:"timeout"
        None )
  ; ( "failed tool result without class"
    , history_tool_result ~outcome:(failed P.Validation_error) ~content:"bad args" None )
  ; ( "structured tool result"
    , history_tool_result ~content:"line one" (Some [ H.Text "line one" ]) )
  ; ( "failed structured tool result"
    , history_tool_result
        ~outcome:(failed ~error_class:P.Deterministic P.Non_retryable_tool_error)
        ~content:"line one"
        (Some [ H.Text "line one"; H.Thinking { content = "aside"; signature = None } ]) )
  ]
;;

let reference_media_blocks =
  [ ( "image url"
    , H.Image { media_type = "image/png"; source = H.Url "https://example.test/a.png" } )
  ; "image file id", H.Image { media_type = "image/png"; source = H.File_id "file-1" }
  ; ( "document url"
    , H.Document { media_type = "application/pdf"; source = H.Url "https://e.test/a.pdf" }
    )
  ; ( "document file id"
    , H.Document { media_type = "application/pdf"; source = H.File_id "file-2" } )
  ; "audio url", H.Audio { media_type = "audio/wav"; source = H.Url "https://e.test/a" }
  ; "audio file id", H.Audio { media_type = "audio/wav"; source = H.File_id "file-3" }
  ; ( "tool result with a url image"
    , history_tool_result
        ~content:"see"
        (Some
           [ H.Text "see"
           ; H.Image { media_type = "image/png"; source = H.Url "https://e.test/b.png" }
           ]) )
  ]
;;

let stored_media_blocks =
  [ "stored image", H.Image { media_type = "image/png"; source = stored_of png_bytes }
  ; ( "stored document"
    , H.Document { media_type = "application/pdf"; source = stored_of pdf_bytes } )
  ; "stored audio", H.Audio { media_type = "audio/wav"; source = stored_of wav_bytes }
  ; ( "tool result with stored media"
    , history_tool_result
        ~outcome:(failed P.Reported_tool_error)
        ~content:"rendered"
        (Some
           [ H.Text "rendered"
           ; H.Image { media_type = "image/png"; source = stored_of png_bytes }
           ; history_tool_result
               ~content:""
               (Some
                  [ H.Audio { media_type = "audio/wav"; source = stored_of wav_bytes } ])
           ]) )
  ]
;;

(* Through text so integer and string forms are what a file holds. *)
let json_round_trip json = Yojson.Safe.from_string (Yojson.Safe.to_string json)

let test_json_round_trip () =
  List.iter
    (fun (name, original) ->
       Alcotest.check
         (decode_result block)
         name
         (Ok original)
         (H.content_block_of_json (json_round_trip (H.content_block_to_json original))))
    (non_media_blocks @ reference_media_blocks @ stored_media_blocks)
;;

let test_message_json_round_trip () =
  let full =
    { H.role = P.Tool
    ; origin = P.Conversation
    ; content = List.map snd stored_media_blocks
    ; name = Some "reader"
    ; tool_call_id = Some "call_7"
    ; metadata = [ "turn", `Int 3; "lane", `String "a" ]
    }
  in
  let bare =
    { full with H.content = [ H.Text "hi" ]; name = None; tool_call_id = None; metadata = [] }
  in
  List.iter
    (fun (name, original) ->
       Alcotest.check
         (decode_result message)
         name
         (Ok original)
         (H.message_of_json (json_round_trip (H.message_to_json original))))
    [ "every optional field", full; "no optional field", bare ]
;;

let to_wire_without_store what history =
  ok_media what (H.to_wire_block refusing_store history)
;;

let checkpoint_json what wire =
  match Agent_core.Checkpoint.content_block_to_json_result ~scope:what wire with
  | Ok json -> Yojson.Safe.to_string json
  | Error error -> Alcotest.failf "%s: %s" what (Agent_core.Error.to_string error)
;;

let test_same_bytes_as_checkpoint () =
  List.iter
    (fun (name, history) ->
       let wire = to_wire_without_store name history in
       let expected = checkpoint_json name wire in
       Alcotest.(check string)
         name
         expected
         (Yojson.Safe.to_string (H.content_block_to_json history));
       Alcotest.check
         (decode_result block)
         (name ^ " decodes the current checkpoint bytes")
         (Ok history)
         (H.content_block_of_json (Yojson.Safe.from_string expected)))
    (non_media_blocks @ reference_media_blocks)
;;

let test_same_bytes_as_api_common () =
  List.iter
    (fun (name, history) ->
       match history with
       | H.Text _ | H.Thinking _ | H.ReasoningDetails _ | H.RedactedThinking _ | H.ToolUse _
       | H.Image _ | H.Document _ | H.Audio _ ->
         Alcotest.(check string)
           name
           (Yojson.Safe.to_string
              (Llm_provider.Api_common.content_block_to_json
                 (to_wire_without_store name history)))
           (Yojson.Safe.to_string (H.content_block_to_json history))
       | H.ToolResult _ -> ())
    (non_media_blocks @ reference_media_blocks)
;;

let test_message_same_bytes_as_checkpoint () =
  let history =
    { H.role = P.User
    ; origin = P.Recovery_instruction
    ; content = List.map snd (non_media_blocks @ reference_media_blocks)
    ; name = Some "operator"
    ; tool_call_id = None
    ; metadata = [ "turn", `Int 3 ]
    }
  in
  let wire = ok_media "to_wire_message" (H.to_wire_message refusing_store history) in
  Alcotest.(check string)
    "message bytes"
    (Yojson.Safe.to_string (Agent_core.Checkpoint.message_to_json wire))
    (Yojson.Safe.to_string (H.message_to_json history))
;;

let test_stored_json_shape () =
  let reference = H.stored_of_raw "hello" in
  Alcotest.(check string)
    "stored source"
    (Printf.sprintf
       {|{"type":"image","source":{"type":"stored","media_type":"image/png","sha256":"%s","bytes":5}}|}
       reference.H.sha256)
    (Yojson.Safe.to_string
       (H.content_block_to_json
          (H.Image { media_type = "image/png"; source = H.Stored reference })))
;;

let test_decode_rejects () =
  let hello = (H.stored_of_raw "hello").H.sha256 in
  let check name expected text =
    Alcotest.check
      (decode_result block)
      name
      (Error expected)
      (H.content_block_of_json (Yojson.Safe.from_string text))
  in
  check
    "base64 source"
    (H.Base64_source { at = "$.source" })
    (Yojson.Safe.to_string (Llm_provider.Api_common.content_block_to_json wire_image));
  check
    "base64 nested in a tool result"
    (H.Base64_source { at = "$.content[1].source" })
    {|{"type":"tool_result","tool_use_id":"c","content":[{"type":"text","text":"a"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"aGk="}}],"is_error":false,"text_content":"a"}|};
  check
    "unknown source type"
    (H.Unknown_source_type { at = "$.source"; source_type = "s3" })
    {|{"type":"image","source":{"type":"s3","media_type":"image/png","data":"x"}}|};
  check
    "uppercase digest"
    (H.Invalid_stored
       { at = "$.source"
       ; error = H.Sha256_not_lowercase_hex (String.uppercase_ascii hello)
       })
    (Printf.sprintf
       {|{"type":"image","source":{"type":"stored","media_type":"image/png","sha256":"%s","bytes":5}}|}
       (String.uppercase_ascii hello));
  check
    "negative length"
    (H.Invalid_stored { at = "$.source"; error = H.Negative_byte_count (-5) })
    (Printf.sprintf
       {|{"type":"image","source":{"type":"stored","media_type":"image/png","sha256":"%s","bytes":-5}}|}
       hello);
  check
    "stored source with data"
    (H.Unknown_field { at = "$.source"; field = "data" })
    (Printf.sprintf
       {|{"type":"image","source":{"type":"stored","media_type":"image/png","sha256":"%s","bytes":5,"data":"aGk="}}|}
       hello);
  check
    "stored length as a string"
    (H.Wrong_json_kind { at = "$.source.bytes"; expected = H.Json_int })
    (Printf.sprintf
       {|{"type":"image","source":{"type":"stored","media_type":"image/png","sha256":"%s","bytes":"5"}}|}
       hello);
  check
    "unknown field"
    (H.Unknown_field { at = "$"; field = "cache_control" })
    {|{"type":"text","text":"a","cache_control":{}}|};
  check
    "duplicate field"
    (H.Duplicate_field { at = "$"; field = "text" })
    {|{"type":"text","text":"a","text":"b"}|};
  check
    "unknown block type"
    (H.Unknown_block_type { at = "$"; block_type = "video" })
    {|{"type":"video"}|};
  check
    "blank tool use id"
    (H.Wrong_json_kind { at = "$.id"; expected = H.Json_non_blank_string })
    {|{"type":"tool_use","id":" ","name":"read","input":{}}|};
  check
    "structured content without text_content"
    (H.Missing_field { at = "$"; field = "text_content" })
    {|{"type":"tool_result","tool_use_id":"c","content":[],"is_error":false}|};
  check
    "text_content beside string content"
    (H.Inconsistent_tool_result { at = "$"; problem = H.Text_content_with_string_content })
    {|{"type":"tool_result","tool_use_id":"c","content":"a","is_error":false,"text_content":"a"}|};
  check
    "failure without kind"
    (H.Inconsistent_tool_result { at = "$"; problem = H.Failure_without_kind })
    {|{"type":"tool_result","tool_use_id":"c","content":"a","is_error":true}|};
  check
    "success with provenance"
    (H.Inconsistent_tool_result { at = "$"; problem = H.Success_with_provenance })
    {|{"type":"tool_result","tool_use_id":"c","content":"a","is_error":false,"failure_kind":["Validation_error"]}|};
  check "not an object" (H.Wrong_json_kind { at = "$"; expected = H.Json_object }) {|"text"|}
;;

let test_message_decode_rejects () =
  let check name expected text =
    Alcotest.check
      (decode_result message)
      name
      (Error expected)
      (H.message_of_json (Yojson.Safe.from_string text))
  in
  check
    "empty metadata"
    (H.Empty_metadata { at = "$.metadata" })
    {|{"role":"user","origin":"conversation","content":[],"metadata":{}}|};
  check
    "unknown role"
    (H.Unknown_role { at = "$.role"; role = "robot" })
    {|{"role":"robot","origin":"conversation","content":[]}|};
  check
    "unknown origin"
    (H.Unknown_origin { at = "$.origin"; origin = "dream" })
    {|{"role":"user","origin":"dream","content":[]}|};
  check
    "block path inside a message"
    (H.Base64_source { at = "$.content[0].source" })
    {|{"role":"user","origin":"conversation","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"aGk="}}]}|}
;;

let () =
  Alcotest.run
    "history"
    [ ( "stored"
      , [ Alcotest.test_case "stored_of_raw" `Quick test_stored_of_raw
        ; Alcotest.test_case "constructor rejects" `Quick test_stored_rejects
        ] )
    ; ( "conversion"
      , [ Alcotest.test_case "base64 round trip" `Quick test_base64_round_trip
        ; Alcotest.test_case "base64 becomes stored" `Quick test_base64_becomes_stored
        ; Alcotest.test_case "message round trip" `Quick test_message_round_trip
        ; Alcotest.test_case "same bytes same reference" `Quick test_same_bytes_same_reference
        ; Alcotest.test_case "references pass through" `Quick test_references_pass_through
        ; Alcotest.test_case "invalid base64" `Quick test_invalid_base64
        ; Alcotest.test_case "put failure" `Quick test_put_failure_propagates
        ; Alcotest.test_case "missing bytes" `Quick test_missing_bytes
        ; Alcotest.test_case "digest mismatch" `Quick test_digest_mismatch
        ; Alcotest.test_case "media bytes" `Quick test_media_bytes
        ] )
    ; ( "json"
      , [ Alcotest.test_case "block round trip" `Quick test_json_round_trip
        ; Alcotest.test_case "message round trip" `Quick test_message_json_round_trip
        ; Alcotest.test_case "same bytes as checkpoint" `Quick test_same_bytes_as_checkpoint
        ; Alcotest.test_case "same bytes as api_common" `Quick test_same_bytes_as_api_common
        ; Alcotest.test_case
            "message same bytes as checkpoint"
            `Quick
            test_message_same_bytes_as_checkpoint
        ; Alcotest.test_case "stored shape" `Quick test_stored_json_shape
        ; Alcotest.test_case "block decode rejects" `Quick test_decode_rejects
        ; Alcotest.test_case "message decode rejects" `Quick test_message_decode_rejects
        ] )
    ]
;;
