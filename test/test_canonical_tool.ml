(** Tests for {!Llm_provider.Canonical_tool} — RFC-OAS-024 WP8 Increments 1-2.

    Covers result projection (round-trip fidelity, is_error, totality) and the
    structural call projection used by downstream consumers that need to render
    interleaved Thinking -> ToolUse responses. The {e wiring} of
    [tool_result_of_block] into the turn pipeline is covered by the inline tests
    on [Pipeline_stage_prepare.last_tool_results_from]. *)

module Ct = Llm_provider.Canonical_tool
module PK = Llm_provider.Provider_kind
module Types = Llm_provider.Types

let json_eq = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let response ?provider_kind content : Types.api_response =
  let telemetry =
    match provider_kind with
    | Some provider_kind ->
      Some { Types.default_inference_telemetry with provider_kind = Some provider_kind }
    | None -> None
  in
  { id = "resp_1"
  ; model = "model"
  ; stop_reason = Types.StopToolUse
  ; content
  ; usage = None
  ; telemetry
  }
;;

let one_tool_call resp =
  match Ct.tool_calls_of_response resp with
  | [ call ] -> call
  | calls -> Alcotest.failf "expected one tool call, got %d" (List.length calls)
;;

let check_provider_kind label expected actual =
  match expected, actual with
  | None, None -> ()
  | Some PK.Ollama, Some PK.Ollama -> ()
  | Some PK.Anthropic, Some PK.Anthropic -> ()
  | Some PK.Kimi, Some PK.Kimi -> ()
  | Some PK.OpenAI_compat, Some PK.OpenAI_compat -> ()
  | Some PK.Gemini, Some PK.Gemini -> ()
  | Some PK.Glm, Some PK.Glm -> ()
  | Some PK.DashScope, Some PK.DashScope -> ()
  | _ -> Alcotest.failf "%s provider kind mismatch" label
;;

let check_no_adjacent_reasoning label = function
  | Ct.No_adjacent_reasoning -> ()
  | Ct.Adjacent_reasoning blocks ->
    Alcotest.failf
      "%s expected no adjacent reasoning, got %d blocks"
      label
      (List.length blocks)
;;

let check_visible_reasoning
      label
      expected_order
      expected_signature
      (block : Ct.provider_reasoning_block)
  =
  Alcotest.(check int) (label ^ " order") expected_order block.Ct.order_index;
  (match block.Ct.kind with
   | Ct.Visible_thinking -> ()
   | Ct.Redacted_thinking -> Alcotest.failf "%s expected visible thinking" label);
  Alcotest.(check (option string))
    (label ^ " signature")
    expected_signature
    block.Ct.signature
;;

let check_redacted_reasoning label expected_order (block : Ct.provider_reasoning_block) =
  Alcotest.(check int) (label ^ " order") expected_order block.Ct.order_index;
  (match block.Ct.kind with
   | Ct.Redacted_thinking -> ()
   | Ct.Visible_thinking -> Alcotest.failf "%s expected redacted thinking" label);
  Alcotest.(check (option string)) (label ^ " signature") None block.Ct.signature
;;

let metadata_only_copy (block : Ct.provider_reasoning_block) =
  { Ct.order_index = block.Ct.order_index
  ; kind = block.Ct.kind
  ; signature = block.Ct.signature
  }
;;

let exposed_reasoning_strings block =
  let block = metadata_only_copy block in
  match block.Ct.signature with
  | Some signature -> [ signature ]
  | None -> []
;;

let check_no_exposed_payload label payload block =
  let exposed = exposed_reasoning_strings block in
  if List.exists (String.equal payload) exposed
  then Alcotest.failf "%s leaked reasoning payload %S" label payload
;;

let test_tool_call_projection_preserves_fields_and_adjacent_reasoning () =
  let input = `Assoc [ "city", `String "Seoul" ] in
  let resp =
    response
      ~provider_kind:PK.Ollama
      [ Types.Text "visible preface"
      ; Types.Thinking { signature = Some "sig_1"; content = "call weather" }
      ; Types.ToolUse { id = "call_weather"; name = "get_weather"; input }
      ]
  in
  let call = one_tool_call resp in
  Alcotest.(check string) "call_id" "call_weather" call.Ct.call_id;
  Alcotest.(check string) "name" "get_weather" call.Ct.name;
  Alcotest.check json_eq "input" input call.Ct.input;
  Alcotest.(check int) "order_index" 0 call.Ct.order_index;
  check_provider_kind "call" (Some PK.Ollama) call.Ct.provider_kind;
  match call.Ct.adjacent_reasoning with
  | Ct.Adjacent_reasoning [ block ] ->
    check_visible_reasoning "adjacent reasoning" 1 (Some "sig_1") block
  | Ct.Adjacent_reasoning blocks ->
    Alcotest.failf "expected one adjacent reasoning block, got %d" (List.length blocks)
  | Ct.No_adjacent_reasoning -> Alcotest.fail "expected adjacent reasoning"
;;

let test_tool_calls_keep_interleaved_reasoning_groups () =
  let resp =
    response
      [ Types.Thinking { signature = None; content = "first plan" }
      ; Types.ToolUse { id = "call_1"; name = "lookup"; input = `Assoc [] }
      ; Types.Thinking { signature = None; content = "second plan" }
      ; Types.RedactedThinking "opaque_blob"
      ; Types.ToolUse
          { id = "call_2"; name = "search"; input = `Assoc [ "q", `String "x" ] }
      ; Types.ToolUse { id = "call_3"; name = "summarize"; input = `Assoc [] }
      ]
  in
  match Ct.tool_calls_of_response resp with
  | [ first; second; third ] ->
    Alcotest.(check string) "first id" "call_1" first.Ct.call_id;
    Alcotest.(check int) "first order" 0 first.Ct.order_index;
    (match first.Ct.adjacent_reasoning with
     | Ct.Adjacent_reasoning [ block ] ->
       check_visible_reasoning "first reasoning" 0 None block
     | _ -> Alcotest.fail "first call should have one adjacent reasoning block");
    Alcotest.(check string) "second id" "call_2" second.Ct.call_id;
    Alcotest.(check int) "second order" 1 second.Ct.order_index;
    (match second.Ct.adjacent_reasoning with
     | Ct.Adjacent_reasoning [ visible; redacted ] ->
       check_visible_reasoning "second visible reasoning" 2 None visible;
       check_redacted_reasoning "second redacted reasoning" 3 redacted
     | Ct.Adjacent_reasoning blocks ->
       Alcotest.failf
         "second call expected two adjacent reasoning blocks, got %d"
         (List.length blocks)
     | Ct.No_adjacent_reasoning -> Alcotest.fail "second call should have reasoning");
    Alcotest.(check string) "third id" "call_3" third.Ct.call_id;
    Alcotest.(check int) "third order" 2 third.Ct.order_index;
    check_no_adjacent_reasoning "third call" third.Ct.adjacent_reasoning
  | calls -> Alcotest.failf "expected three tool calls, got %d" (List.length calls)
;;

let test_text_breaks_reasoning_adjacency () =
  let resp =
    response
      [ Types.Thinking { signature = None; content = "not adjacent" }
      ; Types.Text "visible answer fragment"
      ; Types.ToolUse { id = "call_late"; name = "late_tool"; input = `Null }
      ]
  in
  let call = one_tool_call resp in
  Alcotest.(check int) "order_index" 0 call.Ct.order_index;
  check_no_adjacent_reasoning "text break" call.Ct.adjacent_reasoning
;;

let test_tool_call_of_block_preserves_fields_without_inference () =
  let input = `Assoc [ "path", `String "lib/" ] in
  let reasoning =
    { Ct.order_index = 2; kind = Ct.Visible_thinking; signature = Some "sig-tool" }
  in
  let block = Types.ToolUse { id = "call_read"; name = "read"; input } in
  match
    Ct.tool_call_of_block
      ~order_index:3
      ~provider_kind:PK.Anthropic
      ~adjacent_reasoning:(Ct.Adjacent_reasoning [ reasoning ])
      block
  with
  | Some call ->
    Alcotest.(check string) "call_id" "call_read" call.Ct.call_id;
    Alcotest.(check string) "name" "read" call.Ct.name;
    Alcotest.check json_eq "input" input call.Ct.input;
    Alcotest.(check int) "order_index" 3 call.Ct.order_index;
    check_provider_kind "block call" (Some PK.Anthropic) call.Ct.provider_kind;
    (match call.Ct.adjacent_reasoning with
     | Ct.Adjacent_reasoning [ block ] ->
       check_visible_reasoning "block adjacent reasoning" 2 (Some "sig-tool") block
     | Ct.Adjacent_reasoning blocks ->
       Alcotest.failf "expected one adjacent reasoning block, got %d" (List.length blocks)
     | Ct.No_adjacent_reasoning -> Alcotest.fail "expected supplied adjacent reasoning")
  | None -> Alcotest.fail "expected ToolUse projection"
;;

let test_adjacent_reasoning_projection_omits_payloads () =
  let visible_payload = "VISIBLE_REASONING_PAYLOAD_DO_NOT_RENDER" in
  let redacted_payload = "REDACTED_REASONING_PAYLOAD_DO_NOT_RENDER" in
  let resp =
    response
      [ Types.Thinking { signature = Some "payload-sig"; content = visible_payload }
      ; Types.RedactedThinking redacted_payload
      ; Types.ToolUse { id = "call_private"; name = "private_tool"; input = `Null }
      ]
  in
  let call = one_tool_call resp in
  match call.Ct.adjacent_reasoning with
  | Ct.Adjacent_reasoning [ visible; redacted ] ->
    check_visible_reasoning "visible metadata" 0 (Some "payload-sig") visible;
    check_redacted_reasoning "redacted metadata" 1 redacted;
    check_no_exposed_payload "visible metadata" visible_payload visible;
    check_no_exposed_payload "redacted metadata" redacted_payload redacted
  | Ct.Adjacent_reasoning blocks ->
    Alcotest.failf "expected two adjacent reasoning blocks, got %d" (List.length blocks)
  | Ct.No_adjacent_reasoning -> Alcotest.fail "expected adjacent reasoning"
;;

let test_tool_call_of_block_defaults_to_no_context () =
  let block = Types.ToolUse { id = "call_default"; name = "noop"; input = `Null } in
  match Ct.tool_call_of_block block with
  | Some call ->
    Alcotest.(check string) "call_id" "call_default" call.Ct.call_id;
    Alcotest.(check int) "default order" 0 call.Ct.order_index;
    check_provider_kind "default provider kind" None call.Ct.provider_kind;
    check_no_adjacent_reasoning "default adjacency" call.Ct.adjacent_reasoning
  | None -> Alcotest.fail "expected ToolUse projection"
;;

let test_tool_call_none_for_non_tooluse () =
  let cases =
    [ Types.Text "hi"
    ; Types.Thinking { signature = None; content = "..." }
    ; Types.ReasoningDetails { reasoning_content = Some "why"; details = [] }
    ; Types.RedactedThinking "redacted"
    ; Types.ToolResult
        { tool_use_id = "call_x"
        ; content = "ok"
        ; outcome = Tool_succeeded
        ; json = None
        ; content_blocks = None
        }
    ; Types.Image { media_type = "image/png"; data = "AAAA"; source_type = Types.Base64 }
    ; Types.Document
        { media_type = "application/pdf"; data = "JVBE"; source_type = Types.Base64 }
    ; Types.Audio { media_type = "audio/wav"; data = "UklG"; source_type = Types.Base64 }
    ]
  in
  List.iter
    (fun block ->
       Alcotest.(check bool)
         "non-ToolUse projects to None"
         true
         (Option.is_none (Ct.tool_call_of_block block)))
    cases
;;

let test_result_roundtrip_preserves_fields () =
  let json = `Assoc [ "rows", `Int 3 ] in
  let blocks = [ Types.Text "ignored" ] in
  let block =
    Types.ToolResult
      { tool_use_id = "call_abc"
      ; content = "3 rows"
      ; outcome = Tool_succeeded
      ; json = Some json
      ; content_blocks = Some blocks
      }
  in
  match Ct.tool_result_of_block block with
  | None -> Alcotest.fail "expected Some projection for a ToolResult block"
  | Some proj ->
    Alcotest.(check string) "call_id" "call_abc" proj.call_id;
    Alcotest.(check string) "content" "3 rows" proj.content;
    Alcotest.(check bool) "succeeded" true (proj.outcome = Types.Tool_succeeded);
    (match proj.structured_content with
     | Some j -> Alcotest.check json_eq "structured_content == json" json j
     | None -> Alcotest.fail "structured_content dropped");
    (match proj.content_blocks with
     | Some bs -> Alcotest.(check int) "content_blocks length" 1 (List.length bs)
     | None -> Alcotest.fail "content_blocks dropped")
;;

let test_result_preserves_failure_outcome () =
  let block =
    Types.ToolResult
      { tool_use_id = "call_err"
      ; content = "boom"
      ; outcome = Tool_failed { failure_kind = Reported_tool_error; error_class = None }
      ; json = None
      ; content_blocks = None
      }
  in
  match Ct.tool_result_of_block block with
  | Some proj ->
    Alcotest.(check bool)
      "failure outcome preserved"
      true
      (proj.outcome
       = Types.Tool_failed
           { failure_kind = Types.Reported_tool_error; error_class = None });
    Alcotest.(check (option json_eq))
      "structured_content None when json None"
      None
      proj.structured_content
  | None -> Alcotest.fail "expected Some projection"
;;

(* All six non-ToolResult content_block constructors project to None. *)
let test_result_none_for_non_toolresult () =
  let cases =
    [ Types.Text "hi"
    ; Types.Thinking { signature = None; content = "..." }
    ; Types.ReasoningDetails { reasoning_content = Some "why"; details = [] }
    ; Types.RedactedThinking "redacted"
    ; Types.ToolUse { id = "call_x"; name = "t"; input = `Null }
    ; Types.Image { media_type = "image/png"; data = "AAAA"; source_type = Types.Base64 }
    ; Types.Document
        { media_type = "application/pdf"; data = "JVBE"; source_type = Types.Base64 }
    ; Types.Audio { media_type = "audio/wav"; data = "UklG"; source_type = Types.Base64 }
    ]
  in
  List.iter
    (fun block ->
       Alcotest.(check bool)
         "non-ToolResult projects to None"
         true
         (Option.is_none (Ct.tool_result_of_block block)))
    cases
;;

let () =
  Alcotest.run
    "canonical_tool"
    [ ( "tool_calls_of_response"
      , [ Alcotest.test_case
            "preserves call fields and adjacent reasoning"
            `Quick
            test_tool_call_projection_preserves_fields_and_adjacent_reasoning
        ; Alcotest.test_case
            "keeps interleaved reasoning groups"
            `Quick
            test_tool_calls_keep_interleaved_reasoning_groups
        ; Alcotest.test_case
            "text breaks reasoning adjacency"
            `Quick
            test_text_breaks_reasoning_adjacency
        ; Alcotest.test_case
            "omits reasoning payloads"
            `Quick
            test_adjacent_reasoning_projection_omits_payloads
        ] )
    ; ( "tool_call_of_block"
      , [ Alcotest.test_case
            "preserves fields without inferring context"
            `Quick
            test_tool_call_of_block_preserves_fields_without_inference
        ; Alcotest.test_case
            "defaults to no structural context"
            `Quick
            test_tool_call_of_block_defaults_to_no_context
        ; Alcotest.test_case
            "None for non-ToolUse"
            `Quick
            test_tool_call_none_for_non_tooluse
        ] )
    ; ( "tool_result_of_block"
      , [ Alcotest.test_case
            "roundtrip preserves fields"
            `Quick
            test_result_roundtrip_preserves_fields
        ; Alcotest.test_case
            "preserves failure outcome / None json"
            `Quick
            test_result_preserves_failure_outcome
        ; Alcotest.test_case
            "None for non-ToolResult"
            `Quick
            test_result_none_for_non_toolresult
        ] )
    ]
;;
