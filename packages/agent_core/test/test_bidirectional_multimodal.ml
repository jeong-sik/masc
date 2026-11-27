open Alcotest
open Llm_provider
open Llm_provider.Types

module Cap = Capabilities
module PC = Provider_config
module S = Streaming
module OW = Openai_wire
module RD = Reasoning_dialect
module Acc = Complete_stream_acc

let image_output_testable =
  testable Cap.pp_image_output_contract Cap.equal_image_output_contract
;;

let dialect_testable =
  testable Cap.pp_images_api_dialect Cap.equal_images_api_dialect
;;

let media_caps_testable =
  testable Cap.pp_media_capabilities Cap.equal_media_capabilities
;;

let png_header_bytes = "\x89PNG\r\n\x1a\nfake-png-payload"
let png_header_b64 = Base64.encode_exn png_header_bytes
let jpeg_header_bytes = "\xff\xd8\xff\xe0fake-jpeg-payload"
let jpeg_header_b64 = Base64.encode_exn jpeg_header_bytes
let webp_header_bytes = "RIFF\x24\x00\x00\x00WEBPfake-webp"
let webp_header_b64 = Base64.encode_exn webp_header_bytes

let stream_error_msg = function
  | Stream_provider_error { message; _ } -> "provider_error: " ^ message
  | Stream_parse_failed { reason; _ } -> "parse_failed: " ^ reason
  | Stream_ndjson_parse_failed { reason; _ } -> "ndjson_parse_failed: " ^ reason
  | Stream_incomplete { reason } -> "incomplete: " ^ reason
  | Stream_unknown_event { event_type; _ } -> "unknown_event: " ^ event_type
  | Stream_unsupported_part { part; _ } -> "unsupported_part: " ^ part
  | Stream_unsupported_response { response; _ } -> "unsupported_response: " ^ response
;;

(* ── 1. Closed media capabilities & projections ───────────────────────── *)

let test_image_output_vocab_roundtrip () =
  let all_contracts =
    [ Cap.No_image_output
    ; Cap.In_turn_gemini_modalities
    ; Cap.In_turn_openai_responses_tool
    ; Cap.In_turn_openai_chat_modalities
    ; Cap.In_turn_codex_item
    ; Cap.In_turn_acp_chunk
    ; Cap.Endpoint_images_api Cap.Openai_images_v1
    ; Cap.Endpoint_images_api Cap.Zai_images_v4
    ; Cap.Endpoint_images_api Cap.Gemini_imagen_predict
    ]
  in
  List.iter
    (fun contract ->
      let s = Cap.image_output_contract_to_string contract in
      check
        (option image_output_testable)
        ("roundtrip " ^ s)
        (Some contract)
        (Cap.image_output_contract_of_string s))
    all_contracts;
  check
    (option image_output_testable)
    "unknown contract rejected"
    None
    (Cap.image_output_contract_of_string "dalle_magic");
  List.iter
    (fun dialect ->
      let s = Cap.images_api_dialect_to_string dialect in
      check
        (option dialect_testable)
        ("dialect roundtrip " ^ s)
        (Some dialect)
        (Cap.images_api_dialect_of_string s))
    [ Cap.Openai_images_v1; Cap.Zai_images_v4; Cap.Gemini_imagen_predict ];
  check
    (option dialect_testable)
    "unknown dialect rejected"
    None
    (Cap.images_api_dialect_of_string "unknown_dialect")
;;

let test_media_capabilities_projection () =
  (* Anthropic: inline_base64, remote_url, provider_file_id; inline tool results *)
  let anthropic_cfg =
    PC.make
      ~kind:PC.Anthropic
      ~model_id:"claude-sonnet-5"
      ~base_url:"https://api.anthropic.com"
      ~request_path:"/v1/messages"
      ~model_capabilities_override:Cap.anthropic_capabilities
      ()
  in
  let anth_media = PC.media_capabilities anthropic_cfg in
  check
    media_caps_testable
    "anthropic media capabilities"
    { Cap.vision_input =
        Cap.Native_vision_input
          { carriers = [ Cap.Inline_base64; Cap.Remote_url; Cap.Provider_file_id ]
          ; tool_results = Cap.Inline_in_tool_result
          ; modality_priority = Modality.Preserve_input_order
          }
    ; document_input = [ Cap.Inline_base64; Cap.Remote_url; Cap.Provider_file_id ]
    ; audio_input = []
    ; image_output = Cap.No_image_output
    }
    anth_media;
  check bool "anthropic vision input" true (Cap.supports_image_input_of_media anth_media);
  check bool "anthropic image output" false (Cap.supports_image_output_of_media anth_media);

  (* OpenAI Responses: supports provider_file_id and inline tool results + tool image gen *)
  let responses_cfg =
    PC.make
      ~kind:PC.OpenAI_compat
      ~provider_id:"openai-responses"
      ~model_id:"gpt-6-sol"
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/responses"
      ~model_capabilities_override:
        { Cap.openai_compat_chat_extended_capabilities with
          supports_document_input = true
        ; image_output = Cap.In_turn_openai_responses_tool
        }
      ()
  in
  let resp_media = PC.media_capabilities responses_cfg in
  check
    media_caps_testable
    "responses media capabilities"
    { Cap.vision_input =
        Cap.Native_vision_input
          { carriers = [ Cap.Inline_base64; Cap.Remote_url; Cap.Provider_file_id ]
          ; tool_results = Cap.Inline_in_tool_result
          ; modality_priority = Modality.Preserve_input_order
          }
    ; document_input = [ Cap.Inline_base64; Cap.Remote_url; Cap.Provider_file_id ]
    ; audio_input = []
    ; image_output = Cap.In_turn_openai_responses_tool
    }
    resp_media;
  check bool "responses image output" true (Cap.supports_image_output_of_media resp_media);

  (* OpenAI Chat / OpenRouter: hoisted tool results, no file_id *)
  let openrouter_cfg =
    PC.make
      ~kind:PC.OpenAI_compat
      ~provider_id:"openrouter"
      ~model_id:"google/gemini-2.5-flash-image"
      ~base_url:"https://openrouter.ai/api"
      ~request_path:"/v1/chat/completions"
      ~model_capabilities_override:
        { Cap.openai_compat_chat_extended_capabilities with
          supports_document_input = true
        ; image_output = Cap.In_turn_openai_chat_modalities
        }
      ()
  in
  let or_media = PC.media_capabilities openrouter_cfg in
  check
    media_caps_testable
    "openrouter chat media capabilities"
    { Cap.vision_input =
        Cap.Native_vision_input
          { carriers = [ Cap.Inline_base64; Cap.Remote_url; Cap.Provider_file_id ]
          ; tool_results = Cap.Hoisted_user_followup
          ; modality_priority = Modality.Preserve_input_order
          }
    ; document_input = [ Cap.Inline_base64; Cap.Provider_file_id ]
    ; audio_input = []
    ; image_output = Cap.In_turn_openai_chat_modalities
    }
    or_media;

  (* Gemini with function_response_parts + image modalities *)
  let gemini_cfg =
    PC.make
      ~kind:PC.Gemini
      ~model_id:"gemini-3.1-flash-image"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ~request_path:""
      ~model_capabilities_override:
        { Cap.gemini_capabilities with
          supports_function_response_parts = true
        ; image_output = Cap.In_turn_gemini_modalities
        }
      ()
  in
  let gem_media = PC.media_capabilities gemini_cfg in
  check
    media_caps_testable
    "gemini media capabilities"
    { Cap.vision_input =
        Cap.Native_vision_input
          { carriers = [ Cap.Inline_base64; Cap.Provider_file_uri ]
          ; tool_results = Cap.Native_function_response_parts
          ; modality_priority = Modality.Preserve_input_order
          }
    ; document_input = [ Cap.Inline_base64; Cap.Provider_file_uri ]
    ; audio_input = [ Cap.Inline_base64; Cap.Provider_file_uri ]
    ; image_output = Cap.In_turn_gemini_modalities
    }
    gem_media;

  (* Ollama vision model: inline base64 only *)
  let ollama_cfg =
    PC.make
      ~kind:PC.Ollama
      ~model_id:"qwen3-vl:8b"
      ~base_url:"http://127.0.0.1:11434"
      ~request_path:"/api/chat"
      ~model_capabilities_override:
        { Cap.ollama_capabilities with
          supports_multimodal_inputs = true
        ; supports_image_input = true
        }
      ()
  in
  let oll_media = PC.media_capabilities ollama_cfg in
  check
    media_caps_testable
    "ollama media capabilities"
    { Cap.vision_input =
        Cap.Native_vision_input
          { carriers = [ Cap.Inline_base64 ]
          ; tool_results = Cap.Inline_in_tool_result
          ; modality_priority = Modality.Preserve_input_order
          }
    ; document_input = []
    ; audio_input = []
    ; image_output = Cap.No_image_output
    }
    oll_media;

  (* Text-only model *)
  let text_only =
    Cap.media_capabilities_of_capabilities
      ~wire:Provider_kind.Ollama
      { Cap.ollama_capabilities with supports_image_input = false }
  in
  check bool "text-only vision" false (Cap.supports_image_input_of_media text_only);
  check bool "text-only image output" false (Cap.supports_image_output_of_media text_only)
;;

(* ── 2. models.toml / Manifest / Provider_catalog declarations ────────── *)

let test_models_toml_image_output_contracts () =
  let catalog =
    match Model_catalog.load_default () with
    | Ok c -> c
    | Error msg -> fail ("load_default failed: " ^ msg)
  in
  (* Verify gemini-image provider request_path fix *)
  (match
     Model_catalog.provider_entry_for_reference
       catalog
       (Model_catalog.Declared_provider "gemini-image")
   with
   | None -> fail "gemini-image provider missing from models.toml"
   | Some p -> check string "gemini-image request_path" "" p.request_path);
  let check_row provider_id model_id expected =
    let cfg =
      PC.make
        ~kind:PC.OpenAI_compat
        ~provider_id
        ~model_id
        ~base_url:"https://example.invalid"
        ~request_path:""
        ()
    in
    let caps =
      match PC.capabilities_for_config_model cfg with
      | Some c -> c
      | None -> fail (Printf.sprintf "missing catalog row %s / %s" provider_id model_id)
    in
    check
      image_output_testable
      (Printf.sprintf "%s / %s image_output" provider_id model_id)
      expected
      caps.image_output
  in
  check_row "gemini-image" "gemini-3.1-flash-image" Cap.In_turn_gemini_modalities;
  check_row "gemini-image" "gemini-2.5-flash-image" Cap.In_turn_gemini_modalities;
  check_row
    "gemini-image"
    "imagen-3.0-generate-002"
    (Cap.Endpoint_images_api Cap.Gemini_imagen_predict);
  check_row
    "gemini-image"
    "imagen-4.0-generate-001"
    (Cap.Endpoint_images_api Cap.Gemini_imagen_predict);
  check_row
    "openai-image"
    "gpt-image-2"
    (Cap.Endpoint_images_api Cap.Openai_images_v1);
  check_row
    "openai-image"
    "gpt-image-1"
    (Cap.Endpoint_images_api Cap.Openai_images_v1);
  check_row
    "zai-image"
    "glm-image"
    (Cap.Endpoint_images_api Cap.Zai_images_v4);
  check_row
    "zai-image"
    "cogview-4-250304"
    (Cap.Endpoint_images_api Cap.Zai_images_v4);
  check_row
    "openrouter-image"
    "google/gemini-2.5-flash-image"
    Cap.In_turn_openai_chat_modalities;
  check_row
    "openrouter-image"
    "google/gemini-3.1-flash-image"
    Cap.In_turn_openai_chat_modalities;
  check_row "openai-responses" "gpt-6-sol" Cap.In_turn_openai_responses_tool
;;

let test_manifest_and_provider_catalog_image_output () =
  let valid_manifest_json =
    Yojson.Safe.from_string
      {|{
        "schema_version": 2,
        "models": [
          {
            "model_id": "custom-image-model",
            "base": "openai_chat_extended",
            "image_output": "in_turn_openai_chat_modalities"
          }
        ]
      }|}
  in
  (match Capability_manifest.of_json valid_manifest_json with
   | Error msg -> fail ("manifest parse failed: " ^ msg)
   | Ok manifest ->
     let id = Result.get_ok (Model_identifiers.Model_id.of_string "custom-image-model") in
     match Capability_manifest.lookup manifest id with
     | None -> fail "missing custom-image-model"
     | Some entry ->
       check
         (option image_output_testable)
         "manifest image_output"
         (Some Cap.In_turn_openai_chat_modalities)
         entry.image_output);
  let invalid_manifest_json =
    Yojson.Safe.from_string
      {|{
        "schema_version": 2,
        "models": [
          {
            "model_id": "bad-image-model",
            "image_output": "not_a_real_contract"
          }
        ]
      }|}
  in
  check
    bool
    "invalid manifest image_output rejected"
    true
    (Result.is_error (Capability_manifest.of_json invalid_manifest_json));

  let valid_provider_json =
    Yojson.Safe.from_string
      {|{
        "schema_version": 1,
        "providers": [
          {
            "id": "custom-img-gw",
            "kind": "openai_compat",
            "base_url": "http://127.0.0.1:9000",
            "request_path": "/v1/chat/completions",
            "auth": {"type": "none"},
            "capabilities_base": "openai_chat",
            "capabilities": {
              "supports_image_input": true,
              "image_output": "in_turn_openai_chat_modalities"
            }
          }
        ]
      }|}
  in
  (match Provider_catalog.of_json valid_provider_json with
   | Error msg -> fail ("provider catalog parse failed: " ^ msg)
   | Ok cat ->
     match Provider_catalog.lookup cat "custom-img-gw" with
     | Some { capabilities = Some caps; _ } ->
       check
         image_output_testable
         "provider catalog image_output"
         Cap.In_turn_openai_chat_modalities
         caps.image_output
     | _ -> fail "expected capabilities on custom-img-gw");

  let invalid_provider_json =
    Yojson.Safe.from_string
      {|{
        "schema_version": 1,
        "providers": [
          {
            "id": "bad-img-gw",
            "kind": "openai_compat",
            "base_url": "http://127.0.0.1:9000",
            "request_path": "/v1/chat/completions",
            "auth": {"type": "none"},
            "capabilities_base": "openai_chat",
            "capabilities": {
              "image_output": "invalid_mode"
            }
          }
        ]
      }|}
  in
  check
    bool
    "invalid provider catalog image_output rejected"
    true
    (Result.is_error (Provider_catalog.of_json invalid_provider_json))
;;

(* ── 3. Gemini bidirectional wire codec ───────────────────────────────── *)

let test_gemini_file_uri_and_typed_errors () =
  let cfg =
    PC.make
      ~kind:PC.Gemini
      ~model_id:"gemini-3.5-flash"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ~request_path:""
      ~model_capabilities_override:
        { Cap.gemini_capabilities with
          supports_function_response_parts = true
        }
      ()
  in
  (* Url carrier maps to fileData in both user parts and functionResponse.parts *)
  let messages =
    [ { role = User
      ; content =
          [ Text "Inspect this file"
          ; Image
              { media_type = "image/png"
              ; source = Url "https://generativelanguage.googleapis.com/v1beta/files/abc123"
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; origin = Conversation
      ; metadata = []
      }
    ; { role = Assistant
      ; content =
          [ ToolUse
              { id = "call_1"; name = "capture_screen"; input = `Assoc [] }
          ]
      ; name = None
      ; tool_call_id = None
      ; origin = Conversation
      ; metadata = []
      }
    ; { role = Tool
      ; content =
          [ ToolResult
              { tool_use_id = "call_1"
              ; content = "captured"
              ; outcome = Tool_succeeded
              ; json = None
              ; content_blocks =
                  Some
                    [ Image
                        { media_type = "image/jpeg"
                        ; source = Url "gs://my-bucket/frame.jpg"
                        }
                    ]
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; origin = Conversation
      ; metadata = []
      }
    ]
  in
  (match Backend_gemini.build_request_artifact_result ~config:cfg ~messages () with
   | Error msg -> fail ("gemini fileData build failed: " ^ msg)
   | Ok artifact ->
     let json = Yojson.Safe.from_string (Backend_gemini.request_payload artifact) in
     let open Yojson.Safe.Util in
     let contents = json |> member "contents" |> to_list in
     let user_parts = List.nth contents 0 |> member "parts" |> to_list in
     let file_data = List.nth user_parts 1 |> member "fileData" in
     check string "user fileData mimeType" "image/png" (file_data |> member "mimeType" |> to_string);
     check
       string
       "user fileData fileUri"
       "https://generativelanguage.googleapis.com/v1beta/files/abc123"
       (file_data |> member "fileUri" |> to_string);
     let tool_parts = List.nth contents 2 |> member "parts" |> to_list in
     let fn_resp_parts =
       List.nth tool_parts 0 |> member "functionResponse" |> member "parts" |> to_list
     in
     let fn_file_data = List.nth fn_resp_parts 0 |> member "fileData" in
     check
       string
       "tool fileData mimeType"
       "image/jpeg"
       (fn_file_data |> member "mimeType" |> to_string);
     check
       string
       "tool fileData fileUri"
       "gs://my-bucket/frame.jpg"
       (fn_file_data |> member "fileUri" |> to_string));

  (* File_id returns typed Error (no Invalid_argument crash) *)
  let bad_file_id_msgs =
    [ { role = User
      ; content = [ Image { media_type = "image/png"; source = File_id "file_xyz" } ]
      ; name = None
      ; tool_call_id = None
      ; origin = Conversation
      ; metadata = []
      }
    ]
  in
  check
    bool
    "gemini rejects File_id with typed Error"
    true
    (Result.is_error
       (Backend_gemini.build_request_artifact_result ~config:cfg ~messages:bad_file_id_msgs ()));

  (* Blank Url returns typed Error *)
  let blank_url_msgs =
    [ { role = User
      ; content = [ Image { media_type = "image/png"; source = Url "   " } ]
      ; name = None
      ; tool_call_id = None
      ; origin = Conversation
      ; metadata = []
      }
    ]
  in
  check
    bool
    "gemini rejects blank Url with typed Error"
    true
    (Result.is_error
       (Backend_gemini.build_request_artifact_result ~config:cfg ~messages:blank_url_msgs ()))
;;

let test_gemini_image_output_modalities_and_config () =
  let base_messages =
    [ { role = User
      ; content = [ Text "Draw a sunset over mountains" ]
      ; name = None
      ; tool_call_id = None
      ; origin = Conversation
      ; metadata = []
      }
    ]
  in
  (* Normal text model without output_media omits responseModalities and imageConfig *)
  let text_cfg =
    PC.make
      ~kind:PC.Gemini
      ~model_id:"gemini-3.5-flash"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ~request_path:""
      ~model_capabilities_override:Cap.gemini_capabilities
      ()
  in
  let text_json =
    Backend_gemini.build_request ~config:text_cfg ~messages:base_messages ()
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  let text_gc = text_json |> member "generationConfig" in
  check bool "text model omits responseModalities" true (text_gc |> member "responseModalities" = `Null);
  check bool "text model omits imageConfig" true (text_gc |> member "imageConfig" = `Null);

  (* Model with In_turn_gemini_modalities + output_media emits responseModalities + imageConfig + candidateCount *)
  let image_cfg =
    PC.make
      ~kind:PC.Gemini
      ~model_id:"gemini-3.1-flash-image"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ~request_path:""
      ~output_media:
        { PC.aspect_ratio = Some "16:9"
        ; size = Some "2K"
        ; quality = None
        ; count = Some 2
        }
      ~model_capabilities_override:
        { Cap.gemini_capabilities with image_output = Cap.In_turn_gemini_modalities }
      ()
  in
  let img_json =
    Backend_gemini.build_request ~config:image_cfg ~messages:base_messages ()
    |> Yojson.Safe.from_string
  in
  let gc = img_json |> member "generationConfig" in
  let modalities = gc |> member "responseModalities" |> to_list |> List.map to_string in
  check (list string) "responseModalities" [ "TEXT"; "IMAGE" ] modalities;
  let ic = gc |> member "imageConfig" in
  check string "aspectRatio" "16:9" (ic |> member "aspectRatio" |> to_string);
  check string "imageSize" "2K" (ic |> member "imageSize" |> to_string);
  check int "candidateCount" 2 (gc |> member "candidateCount" |> to_int);

  (* Default auto responseModalities when output_media = None *)
  let default_img_cfg = { image_cfg with output_media = None } in
  let default_img_json =
    Backend_gemini.build_request ~config:default_img_cfg ~messages:base_messages ()
    |> Yojson.Safe.from_string
  in
  let default_modalities =
    default_img_json
    |> member "generationConfig"
    |> member "responseModalities"
    |> to_list
    |> List.map to_string
  in
  check (list string) "auto responseModalities" [ "TEXT"; "IMAGE" ] default_modalities;

  (* Non-positive output_media.count fails closed as typed Error in build_request_artifact_result *)
  let bad_count_cfg =
    { image_cfg with
      output_media = Some { PC.default_image_generation_options with count = Some 0 }
    }
  in
  check
    bool
    "gemini non-positive count returns typed Error"
    true
    (Result.is_error
       (Backend_gemini.build_request_artifact_result
          ~config:bad_count_cfg
          ~messages:base_messages
          ()))
;;

(* ── 4. Ollama typed carrier refusal ──────────────────────────────────── *)

let test_ollama_typed_media_refusals () =
  let cfg =
    PC.make
      ~kind:PC.Ollama
      ~model_id:"qwen3-vl:8b"
      ~base_url:"http://127.0.0.1:11434"
      ~request_path:"/api/chat"
      ~model_capabilities_override:
        { Cap.ollama_capabilities with
          supports_multimodal_inputs = true
        ; supports_image_input = true
        }
      ()
  in
  let user_url_msgs =
    [ { role = User
      ; content = [ Image { media_type = "image/png"; source = Url "https://example.com/a.png" } ]
      ; name = None
      ; tool_call_id = None
      ; origin = Conversation
      ; metadata = []
      }
    ]
  in
  check
    bool
    "ollama rejects Url with Error"
    true
    (Result.is_error
       (Backend_ollama.build_request_artifact_result ~config:cfg ~messages:user_url_msgs ()));
  let user_file_id_msgs =
    [ { role = User
      ; content = [ Image { media_type = "image/png"; source = File_id "file_1" } ]
      ; name = None
      ; tool_call_id = None
      ; origin = Conversation
      ; metadata = []
      }
    ]
  in
  check
    bool
    "ollama rejects File_id with Error"
    true
    (Result.is_error
       (Backend_ollama.build_request_artifact_result ~config:cfg ~messages:user_file_id_msgs ()));
  let bad_num_ctx_cfg = { cfg with num_ctx = Some 0 } in
  check
    bool
    "ollama rejects non-positive num_ctx with typed Error"
    true
    (Result.is_error
       (Backend_ollama.build_request_artifact_result
          ~config:bad_num_ctx_cfg
          ~messages:
            [ { role = User
              ; content = [ Text "hi" ]
              ; name = None
              ; tool_call_id = None
              ; origin = Conversation
              ; metadata = []
              }
            ]
          ()));
  let base64_msgs =
    [ { role = User
      ; content =
          [ Text "describe"
          ; Image { media_type = "image/png"; source = Base64 png_header_b64 }
          ]
      ; name = None
      ; tool_call_id = None
      ; origin = Conversation
      ; metadata = []
      }
    ]
  in
  match Backend_ollama.build_request_artifact_result ~config:cfg ~messages:base64_msgs () with
  | Error msg -> fail ("ollama base64 image failed: " ^ msg)
  | Ok artifact ->
    let open Yojson.Safe.Util in
    let json = Yojson.Safe.from_string (Backend_ollama.request_payload artifact) in
    let msg0 = json |> member "messages" |> to_list |> List.hd in
    let images = msg0 |> member "images" |> to_list |> List.map to_string in
    check (list string) "ollama images array" [ png_header_b64 ] images
;;

(* ── 5. OpenAI Responses bidirectional image generation ───────────────── *)

let test_openai_responses_image_generation_sync_and_stream () =
  let cfg =
    PC.make
      ~kind:PC.OpenAI_compat
      ~provider_id:"openai-responses"
      ~model_id:"gpt-6-sol"
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/responses"
      ~output_media:
        { PC.aspect_ratio = None
        ; size = Some "1024x1024"
        ; quality = Some "high"
        ; count = None
        }
      ~model_capabilities_override:
        { Cap.openai_compat_chat_extended_capabilities with
          supports_document_input = true
        ; image_output = Cap.In_turn_openai_responses_tool
        }
      ()
  in
  let messages =
    [ { role = User
      ; content = [ Text "Generate a geometric icon" ]
      ; name = None
      ; tool_call_id = None
      ; origin = Conversation
      ; metadata = []
      }
    ]
  in
  let body =
    Backend_openai_responses.build_request ~config:cfg ~messages ()
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  let tools = body |> member "tools" |> to_list in
  check int "1 built-in image_generation tool" 1 (List.length tools);
  let tool0 = List.hd tools in
  check string "tool type" "image_generation" (tool0 |> member "type" |> to_string);
  check string "tool size" "1024x1024" (tool0 |> member "size" |> to_string);
  check string "tool quality" "high" (tool0 |> member "quality" |> to_string);

  (* When image_output = No_image_output, tool is not injected *)
  let no_img_cfg =
    { cfg with
      model_capabilities_override =
        Some
          { Cap.openai_compat_chat_extended_capabilities with
            image_output = Cap.No_image_output
          }
    }
  in
  let no_img_body =
    Backend_openai_responses.build_request ~config:no_img_cfg ~messages ()
    |> Yojson.Safe.from_string
  in
  check bool "no tools injected when No_image_output" true (no_img_body |> member "tools" = `Null);

  (* Sync parse of image_generation_call output item *)
  let sync_json =
    Printf.sprintf
      {|{
        "id": "resp_img_1",
        "model": "gpt-6-sol",
        "status": "completed",
        "output": [
          {
            "type": "image_generation_call",
            "id": "ig_1",
            "status": "completed",
            "output_format": "webp",
            "result": %s
          },
          {
            "type": "message",
            "role": "assistant",
            "content": [{"type": "output_text", "text": "Here is your icon."}]
          }
        ],
        "usage": {"input_tokens": 12, "output_tokens": 34}
      }|}
      (Yojson.Safe.to_string (`String webp_header_b64))
  in
  (match Backend_openai_responses.parse_response_result sync_json with
   | Error err -> fail ("responses sync parse failed: " ^ err.detail)
   | Ok parsed ->
     match parsed.response.content with
     | [ Image { media_type; source = Base64 data }; Text caption ] ->
       check string "sync webp mime" "image/webp" media_type;
       check string "sync webp data" webp_header_b64 data;
       check string "sync caption" "Here is your icon." caption
     | _ -> fail "expected [Image; Text] from Responses sync parse");

  (* Sync parse: omitted output_format sniffs JPEG magic header instead of defaulting to PNG *)
  let sync_sniff_json =
    Printf.sprintf
      {|{"id":"resp_img_2","model":"gpt-6-sol","status":"completed","output":[{"type":"image_generation_call","id":"ig_2","status":"completed","result":%s}]}|}
      (Yojson.Safe.to_string (`String jpeg_header_b64))
  in
  (match Backend_openai_responses.parse_response_result sync_sniff_json with
   | Error err -> fail ("responses sync sniff failed: " ^ err.detail)
   | Ok parsed ->
     match parsed.response.content with
     | [ Image { media_type; _ } ] -> check string "sniffed jpeg mime" "image/jpeg" media_type
     | _ -> fail "expected sniffed JPEG Image");

  (* Sync parse & stream fail closed on explicit unsupported output_format with non-raster payload *)
  let svg_b64 = Base64.encode_exn "<svg xmlns='http://www.w3.org/2000/svg'/>" in
  let bad_fmt_sync_json =
    Printf.sprintf
      {|{"id":"resp_img_3","model":"gpt-6-sol","status":"completed","output":[{"type":"image_generation_call","id":"ig_3","status":"completed","output_format":"svg","result":%s}]}|}
      (Yojson.Safe.to_string (`String svg_b64))
  in
  check
    bool
    "responses sync rejects unknown svg output_format"
    true
    (Result.is_error (Backend_openai_responses.parse_response_result bad_fmt_sync_json));
  let st_bad = S.create_openai_stream_state ~provider:"openai-responses" ~model:"gpt-6-sol" () in
  let bad_stream_events, _ =
    S.responses_sse_to_events
      st_bad
      (Some "response.image_generation_call.completed")
      (Printf.sprintf
         {|{"type":"response.image_generation_call.completed","output_index":0,"output_format":"svg","result":%s}|}
         (Yojson.Safe.to_string (`String svg_b64)))
  in
  check
    bool
    "responses stream emits SSEParseFailed on unknown svg output_format"
    true
    (List.exists (function SSEParseFailed _ -> true | _ -> false) bad_stream_events);

  (* Streaming: partial_image buffered, final output_item.done emits once cleanly *)
  let st = S.create_openai_stream_state ~provider:"openai-responses" ~model:"gpt-6-sol" () in
  let acc = Acc.create_stream_acc () in
  let feed event_type payload =
    let events, _ = S.responses_sse_to_events st (Some event_type) payload in
    List.iter (Acc.accumulate_event acc) events
  in
  feed "response.created" {|{"type":"response.created","response":{"id":"resp_s1","model":"gpt-6-sol"}}|};
  feed "response.image_generation_call.in_progress" {|{"type":"response.image_generation_call.in_progress","output_index":0,"item_id":"ig_1"}|};
  feed "response.image_generation_call.generating" {|{"type":"response.image_generation_call.generating","output_index":0,"item_id":"ig_1"}|};
  feed
    "response.image_generation_call.partial_image"
    (Printf.sprintf
       {|{"type":"response.image_generation_call.partial_image","output_index":0,"partial_image_index":0,"partial_image_b64":%s,"output_format":"png"}|}
       (Yojson.Safe.to_string (`String jpeg_header_b64)));
  feed
    "response.output_item.done"
    (Printf.sprintf
       {|{"type":"response.output_item.done","output_index":0,"item":{"type":"image_generation_call","id":"ig_1","status":"completed","output_format":"png","result":%s}}|}
       (Yojson.Safe.to_string (`String png_header_b64)));
  feed
    "response.completed"
    {|{"type":"response.completed","response":{"id":"resp_s1","model":"gpt-6-sol","status":"completed","usage":{"input_tokens":5,"output_tokens":10}}}|};
  (match Acc.finalize_stream_acc acc with
   | Error err -> fail ("responses stream finalize failed: " ^ stream_error_msg err)
   | Ok resp ->
     match resp.content with
     | [ Image { media_type; source = Base64 data } ] ->
       check string "stream final mime" "image/png" media_type;
       check string "stream final b64 not corrupted by partial" png_header_b64 data
     | _ -> fail "expected single finalized Image from Responses stream");

  (* Streaming incomplete: partial_image preview must NOT be flushed as a completed final image *)
  let st2 = S.create_openai_stream_state ~provider:"openai-responses" ~model:"gpt-6-sol" () in
  let acc2 = Acc.create_stream_acc () in
  let feed2 event_type payload =
    let events, _ = S.responses_sse_to_events st2 (Some event_type) payload in
    List.iter (Acc.accumulate_event acc2) events
  in
  feed2 "response.created" {|{"type":"response.created","response":{"id":"resp_s2","model":"gpt-6-sol"}}|};
  feed2
    "response.image_generation_call.partial_image"
    (Printf.sprintf
       {|{"type":"response.image_generation_call.partial_image","output_index":0,"partial_image_b64":%s,"output_format":"jpeg"}|}
       (Yojson.Safe.to_string (`String jpeg_header_b64)));
  feed2
    "response.incomplete"
    {|{"type":"response.incomplete","response":{"id":"resp_s2","model":"gpt-6-sol","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"image_generation_call","id":"ig_2","status":"incomplete"}]}}|};
  match Acc.finalize_stream_acc acc2 with
  | Error err -> fail ("responses incomplete stream finalize failed: " ^ stream_error_msg err)
  | Ok resp ->
    check
      int
      "incomplete Responses stream emits zero final Image blocks"
      0
      (List.length
         (List.filter (function Image _ -> true | _ -> false) resp.content))
;;

(* ── 6. OpenAI Chat / OpenRouter bidirectional image generation ───────── *)

let test_openrouter_chat_image_generation_sync_and_stream () =
  let cfg =
    PC.make
      ~kind:PC.OpenAI_compat
      ~provider_id:"openrouter"
      ~model_id:"google/gemini-2.5-flash-image"
      ~base_url:"https://openrouter.ai/api"
      ~request_path:"/v1/chat/completions"
      ~output_media:
        { PC.aspect_ratio = Some "16:9"
        ; size = Some "1K"
        ; quality = None
        ; count = None
        }
      ~model_capabilities_override:
        { Cap.openai_compat_chat_extended_capabilities with
          supports_document_input = true
        ; image_output = Cap.In_turn_openai_chat_modalities
        }
      ()
  in
  let messages =
    [ { role = User
      ; content = [ Text "Create a banner" ]
      ; name = None
      ; tool_call_id = None
      ; origin = Conversation
      ; metadata = []
      }
    ]
  in
  let req = Backend_openai_request.build_request_assoc ~config:cfg ~messages () in
  let open Yojson.Safe.Util in
  let modalities = req |> member "modalities" |> to_list |> List.map to_string in
  check (list string) "chat modalities" [ "image"; "text" ] modalities;
  let img_cfg = req |> member "image_config" in
  check string "chat aspect_ratio" "16:9" (img_cfg |> member "aspect_ratio" |> to_string);
  check string "chat image_size" "1K" (img_cfg |> member "image_size" |> to_string);

  (* Sync parse: image-only message (content = null) succeeds instead of Empty_completion *)
  let data_uri = "data:image/png;base64," ^ png_header_b64 in
  let sync_body =
    Printf.sprintf
      {|{
        "id": "gen-or-img-1",
        "model": "google/gemini-2.5-flash-image",
        "choices": [{
          "index": 0,
          "finish_reason": "stop",
          "message": {
            "role": "assistant",
            "content": null,
            "images": [
              {"type": "image_url", "image_url": {"url": %s}},
              {"type": "image_url", "image_url": {"url": "https://cdn.example.com/out.webp"}},
              {"type": "image_url", "image_url": {"url": "https://cdn.example.com/asset/99?sig=1"}}
            ]
          }
        }]
      }|}
      (Yojson.Safe.to_string (`String data_uri))
  in
  (match Backend_openai_parse.parse_openai_response_result sync_body with
   | Error err ->
     fail ("openrouter image-only sync parse failed: " ^ Backend_openai_parse.parse_error_to_string err)
   | Ok resp ->
     match resp.content with
     | [ Image { media_type = m1; source = Base64 d1 }
       ; Image { media_type = m2; source = Url u2 }
       ; Image { media_type = m3; source = Url u3 }
       ] ->
       check string "sync data uri mime" "image/png" m1;
       check string "sync data uri b64" png_header_b64 d1;
       check string "sync remote url mime" "image/webp" m2;
       check string "sync remote url" "https://cdn.example.com/out.webp" u2;
       check string "extensionless url uses unknown sentinel not png" Api_common.unknown_media_type m3;
       check (option string) "extensionless url declared_media_type_opt is None" None (Api_common.declared_media_type_opt m3);
       check string "sync extensionless url" "https://cdn.example.com/asset/99?sig=1" u3
     | _ -> fail "expected three Images from OpenRouter sync parse");

  (* Streaming parse of delta.images[] *)
  let st =
    S.create_openai_stream_state
      ~provider:"openrouter"
      ~model:"google/gemini-2.5-flash-image"
      ()
  in
  let acc = Acc.create_stream_acc () in
  let feed_sse raw =
    let parsed =
      OW.parse_openai_sse_chunk ~streaming_reasoning:RD.No_streaming_reasoning raw
    in
    let events, _ = S.openai_sse_parse_result_to_events st parsed in
    List.iter (Acc.accumulate_event acc) events
  in
  feed_sse
    (Printf.sprintf
       {|{"id":"gen-s1","model":"google/gemini-2.5-flash-image","choices":[{"index":0,"delta":{"role":"assistant","content":"Done: ","images":[{"type":"image_url","image_url":{"url":%s}}]},"finish_reason":null}]}|}
       (Yojson.Safe.to_string (`String data_uri)));
  feed_sse
    {|{"id":"gen-s1","model":"google/gemini-2.5-flash-image","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}|};
  feed_sse "[DONE]";
  match Acc.finalize_stream_acc acc with
  | Error err -> fail ("openrouter stream finalize failed: " ^ stream_error_msg err)
  | Ok resp ->
    match resp.content with
    | [ Text "Done: "; Image { media_type; source = Base64 d } ] ->
      check string "stream image mime" "image/png" media_type;
      check string "stream image b64" png_header_b64 d
    | _ -> fail "expected [Text; Image] from OpenRouter stream"
;;

(* ── 7. Unified Api_common image degradation ──────────────────────────── *)

let test_unified_image_degradation () =
  let img_msg =
    [ { role = User
      ; content =
          [ Text "Look"
          ; Image { media_type = "image/png"; source = Base64 png_header_b64 }
          ]
      ; name = None
      ; tool_call_id = None
      ; origin = Conversation
      ; metadata = []
      }
    ]
  in
  let anthropic_no_vision =
    PC.make
      ~kind:PC.Anthropic
      ~model_id:"text-only-claude"
      ~base_url:"https://api.anthropic.com"
      ~request_path:"/v1/messages"
      ~model_capabilities_override:
        { Cap.anthropic_capabilities with supports_image_input = false }
      ()
  in
  let expected_placeholder = Api_common.image_omitted_placeholder ~media_type:"image/png" in
  (match Backend_anthropic.project_history anthropic_no_vision img_msg with
   | Error _ -> fail "anthropic project_history failed"
   | Ok proj ->
     match proj.messages with
     | [ { content = [ Text "Look"; block ]; _ } ] when block = expected_placeholder -> ()
     | _ -> fail "expected degraded image placeholder in anthropic project_history");

  let responses_no_vision =
    PC.make
      ~kind:PC.OpenAI_compat
      ~provider_id:"openai-responses"
      ~model_id:"text-only-responses"
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/responses"
      ~model_capabilities_override:
        { Cap.openai_compat_chat_extended_capabilities with supports_image_input = false }
      ()
  in
  match Backend_openai_responses.project_history responses_no_vision img_msg with
  | Error _ -> fail "responses project_history failed"
  | Ok proj ->
    match proj.messages with
    | [ { content = [ Text "Look"; block ]; _ } ] when block = expected_placeholder -> ()
    | _ -> fail "expected degraded image placeholder in responses project_history"
;;

(* ── 8. Standalone Image_gen dialects + Eio loopback HTTP ─────────────── *)

let test_image_gen_dialects_pure () =
  let openai_cfg =
    PC.make
      ~kind:PC.OpenAI_compat
      ~provider_id:"openai-image"
      ~model_id:"gpt-image-2"
      ~base_url:"https://api.openai.com"
      ~request_path:"/v1/images/generations"
      ~model_capabilities_override:
        { Cap.default_capabilities with
          image_output = Cap.Endpoint_images_api Cap.Openai_images_v1
        }
      ()
  in
  let zai_cfg =
    PC.make
      ~kind:PC.Glm
      ~provider_id:"zai-image"
      ~model_id:"glm-image"
      ~base_url:"https://api.z.ai/api/paas/v4"
      ~request_path:"/images/generations"
      ~model_capabilities_override:
        { Cap.default_capabilities with
          image_output = Cap.Endpoint_images_api Cap.Zai_images_v4
        }
      ()
  in
  let imagen_cfg =
    PC.make
      ~kind:PC.Gemini
      ~provider_id:"gemini-image"
      ~model_id:"imagen-3.0-generate-002"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ~request_path:""
      ~model_capabilities_override:
        { Cap.default_capabilities with
          image_output = Cap.Endpoint_images_api Cap.Gemini_imagen_predict
        }
      ()
  in
  check
    (result dialect_testable string)
    "openai dialect"
    (Ok Cap.Openai_images_v1)
    (Image_gen.dialect_of_config openai_cfg);
  check
    (result dialect_testable string)
    "zai dialect"
    (Ok Cap.Zai_images_v4)
    (Image_gen.dialect_of_config zai_cfg);
  check
    (result dialect_testable string)
    "imagen dialect"
    (Ok Cap.Gemini_imagen_predict)
    (Image_gen.dialect_of_config imagen_cfg);
  let non_standalone_cfg =
    { openai_cfg with
      model_capabilities_override =
        Some { Cap.default_capabilities with image_output = Cap.In_turn_gemini_modalities }
    }
  in
  check
    bool
    "in-turn contract rejected by dialect_of_config"
    true
    (Result.is_error (Image_gen.dialect_of_config non_standalone_cfg));

  (* URL construction: explicit request_path, blank request_path w/ bare origin & versioned base *)
  check
    string
    "openai url"
    "https://api.openai.com/v1/images/generations"
    (Image_gen.request_url ~dialect:Cap.Openai_images_v1 ~config:openai_cfg);
  check
    string
    "openai blank path on bare origin"
    "https://api.openai.com/v1/images/generations"
    (Image_gen.request_url
       ~dialect:Cap.Openai_images_v1
       ~config:{ openai_cfg with base_url = "https://api.openai.com"; request_path = "" });
  check
    string
    "openai blank path on /v1 base"
    "https://api.openai.com/v1/images/generations"
    (Image_gen.request_url
       ~dialect:Cap.Openai_images_v1
       ~config:{ openai_cfg with base_url = "https://api.openai.com/v1"; request_path = "" });
  check
    string
    "zai url"
    "https://api.z.ai/api/paas/v4/images/generations"
    (Image_gen.request_url ~dialect:Cap.Zai_images_v4 ~config:zai_cfg);
  check
    string
    "zai blank path on bare origin"
    "https://api.z.ai/api/paas/v4/images/generations"
    (Image_gen.request_url
       ~dialect:Cap.Zai_images_v4
       ~config:{ zai_cfg with base_url = "https://api.z.ai"; request_path = "" });
  check
    string
    "zai blank path on /api/paas/v4 base"
    "https://api.z.ai/api/paas/v4/images/generations"
    (Image_gen.request_url
       ~dialect:Cap.Zai_images_v4
       ~config:{ zai_cfg with base_url = "https://api.z.ai/api/paas/v4"; request_path = "" });
  check
    string
    "imagen predict url"
    "https://generativelanguage.googleapis.com/v1beta/models/imagen-3.0-generate-002:predict"
    (Image_gen.request_url ~dialect:Cap.Gemini_imagen_predict ~config:imagen_cfg);
  check
    (option string)
    "infer_image_mime_of_url_opt strips query and fragment"
    (Some "image/webp")
    (Api_common.infer_image_mime_of_url_opt "https://cdn.example.com/pic.WEBP?sig=1#top");
  check
    (option string)
    "infer_image_mime_of_url_opt returns None for extensionless URL"
    None
    (Api_common.infer_image_mime_of_url_opt "https://cdn.example.com/asset/42?token=abc");
  check int "image_gen max_response_bytes is 64 MiB" (64 * 1024 * 1024) Image_gen.max_response_bytes;

  (* Validation failures *)
  check
    bool
    "blank prompt rejected"
    true
    (Result.is_error
       (Image_gen.build_request_body
          ~dialect:Cap.Openai_images_v1
          ~config:openai_cfg
          (Image_gen.make_request "   ")));
  check
    bool
    "non-positive count rejected"
    true
    (Result.is_error
       (Image_gen.build_request_body
          ~dialect:Cap.Openai_images_v1
          ~config:openai_cfg
          (Image_gen.make_request ~count:0 "cat")));
  check
    bool
    "unrecognized output_format rejected"
    true
    (Result.is_error
       (Image_gen.build_request_body
          ~dialect:Cap.Gemini_imagen_predict
          ~config:imagen_cfg
          (Image_gen.make_request ~output_format:"bmp" "cat")));
  check
    bool
    "negative_prompt rejected on openai_images_v1"
    true
    (Result.is_error
       (Image_gen.build_request_body
          ~dialect:Cap.Openai_images_v1
          ~config:openai_cfg
          (Image_gen.make_request ~negative_prompt:"no text" "cat")));
  check
    bool
    "negative_prompt rejected on zai_images_v4"
    true
    (Result.is_error
       (Image_gen.build_request_body
          ~dialect:Cap.Zai_images_v4
          ~config:zai_cfg
          (Image_gen.make_request ~negative_prompt:"no watermark" "cat")));

  (* unsupported_options & unsupported_options_for_contract *)
  let full_req =
    Image_gen.make_request
      ~aspect_ratio:"16:9"
      ~size:"1024x1024"
      ~quality:"hd"
      ~count:2
      ~output_format:"png"
      ~negative_prompt:"blurry"
      "a calm lighthouse"
  in
  check
    (list string)
    "openai_images_v1 unsupported options"
    [ "aspect_ratio"; "negative_prompt" ]
    (Image_gen.unsupported_options ~dialect:Cap.Openai_images_v1 full_req);
  check
    (list string)
    "zai_images_v4 unsupported options"
    [ "aspect_ratio"; "count"; "output_format"; "negative_prompt" ]
    (Image_gen.unsupported_options ~dialect:Cap.Zai_images_v4 full_req);
  check
    (list string)
    "gemini_imagen_predict unsupported options"
    [ "quality" ]
    (Image_gen.unsupported_options ~dialect:Cap.Gemini_imagen_predict full_req);
  check
    (list string)
    "in_turn_gemini_modalities unsupported options"
    [ "quality"; "output_format"; "negative_prompt" ]
    (Image_gen.unsupported_options_for_contract
       ~contract:Cap.In_turn_gemini_modalities
       full_req);
  check
    (list string)
    "in_turn_openai_responses_tool unsupported options"
    [ "aspect_ratio"; "count"; "output_format"; "negative_prompt" ]
    (Image_gen.unsupported_options_for_contract
       ~contract:Cap.In_turn_openai_responses_tool
       full_req);
  check
    (list string)
    "in_turn_openai_chat_modalities unsupported options"
    [ "quality"; "count"; "output_format"; "negative_prompt" ]
    (Image_gen.unsupported_options_for_contract
       ~contract:Cap.In_turn_openai_chat_modalities
       full_req);
  check
    (list string)
    "zai count=1 is not flagged as unsupported"
    []
    (Image_gen.unsupported_options
       ~dialect:Cap.Zai_images_v4
       (Image_gen.make_request ~size:"1024x1024" ~quality:"hd" ~count:1 "cat"));

  (* Request body serialization across all 3 dialects (no negative_prompt on OpenAI/ZAI) *)
  let no_neg_req = { full_req with negative_prompt = None } in
  let open Yojson.Safe.Util in
  (match Image_gen.build_request_body ~dialect:Cap.Openai_images_v1 ~config:openai_cfg no_neg_req with
   | Error msg -> fail msg
   | Ok body ->
     let j = Yojson.Safe.from_string body in
     check string "openai model" "gpt-image-2" (j |> member "model" |> to_string);
     check string "openai size" "1024x1024" (j |> member "size" |> to_string);
     check string "openai quality" "hd" (j |> member "quality" |> to_string);
     check int "openai n" 2 (j |> member "n" |> to_int);
     check string "openai output_format" "png" (j |> member "output_format" |> to_string));

  (match Image_gen.build_request_body ~dialect:Cap.Zai_images_v4 ~config:zai_cfg no_neg_req with
   | Error msg -> fail msg
   | Ok body ->
     let j = Yojson.Safe.from_string body in
     check string "zai model" "glm-image" (j |> member "model" |> to_string);
     check string "zai size" "1024x1024" (j |> member "size" |> to_string);
     check string "zai quality" "hd" (j |> member "quality" |> to_string));

  (match Image_gen.build_request_body ~dialect:Cap.Gemini_imagen_predict ~config:imagen_cfg full_req with
   | Error msg -> fail msg
   | Ok body ->
     let j = Yojson.Safe.from_string body in
     let inst = j |> member "instances" |> to_list |> List.hd in
     check string "imagen prompt" "a calm lighthouse" (inst |> member "prompt" |> to_string);
     let params = j |> member "parameters" in
     check int "imagen sampleCount" 2 (params |> member "sampleCount" |> to_int);
     check string "imagen aspectRatio" "16:9" (params |> member "aspectRatio" |> to_string);
     check string "imagen negativePrompt" "blurry" (params |> member "negativePrompt" |> to_string);
     check
       string
       "imagen mimeType"
       "image/png"
       (params |> member "outputOptions" |> member "mimeType" |> to_string));

  (* Response decoding across all 3 dialects: mime_type = Some ONLY when declared *)
  let openai_resp =
    Printf.sprintf
      {|{"created":1700000000,"data":[{"b64_json":%s,"revised_prompt":"a glowing lighthouse"},{"url":"https://img.example.com/asset/2"},{"b64_json":%s,"output_format":"webp"}]}|}
      (Yojson.Safe.to_string (`String png_header_b64))
      (Yojson.Safe.to_string (`String webp_header_b64))
  in
  (match Image_gen.parse_response ~dialect:Cap.Openai_images_v1 openai_resp with
   | Error msg -> fail ("openai parse failed: " ^ msg)
   | Ok [ img1; img2; img3 ] ->
     check (option string) "undeclared b64_json mime is None" None img1.mime_type;
     check (option string) "decoded png bytes" (Some png_header_bytes) img1.data_bytes;
     check (option string) "revised_prompt" (Some "a glowing lighthouse") img1.revised_prompt;
     check (option string) "extensionless url mime is None" None img2.mime_type;
     check (option string) "remote_url" (Some "https://img.example.com/asset/2") img2.remote_url;
     check (option string) "declared output_format webp" (Some "image/webp") img3.mime_type
   | Ok _ -> fail "expected 3 images from OpenAI Images API");

  let zai_resp =
    {|{"created":1700000000,"data":[{"url":"https://z.ai/img/out"}]}|}
  in
  (match Image_gen.parse_response ~dialect:Cap.Zai_images_v4 zai_resp with
   | Error msg -> fail ("zai parse failed: " ^ msg)
   | Ok [ img ] ->
     check (option string) "zai undeclared url mime is None" None img.mime_type;
     check (option string) "zai remote_url" (Some "https://z.ai/img/out") img.remote_url
   | Ok _ -> fail "expected 1 image from ZAI Images API");

  let imagen_resp =
    Printf.sprintf
      {|{"predictions":[{"bytesBase64Encoded":%s,"prompt":"refined prompt"},{"bytesBase64Encoded":%s,"mimeType":"image/jpeg"}]}|}
      (Yojson.Safe.to_string (`String jpeg_header_b64))
      (Yojson.Safe.to_string (`String jpeg_header_b64))
  in
  (match Image_gen.parse_response ~dialect:Cap.Gemini_imagen_predict imagen_resp with
   | Error msg -> fail ("imagen parse failed: " ^ msg)
   | Ok [ img1; img2 ] ->
     check (option string) "imagen undeclared mimeType is None" None img1.mime_type;
     check (option string) "imagen decoded bytes" (Some jpeg_header_bytes) img1.data_bytes;
     check (option string) "imagen prompt" (Some "refined prompt") img1.revised_prompt;
     check (option string) "imagen declared mimeType" (Some "image/jpeg") img2.mime_type
   | Ok _ -> fail "expected 2 images from Imagen predict");

  (* Error envelopes & malformed base64 fail closed *)
  check
    bool
    "provider error envelope fails"
    true
    (Result.is_error
       (Image_gen.parse_response
          ~dialect:Cap.Openai_images_v1
          {|{"error":{"message":"safety blocked"}}|}));
  check
    bool
    "bad base64 fails"
    true
    (Result.is_error
       (Image_gen.parse_response
          ~dialect:Cap.Openai_images_v1
          {|{"data":[{"b64_json":"!!!not-base64!!!"}]}|}));
  check
    bool
    "empty data fails"
    true
    (Result.is_error
       (Image_gen.parse_response ~dialect:Cap.Openai_images_v1 {|{"data":[]}|}))
;;

let with_mock_server ~port handler f =
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let socket =
      Eio.Net.listen
        env#net
        ~sw
        ~backlog:128
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let server = Cohttp_eio.Server.make ~callback:handler () in
    Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    let endpoint = Printf.sprintf "http://127.0.0.1:%d" port in
    f ~sw ~net:env#net ~clock:env#clock ~endpoint;
    Eio.Switch.fail sw Exit
  with
  | Unix.Unix_error (Unix.EPERM, "bind", _) -> Alcotest.skip ()
  | Exit -> ()
;;

let http_error_msg = function
  | Http_client.HttpError { code; _ } -> Printf.sprintf "HTTP %d" code
  | Http_client.NetworkError { message; _ } -> "NetworkError: " ^ message
  | Http_client.Connect_failed { message; _ } -> "Connect_failed: " ^ message
  | Http_client.TimeoutError { message; _ } -> "TimeoutError: " ^ message
  | Http_client.AcceptRejected { reason } -> "AcceptRejected: " ^ reason
  | Http_client.ProviderTerminal { message; _ } -> "ProviderTerminal: " ^ message
  | Http_client.ProviderFailure { message; _ } -> "ProviderFailure: " ^ message
;;

let test_image_gen_http_loopback () =
  let seen_paths = ref [] in
  let handler _conn req body =
    let _req_body = Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) in
    let path = Uri.path (Cohttp.Request.uri req) in
    seen_paths := path :: !seen_paths;
    match path with
    | "/v1/images/generations" ->
      let resp =
        Printf.sprintf
          {|{"output_format":"png","data":[{"b64_json":%s,"revised_prompt":"loopback ok"}]}|}
          (Yojson.Safe.to_string (`String png_header_b64))
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~body:resp ()
    | "/v1/images/large" ->
      (* >10 MiB JSON payload exceeding Api_common.max_response_body (10 MiB)
         to prove Image_gen.generate uses the 64 MiB cap end-to-end. *)
      let large_raw = png_header_bytes ^ String.make (8 * 1024 * 1024) '\x00' in
      let large_b64 = Base64.encode_exn large_raw in
      let resp =
        Printf.sprintf {|{"data":[{"b64_json":"%s"}]}|} large_b64
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~body:resp ()
    | "/v1beta/models/imagen-4.0-generate-001:predict" ->
      let resp =
        Printf.sprintf
          {|{"predictions":[{"bytesBase64Encoded":%s,"mimeType":"image/webp"}]}|}
          (Yojson.Safe.to_string (`String webp_header_b64))
      in
      Cohttp_eio.Server.respond_string ~status:`OK ~body:resp ()
    | _ ->
      Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"not found" ()
  in
  with_mock_server ~port:18391 handler (fun ~sw ~net ~clock ~endpoint ->
    let openai_cfg =
      PC.make
        ~kind:PC.OpenAI_compat
        ~provider_id:"openai-image"
        ~model_id:"gpt-image-2"
        ~base_url:endpoint
        ~api_key:"test-key"
        ~request_path:"/v1/images/generations"
        ()
    in
    (match
       Image_gen.generate
         ~sw
         ~net
         ~clock
         ~config:openai_cfg
         ~dialect:Cap.Openai_images_v1
         (Image_gen.make_request ~aspect_ratio:"16:9" "a red star")
     with
     | Error err -> fail ("openai loopback failed: " ^ http_error_msg err)
     | Ok { images = [ img ]; ignored_options } ->
       check (option string) "http openai mime" (Some "image/png") img.mime_type;
       check (option string) "http openai bytes" (Some png_header_bytes) img.data_bytes;
       check (option string) "http openai revised" (Some "loopback ok") img.revised_prompt;
       check (list string) "ignored aspect_ratio reported" [ "aspect_ratio" ] ignored_options
     | Ok _ -> fail "expected 1 image from openai loopback");

    (* Large (>10 MiB JSON) payload succeeds under default 64 MiB Image_gen cap,
       and fails closed when caller sets a tighter ~max_response_bytes cap. *)
    let large_cfg = { openai_cfg with request_path = "/v1/images/large" } in
    (match
       Image_gen.generate
         ~sw
         ~net
         ~clock
         ~config:large_cfg
         ~dialect:Cap.Openai_images_v1
         (Image_gen.make_request "high-res image")
     with
     | Error err -> fail ("large (>10 MiB) image_gen failed: " ^ http_error_msg err)
     | Ok { images = [ img ]; ignored_options } ->
       check (option string) "large undeclared mime is None" None img.mime_type;
       check (list string) "no ignored options" [] ignored_options;
       let decoded_len = Option.fold ~none:0 ~some:String.length img.data_bytes in
       check bool "decoded > 8 MiB payload" true (decoded_len > 8 * 1024 * 1024)
     | Ok _ -> fail "expected 1 large image");
    (match
       Image_gen.generate
         ~max_response_bytes:1024
         ~sw
         ~net
         ~clock
         ~config:large_cfg
         ~dialect:Cap.Openai_images_v1
         (Image_gen.make_request "too big for 1 KiB cap")
     with
     | Error (Http_client.ProviderFailure { kind = Response_body_too_large { limit_bytes = 1024 }; _ }) ->
       ()
     | Error err -> fail ("expected Response_body_too_large(1024), got: " ^ http_error_msg err)
     | Ok _ -> fail "expected tight max_response_bytes cap to reject >10 MiB body");
    (match
       Image_gen.generate
         ~max_response_bytes:0
         ~sw
         ~net
         ~clock
         ~config:openai_cfg
         ~dialect:Cap.Openai_images_v1
         (Image_gen.make_request "invalid cap")
     with
     | Error (Http_client.AcceptRejected _) -> ()
     | Error err -> fail ("expected AcceptRejected for 0 cap, got: " ^ http_error_msg err)
     | Ok _ -> fail "expected 0 max_response_bytes to be rejected");

    let imagen_cfg =
      PC.make
        ~kind:PC.Gemini
        ~provider_id:"gemini-image"
        ~model_id:"imagen-4.0-generate-001"
        ~base_url:(endpoint ^ "/v1beta")
        ~api_key:"test-gemini-key"
        ~request_path:""
        ()
    in
    match
      Image_gen.generate
        ~sw
        ~net
        ~clock
        ~config:imagen_cfg
        ~dialect:Cap.Gemini_imagen_predict
        (Image_gen.make_request ~aspect_ratio:"1:1" "a blue square")
    with
    | Error err -> fail ("imagen loopback failed: " ^ http_error_msg err)
    | Ok { images = [ img ]; ignored_options } ->
      check (option string) "http imagen mime" (Some "image/webp") img.mime_type;
      check (option string) "http imagen bytes" (Some webp_header_bytes) img.data_bytes;
      check (list string) "imagen no ignored options" [] ignored_options;
      check
        bool
        "both endpoints hit"
        true
        (List.mem "/v1beta/models/imagen-4.0-generate-001:predict" !seen_paths
         && List.mem "/v1/images/generations" !seen_paths
         && List.mem "/v1/images/large" !seen_paths)
    | Ok _ -> fail "expected 1 image from imagen loopback")
;;

let () =
  run
    "bidirectional_multimodal"
    [ ( "capabilities"
      , [ test_case "image_output vocab roundtrip" `Quick test_image_output_vocab_roundtrip
        ; test_case "media_capabilities projection" `Quick test_media_capabilities_projection
        ; test_case
            "models.toml image_output contracts"
            `Quick
            test_models_toml_image_output_contracts
        ; test_case
            "manifest and provider_catalog image_output"
            `Quick
            test_manifest_and_provider_catalog_image_output
        ] )
    ; ( "wire_codecs"
      , [ test_case
            "gemini fileData URI and typed errors"
            `Quick
            test_gemini_file_uri_and_typed_errors
        ; test_case
            "gemini image output responseModalities and imageConfig"
            `Quick
            test_gemini_image_output_modalities_and_config
        ; test_case "ollama typed media refusals" `Quick test_ollama_typed_media_refusals
        ; test_case
            "openai responses image_generation sync and stream"
            `Quick
            test_openai_responses_image_generation_sync_and_stream
        ; test_case
            "openrouter chat image output sync and stream"
            `Quick
            test_openrouter_chat_image_generation_sync_and_stream
        ; test_case
            "unified Api_common image degradation"
            `Quick
            test_unified_image_degradation
        ] )
    ; ( "image_gen"
      , [ test_case "standalone image_gen dialects pure" `Quick test_image_gen_dialects_pure
        ; test_case "standalone image_gen http loopback" `Quick test_image_gen_http_loopback
        ] )
    ]
;;
