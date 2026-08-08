(** Verify all remaining edge cases for Gemini backend. *)

open Llm_provider

let check label cond =
  if cond
  then Printf.printf "  PASS: %s\n" label
  else (
    Printf.printf "  FAIL: %s\n" label;
    exit 1)
;;

let parse_gemini_chunk data =
  match Streaming.parse_gemini_sse_chunk data with
  | Streaming.Gemini_chunk chunk -> Some chunk
  | Streaming.Gemini_unsupported_part _ -> None
  | Streaming.Gemini_unsupported_response _ -> None
  | Streaming.Gemini_parse_failed _ -> None
;;

let gemini_events state chunk =
  match Streaming.gemini_chunk_to_events state chunk with
  | Ok events -> events
  | Error { reason } -> failwith ("unexpected Gemini stream decode failure: " ^ reason)
;;

let string_has haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen
  then false
  else (
    let found = ref false in
    for i = 0 to hlen - nlen do
      if (not !found) && String.sub haystack i nlen = needle then found := true
    done;
    !found)
;;

(* ── 1. disable_parallel_tool_use: should not crash, field ignored ── *)
let test_disable_parallel () =
  Printf.printf "=== disable_parallel_tool_use ===\n";
  let config =
    Provider_config.make
      ~kind:Gemini
      ~model_id:"gemini-2.5-flash"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ~disable_parallel_tool_use:true
      ()
  in
  let tools = [ `Assoc [ "name", `String "t1"; "description", `String "d" ] ] in
  let body =
    Backend_gemini.build_request ~config ~messages:[ Types.user_msg "hi" ] ~tools ()
  in
  let json = Yojson.Safe.from_string body in
  ignore json;
  check "no crash with disable_parallel=true" true;
  check "parallel flag absent from Gemini body" (not (string_has body "parallel"))
;;

(* ── 2. cache_system_prompt: verify graceful ignore ── *)
let test_cache_system_prompt () =
  Printf.printf "=== cache_system_prompt ===\n";
  let config =
    Provider_config.make
      ~kind:Gemini
      ~model_id:"gemini-2.5-flash"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ~cache_system_prompt:true
      ~system_prompt:"Be helpful."
      ()
  in
  let body = Backend_gemini.build_request ~config ~messages:[ Types.user_msg "hi" ] () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let si = json |> member "systemInstruction" in
  check "systemInstruction present" (si <> `Null);
  let cached = json |> member "cachedContent" in
  check "cachedContent absent (not implemented)" (cached = `Null)
;;

(* ── 3. Gemini cloud auth: URL without ?key= when api_key empty ── *)
let test_vertex_ai_url () =
  Printf.printf "=== Gemini cloud URL (no api_key) ===\n";
  let config =
    Provider_config.make
      ~kind:Gemini
      ~model_id:"gemini-2.5-flash"
      ~base_url:"https://us-central1-aiplatform.googleapis.com/v1beta1"
      ~api_key:""
      ()
  in
  let url = Complete_sampling.gemini_url ~config ~stream:false in
  check "no ?key= in URL" (not (string_has url "key="));
  check "has :generateContent" (string_has url ":generateContent");
  check "has model in path" (string_has url "gemini-2.5-flash");
  Printf.printf "  URL: %s\n" url;
  let stream_url = Complete_sampling.gemini_url ~config ~stream:true in
  check
    "stream has :streamGenerateContent"
    (string_has stream_url ":streamGenerateContent");
  check "stream has alt=sse" (string_has stream_url "alt=sse");
  check "stream no ?key=" (not (string_has stream_url "key="));
  Printf.printf "  Stream URL: %s\n" stream_url
;;

(* ── 4. SSE streaming function call chunk parsing ── *)
let test_sse_function_call () =
  Printf.printf "=== SSE streaming functionCall ===\n";
  let chunk_data =
    {|{"candidates":[{"content":{"parts":[{"functionCall":{"name":"get_weather","args":{"city":"Seoul"}},"thoughtSignature":"abc123"}],"role":"model"},"finishReason":"STOP","index":0}],"usageMetadata":{"promptTokenCount":44,"candidatesTokenCount":15},"modelVersion":"gemini-2.5-flash"}|}
  in
  match parse_gemini_chunk chunk_data with
  | Some chunk ->
    check "parsed chunk" true;
    check "has parts" (List.length chunk.gem_parts > 0);
    check
      "finish reason STOP"
      (chunk.gem_finish_reason = Some (Streaming.Gemini_candidate_finish_reason "STOP"));
    let state = Streaming.create_openai_stream_state () in
    let events, _tel = gemini_events state chunk in
    let has_tool_start =
      List.exists
        (function
          | Types.ContentBlockStart
              { content_type = "tool_use"; tool_name = Some "get_weather"; _ } -> true
          | _ -> false)
        events
    in
    check "tool_use BlockStart emitted" has_tool_start;
    let has_input_delta =
      List.exists
        (function
          | Types.ContentBlockDelta { delta = InputJsonSnapshot _; _ } -> true
          | _ -> false)
        events
    in
    check "InputJsonSnapshot emitted" has_input_delta;
    (* A Gemini stream that emitted a functionCall and finishes with STOP now
       reports StopToolUse, not EndTurn (#2061): the model wants a tool call.
       Mirrors the Alcotest gemini stop-reason tests #2061 already updated. *)
    let has_stop_tool_use =
      List.exists
        (function
          | Types.MessageDelta { stop_reason = Some Types.StopToolUse; _ } -> true
          | _ -> false)
        events
    in
    check "StopToolUse MessageDelta emitted" has_stop_tool_use
  | None -> check "parsed chunk" false
;;

(* ── 5. OAS-allocated tool_use_id + roundtrip ── *)
let test_tool_use_id_roundtrip () =
  Printf.printf "=== allocated tool_use_id roundtrip ===\n";
  let response_json =
    Yojson.Safe.from_string
      {|{
    "candidates": [{"content": {"parts": [
      {"functionCall": {"name": "get_weather", "args": {"city": "Seoul"}}}
    ], "role": "model"}, "finishReason": "STOP"}],
    "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 5}
  }|}
  in
  let resp = Backend_gemini.parse_response response_json in
  let tu_id, tu_name, tu_input =
    match List.hd resp.content with
    | Types.ToolUse { id; name; input } -> id, name, input
    | _ -> failwith "expected ToolUse"
  in
  Printf.printf "  allocated id: %s\n" tu_id;
  Printf.printf "  name: %s\n" tu_name;
  check "id is non-empty" (tu_id <> "");
  check "name is get_weather" (tu_name = "get_weather");
  (* Build next turn with ToolResult using this allocated id. *)
  let config =
    Provider_config.make
      ~kind:Gemini
      ~model_id:"gemini-2.5-flash"
      ~base_url:"https://generativelanguage.googleapis.com/v1beta"
      ()
  in
  let messages =
    [ Types.user_msg "What's the weather?"
    ; { Types.role = Assistant
      ; content = [ Types.ToolUse { id = tu_id; name = tu_name; input = tu_input } ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ; { Types.role = Tool
      ; content =
          [ Types.ToolResult
              { tool_use_id = tu_id
              ; content = "Sunny 25C"
              ; outcome = Tool_succeeded
              ; json = None
              ; content_blocks = None
              }
          ]
      ; name = None
      ; tool_call_id = None
      ; metadata = []
      }
    ]
  in
  let body = Backend_gemini.build_request ~config ~messages () in
  let json = Yojson.Safe.from_string body in
  let open Yojson.Safe.Util in
  let contents = json |> member "contents" |> to_list in
  check "3 content turns" (List.length contents = 3);
  let third = List.nth contents 2 in
  let parts = third |> member "parts" |> to_list in
  let fr = List.hd parts |> member "functionResponse" in
  check "functionResponse present" (fr <> `Null);
  check "functionResponse.id preserved" (fr |> member "id" |> to_string = tu_id);
  let fr_name = fr |> member "name" |> to_string in
  check "functionResponse.name = get_weather (resolved from id)" (fr_name = "get_weather");
  Printf.printf "  functionResponse.name: %s (resolved from allocated id)\n" fr_name
;;

let () =
  test_disable_parallel ();
  test_cache_system_prompt ();
  test_vertex_ai_url ();
  test_sse_function_call ();
  test_tool_use_id_roundtrip ();
  Printf.printf "\nALL 5 EDGE CASES PASSED\n"
;;
