module Lib = Masc_mcp

open Alcotest

let contains haystack needle =
  let len_h = String.length haystack
  and len_n = String.length needle in
  let rec loop i =
    if i + len_n > len_h then false
    else if String.sub haystack i len_n = needle then true
    else loop (i + 1)
  in
  loop 0

let test_prompt_requires_strict_json () =
  let prompt =
    Lib.Autoresearch.build_code_change_prompt
      ~goal:"Improve throughput"
      ~baseline:1.25
      ~lower_is_better:false
      ~history:[]
      ~insights:[]
      ~file_content:"let batch = 32\n"
      ~target_file:"main.py"
  in
  check bool "mentions valid JSON object" true
    (contains prompt "Reply with exactly one valid JSON object and nothing else.");
  check bool "forbids markdown fences" true
    (contains prompt "Do not wrap the JSON in markdown or code fences.");
  check bool "includes hypothesis key" true
    (contains prompt "\"hypothesis\"");
  check bool "includes modified_code key" true
    (contains prompt "\"modified_code\"")

let test_parse_model_code_response_accepts_strict_json () =
  let response =
    {|{"hypothesis":"Increase batch size","modified_code":"\nlet batch = 64\nlet keep = true\n\n"}|}
  in
  match Lib.Autoresearch.parse_model_code_response response with
  | Ok (hypothesis, code) ->
    check string "hypothesis" "Increase batch size" hypothesis;
    check string "normalized code" "let batch = 64\nlet keep = true" code
  | Error err ->
    failf "expected strict JSON response to parse, got %s" err

let test_parse_model_code_response_rejects_legacy_xml () =
  let response =
    "<hypothesis>Increase batch size</hypothesis>\n<modified_code>let batch = 64</modified_code>"
  in
  match Lib.Autoresearch.parse_model_code_response response with
  | Ok _ -> fail "expected legacy XML response to be rejected"
  | Error err ->
    check bool "mentions lenient recovery failure" true
      (contains err "not valid JSON after lenient recovery")

let test_parse_model_code_response_accepts_fenced_json () =
  let response =
    "```json\n{\"hypothesis\":\"Increase batch size\",\"modified_code\":\"let batch = 64\"}\n```"
  in
  match Lib.Autoresearch.parse_model_code_response response with
  | Ok (hypothesis, code) ->
    check string "fenced hypothesis" "Increase batch size" hypothesis;
    check string "fenced code" "let batch = 64" code
  | Error err ->
    failf "expected fenced JSON response to parse, got %s" err

let test_parse_model_code_response_rejects_missing_fields () =
  let response = {|{"hypothesis":"Increase batch size"}|} in
  match Lib.Autoresearch.parse_model_code_response response with
  | Ok _ -> fail "expected missing modified_code to be rejected"
  | Error err ->
    check bool "mentions missing modified_code" true
      (contains err "\"modified_code\"")

let () =
  run "autoresearch_codegen"
    [
      ( "prompt",
        [
          test_case "requires strict JSON object output" `Quick
            test_prompt_requires_strict_json;
        ] );
      ( "parser",
        [
          test_case "accepts strict JSON object" `Quick
            test_parse_model_code_response_accepts_strict_json;
          test_case "rejects legacy XML tags" `Quick
            test_parse_model_code_response_rejects_legacy_xml;
          test_case "accepts fenced JSON" `Quick
            test_parse_model_code_response_accepts_fenced_json;
          test_case "rejects missing fields" `Quick
            test_parse_model_code_response_rejects_missing_fields;
        ] );
    ]
