(** Tests for Llm_provider.Cache — fingerprinting, serialization roundtrip,
    and cache backend interface contract. Covers the 80 uncovered bisect points. *)

module Cache = Llm_provider.Cache
module PC = Llm_provider.Provider_config
open Llm_provider.Types

(* ── Helpers ─────────────────────────────────────────────── *)

let make_config ?(model_id = "test-model") () =
  PC.make ~kind:Anthropic ~model_id ~base_url:"http://localhost" ()
;;

let simple_response ?(id = "resp-1") ?(model = "test-model") content =
  { id; model; stop_reason = EndTurn; content; usage = None; telemetry = None }
;;

let response_with_usage ?(id = "resp-u") ?(model = "test-model") content =
  { id
  ; model
  ; stop_reason = EndTurn
  ; content
  ; usage =
      Some
        { input_tokens = 100
        ; output_tokens = 50
        ; cache_creation_input_tokens = 20
        ; cache_read_input_tokens = 10
        ; cost_usd = None
        }
  ; telemetry = None
  }
;;

(* ── request_fingerprint ─────────────────────────────────── *)

let test_fingerprint_deterministic () =
  let config = make_config () in
  let msgs = [ user_msg "hello" ] in
  let k1 = Cache.request_fingerprint ~config ~messages:msgs () in
  let k2 = Cache.request_fingerprint ~config ~messages:msgs () in
  Alcotest.(check string) "same inputs = same key" k1 k2
;;

let test_fingerprint_different_messages () =
  let config = make_config () in
  let k1 = Cache.request_fingerprint ~config ~messages:[ user_msg "hello" ] () in
  let k2 = Cache.request_fingerprint ~config ~messages:[ user_msg "world" ] () in
  Alcotest.(check bool) "different messages = different key" true (k1 <> k2)
;;

let test_fingerprint_different_models () =
  let c1 = make_config ~model_id:"model-a" () in
  let c2 = make_config ~model_id:"model-b" () in
  let msgs = [ user_msg "same" ] in
  let k1 = Cache.request_fingerprint ~config:c1 ~messages:msgs () in
  let k2 = Cache.request_fingerprint ~config:c2 ~messages:msgs () in
  Alcotest.(check bool) "different models = different key" true (k1 <> k2)
;;

let test_fingerprint_with_tools () =
  let config = make_config () in
  let msgs = [ user_msg "hi" ] in
  let tool = `Assoc [ "name", `String "calc" ] in
  let k1 = Cache.request_fingerprint ~config ~messages:msgs () in
  let k2 = Cache.request_fingerprint ~config ~messages:msgs ~tools:[ tool ] () in
  Alcotest.(check bool) "tools change key" true (k1 <> k2)
;;

let test_fingerprint_empty_tools_vs_none () =
  let config = make_config () in
  let msgs = [ user_msg "hi" ] in
  let k1 = Cache.request_fingerprint ~config ~messages:msgs () in
  let k2 = Cache.request_fingerprint ~config ~messages:msgs ~tools:[] () in
  Alcotest.(check string) "empty tools = no tools (default)" k1 k2
;;

let test_fingerprint_multiple_messages () =
  let config = make_config () in
  let msgs = [ user_msg "hello"; assistant_msg "hi"; user_msg "how?" ] in
  let k = Cache.request_fingerprint ~config ~messages:msgs () in
  Alcotest.(check bool) "key is hex string" true (String.length k > 0)
;;

let test_fingerprint_hex_format () =
  let config = make_config () in
  let k = Cache.request_fingerprint ~config ~messages:[ user_msg "x" ] () in
  (* MD5 hex output is always 32 chars *)
  Alcotest.(check int) "hex length 32" 32 (String.length k);
  let is_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') in
  String.iter (fun c -> Alcotest.(check bool) "hex char" true (is_hex c)) k
;;

let test_fingerprint_message_roles () =
  let config = make_config () in
  let k1 = Cache.request_fingerprint ~config ~messages:[ user_msg "hi" ] () in
  let k2 = Cache.request_fingerprint ~config ~messages:[ assistant_msg "hi" ] () in
  Alcotest.(check bool) "different roles = different key" true (k1 <> k2)
;;

let test_fingerprint_tool_use_blocks () =
  let config = make_config () in
  let msg name =
    { role = Assistant
    ; content = [ ToolUse { id = "call_1"; name; input = `Assoc [ "q", `String "x" ] } ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let k1 = Cache.request_fingerprint ~config ~messages:[ msg "search" ] () in
  let k2 = Cache.request_fingerprint ~config ~messages:[ msg "lookup" ] () in
  Alcotest.(check bool) "tool_use changes key" true (k1 <> k2)
;;

let test_fingerprint_redacted_thinking_blocks () =
  let config = make_config () in
  let msg data =
    { role = Assistant
    ; content = [ RedactedThinking data; Text "visible" ]
    ; name = None
    ; tool_call_id = None
    ; metadata = []
    }
  in
  let k1 = Cache.request_fingerprint ~config ~messages:[ msg "encrypted-a" ] () in
  let k2 = Cache.request_fingerprint ~config ~messages:[ msg "encrypted-b" ] () in
  Alcotest.(check bool) "redacted_thinking changes key" true (k1 <> k2)
;;

(* ── response_to_json / response_of_json roundtrip ───────── *)

let test_roundtrip_text () =
  let resp = simple_response [ Text "hello world" ] in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    Alcotest.(check string) "id" resp.id r.id;
    Alcotest.(check string) "model" resp.model r.model;
    (match r.content with
     | [ Text s ] -> Alcotest.(check string) "text" "hello world" s
     | _ -> Alcotest.fail "expected single Text block")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_thinking () =
  let resp =
    simple_response
      [ Thinking { signature = None; content = "let me think..." }; Text "answer" ]
  in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    Alcotest.(check int) "2 blocks" 2 (List.length r.content);
    (match List.hd r.content with
     | Thinking { content; _ } ->
       Alcotest.(check string) "thinking" "let me think..." content
     | _ -> Alcotest.fail "expected Thinking block")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_tool_use () =
  let resp =
    { (simple_response
         [ ToolUse
             { id = "tu_1"; name = "search"; input = `Assoc [ "q", `String "test" ] }
         ])
      with
      stop_reason = StopToolUse
    }
  in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.content with
     | [ ToolUse { id; name; input } ] ->
       Alcotest.(check string) "id" "tu_1" id;
       Alcotest.(check string) "name" "search" name;
       Alcotest.(check string) "input" {|{"q":"test"}|} (Yojson.Safe.to_string input)
     | _ -> Alcotest.fail "expected single ToolUse block")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_tool_result () =
  let resp =
    simple_response
      [ ToolResult
          { tool_use_id = "tu_1"
          ; content = "result data"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = None
          }
      ]
  in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.content with
     | [ ToolResult { tool_use_id; content; outcome; _ } ] ->
       Alcotest.(check string) "tool_use_id" "tu_1" tool_use_id;
       Alcotest.(check string) "content" "result data" content;
       Alcotest.(check bool) "not error" false (tool_result_outcome_is_error outcome)
     | _ -> Alcotest.fail "expected single ToolResult block")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_tool_result_error () =
  let resp =
    simple_response
      [ ToolResult
          { tool_use_id = "tu_2"
          ; content = "failed"
          ; outcome =
              Tool_failed { failure_kind = Reported_tool_error; error_class = None }
          ; json = None
          ; content_blocks = None
          }
      ]
  in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.content with
     | [ ToolResult { outcome; _ } ] ->
       Alcotest.(check bool) "is error" true (tool_result_outcome_is_error outcome)
     | _ -> Alcotest.fail "expected ToolResult block")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_tool_result_content_blocks () =
  let blocks =
    [ Text "preview"
    ; Image { media_type = "image/png"; data = "abc"; source_type = Base64 }
    ]
  in
  let resp =
    simple_response
      [ ToolResult
          { tool_use_id = "tu_blocks"
          ; content = "preview"
          ; outcome = Tool_succeeded
          ; json = None
          ; content_blocks = Some blocks
          }
      ]
  in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.content with
     | [ ToolResult { tool_use_id; content; content_blocks = Some restored; _ } ] ->
       Alcotest.(check string) "tool_use_id" "tu_blocks" tool_use_id;
       Alcotest.(check string) "content from text blocks" "preview" content;
       Alcotest.(check int) "content_blocks length" 2 (List.length restored)
     | [ ToolResult { content_blocks = None; _ } ] ->
       Alcotest.fail "expected structured content_blocks to survive cache roundtrip"
     | _ -> Alcotest.fail "expected ToolResult block")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_with_usage () =
  let resp = response_with_usage [ Text "hi" ] in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.usage with
     | Some u ->
       Alcotest.(check int) "input_tokens" 100 u.input_tokens;
       Alcotest.(check int) "output_tokens" 50 u.output_tokens;
       Alcotest.(check int) "cache_creation" 20 u.cache_creation_input_tokens;
       Alcotest.(check int) "cache_read" 10 u.cache_read_input_tokens
     | None -> Alcotest.fail "expected usage")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_with_usage_cost () =
  let resp =
    { id = "resp-cost"
    ; model = "claude-sonnet-4-6"
    ; stop_reason = EndTurn
    ; content = [ Text "hi" ]
    ; usage =
        Some
          { input_tokens = 100
          ; output_tokens = 50
          ; cache_creation_input_tokens = 20
          ; cache_read_input_tokens = 10
          ; cost_usd = Some 0.1234
          }
    ; telemetry = None
    }
  in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some { usage = Some u; _ } ->
    Alcotest.(check (option (float 0.0001))) "cost roundtrip" (Some 0.1234) u.cost_usd
  | _ -> Alcotest.fail "expected usage with cost"
;;

let test_roundtrip_no_usage () =
  let resp = simple_response [ Text "no usage" ] in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r -> Alcotest.(check bool) "no usage" true (Option.is_none r.usage)
  | None -> Alcotest.fail "roundtrip failed"
;;

(* ── stop_reason roundtrip ───────────────────────────────── *)

let test_roundtrip_stop_end_turn () =
  let resp = { (simple_response [ Text "done" ]) with stop_reason = EndTurn } in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.stop_reason with
     | EndTurn -> ()
     | _ -> Alcotest.fail "expected EndTurn")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_stop_tool_use () =
  let resp = { (simple_response [ Text "tool" ]) with stop_reason = StopToolUse } in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.stop_reason with
     | StopToolUse -> ()
     | _ -> Alcotest.fail "expected StopToolUse")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_stop_max_tokens () =
  let resp = { (simple_response [ Text "max" ]) with stop_reason = MaxTokens } in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.stop_reason with
     | MaxTokens -> ()
     | _ -> Alcotest.fail "expected MaxTokens")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_stop_sequence () =
  let resp = { (simple_response [ Text "seq" ]) with stop_reason = StopSequence } in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.stop_reason with
     | StopSequence -> ()
     | _ -> Alcotest.fail "expected StopSequence")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_stop_unknown () =
  let resp = { (simple_response [ Text "?" ]) with stop_reason = Unknown "custom" } in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.stop_reason with
     | Unknown s -> Alcotest.(check string) "reason" "custom" s
     | _ -> Alcotest.fail "expected Unknown")
  | None -> Alcotest.fail "roundtrip failed"
;;

(* ── content_block edge cases (via roundtrip) ────────────── *)

let test_roundtrip_redacted_thinking () =
  let resp = simple_response [ RedactedThinking "secret" ] in
  let json = Cache.response_to_json resp in
  let open Yojson.Safe.Util in
  (match json |> member "content" |> to_list with
   | [ block ] ->
     Alcotest.(check string)
       "type"
       "redacted_thinking"
       (block |> member "type" |> to_string);
     Alcotest.(check string) "data" "secret" (block |> member "data" |> to_string)
   | _ -> Alcotest.fail "expected serialized redacted_thinking block");
  match Cache.response_of_json json with
  | Some r ->
    (match r.content with
     | [ RedactedThinking data ] -> Alcotest.(check string) "redacted data" "secret" data
     | _ -> Alcotest.fail "expected redacted_thinking roundtrip")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_binary_block () =
  let resp =
    simple_response
      [ Image { media_type = "image/png"; data = "base64data"; source_type = Base64 } ]
  in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.content with
     | [ Image { media_type = "image/png"; data = "base64data"; source_type = Base64 } ]
       -> ()
     | _ -> Alcotest.fail "expected image block to roundtrip")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_mixed_content () =
  let resp =
    simple_response
      [ Thinking { signature = None; content = "hmm" }
      ; Text "answer"
      ; ToolUse { id = "tu_1"; name = "calc"; input = `Int 42 }
      ]
  in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r -> Alcotest.(check int) "3 blocks preserved" 3 (List.length r.content)
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_document_block () =
  let resp =
    simple_response
      [ Document
          { media_type = "application/pdf"; data = "pdf-data"; source_type = Base64 }
      ]
  in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.content with
     | [ Document
           { media_type = "application/pdf"; data = "pdf-data"; source_type = Base64 }
       ] -> ()
     | _ -> Alcotest.fail "expected document block to roundtrip")
  | None -> Alcotest.fail "roundtrip failed"
;;

let test_roundtrip_audio_block () =
  let resp =
    simple_response
      [ Audio { media_type = "audio/mp3"; data = "audio-data"; source_type = Base64 } ]
  in
  let json = Cache.response_to_json resp in
  match Cache.response_of_json json with
  | Some r ->
    (match r.content with
     | [ Audio { media_type = "audio/mp3"; data = "audio-data"; source_type = Base64 } ]
       -> ()
     | _ -> Alcotest.fail "expected audio block to roundtrip")
  | None -> Alcotest.fail "roundtrip failed"
;;

(* ── response_of_json: malformed / incompatible ──────────── *)

let test_of_json_wrong_version () =
  let json =
    `Assoc
      [ "v", `String "99"
      ; "id", `String "x"
      ; "model", `String "m"
      ; "stop_reason", `String "end_turn"
      ; "content", `List []
      ; "usage", `Null
      ]
  in
  Alcotest.(check bool)
    "wrong version = None"
    true
    (Option.is_none (Cache.response_of_json json))
;;

let test_of_json_missing_fields () =
  let json = `Assoc [ "v", `String "1" ] in
  Alcotest.(check bool)
    "missing fields = None"
    true
    (Option.is_none (Cache.response_of_json json))
;;

let test_of_json_garbage () =
  Alcotest.(check bool)
    "garbage = None"
    true
    (Option.is_none (Cache.response_of_json (`String "not json")))
;;

let test_of_json_null () =
  Alcotest.(check bool) "null = None" true (Option.is_none (Cache.response_of_json `Null))
;;

(* ── Cache backend interface (t) ─────────────────────────── *)

let test_cache_hit () =
  let store = Hashtbl.create 16 in
  let cache : Cache.t =
    { get = (fun ~key -> Hashtbl.find_opt store key)
    ; set = (fun ~key ~ttl_sec:_ value -> Hashtbl.replace store key value)
    }
  in
  let resp = simple_response [ Text "cached" ] in
  let json = Cache.response_to_json resp in
  cache.set ~key:"k1" ~ttl_sec:60 json;
  match cache.get ~key:"k1" with
  | Some j ->
    (match Cache.response_of_json j with
     | Some r ->
       (match r.content with
        | [ Text s ] -> Alcotest.(check string) "cached text" "cached" s
        | _ -> Alcotest.fail "wrong content")
     | None -> Alcotest.fail "deserialization failed")
  | None -> Alcotest.fail "cache miss"
;;

let test_cache_miss () =
  let cache : Cache.t =
    { get = (fun ~key:_ -> None); set = (fun ~key:_ ~ttl_sec:_ _value -> ()) }
  in
  Alcotest.(check bool) "miss" true (Option.is_none (cache.get ~key:"nonexistent"))
;;

let test_cache_overwrite () =
  let store = Hashtbl.create 16 in
  let cache : Cache.t =
    { get = (fun ~key -> Hashtbl.find_opt store key)
    ; set = (fun ~key ~ttl_sec:_ value -> Hashtbl.replace store key value)
    }
  in
  let r1 = simple_response [ Text "first" ] in
  let r2 = simple_response [ Text "second" ] in
  cache.set ~key:"k" ~ttl_sec:60 (Cache.response_to_json r1);
  cache.set ~key:"k" ~ttl_sec:60 (Cache.response_to_json r2);
  match cache.get ~key:"k" with
  | Some j ->
    (match Cache.response_of_json j with
     | Some r ->
       (match r.content with
        | [ Text s ] -> Alcotest.(check string) "overwritten" "second" s
        | _ -> Alcotest.fail "wrong content")
     | None -> Alcotest.fail "deserialization failed")
  | None -> Alcotest.fail "cache miss"
;;

(* ── Full integration: fingerprint + store + retrieve ───── *)

let test_full_cache_flow () =
  let store = Hashtbl.create 16 in
  let cache : Cache.t =
    { get = (fun ~key -> Hashtbl.find_opt store key)
    ; set = (fun ~key ~ttl_sec:_ value -> Hashtbl.replace store key value)
    }
  in
  let config = make_config () in
  let msgs = [ user_msg "what is 2+2?" ] in
  let key = Cache.request_fingerprint ~config ~messages:msgs () in
  (* Miss *)
  Alcotest.(check bool) "initial miss" true (Option.is_none (cache.get ~key));
  (* Store *)
  let resp = simple_response [ Text "4" ] in
  cache.set ~key ~ttl_sec:300 (Cache.response_to_json resp);
  (* Hit *)
  match cache.get ~key with
  | Some j ->
    (match Cache.response_of_json j with
     | Some r ->
       (match r.content with
        | [ Text s ] -> Alcotest.(check string) "answer" "4" s
        | _ -> Alcotest.fail "wrong content")
     | None -> Alcotest.fail "deserialization failed")
  | None -> Alcotest.fail "expected cache hit"
;;

(* ── Runner ──────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "llm_cache"
    [ ( "fingerprint"
      , [ Alcotest.test_case "deterministic" `Quick test_fingerprint_deterministic
        ; Alcotest.test_case
            "different messages"
            `Quick
            test_fingerprint_different_messages
        ; Alcotest.test_case "different models" `Quick test_fingerprint_different_models
        ; Alcotest.test_case "with tools" `Quick test_fingerprint_with_tools
        ; Alcotest.test_case
            "empty tools vs none"
            `Quick
            test_fingerprint_empty_tools_vs_none
        ; Alcotest.test_case "multiple messages" `Quick test_fingerprint_multiple_messages
        ; Alcotest.test_case "hex format" `Quick test_fingerprint_hex_format
        ; Alcotest.test_case "message roles" `Quick test_fingerprint_message_roles
        ; Alcotest.test_case "tool_use blocks" `Quick test_fingerprint_tool_use_blocks
        ; Alcotest.test_case
            "redacted_thinking blocks"
            `Quick
            test_fingerprint_redacted_thinking_blocks
        ] )
    ; ( "roundtrip_content"
      , [ Alcotest.test_case "text" `Quick test_roundtrip_text
        ; Alcotest.test_case "thinking" `Quick test_roundtrip_thinking
        ; Alcotest.test_case "tool_use" `Quick test_roundtrip_tool_use
        ; Alcotest.test_case "tool_result" `Quick test_roundtrip_tool_result
        ; Alcotest.test_case "tool_result error" `Quick test_roundtrip_tool_result_error
        ; Alcotest.test_case
            "tool_result content_blocks"
            `Quick
            test_roundtrip_tool_result_content_blocks
        ; Alcotest.test_case "redacted_thinking" `Quick test_roundtrip_redacted_thinking
        ; Alcotest.test_case "binary image" `Quick test_roundtrip_binary_block
        ; Alcotest.test_case "document" `Quick test_roundtrip_document_block
        ; Alcotest.test_case "audio" `Quick test_roundtrip_audio_block
        ; Alcotest.test_case "mixed content" `Quick test_roundtrip_mixed_content
        ] )
    ; ( "roundtrip_stop_reason"
      , [ Alcotest.test_case "end_turn" `Quick test_roundtrip_stop_end_turn
        ; Alcotest.test_case "tool_use" `Quick test_roundtrip_stop_tool_use
        ; Alcotest.test_case "max_tokens" `Quick test_roundtrip_stop_max_tokens
        ; Alcotest.test_case "stop_sequence" `Quick test_roundtrip_stop_sequence
        ; Alcotest.test_case "unknown" `Quick test_roundtrip_stop_unknown
        ] )
    ; ( "roundtrip_usage"
      , [ Alcotest.test_case "with usage" `Quick test_roundtrip_with_usage
        ; Alcotest.test_case "with usage cost" `Quick test_roundtrip_with_usage_cost
        ; Alcotest.test_case "no usage" `Quick test_roundtrip_no_usage
        ] )
    ; ( "deserialization_errors"
      , [ Alcotest.test_case "wrong version" `Quick test_of_json_wrong_version
        ; Alcotest.test_case "missing fields" `Quick test_of_json_missing_fields
        ; Alcotest.test_case "garbage" `Quick test_of_json_garbage
        ; Alcotest.test_case "null" `Quick test_of_json_null
        ] )
    ; ( "cache_backend"
      , [ Alcotest.test_case "hit" `Quick test_cache_hit
        ; Alcotest.test_case "miss" `Quick test_cache_miss
        ; Alcotest.test_case "overwrite" `Quick test_cache_overwrite
        ] )
    ; "integration", [ Alcotest.test_case "full cache flow" `Quick test_full_cache_flow ]
    ]
;;
