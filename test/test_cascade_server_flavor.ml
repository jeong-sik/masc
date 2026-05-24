(** Server flavor adapter unit tests.

    Validates flavor constraints, thinking control,
    finish reason mapping, and Provider_h_wire tools+stream restriction. *)

open Alcotest
open Masc_mcp.Cascade_server_flavor

(* --- Flavor constraints --- *)

let test_llama_cpp_constraints () =
  let c = constraints_of_flavor Llama_cpp in
  check bool "supports_tools_with_streaming" true c.supports_tools_with_streaming;
  check bool "supports_response_format" true c.supports_response_format

let test_ollama_constraints () =
  let c = constraints_of_flavor Ollama in
  check bool "supports_tools_with_streaming" true c.supports_tools_with_streaming;
  check bool "supports_parallel_tool_calls" true c.supports_parallel_tool_calls

let test_openai_constraints () =
  let c = constraints_of_flavor Provider_d_wire in
  check bool "supports_tools_with_streaming" true c.supports_tools_with_streaming;
  check bool "supports_response_format" true c.supports_response_format;
  check bool "supports_parallel_tool_calls" true c.supports_parallel_tool_calls

let test_deep_seek_constraints () =
  let c = constraints_of_flavor Provider_g_wire in
  check bool "supports_tools_with_streaming" true c.supports_tools_with_streaming;
  check bool "supports_response_format" true c.supports_response_format

let test_zai_glm_constraints () =
  let c = constraints_of_flavor Provider_k_zai in
  check bool "supports_tools_with_streaming" true c.supports_tools_with_streaming

let test_qwen_tools_stream_incompatible () =
  let c = constraints_of_flavor Provider_h_wire in
  check bool "Provider_h_wire does NOT support tools with streaming"
    false c.supports_tools_with_streaming;
  check bool "Provider_h_wire does NOT support response_format"
    false c.supports_response_format

let test_vllm_constraints () =
  let c = constraints_of_flavor Vllm in
  check bool "supports_tools_with_streaming" true c.supports_tools_with_streaming

(* --- can_stream_with_tools --- *)

let test_can_stream_with_tools_qwen () =
  check bool "Provider_h_wire cannot stream with tools" false (can_stream_with_tools Provider_h_wire)

let test_can_stream_with_tools_openai () =
  check bool "OpenAI can stream with tools" true (can_stream_with_tools Provider_d_wire)

let test_can_stream_with_tools_llama_cpp () =
  check bool "llama.cpp can stream with tools" true (can_stream_with_tools Llama_cpp)

let test_can_stream_with_tools_ollama () =
  check bool "Ollama can stream with tools" true (can_stream_with_tools Ollama)

(* --- Thinking control --- *)

let test_thinking_llama_cpp () =
  let tc = thinking_control_for_flavor Llama_cpp true (Some 4096) in
  check bool "is Llama_cpp_thinking"
    true
    (match tc with Llama_cpp_thinking { enable = true; budget = Some 4096 } -> true | _ -> false)

let test_thinking_llama_cpp_no_budget () =
  let tc = thinking_control_for_flavor Llama_cpp true None in
  check bool "is Llama_cpp_thinking no budget"
    true
    (match tc with Llama_cpp_thinking { enable = true; budget = None } -> true | _ -> false)

let test_thinking_deep_seek_enabled () =
  let tc = thinking_control_for_flavor Provider_g_wire true None in
  check bool "is Deep_seek_thinking enabled"
    true
    (match tc with Deep_seek_thinking { enabled = true } -> true | _ -> false)

let test_thinking_deep_seek_disabled () =
  let tc = thinking_control_for_flavor Provider_g_wire false None in
  check bool "is Deep_seek_thinking disabled"
    true
    (match tc with Deep_seek_thinking { enabled = false } -> true | _ -> false)

let test_thinking_openai_reasoning_effort () =
  let tc = thinking_control_for_flavor Provider_d_wire true (Some 8192) in
  check bool "is Openai_reasoning_effort"
    true
    (match tc with Openai_reasoning_effort _ -> true | _ -> false)

let test_thinking_ollama () =
  let tc = thinking_control_for_flavor Ollama true None in
  check bool "is Ollama_think"
    true
    (match tc with Ollama_think { think = true } -> true | _ -> false)

let test_thinking_qwen_no_thinking () =
  let tc = thinking_control_for_flavor Provider_h_wire true None in
  check bool "Provider_h_wire has No_thinking" true (tc = No_thinking)

let test_thinking_zai_glm_no_thinking () =
  let tc = thinking_control_for_flavor Provider_k_zai true None in
  check bool "Provider_k_zai has No_thinking" true (tc = No_thinking)

let test_thinking_disabled () =
  let tc = thinking_control_for_flavor Llama_cpp false None in
  check bool "disabled is Llama_cpp_thinking{enable=false}"
    true
    (match tc with Llama_cpp_thinking { enable = false; budget = None } -> true | _ -> false)

(* --- Finish reason mapping --- *)

let test_finish_stop () =
  let fr = finish_reason_of_string Provider_d_wire (Some "stop") in
  check bool "stop → Stop" true (fr = Stop)

let test_finish_length () =
  let fr = finish_reason_of_string Provider_d_wire (Some "length") in
  check bool "length → Length" true (fr = Length)

let test_finish_tool_calls () =
  let fr = finish_reason_of_string Provider_d_wire (Some "tool_calls") in
  check bool "tool_calls → Tool_calls" true (fr = Tool_calls)

let test_finish_content_filter () =
  let fr = finish_reason_of_string Provider_g_wire (Some "content_filter") in
  check bool "content_filter → Content_filter" true (fr = Content_filter)

let test_finish_none_qwen () =
  let fr = finish_reason_of_string Provider_h_wire None in
  check bool "Provider_h_wire None → Stop" true (fr = Stop)

let test_finish_unknown () =
  let fr = finish_reason_of_string Provider_d_wire (Some "weird_reason") in
  check bool "unknown → Error" true (fr = Error)

(* --- Suite --- *)

let () =
  run "Cascade Server Flavor"
    [ ( "constraints"
      , [ test_case "llama_cpp" `Quick test_llama_cpp_constraints
        ; test_case "ollama" `Quick test_ollama_constraints
        ; test_case "provider_d" `Quick test_openai_constraints
        ; test_case "deep_seek" `Quick test_deep_seek_constraints
        ; test_case "zai_glm" `Quick test_zai_glm_constraints
        ; test_case "provider_h tools+stream incompatible" `Quick test_qwen_tools_stream_incompatible
        ; test_case "vllm" `Quick test_vllm_constraints
        ] )
    ; ( "can_stream_with_tools"
      , [ test_case "provider_h false" `Quick test_can_stream_with_tools_qwen
        ; test_case "provider_d true" `Quick test_can_stream_with_tools_openai
        ; test_case "llama_cpp true" `Quick test_can_stream_with_tools_llama_cpp
        ; test_case "ollama true" `Quick test_can_stream_with_tools_ollama
        ] )
    ; ( "thinking_control"
      , [ test_case "llama_cpp with budget" `Quick test_thinking_llama_cpp
        ; test_case "llama_cpp no budget" `Quick test_thinking_llama_cpp_no_budget
        ; test_case "deep_seek enabled" `Quick test_thinking_deep_seek_enabled
        ; test_case "deep_seek disabled" `Quick test_thinking_deep_seek_disabled
        ; test_case "provider_d reasoning_effort" `Quick test_thinking_openai_reasoning_effort
        ; test_case "ollama think" `Quick test_thinking_ollama
        ; test_case "provider_h no thinking" `Quick test_thinking_qwen_no_thinking
        ; test_case "zai_glm no thinking" `Quick test_thinking_zai_glm_no_thinking
        ; test_case "disabled" `Quick test_thinking_disabled
        ] )
    ; ( "finish_reason"
      , [ test_case "stop" `Quick test_finish_stop
        ; test_case "length" `Quick test_finish_length
        ; test_case "tool_calls" `Quick test_finish_tool_calls
        ; test_case "content_filter" `Quick test_finish_content_filter
        ; test_case "provider_h None" `Quick test_finish_none_qwen
        ; test_case "unknown" `Quick test_finish_unknown
        ] )
    ]
