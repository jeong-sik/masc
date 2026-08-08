open Llm_provider
open Types
module Parse = Backend_openai_parse
module Responses = Backend_openai_responses
module Serialize = Backend_openai_serialize

let check_string = Alcotest.(check string)
let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)
let check_float = Alcotest.(check (float 0.0001))

(* Local substring search: this suite links no shared string util. *)
let contains ~needle haystack =
  let nl = String.length needle
  and hl = String.length haystack in
  let rec at i = i + nl <= hl && (String.sub haystack i nl = needle || at (i + 1)) in
  nl = 0 || at 0
;;

let msg role content : message =
  { role; content; name = None; tool_call_id = None; metadata = [] }
;;

let content_has_reasoning =
  List.exists (function
    | Thinking _ | ReasoningDetails _ | RedactedThinking _ -> true
    | Text _ | ToolUse _ | ToolResult _ | Image _ | Document _ | Audio _ -> false)
;;

let reasoning_source_for_dialect dialect =
  let provider_instance =
    Reasoning_source.provider_instance
      ~base_url:"https://codec.test"
      ~request_path:"/v1/chat/completions"
  in
  match
    Reasoning_source.create
      ~provider_kind:Provider_kind.OpenAI_compat
      ~provider_instance
      ~canonical_model_id:"codec-test"
      ~replay_contract:(Reasoning_dialect.replay_contract dialect)
  with
  | Ok source -> source
  | Error detail -> Alcotest.failf "invalid codec-test reasoning source: %s" detail
;;

let replay_capability_for_dialect dialect : Reasoning_dialect.replay_capability =
  { target = reasoning_source_for_dialect dialect
  ; contract = Reasoning_dialect.replay_contract dialect
  ; rotation = Reasoning_dialect.rotation_policy dialect
  }
;;

let reasoning_source_for_config config =
  match Reasoning_dialect.reasoning_source_for_provider_config config with
  | Ok source -> source
  | Error detail -> Alcotest.failf "invalid reasoning source fixture: %s" detail
;;

let stamp_reasoning_history reasoning_source (messages : message list) =
  List.map
    (fun (message : message) ->
       match message.role, content_has_reasoning message.content with
       | Assistant, true ->
         { message with metadata = Reasoning_source.metadata reasoning_source }
       | (System | User | Tool), _ | Assistant, false -> message)
    messages
;;

let dialect_messages_of_history
      ?assistant_tool_content_format
      dialect
      (messages : message list)
  =
  let replay_capability = replay_capability_for_dialect dialect in
  let messages = stamp_reasoning_history replay_capability.target messages in
  match
    Serialize.dialect_messages_of_history
      ?assistant_tool_content_format
      ~replay_capability
      dialect
      messages
  with
  | Ok wire -> wire
  | Error error ->
    Alcotest.failf
      "typed reasoning replay projection failed: %s"
      (Reasoning_history_projection.error_to_string error)
;;

let render_single_dialect_message ?assistant_tool_content_format dialect message =
  dialect_messages_of_history ?assistant_tool_content_format dialect [ message ]
;;

let ollama_messages ~supports_image_input messages =
  let caps = Capabilities.default_capabilities in
  match
    Serialize.ollama_messages_of_history
      ~modality_priority:caps.modality_priority
      ~supports_image_input
      ~supports_document_input:caps.supports_document_input
      messages
  with
  | Ok messages -> messages
  | Error error -> Alcotest.fail ("Ollama history serialization failed: " ^ error)
;;

let only label = function
  | [ x ] -> x
  | xs ->
    Alcotest.fail (Printf.sprintf "expected one %s item, got %d" label (List.length xs))
;;

let as_list label = function
  | `List xs -> xs
  | json ->
    Alcotest.fail
      (Printf.sprintf "expected %s list, got %s" label (Yojson.Safe.to_string json))
;;

let expect_invalid_arg label f =
  match f () with
  | exception Invalid_argument _ -> ()
  | _ -> Alcotest.fail (label ^ " should fail closed with Invalid_argument")
;;

let member key json = Yojson.Safe.Util.member key json
let to_string json = Yojson.Safe.Util.to_string json
let to_int json = Yojson.Safe.Util.to_int json
let to_list json = Yojson.Safe.Util.to_list json

let require_model_capabilities model_id =
  match Capabilities.for_model_id model_id with
  | Some capabilities -> capabilities
  | None -> Alcotest.failf "missing declared capabilities for %S" model_id
;;

let rec find_repo_root dir =
  if Sys.file_exists (Filename.concat dir "dune-project")
  then dir
  else (
    let parent = Filename.dirname dir in
    if String.equal parent dir
    then Alcotest.fail "could not locate dune-project"
    else find_repo_root parent)
;;

let source_path rel = Filename.concat (find_repo_root (Sys.getcwd ())) rel

let require_assoc label = function
  | `Assoc fields -> fields
  | json -> Alcotest.failf "expected %s object, got %s" label (Yojson.Safe.to_string json)
;;

let require_field label key json =
  match List.assoc_opt key (require_assoc label json) with
  | Some value -> value
  | None -> Alcotest.failf "missing %s.%s" label key
;;

let require_string label key json =
  match require_field label key json with
  | `String value -> value
  | value ->
    Alcotest.failf "expected %s.%s string, got %s" label key (Yojson.Safe.to_string value)
;;

let optional_bool ~default label key json =
  match List.assoc_opt key (require_assoc label json) with
  | None -> default
  | Some (`Bool value) -> value
  | Some value ->
    Alcotest.failf "expected %s.%s bool, got %s" label key (Yojson.Safe.to_string value)
;;

let require_list label key json =
  match require_field label key json with
  | `List values -> values
  | value ->
    Alcotest.failf "expected %s.%s list, got %s" label key (Yojson.Safe.to_string value)
;;

let role_of_fixture = function
  | "assistant" -> Assistant
  | "user" -> User
  | "tool" -> Tool
  | "system" -> System
  | role -> Alcotest.failf "unknown fixture role: %s" role
;;

let block_of_fixture json =
  match require_string "block" "type" json with
  | "text" -> Text (require_string "block" "text" json)
  | "thinking" ->
    Thinking { signature = None; content = require_string "block" "text" json }
  | "tool_use" ->
    ToolUse
      { id = require_string "block" "id" json
      ; name = require_string "block" "name" json
      ; input = require_field "block" "input" json
      }
  | "tool_result" ->
    let outcome =
      if optional_bool ~default:false "block" "is_error" json
      then Tool_failed { failure_kind = Reported_tool_error; error_class = None }
      else Tool_succeeded
    in
    ToolResult
      { tool_use_id = require_string "block" "tool_use_id" json
      ; content = require_string "block" "content" json
      ; outcome
      ; json = None
      ; content_blocks = None
      }
  | block_type -> Alcotest.failf "unknown fixture block type: %s" block_type
;;

let message_of_fixture json =
  { role = role_of_fixture (require_string "message" "role" json)
  ; content = List.map block_of_fixture (require_list "message" "blocks" json)
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let masc_oas_replay_fixture_messages () =
  let json =
    Yojson.Safe.from_file
      (source_path "test/fixtures/masc-oas-replay-interleaving.v1.json")
  in
  List.map message_of_fixture (require_list "fixture" "messages" json)
;;

let response_json ?(content = `String "ok") ?(finish_reason = "stop") ?message_fields () =
  let message_fields =
    match message_fields with
    | Some fields -> ("content", content) :: fields
    | None -> [ "content", content ]
  in
  `Assoc
    [ "id", `String "chatcmpl-test"
    ; "model", `String "provider-d-test"
    ; ( "choices"
      , `List
          [ `Assoc
              [ "finish_reason", `String finish_reason; "message", `Assoc message_fields ]
          ] )
    ]
;;

let parse_ok json =
  match Parse.parse_openai_response_result (Yojson.Safe.to_string json) with
  | Ok response -> response
  | Error msg ->
    Alcotest.fail ("unexpected parse error: " ^ Parse.parse_error_to_string msg)
;;

(* Symmetric to [parse_ok]: assert the fail-closed all-empty 200 path
   (oas#2483). Returns the [Empty_completion] payload, which preserves
   [stop_reason]/[usage]/[telemetry] for downstream inspection. *)
let parse_empty json : Parse.empty_completion =
  match Parse.parse_openai_response_result (Yojson.Safe.to_string json) with
  | Error (Parse.Empty_completion e) -> e
  | Error msg ->
    Alcotest.fail
      ("expected Empty_completion, got error: " ^ Parse.parse_error_to_string msg)
  | Ok _ -> Alcotest.fail "expected Empty_completion, got Ok"
;;

let test_parse_reasoning_content_and_tool_calls_coexist () =
  (* 2025-2026 providers (DeepSeek, Kimi, Qwen, MiMo) return reasoning_content
     alongside tool_calls. Both must survive parsing into [content]: the
     reasoning as a Thinking block and the call as a ToolUse block. *)
  let json =
    response_json
      ~content:(`String "")
      ~finish_reason:"tool_calls"
      ~message_fields:
        [ "reasoning_content", `String "think step by step"
        ; ( "tool_calls"
          , `List
              [ `Assoc
                  [ "id", `String "call-1"
                  ; "type", `String "function"
                  ; ( "function"
                    , `Assoc
                        [ "name", `String "search"; "arguments", `String {|{"q":"x"}|} ] )
                  ]
              ] )
        ]
      ()
  in
  let response = parse_ok json in
  let has_thinking =
    List.exists
      (function
        | Thinking { content; _ } -> content = "think step by step"
        | _ -> false)
      response.content
  in
  let has_tool =
    List.exists
      (function
        | ToolUse { name; _ } -> name = "search"
        | _ -> false)
      response.content
  in
  check_bool "reasoning_content -> Thinking" true has_thinking;
  check_bool "tool_calls -> ToolUse" true has_tool;
  check_bool "stop_reason is StopToolUse" true (response.stop_reason = StopToolUse)
;;

let test_parse_reasoning_details_and_tool_calls_coexist () =
  (* MiniMax-M3 reasoning_split mode documents structured reasoning_details on
     tool-call turns. Preserve that message shape for replay rather than
     flattening it into generic reasoning_content text. *)
  let json =
    response_json
      ~content:(`String "")
      ~finish_reason:"tool_calls"
      ~message_fields:
        [ "reasoning_content", `String "use weather tool"
        ; ( "reasoning_details"
          , `List
              [ `Assoc
                  [ "type", `String "reasoning.text"
                  ; "id", `String "reasoning-text-1"
                  ; "format", `String "MiniMax-response-v1"
                  ; "index", `Int 0
                  ; "text", `String "use weather tool"
                  ]
              ; `Assoc
                  [ "type", `String "reasoning.text"
                  ; "id", `String "reasoning-text-2"
                  ; "format", `String "MiniMax-response-v1"
                  ; "index", `Int 1
                  ; "text", `String "  "
                  ]
              ] )
        ; ( "tool_calls"
          , `List
              [ `Assoc
                  [ "id", `String "call-1"
                  ; "type", `String "function"
                  ; ( "function"
                    , `Assoc
                        [ "name", `String "get_weather"
                        ; "arguments", `String {|{"location":"San Francisco, US"}|}
                        ] )
                  ]
              ] )
        ]
      ()
  in
  let response = parse_ok json in
  let has_visible_text =
    List.exists
      (function
        | Text s -> not (Api_common.string_is_blank s)
        | _ -> false)
      response.content
  in
  let has_flat_thinking =
    List.exists
      (function
        | Thinking _ -> true
        | _ -> false)
      response.content
  in
  let reasoning_content, details =
    match response.content with
    | ReasoningDetails { reasoning_content; details } :: ToolUse { name; _ } :: _
      when name = "get_weather" -> reasoning_content, details
    | _ -> Alcotest.fail "expected [ReasoningDetails; ToolUse]"
  in
  let has_tool =
    List.exists
      (function
        | ToolUse { name; _ } -> name = "get_weather"
        | _ -> false)
      response.content
  in
  Alcotest.(check (option string))
    "reasoning_content preserved"
    (Some "use weather tool")
    reasoning_content;
  check_bool "reasoning_details block count" true (List.length details = 2);
  check_string
    "reasoning_details raw id preserved"
    "reasoning-text-1"
    (member "id" (List.hd details).raw |> to_string);
  check_string
    "reasoning_details text captured"
    "use weather tool"
    (Option.value ~default:"" (List.hd details).text);
  check_bool "reasoning_details does not leak as visible text" false has_visible_text;
  check_bool "reasoning_details are not flattened to Thinking" false has_flat_thinking;
  check_bool "tool_calls -> ToolUse" true has_tool;
  check_bool "stop_reason is StopToolUse" true (response.stop_reason = StopToolUse);
  let projected_calls = Canonical_tool.tool_calls_of_response response in
  (match projected_calls with
   | [ { Canonical_tool.adjacent_reasoning =
           Canonical_tool.Adjacent_reasoning
             [ { Canonical_tool.kind = Canonical_tool.Visible_thinking
               ; order_index = 0
               ; signature = None
               }
             ]
       ; _
       }
     ] -> ()
   | _ -> Alcotest.fail "expected one visible adjacent reasoning block");
  let minimax_dialect =
    { Reasoning_dialect.default with
      replay_policy = All_assistant_messages
    ; output_wire = Reasoning_split
    }
  in
  let replay =
    render_single_dialect_message minimax_dialect (msg Assistant response.content)
    |> only "assistant replay"
  in
  let replay_details = member "reasoning_details" replay |> as_list "reasoning_details" in
  check_int "replay preserves reasoning_details entries" 2 (List.length replay_details);
  check_string
    "reasoning_content preserved on replay"
    "use weather tool"
    (member "reasoning_content" replay |> to_string);
  let first_detail = List.hd replay_details in
  check_string
    "reasoning_details replay id"
    "reasoning-text-1"
    (member "id" first_detail |> to_string);
  check_string
    "reasoning_details replay format"
    "MiniMax-response-v1"
    (member "format" first_detail |> to_string);
  check_int "reasoning_details replay index" 0 (member "index" first_detail |> to_int);
  check_string
    "reasoning_details replay text"
    "use weather tool"
    (member "text" first_detail |> to_string);
  check_bool
    "reasoning_details text still absent from visible content on replay"
    true
    (match member "content" replay with
     | `Null -> true
     | `String s -> Api_common.string_is_blank s
     | _ -> false)
;;

let test_parse_reasoning_details_rejects_malformed () =
  let expect_error label expected_prefix reasoning_details =
    let json =
      response_json
        ~content:(`String "")
        ~finish_reason:"tool_calls"
        ~message_fields:
          [ "reasoning_content", `String "use weather tool"
          ; "reasoning_details", reasoning_details
          ; ( "tool_calls"
            , `List
                [ `Assoc
                    [ "id", `String "call-1"
                    ; "type", `String "function"
                    ; ( "function"
                      , `Assoc
                          [ "name", `String "get_weather"
                          ; "arguments", `String {|{"location":"San Francisco, US"}|}
                          ] )
                    ]
                ] )
          ]
        ()
    in
    match Parse.parse_openai_response_result (Yojson.Safe.to_string json) with
    | Error msg ->
      check_bool
        label
        true
        (String.starts_with ~prefix:expected_prefix (Parse.parse_error_to_string msg))
    | Ok _ -> Alcotest.fail (label ^ " should fail closed")
  in
  expect_error
    "non-list reasoning_details"
    "malformed_reasoning_details:not_list"
    (`Assoc [ "text", `String "bad shape" ]);
  expect_error
    "non-object reasoning detail"
    "malformed_reasoning_details:index:1:not_object"
    (`List
        [ `Assoc
            [ "type", `String "reasoning.text"
            ; "id", `String "reasoning-text-1"
            ; "text", `String "valid"
            ]
        ; `String "bad detail"
        ])
;;

let test_reasoning_only_stays_thinking_and_never_reinjected_on_replay () =
  (* End-to-end #2236 regression guard. Provider-agnostic: it exercises the
     Types<->serialize boundary every OpenAI-compatible family (DeepSeek, Kimi,
     Qwen, GLM, Ollama) shares, so one assertion here covers all of them.

     A reasoning-only reply must stay typed as [Thinking] in canonical content;
     it is never promoted to a [Text] answer block. On the next turn the request
     serializer must not surface that reasoning as the assistant "content"
     (answer) field -- otherwise the model is re-fed its own reasoning as a
     finalized answer and re-reasons over it: the parrot / infinite-recursion
     loop. Promotion (the removed mechanism) erased the type distinction and is
     exactly what made the leak possible. *)
  let reasoning_text = "최종 답은 42" in
  let json =
    response_json
      ~content:(`String "")
      ~finish_reason:"stop"
      ~message_fields:[ "reasoning_content", `String reasoning_text ]
      ()
  in
  let response =
    match Parse.parse_openai_response_result (Yojson.Safe.to_string json) with
    | Ok r -> r
    | Error msg ->
      Alcotest.fail ("unexpected parse error: " ^ Parse.parse_error_to_string msg)
  in
  let has_text =
    List.exists
      (function
        | Text _ -> true
        | _ -> false)
      response.content
  in
  let has_thinking =
    List.exists
      (function
        | Thinking { content; _ } -> String.trim content = reasoning_text
        | _ -> false)
      response.content
  in
  check_bool "reasoning stays typed as Thinking in canonical content" true has_thinking;
  check_bool "reasoning is never promoted to a Text answer block" false has_text;
  let assistant_msg = msg Assistant response.content in
  let serialized = Serialize.openai_messages_of_message assistant_msg in
  let assistant_json = only "assistant message" serialized in
  let content_str =
    match member "content" assistant_json with
    | `String s -> s
    | _ -> ""
  in
  check_bool
    "reasoning must NOT be re-injected as assistant answer content on replay"
    false
    (String.trim content_str = reasoning_text);
  (* Stronger than "not equal to the reasoning text": a reasoning-only reply has
     no Text answer block, so the serialized assistant [content] must be empty.
     This catches any future leak that smuggles the reasoning into [content] in a
     transformed shape (truncated, prefixed, re-encoded) rather than verbatim. *)
  check_string
    "reasoning-only reply serializes to empty assistant content"
    ""
    (String.trim content_str)
;;

let test_content_parts_cover_modalities () =
  let parts =
    Serialize.openai_content_parts_of_blocks
      [ Text "hello"
      ; Image { media_type = "image/png"; data = "img"; source_type = Types.Base64 }
      ; Document
          { media_type = "application/pdf"; data = "doc"; source_type = Types.Base64 }
      ; Audio { media_type = "wav"; data = "aud"; source_type = Types.Base64 }
      ; Thinking { signature = None; content = "hidden" }
      ; RedactedThinking "redacted"
      ; ToolUse { id = "tc"; name = "tool"; input = `Assoc [] }
      ]
  in
  check_int "parts" 4 (List.length parts);
  let text = List.nth parts 0 in
  check_string "text type" "text" (member "type" text |> to_string);
  check_string "text value" "hello" (member "text" text |> to_string);
  let image = List.nth parts 1 in
  check_string "image type" "image_url" (member "type" image |> to_string);
  check_string
    "image url"
    "data:image/png;base64,img"
    (member "image_url" image |> member "url" |> to_string);
  let document = List.nth parts 2 in
  (* oas#2744: a document is emitted as the Chat Completions [file] part. It
     used to be relabelled [image_url], which silently retyped the block as an
     image. *)
  check_string "document type" "file" (member "type" document |> to_string);
  check_string
    "document file_data"
    "data:application/pdf;base64,doc"
    (member "file" document |> member "file_data" |> to_string);
  let audio = List.nth parts 3 in
  check_string "audio type" "input_audio" (member "type" audio |> to_string);
  check_string
    "audio format"
    "wav"
    (member "input_audio" audio |> member "format" |> to_string)
;;

let test_non_base64_media_source_fails_closed () =
  expect_invalid_arg "openai chat image url" (fun () ->
    Serialize.openai_content_parts_of_blocks
      [ Image
          { media_type = "image/png"
          ; data = "https://example.invalid/image.png"
          ; source_type = Types.Url
          }
      ]
    |> ignore);
  expect_invalid_arg "ollama image url" (fun () ->
    ollama_messages
      ~supports_image_input:true
      [ msg
          User
          [ Image
              { media_type = "image/png"
              ; data = "https://example.invalid/image.png"
              ; source_type = Types.Url
              }
          ]
      ]
    |> ignore);
  let config =
    Provider_config.make
      ~kind:Provider_config.OpenAI_compat
      ~model_id:"gpt-test"
      ~base_url:""
      ()
  in
  expect_invalid_arg "responses document file_id" (fun () ->
    Responses.build_request
      ~config
      ~messages:
        [ msg
            User
            [ Document
                { media_type = "application/pdf"
                ; data = "file_abc123"
                ; source_type = Types.File_id
                }
            ]
        ]
      ()
    |> ignore)
;;

let test_openai_user_messages_reject_tool_result_and_drop_empty () =
  let user =
    msg
      User
      [ Text "first"
      ; Text "second"
      ; ToolResult
          { tool_use_id = "call-1"
          ; content = "42"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ]
  in
  Alcotest.check_raises
    "ToolResult requires role Tool"
    (Invalid_argument
       "Backend_openai_serialize.openai_messages_of_message: ToolResult requires role \
        tool")
    (fun () -> ignore (Serialize.openai_messages_of_message user));
  List.iter
    (fun role ->
       Alcotest.check_raises
         "ToolResult rejected outside role Tool"
         (Invalid_argument
            "Backend_openai_serialize.openai_messages_of_message: ToolResult requires \
             role tool")
         (fun () ->
            ignore
              (Serialize.openai_messages_of_message
                 { user with
                   role
                 ; content =
                     List.filter
                       (function
                         | ToolResult _ -> true
                         | Text _
                         | Thinking _
                         | ReasoningDetails _
                         | RedactedThinking _
                         | ToolUse _
                         | Image _
                         | Document _
                         | Audio _ -> false)
                       user.content
                 })))
    [ Assistant; System ];
  let empty_user =
    Serialize.openai_messages_of_message
      (msg User [ Thinking { signature = None; content = "x" } ])
  in
  check_int "empty user drops message" 0 (List.length empty_user)
;;

(* Wire-level adjacency for a nudged tool turn: the internal shape is
   [assistant(tool_calls); tool(ToolResult); user(Text nudge)] and it must
   serialize without interleaving user text before the tool response. *)
let test_wire_adjacency_nudged_tool_turn () =
  let turn =
    [ msg Assistant [ ToolUse { id = "call-9"; name = "f"; input = `Null } ]
    ; msg
        Tool
        [ ToolResult
            { tool_use_id = "call-9"
            ; content = "ok"
            ; outcome = Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    ; msg User [ Text "nudge: try a different tool" ]
    ]
  in
  let wire = List.concat_map Serialize.openai_messages_of_message turn in
  let roles = List.map (fun m -> member "role" m |> to_string) wire in
  Alcotest.(check (list string))
    "tool responses stay adjacent to tool_calls"
    [ "assistant"; "tool"; "user" ]
    roles
;;

let test_user_multimodal_preserve_and_visual_first () =
  let content =
    [ Text "caption"
    ; Image { media_type = "image/jpeg"; data = "jpeg"; source_type = Types.Base64 }
    ]
  in
  let openai = Serialize.openai_messages_of_message (msg User content) |> only "openai" in
  let openai_parts = member "content" openai |> as_list "openai content" in
  check_string
    "openai preserves text first"
    "text"
    (List.nth openai_parts 0 |> member "type" |> to_string);
  let ollama =
    ollama_messages ~supports_image_input:true [ msg User content ] |> only "ollama"
  in
  (* Ollama native /api/chat requires content to be a plain string and places
     base64 image payloads in a separate images array. *)
  check_string "ollama content is string" "caption" (member "content" ollama |> to_string);
  let images = member "images" ollama |> as_list "ollama images" in
  check_int "ollama images count" 1 (List.length images);
  check_string "ollama image payload" "jpeg" (List.nth images 0 |> to_string)
;;

let test_ollama_native_multimodal_variants () =
  (* Image-only user message: content is an empty string, images carries the payload. *)
  let image_only =
    ollama_messages
      ~supports_image_input:true
      [ msg
          User
          [ Image { media_type = "image/png"; data = "png1"; source_type = Types.Base64 }
          ]
      ]
    |> only "ollama"
  in
  check_string "image-only content empty" "" (member "content" image_only |> to_string);
  let images = member "images" image_only |> as_list "image-only images" in
  check_int "image-only images count" 1 (List.length images);
  check_string "image-only payload" "png1" (List.nth images 0 |> to_string);
  (* Audio is not supported by Ollama native /api/chat and must fail closed
     instead of being silently dropped. *)
  expect_invalid_arg "ollama audio input" (fun () ->
    ollama_messages
      ~supports_image_input:false
      [ msg
          User
          [ Audio { media_type = "audio/wav"; data = "wav1"; source_type = Types.Base64 }
          ]
      ]
    |> ignore);
  (* Mixed text + image preserves text in content and the payload in images. *)
  let mixed =
    ollama_messages
      ~supports_image_input:true
      [ msg
          User
          [ Text "describe these"
          ; Image { media_type = "image/png"; data = "png2"; source_type = Types.Base64 }
          ]
      ]
    |> only "ollama"
  in
  check_string "mixed content" "describe these" (member "content" mixed |> to_string);
  let mixed_images = member "images" mixed |> as_list "mixed images" in
  check_int "mixed images count" 1 (List.length mixed_images);
  check_string "mixed first image" "png2" (List.nth mixed_images 0 |> to_string)
;;

let test_assistant_tool_calls_openai_ollama_and_glm () =
  let assistant =
    msg
      Assistant
      [ ToolUse { id = "call-1"; name = "lookup"; input = `Assoc [ "q", `String "x" ] } ]
  in
  let openai = Serialize.openai_messages_of_message assistant |> only "openai" in
  check_string "assistant role" "assistant" (member "role" openai |> to_string);
  Alcotest.(check bool) "openai content null" true (member "content" openai = `Null);
  let call = member "tool_calls" openai |> as_list "tool_calls" |> only "tool_call" in
  check_string
    "openai arguments string"
    {|{"q":"x"}|}
    (member "function" call |> member "arguments" |> to_string);
  let ollama =
    ollama_messages ~supports_image_input:false [ assistant ] |> only "ollama"
  in
  let ollama_call =
    member "tool_calls" ollama |> as_list "ollama tool_calls" |> only "tool_call"
  in
  check_string
    "ollama arguments raw json"
    "x"
    (member "function" ollama_call |> member "arguments" |> member "q" |> to_string);
  let replay_assistant =
    msg
      Assistant
      [ Thinking { signature = None; content = "because" }
      ; ToolUse { id = "call-2"; name = "lookup"; input = `Assoc [ "q", `String "y" ] }
      ]
  in
  let replay_dialect =
    Reasoning_dialect.of_capabilities
      { Capabilities.openai_compat_chat_extended_capabilities with
        thinking_control_format = Capabilities.Thinking_object
      }
  in
  let replay_null =
    render_single_dialect_message
      ~assistant_tool_content_format:Capability_vocab.Assistant_tool_content_null
      replay_dialect
      replay_assistant
    |> only "replay null"
  in
  Alcotest.(check bool)
    "reasoning replay keeps null content when capability says null"
    true
    (member "content" replay_null = `Null);
  check_string
    "reasoning replay still emits reasoning_content"
    "because"
    (member "reasoning_content" replay_null |> to_string);
  let replay_empty =
    render_single_dialect_message
      ~assistant_tool_content_format:Capability_vocab.Assistant_tool_content_empty_string
      replay_dialect
      replay_assistant
    |> only "replay empty"
  in
  check_string
    "reasoning replay emits empty content when capability says empty string"
    ""
    (member "content" replay_empty |> to_string);
  check_string
    "empty-string capability still emits reasoning_content"
    "because"
    (member "reasoning_content" replay_empty |> to_string);
  let glm_dialect =
    { Reasoning_dialect.default with replay_policy = All_assistant_messages }
  in
  let glm =
    render_single_dialect_message
      ~assistant_tool_content_format:Capability_vocab.Assistant_tool_content_empty_string
      glm_dialect
      (msg
         Assistant
         [ Text "answer"; Thinking { signature = None; content = "because" } ])
    |> only "glm"
  in
  check_string "glm content" "answer" (member "content" glm |> to_string);
  check_string "glm reasoning" "because" (member "reasoning_content" glm |> to_string)
;;

let test_system_and_tool_role_messages () =
  let system =
    Serialize.openai_messages_of_message (msg System [ Text "sys" ]) |> only "system"
  in
  check_string "system role" "system" (member "role" system |> to_string);
  check_string "system content" "sys" (member "content" system |> to_string);
  let tool =
    Serialize.openai_messages_of_message
      (msg
         Tool
         [ ToolResult
             { tool_use_id = "call-2"
             ; content = "ok"
             ; outcome = Tool_succeeded
             ; json = None
             ; content_blocks = None
             }
         ])
    |> only "tool"
  in
  check_string "tool role" "tool" (member "role" tool |> to_string);
  check_string "tool call id" "call-2" (member "tool_call_id" tool |> to_string);
  Alcotest.check_raises
    "Tool role requires ToolResult"
    (Invalid_argument
       "Backend_openai_serialize.openai_messages_of_message: role tool requires one or \
        more ToolResult blocks and no other content")
    (fun () ->
       ignore (Serialize.openai_messages_of_message (msg Tool [ Text "invalid" ])))
;;

let test_kimi_replay_trace_preserves_all_historical_reasoning () =
  let messages =
    [ msg
        Assistant
        [ Thinking { signature = None; content = "k-thought:tool" }
        ; ToolUse { id = "call-k"; name = "lookup"; input = `Assoc [] }
        ]
    ; msg
        Tool
        [ ToolResult
            { tool_use_id = "call-k"
            ; content = "ok"
            ; outcome = Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    ; msg
        Assistant
        [ Thinking { signature = None; content = "k-thought:plain" }; Text "visible" ]
    ]
  in
  let kimi_dialect = Reasoning_dialect.of_capabilities Capabilities.kimi_capabilities in
  let wire = dialect_messages_of_history kimi_dialect messages in
  check_string
    "tool-turn reasoning preserved"
    "k-thought:tool"
    (List.nth wire 0 |> member "reasoning_content" |> to_string);
  check_string
    "plain-turn reasoning preserved"
    "k-thought:plain"
    (List.nth wire 2 |> member "reasoning_content" |> to_string);
  check_string
    "plain visible content"
    "visible"
    (List.nth wire 2 |> member "content" |> to_string)
;;

let test_tool_choice_and_tool_schema_conversion () =
  check_string
    "auto"
    "\"auto\""
    (Serialize.tool_choice_to_openai_json Auto |> Yojson.Safe.to_string);
  check_string
    "required"
    "\"required\""
    (Serialize.tool_choice_to_openai_json Any |> Yojson.Safe.to_string);
  check_string
    "none"
    "\"none\""
    (Serialize.tool_choice_to_openai_json None_ |> Yojson.Safe.to_string);
  let tool_choice = Serialize.tool_choice_to_openai_json (Tool "lookup") in
  check_string
    "tool choice name"
    "lookup"
    (member "function" tool_choice |> member "name" |> to_string);
  let schema = `Assoc [ "type", `String "object" ] in
  let with_input_schema =
    Serialize.build_openai_tool_json
      (`Assoc
          [ "name", `String "direct"; "description", `String "d"; "input_schema", schema ])
  in
  check_string
    "input_schema passes through"
    "object"
    (member "function" with_input_schema
     |> member "parameters"
     |> member "type"
     |> to_string);
  let provider_shaped =
    Serialize.build_openai_tool_json
      (`Assoc
          [ "name", `String "provider"
          ; "description", `String "d"
          ; "parameters", schema
          ; "strict", `Bool true
          ])
  in
  check_bool
    "provider-shaped strict passes through"
    true
    (member "function" provider_shaped |> member "strict" |> Yojson.Safe.Util.to_bool);
  Alcotest.check_raises
    "legacy parameter list rejected"
    (Invalid_argument
       "Backend_openai_serialize.tool_definition_of_json: parameters must be a JSON \
        object")
    (fun () ->
       ignore
         (Serialize.build_openai_tool_json
            (`Assoc
                [ "name", `String "legacy"
                ; "description", `String "invalid parameter shape"
                ; "parameters", `List [ `Assoc [ "name", `String "city" ] ]
                ])));
  Alcotest.check_raises
    "non-object tool rejected"
    (Invalid_argument
       "Backend_openai_serialize.tool_definition_of_json: tool must be a JSON object")
    (fun () -> ignore (Serialize.build_openai_tool_json (`String "raw")))
;;

let ignored_blocks : content_block list =
  [ Thinking { signature = None; content = "   " }
  ; RedactedThinking "hidden"
  ; Image { media_type = "image/png"; data = "img"; source_type = Types.Base64 }
  ; Document { media_type = "application/pdf"; data = "doc"; source_type = Types.Base64 }
  ; Audio { media_type = "wav"; data = "aud"; source_type = Types.Base64 }
  ]
;;

let test_serializer_ignored_block_variants () =
  check_int
    "openai tool_calls ignores non-tool blocks"
    0
    (Serialize.tool_calls_to_openai_json ignored_blocks |> List.length);
  let ollama_blocks =
    (* Documents are excluded here because the Ollama native wire has no
       document part and rejects them at admission (oas#2744); this case is
       about tool-call blocks, and the rejection has its own coverage in
       [test_ollama_native_multimodal_variants]. *)
    List.filter
      (function
        | ToolResult _ | Document _ -> false
        | Text _
        | Thinking _
        | ReasoningDetails _
        | RedactedThinking _
        | ToolUse _
        | Image _
        | Audio _ -> true)
      ignored_blocks
  in
  let ollama =
    ollama_messages ~supports_image_input:true [ msg Assistant ollama_blocks ]
    |> only "ollama"
  in
  Alcotest.(check bool)
    "ollama has no tool_calls"
    true
    (member "tool_calls" ollama = `Null);
  let assistant =
    Serialize.openai_messages_of_message (msg Assistant ignored_blocks)
    |> only "assistant"
  in
  check_string "assistant content is empty" "" (member "content" assistant |> to_string);
  Alcotest.(check bool)
    "assistant has no tool_calls"
    true
    (member "tool_calls" assistant = `Null);
  let glm_dialect =
    { Reasoning_dialect.default with replay_policy = All_assistant_messages }
  in
  let glm =
    render_single_dialect_message
      glm_dialect
      (msg Assistant [ Thinking { signature = None; content = "   " } ])
  in
  check_int "blank reasoning-only assistant removed" 0 (List.length glm)
;;

let test_parallel_tool_calls_fields () =
  (* SSOT for the parallel-tool-call wire field: emitted only to disable, and
     only when tools are present. *)
  let fields ~disable ~tools =
    Serialize.parallel_tool_calls_fields ~disable_parallel:disable ~tools_present:tools
  in
  check_int
    "disable + tools -> one field"
    1
    (List.length (fields ~disable:true ~tools:true));
  check_int
    "disable + no tools -> empty"
    0
    (List.length (fields ~disable:true ~tools:false));
  check_int "not disabled -> empty" 0 (List.length (fields ~disable:false ~tools:true));
  match fields ~disable:true ~tools:true with
  | [ ("parallel_tool_calls", `Bool false) ] -> ()
  | _ -> Alcotest.fail "expected parallel_tool_calls:false singleton"
;;

let test_tool_schema_rejects_invalid_current_shape () =
  Alcotest.check_raises
    "mistyped name rejected"
    (Invalid_argument
       "Backend_openai_serialize.tool_definition_of_json: name must be a string")
    (fun () ->
       ignore
         (Serialize.build_openai_tool_json
            (`Assoc
                [ "name", `Int 1; "description", `String ""; "input_schema", `Assoc [] ])));
  Alcotest.check_raises
    "competing schema authorities rejected"
    (Invalid_argument
       "Backend_openai_serialize.tool_definition_of_json: input_schema and parameters \
        are mutually exclusive")
    (fun () ->
       ignore
         (Serialize.build_openai_tool_json
            (`Assoc
                [ "name", `String "tool"
                ; "description", `String ""
                ; "input_schema", `Assoc []
                ; "parameters", `Assoc []
                ])))
;;

let test_usage_openai_fallbacks () =
  let usage =
    Parse.usage_of_openai_json
      (`Assoc
          [ ( "usage"
            , `Assoc
                [ "input_tokens", `Int 11
                ; "output_tokens", `Int 5
                ; "prompt_cache_hit_tokens", `Int 4
                ] )
          ])
  in
  (match usage with
   | Some u ->
     check_int "input" 11 u.input_tokens;
     check_int "output" 5 u.output_tokens;
     check_int "cache read" 4 u.cache_read_input_tokens
   | None -> Alcotest.fail "expected usage");
  let usage =
    Parse.usage_of_openai_json
      (`Assoc
          [ ( "usage"
            , `Assoc
                [ "prompt_tokens", `Int 7
                ; "completion_tokens", `Int 3
                ; "prompt_tokens_details", `Assoc [ "cached_tokens", `Int 2 ]
                ] )
          ])
  in
  match usage with
  | Some u ->
    check_int "prompt" 7 u.input_tokens;
    check_int "completion" 3 u.output_tokens;
    check_int "details cache" 2 u.cache_read_input_tokens
  | None -> Alcotest.fail "expected usage with details"
;;

let test_parse_text_list_reasoning_and_reported_telemetry () =
  let json =
    response_json
      ~content:
        (`List
            [ `Assoc [ "type", `String "text"; "text", `String "hello" ]
            ; `Assoc [ "type", `String "ignored" ]
            ; `String " raw"
            ])
      ~message_fields:[ "reasoning_content", `String "reported reasoning" ]
      ()
  in
  let json =
    match json with
    | `Assoc fields ->
      `Assoc
        (fields
         @ [ ( "usage"
             , `Assoc
                 [ "prompt_tokens", `Int 12
                 ; "completion_tokens", `Int 7
                 ; "completion_tokens_details", `Assoc [ "reasoning_tokens", `Int 5 ]
                 ] )
           ; ( "timings"
             , `Assoc
                 [ "prompt_n", `Int 12
                 ; "prompt_ms", `Float 20.5
                 ; "predicted_n", `Int 7
                 ; "predicted_per_second", `Float 14.0
                 ; "cache_n", `Int 2
                 ] )
           ; "system_fingerprint", `String "fp-test"
           ; "peak_memory_gb", `Float 1.25
           ])
    | _ -> json
  in
  let response = parse_ok json in
  (match response.content with
   | [ Thinking { content = "reported reasoning"; _ }; Text "hello raw" ] -> ()
   | _ -> Alcotest.fail "expected thinking + concatenated text");
  match response.telemetry with
  | Some
      { system_fingerprint = Some fp
      ; timings = Some timings
      ; reasoning_tokens = Some rt
      ; peak_memory_gb = Some peak
      ; _
      } ->
    check_string "fingerprint" "fp-test" fp;
    check_int "reasoning tokens" 5 rt;
    check_float "prompt ms" 20.5 (Option.get timings.prompt_ms);
    check_float "predicted per second" 14.0 (Option.get timings.predicted_per_second);
    check_int "cache_n" 2 (Option.get timings.cache_n);
    check_float "peak" 1.25 peak
  | _ -> Alcotest.fail "expected telemetry"
;;

let test_parse_reasoning_without_reported_tokens_preserves_fenced_json () =
  let json =
    response_json
      ~content:(`String "```json\n{\"ok\":true}\n```")
      ~message_fields:[ "reasoning", `String "abcdefghij" ]
      ()
  in
  let response = parse_ok json in
  (match response.content with
   | [ Thinking { content = "abcdefghij"; _ }; Text "```json\n{\"ok\":true}\n```" ] -> ()
   | _ -> Alcotest.fail "expected reasoning and lossless fenced JSON text");
  match response.telemetry with
  | Some { timings = None; reasoning_tokens = None; _ } -> ()
  | _ -> Alcotest.fail "reasoning tokens must remain absent when provider omits them"
;;

let test_parse_tool_calls_rejects_malformed_and_does_not_drop () =
  let json =
    response_json
      ~content:`Null
      ~finish_reason:"unexpected-finish"
      ~message_fields:
        [ ( "tool_calls"
          , `List
              [ `Assoc
                  [ "id", `String "call-ok"
                  ; ( "function"
                    , `Assoc
                        [ "name", `String "lookup"
                        ; "arguments", `String {|{"city":"Seoul"}|}
                        ] )
                  ]
              ; `Assoc [ "id", `String "broken"; "function", `Assoc [] ]
              ] )
        ]
      ()
  in
  match Parse.parse_openai_response_result (Yojson.Safe.to_string json) with
  | Error msg ->
    check_bool
      "malformed tool call is not silently dropped"
      true
      (String.starts_with
         ~prefix:"malformed_tool_call:index:1:"
         (Parse.parse_error_to_string msg))
  | Ok _ -> Alcotest.fail "expected malformed tool_calls to fail closed"
;;

let test_parse_tool_calls_rejects_malformed_arguments () =
  let json =
    response_json
      ~content:`Null
      ~finish_reason:"tool_calls"
      ~message_fields:
        [ ( "tool_calls"
          , `List
              [ `Assoc
                  [ "id", `String "call-bad"
                  ; ( "function"
                    , `Assoc
                        [ "name", `String "lookup"; "arguments", `String {|{"city":|} ] )
                  ]
              ] )
        ]
      ()
  in
  match Parse.parse_openai_response_result (Yojson.Safe.to_string json) with
  | Error msg ->
    check_bool
      "malformed arguments are not repaired"
      true
      (String.starts_with
         ~prefix:"malformed_tool_call_arguments:index:0:"
         (Parse.parse_error_to_string msg))
  | Ok _ -> Alcotest.fail "expected malformed tool arguments to fail closed"
;;

let test_parse_tool_calls_rejects_non_object_arguments () =
  List.iter
    (fun (label, arguments) ->
       let json =
         response_json
           ~content:`Null
           ~finish_reason:"tool_calls"
           ~message_fields:
             [ ( "tool_calls"
               , `List
                   [ `Assoc
                       [ "id", `String "call-non-object"
                       ; ( "function"
                         , `Assoc
                             [ "name", `String "lookup"; "arguments", `String arguments ]
                         )
                       ]
                   ] )
             ]
           ()
       in
       match Parse.parse_openai_response_result (Yojson.Safe.to_string json) with
       | Error msg ->
         check_string
           (label ^ " rejected")
           "malformed_tool_call_arguments:index:0:not_object"
           (Parse.parse_error_to_string msg)
       | Ok _ -> Alcotest.fail (label ^ " tool arguments must fail closed"))
    [ "number", "42"
    ; "array", "[]"
    ; "boolean", "true"
    ; "null", "null"
    ; "string", {|"value"|}
    ]
;;

let test_parse_error_default_message () =
  let json = `Assoc [ "error", `Assoc [] ] |> Yojson.Safe.to_string in
  match Parse.parse_openai_response_result json with
  | Error msg ->
    check_string "default error" "Unknown API error" (Parse.parse_error_to_string msg)
  | Ok _ -> Alcotest.fail "expected API error"
;;

let test_parse_edge_shapes_for_text_and_telemetry () =
  let invalid_fence =
    parse_ok (response_json ~content:(`String "```json\nnot-json\n```") ())
  in
  (match invalid_fence.content with
   | [ Text "```json\nnot-json\n```" ] -> ()
   | _ -> Alcotest.fail "invalid JSON fence should keep original text");
  (* Every content block is malformed (dropped) and whitespace-only
     reasoning_content yields no Thinking block, so the completion is
     all-empty and now fails closed as [Empty_completion] (oas#2483) instead
     of the old [Ok content=[]]. The fail-closed payload still carries the
     stop_reason. *)
  let no_text =
    parse_empty
      (response_json
         ~content:
           (`List
               [ `Assoc [ "text", `Int 1 ]; `Assoc [ "type", `String "ignored" ]; `Int 7 ])
         ~message_fields:[ "reasoning_content", `String "  " ]
         ())
  in
  (match no_text.stop_reason with
   | EndTurn -> ()
   | _ ->
     Alcotest.fail "empty completion should preserve the stop finish_reason as EndTurn");
  (* Malformed object content also parses to no blocks, but the fail-closed
     [Empty_completion] payload still surfaces stop_reason and telemetry. *)
  let telemetry =
    parse_empty
      (`Assoc
          [ "id", `String "chatcmpl-telemetry"
          ; "model", `String "provider-d-test"
          ; ( "choices"
            , `List
                [ `Assoc
                    [ "finish_reason", `String "length"
                    ; "message", `Assoc [ "content", `Assoc [ "unexpected", `Bool true ] ]
                    ]
                ] )
          ; ( "usage"
            , `Assoc
                [ "input_tokens", `Int 11
                ; "output_tokens", `Int 5
                ; "prompt_tps", `Int 22
                ; "generation_tps", `Int 50
                ; "peak_memory", `Int 3
                ] )
          ])
  in
  (match telemetry.stop_reason with
   | MaxTokens -> ()
   | _ -> Alcotest.fail "length should map to MaxTokens");
  match telemetry.telemetry with
  | Some { timings = Some t; peak_memory_gb = Some peak; _ } ->
    check_float "int prompt tps" 22.0 (Option.get t.prompt_per_second);
    check_float "int peak memory" 3.0 peak
  | _ -> Alcotest.fail "expected telemetry from integer rates"
;;

let responses_response_json () =
  `Assoc
    [ "id", `String "resp_123"
    ; "model", `String "gpt-5.5"
    ; "status", `String "completed"
    ; ( "output"
      , `List
          [ `Assoc
              [ "id", `String "rs_1"
              ; "type", `String "reasoning"
              ; ( "summary"
                , `List
                    [ `Assoc
                        [ "type", `String "summary_text"
                        ; "text", `String "Need current weather before answering."
                        ]
                    ] )
              ]
          ; `Assoc
              [ "id", `String "fc_1"
              ; "type", `String "function_call"
              ; "call_id", `String "call_weather"
              ; "name", `String "get_weather"
              ; "arguments", `String {|{"city":"Paris"}|}
              ]
          ] )
    ; ( "usage"
      , `Assoc
          [ "input_tokens", `Int 12
          ; "output_tokens", `Int 8
          ; "output_tokens_details", `Assoc [ "reasoning_tokens", `Int 3 ]
          ] )
    ]
;;

let responses_with_output output =
  `Assoc
    [ "id", `String "resp_bad"
    ; "model", `String "gpt-5.5"
    ; "status", `String "completed"
    ; "output", `List output
    ]
;;

let expect_responses_parse_error label expected json =
  match Responses.parse_response_result (Yojson.Safe.to_string json) with
  | Error msg -> check_string label expected msg
  | Ok _ -> Alcotest.fail (label ^ " should fail closed")
;;

let expect_responses_parse_error_prefix label prefix json =
  match Responses.parse_response_result (Yojson.Safe.to_string json) with
  | Error msg -> check_bool label true (String.starts_with ~prefix msg)
  | Ok _ -> Alcotest.fail (label ^ " should fail closed")
;;

let test_responses_parse_reasoning_and_function_call () =
  match
    Responses.parse_response_result (responses_response_json () |> Yojson.Safe.to_string)
  with
  | Error msg -> Alcotest.fail ("unexpected responses parse error: " ^ msg)
  | Ok response ->
    check_string "id" "resp_123" response.id;
    check_string "model" "gpt-5.5" response.model;
    check_bool "stop tool use" true (response.stop_reason = StopToolUse);
    (match response.content with
     | [ Thinking { signature; content }; ToolUse { id; name; input } ] ->
       check_bool "thinking unsigned" true (signature = None);
       check_string "thinking content" "Need current weather before answering." content;
       check_string "tool call_id" "call_weather" id;
       check_string "tool name" "get_weather" name;
       check_string "tool arg" "Paris" (member "city" input |> to_string)
     | _ -> Alcotest.fail "expected reasoning summary followed by function_call");
    (match response.usage with
     | Some usage ->
       check_int "input tokens" 12 usage.input_tokens;
       check_int "output tokens" 8 usage.output_tokens
     | None -> Alcotest.fail "expected usage");
    (match response.telemetry with
     | Some telemetry ->
       Alcotest.(check (option int))
         "reasoning tokens"
         (Some 3)
         telemetry.reasoning_tokens
     | None -> Alcotest.fail "expected telemetry")
;;

let test_responses_ignores_hosted_tool_item_and_preserves_message () =
  let json =
    responses_with_output
      [ `Assoc
          [ "id", `String "ws_1"
          ; "type", `String "web_search_call"
          ; "status", `String "completed"
          ]
      ; `Assoc
          [ "id", `String "msg_1"
          ; "type", `String "message"
          ; "role", `String "assistant"
          ; ( "content"
            , `List
                [ `Assoc
                    [ "type", `String "output_text"
                    ; "text", `String "It is sunny in Paris."
                    ]
                ] )
          ]
      ]
  in
  match Responses.parse_response_result (Yojson.Safe.to_string json) with
  | Error msg -> Alcotest.fail ("unexpected responses parse error: " ^ msg)
  | Ok response ->
    check_bool "stop end turn" true (response.stop_reason = EndTurn);
    (match response.content with
     | [ Text text ] -> check_string "message text" "It is sunny in Paris." text
     | _ -> Alcotest.fail "expected hosted-tool item skipped and message preserved")
;;

let test_responses_rejects_function_call_missing_call_id () =
  expect_responses_parse_error
    "missing call_id"
    "malformed_responses_function_call:missing_call_id"
    (responses_with_output
       [ `Assoc
           [ "id", `String "fc_item_1"
           ; "type", `String "function_call"
           ; "name", `String "get_weather"
           ; "arguments", `String {|{"city":"Paris"}|}
           ]
       ])
;;

let test_responses_rejects_function_call_non_object_arguments () =
  expect_responses_parse_error
    "non-object arguments"
    "malformed_responses_function_call:call_weather:arguments:not_object"
    (responses_with_output
       [ `Assoc
           [ "id", `String "fc_1"
           ; "type", `String "function_call"
           ; "call_id", `String "call_weather"
           ; "name", `String "get_weather"
           ; "arguments", `String {|["Paris"]|}
           ]
       ])
;;

let test_responses_rejects_function_call_malformed_arguments () =
  expect_responses_parse_error_prefix
    "malformed arguments"
    "malformed_responses_function_call:call_weather:arguments:json_parse_error:"
    (responses_with_output
       [ `Assoc
           [ "id", `String "fc_1"
           ; "type", `String "function_call"
           ; "call_id", `String "call_weather"
           ; "name", `String "get_weather"
           ; "arguments", `String {|{"city":"Par|}
           ]
       ])
;;

(* Regression for Codex P2 (#2048): a Responses result whose generation was cut
   off (status="incomplete", incomplete_details.reason="max_output_tokens") can
   still carry a [function_call] item with truncated arguments. The stop reason
   must surface the cut-off ([MaxTokens]) rather than [StopToolUse], so the agent
   does not execute partial/invalid tool arguments. Before the fix,
   [has_tool_calls] short-circuited to [StopToolUse] before the status was
   examined. *)
let responses_incomplete_with_function_call_json () =
  `Assoc
    [ "id", `String "resp_inc"
    ; "model", `String "gpt-5.5"
    ; "status", `String "incomplete"
    ; "incomplete_details", `Assoc [ "reason", `String "max_output_tokens" ]
    ; ( "output"
      , `List
          [ `Assoc
              [ "id", `String "fc_1"
              ; "type", `String "function_call"
              ; "call_id", `String "call_weather"
              ; "name", `String "get_weather"
              ; "arguments", `String {|{"city":"Par|}
              ]
          ] )
    ; "usage", `Assoc [ "input_tokens", `Int 12; "output_tokens", `Int 256 ]
    ]
;;

let test_responses_incomplete_status_wins_over_function_call () =
  match
    Responses.parse_response_result
      (responses_incomplete_with_function_call_json () |> Yojson.Safe.to_string)
  with
  | Error msg -> Alcotest.fail ("unexpected responses parse error: " ^ msg)
  | Ok response ->
    check_bool
      "incomplete max_output_tokens maps to MaxTokens, not StopToolUse"
      true
      (response.stop_reason = MaxTokens);
    (* The partial function_call must be dropped from content so the pipeline
       does not append a dangling ToolUse (which a later turn would repair with a
       synthetic error ToolResult). Codex P2 follow-up on #2073. *)
    check_bool
      "partial function_call suppressed from incomplete response content"
      false
      (List.exists
         (function
           | ToolUse _ -> true
           | _ -> false)
         response.content)
;;

let test_responses_stop_reason_ssot_status_table () =
  check_bool
    "failed message wins over tool calls"
    true
    (Responses_stop_reason.of_status
       ~status:(Some "failed")
       ~incomplete_reason:None
       ~failed_message:(Some "quota exhausted")
       ~has_tool_calls:true
     = Some (Unknown "quota exhausted"));
  check_bool
    "completed with tool calls is tool use"
    true
    (Responses_stop_reason.of_status
       ~status:(Some "completed")
       ~incomplete_reason:None
       ~failed_message:None
       ~has_tool_calls:true
     = Some StopToolUse);
  check_bool
    "unknown status without tools is preserved"
    true
    (Responses_stop_reason.of_status
       ~status:(Some "queued")
       ~incomplete_reason:None
       ~failed_message:None
       ~has_tool_calls:false
     = Some (Unknown "queued"));
  check_bool
    "missing status stays absent"
    true
    (Responses_stop_reason.of_status
       ~status:None
       ~incomplete_reason:None
       ~failed_message:None
       ~has_tool_calls:true
     = None);
  match
    Backend_openai_responses.parse_response_result
      {|{"id":"resp-missing-status","model":"m","output":[]}|}
  with
  | Error "malformed_openai_responses:missing_status" -> ()
  | Error message -> Alcotest.fail ("unexpected missing-status error: " ^ message)
  | Ok _ -> Alcotest.fail "missing Responses status must fail closed"
;;

let test_responses_preserves_encrypted_reasoning_item_for_replay () =
  let encrypted_reasoning_item =
    `Assoc
      [ "id", `String "rs_1"
      ; "type", `String "reasoning"
      ; "status", `String "completed"
      ; ( "summary"
        , `List
            [ `Assoc
                [ "type", `String "summary_text"
                ; "text", `String "Need current weather before answering."
                ]
            ] )
      ; "encrypted_content", `String "enc_reasoning_123"
      ]
  in
  let json =
    `Assoc
      [ "id", `String "resp_123"
      ; "model", `String "gpt-5.5"
      ; "status", `String "completed"
      ; ( "output"
        , `List
            [ encrypted_reasoning_item
            ; `Assoc
                [ "id", `String "fc_1"
                ; "type", `String "function_call"
                ; "call_id", `String "call_weather"
                ; "name", `String "get_weather"
                ; "arguments", `String {|{"city":"Paris"}|}
                ]
            ] )
      ]
  in
  match Responses.parse_response_result (Yojson.Safe.to_string json) with
  | Error msg -> Alcotest.fail ("unexpected responses parse error: " ^ msg)
  | Ok response ->
    (match response.content with
     | [ RedactedThinking raw; ToolUse { id; name; input } ] ->
       let raw_json = Yojson.Safe.from_string raw in
       check_string "raw type" "reasoning" (member "type" raw_json |> to_string);
       check_string "raw id" "rs_1" (member "id" raw_json |> to_string);
       check_string
         "raw encrypted content"
         "enc_reasoning_123"
         (member "encrypted_content" raw_json |> to_string);
       check_string "tool call_id" "call_weather" id;
       check_string "tool name" "get_weather" name;
       check_string "tool arg" "Paris" (member "city" input |> to_string)
     | _ -> Alcotest.fail "expected raw encrypted reasoning followed by function_call");
    let config =
      Provider_config.make
        ~kind:OpenAI_compat
        ~model_id:"gpt-5.5"
        ~base_url:"https://api.openai.com"
        ~request_path:"/v1/responses"
        ~max_tokens:128
        ()
    in
    let messages =
      [ msg User [ Text "weather?" ]
      ; msg Assistant response.content
      ; msg
          Tool
          [ ToolResult
              { tool_use_id = "call_weather"
              ; content = {|{"temp_c":12}|}
              ; outcome = Tool_succeeded
              ; json = Some (`Assoc [ "temp_c", `Int 12 ])
              ; content_blocks = None
              }
          ]
      ]
      |> stamp_reasoning_history (reasoning_source_for_config config)
    in
    let body = Responses.build_request ~config ~messages () |> Yojson.Safe.from_string in
    Alcotest.(check (list string))
      "include encrypted reasoning"
      [ "reasoning.encrypted_content" ]
      (member "include" body |> to_list |> List.map to_string);
    let input = member "input" body |> to_list in
    check_int "input items" 4 (List.length input);
    let reasoning = List.nth input 1 in
    check_string "replayed type" "reasoning" (member "type" reasoning |> to_string);
    check_string "replayed id" "rs_1" (member "id" reasoning |> to_string);
    check_string
      "replayed encrypted content"
      "enc_reasoning_123"
      (member "encrypted_content" reasoning |> to_string);
    check_string
      "function call item"
      "function_call"
      (List.nth input 2 |> member "type" |> to_string);
    check_string
      "function output item"
      "function_call_output"
      (List.nth input 3 |> member "type" |> to_string)
;;

let test_responses_build_request_round_trips_tool_result_items () =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"gpt-5.5"
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/responses"
      ~enable_thinking:true
      ~max_tokens:128
      ~model_capabilities_override:(require_model_capabilities "gpt-5.5")
      ()
  in
  let tool =
    `Assoc
      [ "name", `String "get_weather"
      ; "description", `String "weather lookup"
      ; "input_schema", `Assoc [ "type", `String "object" ]
      ; "strict", `Bool true
      ]
  in
  let messages =
    [ msg User [ Text "weather?" ]
    ; msg
        Assistant
        [ Thinking { signature = None; content = "Need a tool." }
        ; ToolUse
            { id = "call_weather"
            ; name = "get_weather"
            ; input = `Assoc [ "city", `String "Paris" ]
            }
        ]
    ; msg
        Tool
        [ ToolResult
            { tool_use_id = "call_weather"
            ; content = {|{"temp_c":12}|}
            ; outcome = Tool_succeeded
            ; json = Some (`Assoc [ "temp_c", `Int 12 ])
            ; content_blocks = None
            }
        ]
    ]
    |> stamp_reasoning_history (reasoning_source_for_config config)
  in
  let body =
    Responses.build_request ~config ~messages ~tools:[ tool ] ()
    |> Yojson.Safe.from_string
  in
  check_string "model" "gpt-5.5" (member "model" body |> to_string);
  check_int "max output" 128 (member "max_output_tokens" body |> to_int);
  check_bool
    "generic reasoning does not request encrypted content"
    true
    (member "include" body = `Null);
  let input = member "input" body |> to_list in
  check_int "generic reasoning is not replayed as opaque state" 3 (List.length input);
  check_string "first role" "user" (List.nth input 0 |> member "role" |> to_string);
  check_string
    "function call item"
    "function_call"
    (List.nth input 1 |> member "type" |> to_string);
  check_string
    "function output item"
    "function_call_output"
    (List.nth input 2 |> member "type" |> to_string);
  check_string
    "output call id"
    "call_weather"
    (List.nth input 2 |> member "call_id" |> to_string);
  let tool_json = member "tools" body |> to_list |> only "responses tool" in
  check_string "tool type" "function" (member "type" tool_json |> to_string);
  check_string "tool name" "get_weather" (member "name" tool_json |> to_string);
  check_bool "tool strict" true (Yojson.Safe.Util.to_bool (member "strict" tool_json))
;;

let test_responses_build_request_preserves_multiturn_reasoning_tool_order () =
  let raw_reasoning ~id ~encrypted_content ~summary =
    RedactedThinking
      (Yojson.Safe.to_string
         (`Assoc
             [ "id", `String id
             ; "type", `String "reasoning"
             ; "status", `String "completed"
             ; ( "summary"
               , `List
                   [ `Assoc [ "type", `String "summary_text"; "text", `String summary ] ]
               )
             ; "encrypted_content", `String encrypted_content
             ]))
  in
  let tool_call id city =
    ToolUse { id; name = "lookup_weather"; input = `Assoc [ "city", `String city ] }
  in
  let tool_result id content =
    ToolResult
      { tool_use_id = id
      ; content
      ; outcome = Tool_succeeded
      ; json = Some (`Assoc [ "content", `String content ])
      ; content_blocks = None
      }
  in
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"gpt-5.5"
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/responses"
      ~max_tokens:128
      ()
  in
  let messages =
    [ msg User [ Text "User message 1" ]
    ; msg
        Assistant
        [ raw_reasoning ~id:"rs_1_1" ~encrypted_content:"enc_1_1" ~summary:"Thinking 1.1"
        ; tool_call "call_1_1" "Seoul"
        ]
    ; msg Tool [ tool_result "call_1_1" "Tool result 1.1" ]
    ; msg
        Assistant
        [ raw_reasoning ~id:"rs_1_2" ~encrypted_content:"enc_1_2" ~summary:"Thinking 1.2"
        ; tool_call "call_1_2" "Busan"
        ]
    ; msg Tool [ tool_result "call_1_2" "Tool result 1.2" ]
    ; msg
        Assistant
        [ raw_reasoning ~id:"rs_1_3" ~encrypted_content:"enc_1_3" ~summary:"Thinking 1.3"
        ; Text "Answer 1"
        ]
    ; msg User [ Text "User message 2" ]
    ]
    |> stamp_reasoning_history (reasoning_source_for_config config)
  in
  let body = Responses.build_request ~config ~messages () |> Yojson.Safe.from_string in
  Alcotest.(check (list string))
    "include encrypted reasoning"
    [ "reasoning.encrypted_content" ]
    (member "include" body |> to_list |> List.map to_string);
  let input = member "input" body |> to_list in
  let string_field key json =
    match member key json with
    | `String value -> Some value
    | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
  in
  let require_string_field key json =
    match string_field key json with
    | Some value -> value
    | None ->
      Alcotest.failf "expected string field %s in %s" key (Yojson.Safe.to_string json)
  in
  let marker json =
    match string_field "type" json with
    | Some "reasoning" -> "reasoning:" ^ require_string_field "id" json
    | Some "function_call" -> "tool_call:" ^ require_string_field "call_id" json
    | Some "function_call_output" -> "tool_result:" ^ require_string_field "call_id" json
    | Some "message" ->
      let content = member "content" json |> to_list |> only "assistant message part" in
      "assistant:" ^ require_string_field "text" content
    | Some other -> "type:" ^ other
    | None ->
      (match string_field "role" json, string_field "content" json with
       | Some "user", Some text -> "user:" ^ text
       | Some "user", None ->
         let content = member "content" json |> to_list |> only "user message part" in
         "user:" ^ require_string_field "text" content
       | Some role, Some text -> role ^ ":" ^ text
       | Some role, None -> role ^ ":"
       | None, Some text -> "content:" ^ text
       | None, None -> "unknown")
  in
  Alcotest.(check (list string))
    "turn 2.1 input keeps prior reasoning/tool groups in order"
    [ "user:User message 1"
    ; "reasoning:rs_1_1"
    ; "tool_call:call_1_1"
    ; "tool_result:call_1_1"
    ; "reasoning:rs_1_2"
    ; "tool_call:call_1_2"
    ; "tool_result:call_1_2"
    ; "reasoning:rs_1_3"
    ; "assistant:Answer 1"
    ; "user:User message 2"
    ]
    (List.map marker input);
  check_string
    "first encrypted content preserved"
    "enc_1_1"
    (List.nth input 1 |> member "encrypted_content" |> to_string);
  check_string
    "second encrypted content preserved"
    "enc_1_2"
    (List.nth input 4 |> member "encrypted_content" |> to_string);
  check_string
    "third encrypted content preserved"
    "enc_1_3"
    (List.nth input 7 |> member "encrypted_content" |> to_string)
;;

let test_responses_build_request_includes_previous_response_id () =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"gpt-5.5"
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/responses"
      ~previous_response_id:"resp_previous_123"
      ~max_tokens:128
      ()
  in
  let body =
    Responses.build_request ~config ~messages:[ msg User [ Text "continue" ] ] ()
    |> Yojson.Safe.from_string
  in
  check_string
    "previous_response_id"
    "resp_previous_123"
    (member "previous_response_id" body |> to_string);
  check_int "manual input still present" 1 (member "input" body |> to_list |> List.length)
;;

let test_responses_build_request_rejects_numeric_thinking_budget () =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"gpt-5.5"
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/responses"
      ~enable_thinking:false
      ~thinking_budget:4096
      ~max_tokens:128
      ()
  in
  match
    Responses.build_request ~config ~messages:[ msg User [ Text "short answer" ] ] ()
  with
  | _ -> Alcotest.fail "expected numeric thinking-budget rejection"
  | exception Invalid_argument message ->
    check_string
      "rejection"
      "Backend_openai_responses.build_request: thinking_budget is unsupported; pass \
       reasoning_effort"
      message
;;

let test_responses_build_request_uses_text_format_json_schema () =
  let schema =
    `Assoc
      [ "title", `String "Weather Answer"
      ; "type", `String "object"
      ; ( "properties"
        , `Assoc
            [ "city", `Assoc [ "type", `String "string" ]
            ; "temp_c", `Assoc [ "type", `String "number" ]
            ] )
      ; "required", `List [ `String "city"; `String "temp_c" ]
      ; "additionalProperties", `Bool false
      ]
  in
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"gpt-5.5"
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/responses"
      ~response_format:(Types.JsonSchema schema)
      ~max_tokens:128
      ()
  in
  let body =
    Responses.build_request ~config ~messages:[ msg User [ Text "weather?" ] ] ()
    |> Yojson.Safe.from_string
  in
  let format = member "text" body |> member "format" in
  check_string "format type" "json_schema" (member "type" format |> to_string);
  check_string "format name" "weather_answer" (member "name" format |> to_string);
  check_bool "format strict" true (Yojson.Safe.Util.to_bool (member "strict" format));
  Alcotest.(check bool) "format schema" true (member "schema" format = schema)
;;

let test_responses_build_request_uses_text_format_json_object () =
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"gpt-5.5"
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/responses"
      ~response_format:Types.JsonMode
      ~max_tokens:128
      ()
  in
  let body =
    Responses.build_request ~config ~messages:[ msg User [ Text "json please" ] ] ()
    |> Yojson.Safe.from_string
  in
  check_string
    "format type"
    "json_object"
    (member "text" body |> member "format" |> member "type" |> to_string)
;;

(* Regression: the Responses builder shares the Chat builder's max-token
   resolution policy, so an over-cap caller value is clamped WITH the
   one-shot capability-drop WARN — not silently. The unique model_id keeps
   the process-wide WARN dedup table from suppressing the assertion. *)
let test_responses_build_request_warns_on_max_tokens_clamp () =
  let model_id = "codec-responses-clamp-warn" in
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/responses"
      ~max_tokens:4096
      ~model_capabilities_override:
        { Capabilities.default_capabilities with
          Capabilities.max_output_tokens = Some 64
        }
      ()
  in
  let drops = ref [] in
  let previous_metrics = Metrics.get_global () in
  Fun.protect
    ~finally:(fun () -> Metrics.set_global previous_metrics)
    (fun () ->
       Metrics.set_global
         { Metrics.noop with
           on_capability_drop =
             (fun ~model_id ~field -> drops := (model_id, field) :: !drops)
         };
       let body =
         Responses.build_request ~config ~messages:[ msg User [ Text "hi" ] ] ()
         |> Yojson.Safe.from_string
       in
       check_int
         "max_output_tokens clamped to capability ceiling"
         64
         (member "max_output_tokens" body |> to_int));
  match !drops with
  | [ (dropped_model, field) ] ->
    check_string "clamp warn model" model_id dropped_model;
    check_string "clamp warn field" "max_tokens:clamp" field
  | drops ->
    Alcotest.failf "expected exactly one capability-drop warn, got %d" (List.length drops)
;;

(* Regression: dialect-suppressed sampling params are dropped WITH the
   one-shot WARN in the Responses builder, matching the Chat builder. The
   [Thinking_object] capability resolves to a dialect that ignores
   [temperature] while thinking is enabled. *)
let test_responses_build_request_warns_on_dialect_suppressed_sampling () =
  let model_id = "codec-responses-sampling-warn" in
  let config =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/responses"
      ~max_tokens:128
      ~temperature:0.7
      ~enable_thinking:true
      ~model_capabilities_override:
        { Capabilities.default_capabilities with
          Capabilities.thinking_control_format = Capabilities.Thinking_object
        }
      ()
  in
  let warns = ref [] in
  let body =
    Diag.with_sink
      (fun level ~ctx message ->
         match level with
         | Diag.Warn -> warns := (ctx, message) :: !warns
         | Diag.Debug | Diag.Info | Diag.Error -> ())
      (fun () ->
         Responses.build_request ~config ~messages:[ msg User [ Text "hi" ] ] ()
         |> Yojson.Safe.from_string)
  in
  check_bool "temperature dropped from body" true (member "temperature" body = `Null);
  match !warns with
  | [ (ctx, _) ] -> check_string "sampling-drop warn ctx" "backend_openai" ctx
  | warns ->
    Alcotest.failf "expected exactly one sampling-drop warn, got %d" (List.length warns)
;;

(* Regression: the Responses builder routes advisory [Auto] tool_choice
   through the same capability gate as the Chat builder
   ([supports_tool_choice_override] wins over the capability record). *)
let test_responses_tool_choice_respects_capability_gate () =
  let make_config ~supports =
    Provider_config.make
      ~kind:OpenAI_compat
      ~model_id:"codec-responses-tool-choice-gate"
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/responses"
      ~max_tokens:128
      ~tool_choice:Auto
      ~supports_tool_choice_override:supports
      ()
  in
  let responses_body ~supports =
    Responses.build_request
      ~config:(make_config ~supports)
      ~messages:[ msg User [ Text "weather?" ] ]
      ()
    |> Yojson.Safe.from_string
  in
  check_bool
    "responses omits auto tool_choice when gate denies"
    true
    (member "tool_choice" (responses_body ~supports:false) = `Null);
  check_string
    "responses emits auto tool_choice when gate allows"
    "auto"
    (member "tool_choice" (responses_body ~supports:true) |> to_string);
  (* Parity: the Chat builder resolves the same gate to the same decision. *)
  let chat_body ~supports =
    Backend_openai.build_request
      ~config:(make_config ~supports)
      ~messages:[ msg User [ Text "weather?" ] ]
      ()
    |> Yojson.Safe.from_string
  in
  check_bool
    "chat omits auto tool_choice when gate denies"
    true
    (member "tool_choice" (chat_body ~supports:false) = `Null);
  check_string
    "chat emits auto tool_choice when gate allows"
    "auto"
    (member "tool_choice" (chat_body ~supports:true) |> to_string)
;;

let () =
  Alcotest.run
    "backend_openai_codec"
    [ ( "serialize"
      , [ Alcotest.test_case
            "content parts cover modalities"
            `Quick
            test_content_parts_cover_modalities
        ; Alcotest.test_case
            "openai user text/tool/empty"
            `Quick
            test_openai_user_messages_reject_tool_result_and_drop_empty
        ; Alcotest.test_case
            "non-base64 media source fail-closed"
            `Quick
            test_non_base64_media_source_fails_closed
        ; Alcotest.test_case
            "wire adjacency: nudged tool turn"
            `Quick
            test_wire_adjacency_nudged_tool_turn
        ; Alcotest.test_case
            "multimodal ordering policies"
            `Quick
            test_user_multimodal_preserve_and_visual_first
        ; Alcotest.test_case
            "ollama native multimodal variants"
            `Quick
            test_ollama_native_multimodal_variants
        ; Alcotest.test_case
            "assistant tool calls provider variants"
            `Quick
            test_assistant_tool_calls_openai_ollama_and_glm
        ; Alcotest.test_case
            "system and tool roles"
            `Quick
            test_system_and_tool_role_messages
        ; Alcotest.test_case
            "Kimi replay preserves historical reasoning"
            `Quick
            test_kimi_replay_trace_preserves_all_historical_reasoning
        ; Alcotest.test_case
            "tool choice and schema conversion"
            `Quick
            test_tool_choice_and_tool_schema_conversion
        ; Alcotest.test_case
            "ignored block variants"
            `Quick
            test_serializer_ignored_block_variants
        ; Alcotest.test_case
            "tool schema rejects invalid current shape"
            `Quick
            test_tool_schema_rejects_invalid_current_shape
        ; Alcotest.test_case
            "parallel_tool_calls fields SSOT"
            `Quick
            test_parallel_tool_calls_fields
        ] )
    ; ( "parse"
      , [ Alcotest.test_case "usage fallbacks" `Quick test_usage_openai_fallbacks
        ; Alcotest.test_case
            "text list reasoning and reported telemetry"
            `Quick
            test_parse_text_list_reasoning_and_reported_telemetry
        ; Alcotest.test_case
            "reasoning without token estimate preserves fenced JSON"
            `Quick
            test_parse_reasoning_without_reported_tokens_preserves_fenced_json
        ; Alcotest.test_case
            "tool calls reject malformed"
            `Quick
            test_parse_tool_calls_rejects_malformed_and_does_not_drop
        ; Alcotest.test_case
            "tool calls reject malformed arguments"
            `Quick
            test_parse_tool_calls_rejects_malformed_arguments
        ; Alcotest.test_case
            "tool calls reject non-object arguments"
            `Quick
            test_parse_tool_calls_rejects_non_object_arguments
        ; Alcotest.test_case
            "reasoning_content and tool_calls coexist"
            `Quick
            test_parse_reasoning_content_and_tool_calls_coexist
        ; Alcotest.test_case
            "reasoning_details and tool_calls coexist"
            `Quick
            test_parse_reasoning_details_and_tool_calls_coexist
        ; Alcotest.test_case
            "reasoning_details rejects malformed"
            `Quick
            test_parse_reasoning_details_rejects_malformed
        ; Alcotest.test_case
            "reasoning-only stays Thinking and is never re-injected on replay"
            `Quick
            test_reasoning_only_stays_thinking_and_never_reinjected_on_replay
        ; Alcotest.test_case
            "error default message"
            `Quick
            test_parse_error_default_message
        ; Alcotest.test_case
            "edge text shapes and telemetry"
            `Quick
            test_parse_edge_shapes_for_text_and_telemetry
        ] )
    ; ( "responses"
      , [ Alcotest.test_case
            "parse reasoning and function_call items"
            `Quick
            test_responses_parse_reasoning_and_function_call
        ; Alcotest.test_case
            "ignores hosted tool item and preserves message"
            `Quick
            test_responses_ignores_hosted_tool_item_and_preserves_message
        ; Alcotest.test_case
            "rejects function_call missing call_id"
            `Quick
            test_responses_rejects_function_call_missing_call_id
        ; Alcotest.test_case
            "rejects function_call non-object arguments"
            `Quick
            test_responses_rejects_function_call_non_object_arguments
        ; Alcotest.test_case
            "rejects function_call malformed arguments"
            `Quick
            test_responses_rejects_function_call_malformed_arguments
        ; Alcotest.test_case
            "incomplete status wins over function_call (#2048)"
            `Quick
            test_responses_incomplete_status_wins_over_function_call
        ; Alcotest.test_case
            "stop reason status table SSOT"
            `Quick
            test_responses_stop_reason_ssot_status_table
        ; Alcotest.test_case
            "preserve encrypted reasoning item for replay"
            `Quick
            test_responses_preserves_encrypted_reasoning_item_for_replay
        ; Alcotest.test_case
            "build request round-trips tool result items"
            `Quick
            test_responses_build_request_round_trips_tool_result_items
        ; Alcotest.test_case
            "build request preserves multiturn reasoning/tool order"
            `Quick
            test_responses_build_request_preserves_multiturn_reasoning_tool_order
        ; Alcotest.test_case
            "build request previous_response_id"
            `Quick
            test_responses_build_request_includes_previous_response_id
        ; Alcotest.test_case
            "build request rejects numeric thinking budget"
            `Quick
            test_responses_build_request_rejects_numeric_thinking_budget
        ; Alcotest.test_case
            "build request text.format json_schema"
            `Quick
            test_responses_build_request_uses_text_format_json_schema
        ; Alcotest.test_case
            "build request text.format json_object"
            `Quick
            test_responses_build_request_uses_text_format_json_object
        ; Alcotest.test_case
            "build request warns on max_tokens clamp"
            `Quick
            test_responses_build_request_warns_on_max_tokens_clamp
        ; Alcotest.test_case
            "build request warns on dialect-suppressed sampling"
            `Quick
            test_responses_build_request_warns_on_dialect_suppressed_sampling
        ; Alcotest.test_case
            "tool_choice respects capability gate"
            `Quick
            test_responses_tool_choice_respects_capability_gate
        ] )
    ]
;;
