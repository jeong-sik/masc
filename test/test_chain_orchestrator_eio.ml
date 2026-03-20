open Alcotest
open Masc_mcp

let contains ~needle haystack =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

let test_parse_chain_design_rejects_edge_only_mermaid () =
  let response =
    {|```mermaid
graph LR
  execute_preview_smoke_run --> generate_confirmation_sentence
```|}
  in
  match Chain_orchestrator_eio.parse_chain_design response with
  | Ok chain ->
      failf "expected design rejection, got chain id=%s with %d nodes"
        chain.Chain_types.id (List.length chain.Chain_types.nodes)
  | Error message ->
      check bool "strict validation surfaced" true
        (contains ~needle:"Designed chain failed strict validation" message);
      check bool "empty chain explained" true
        (contains ~needle:"Chain has no nodes" message)

let test_parse_chain_design_accepts_explicit_mermaid_nodes () =
  let response =
    {|```mermaid
graph LR
  model_step_1["MODEL:gemini \"Generate a positive phrase about chain orchestration\""]
  model_step_2["MODEL:gemini \"Build a confirmation sentence using {{model_step_1}}\""]
  model_step_1 --> model_step_2
```|}
  in
  match Chain_orchestrator_eio.parse_chain_design response with
  | Error message -> failf "expected valid chain, got: %s" message
  | Ok chain ->
      check int "two designed nodes" 2 (List.length chain.Chain_types.nodes);
      match Chain_compiler.compile chain with
      | Ok _ -> ()
      | Error message -> failf "compiled designed chain: %s" message

let test_parse_chain_design_preserves_escaped_mermaid_prompts () =
  let response =
    {|```mermaid
graph LR
  draft_step["MODEL:gemini \"Draft a one-sentence confirmation that the preview-run smoke test was successful.\""]
  finalize_step["MODEL:gemini \"Review {{draft_step}} and finalize it into a single, clear confirmation sentence.\""]
  draft_step --> finalize_step
```|}
  in
  match Chain_orchestrator_eio.parse_chain_design response with
  | Error message -> failf "expected escaped mermaid prompt to parse, got: %s" message
  | Ok chain ->
      let find_model_prompt node_id =
        match List.find_opt (fun (node : Chain_types.node) -> node.id = node_id) chain.Chain_types.nodes with
        | Some { node_type = Model { prompt; _ }; _ } -> prompt
        | Some _ -> failf "node %s was not parsed as model" node_id
        | None -> failf "missing node %s" node_id
      in
      check string "draft prompt preserved"
        "Draft a one-sentence confirmation that the preview-run smoke test was successful."
        (find_model_prompt "draft_step");
      check string "finalize prompt preserved"
        "Review {{draft_step}} and finalize it into a single, clear confirmation sentence."
        (find_model_prompt "finalize_step")

let test_parse_chain_design_rejects_disconnected_dataflow () =
  let response =
    {|```mermaid
graph TD
  generate_sentence["MODEL:gemini \"Generate a one-sentence confirmation that the preview-run smoke test was successful.\""]
  output_confirmation["Tool:echo \"Output the generated sentence\""]
  generate_sentence --> output_confirmation
```|}
  in
  match Chain_orchestrator_eio.parse_chain_design response with
  | Ok _ -> fail "expected disconnected dataflow to be rejected"
  | Error message ->
      check bool "semantic validation surfaced" true
        (contains ~needle:"Designed chain failed semantic validation" message);
      check bool "missing upstream ref explained" true
        (contains ~needle:"does not reference upstream inputs generate_sentence" message)

let test_build_design_context_uses_parser_compatible_mermaid_examples () =
  let prompt =
    Chain_composer.build_design_context
      ~goal:"Produce a confirmation sentence"
      ~tasks:[]
  in
  check bool "model example includes model-qualified syntax" true
    (contains ~needle:"MODEL:gemini \\\"Analyze the goal\\\"" prompt);
  check bool "tool example includes parser syntax" true
    (contains ~needle:"Tool:echo \\\"{{task_002}}\\\"" prompt);
  check bool "requires explicit upstream interpolation" true
    (contains ~needle:"explicitly reference that upstream output with `{{upstream_node_id}}`" prompt);
  check bool "quality rule forbids edge-only mermaid" true
    (contains ~needle:"do not return edge-only Mermaid like `a --> b`" prompt)

let () =
  run "Chain_orchestrator_eio"
    [
      ( "parse_chain_design",
        [
          test_case "rejects edge-only mermaid" `Quick
            test_parse_chain_design_rejects_edge_only_mermaid;
          test_case "accepts explicit mermaid nodes" `Quick
            test_parse_chain_design_accepts_explicit_mermaid_nodes;
          test_case "preserves escaped mermaid prompts" `Quick
            test_parse_chain_design_preserves_escaped_mermaid_prompts;
          test_case "rejects disconnected dataflow" `Quick
            test_parse_chain_design_rejects_disconnected_dataflow;
        ] );
      ( "design_prompt",
        [
          test_case "uses parser-compatible mermaid examples" `Quick
            test_build_design_context_uses_parser_compatible_mermaid_examples;
        ] );
    ]
