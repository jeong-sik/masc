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

let latest_log_seq () =
  match Log.Ring.recent ~limit:1 () with
  | (entry : Log.Ring.entry) :: _ -> entry.seq
  | [] -> -1

let autoresearch_warnings_since seq =
  Log.Ring.recent ~limit:20 ~module_filter:"Autoresearch" ~since_seq:seq ()
  |> List.filter (fun (entry : Log.Ring.entry) ->
       String.equal entry.normalized_level "WARN")

(* ------------------------------------------------------------------ *)
(* has_background_capacity: fail-safe + noisy contract (#9537)         *)
(* ------------------------------------------------------------------ *)

(** When no Eio switch/net context is installed, [generate_code_change]
    must fail closed before model dispatch and emit an operator-visible
    Autoresearch warning.  Silent skip was the anti-pattern tracked in
    #9537 comment "Finding 2". *)
let test_capacity_missing_context_fails_closed_and_logs_warning () =
  let before_seq = latest_log_seq () in
  match
    Lib.Autoresearch.generate_code_change
      ~goal:"Improve throughput"
      ~baseline:1.25
      ~lower_is_better:false
      ~history:[]
      ~insights:[]
      ~file_content:"let batch = 32\n"
      ~target_file:"main.py"
  with
  | Ok _ -> fail "expected missing runtime capacity context to fail closed"
  | Error msg ->
      check bool "returns saturated/backoff error" true
        (contains msg "local slots saturated");
      let warnings = autoresearch_warnings_since before_seq in
      check bool "logs capacity skip warning" true
        (List.exists
           (fun (entry : Log.Ring.entry) ->
             contains entry.message "capacity check skipped")
           warnings)

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

(** Unknown / garbage top-level JSON shape must return [Error], not a
    silent default.  This pins the Unknown→Error contract from the
    noisy-by-default meta-issue (#9517). *)
let test_parse_model_code_response_rejects_unknown_shape () =
  let cases =
    [ ({|[1, 2, 3]|},                       "JSON array",         "JSON object")
    ; ({|"just a string"|},                  "bare string",        "JSON object")
    ; ({|42|},                               "bare number",        "JSON object")
    ; ({|true|},                             "bare boolean",       "JSON object")
    ; ("",                                   "empty string",       "empty response")
    ; ({|{"unknown_field": "value"}|},       "unknown fields obj", "hypothesis")
    ]
  in
  List.iter (fun (input, label, expected_fragment) ->
    match Lib.Autoresearch.parse_model_code_response input with
    | Ok _ ->
        failf "expected %s to be rejected as unknown shape" label
    | Error msg ->
        check bool
          (Printf.sprintf "%s: error message mentions expected fragment" label)
          true
          (contains msg expected_fragment)
  ) cases

let () =
  run "autoresearch_codegen"
    [
      ( "capacity-fail-safe",
        [
          test_case "missing context fails closed and logs warning" `Quick
            test_capacity_missing_context_fails_closed_and_logs_warning;
        ] );
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
          test_case "rejects unknown top-level shape (Unknown->Error contract)" `Quick
            test_parse_model_code_response_rejects_unknown_shape;
        ] );
    ]
