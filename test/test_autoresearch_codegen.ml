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

let count_occurrences ~needle haystack =
  let nlen = String.length needle in
  if nlen = 0 then 0
  else
    let len_h = String.length haystack in
    let rec loop i acc =
      if i + nlen > len_h then acc
      else if String.sub haystack i nlen = needle then loop (i + nlen) (acc + 1)
      else loop (i + 1) acc
    in
    loop 0 0

let load_source rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root rel in
  if not (Sys.file_exists path) then
    failwith (Printf.sprintf "source file not found: %s" path)
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> In_channel.input_all ic)

let target_file = "lib/autoresearch_codegen.ml"

(* ------------------------------------------------------------------ *)
(* has_background_capacity: fail-safe + noisy contract (#9537)         *)
(* ------------------------------------------------------------------ *)

(** The wildcard branch of [has_background_capacity] must return [false]
    (fail-safe / fail-closed) and emit a warning log — not silently
    skip.  Silent skip was the anti-pattern tracked in #9537 comment
    "Finding 2". *)
let test_capacity_wildcard_branch_logs_warning () =
  let src = load_source target_file in
  (* Must have a warn call in the vicinity of the wildcard branch *)
  check bool "wildcard branch emits Log.Autoresearch.warn" true
    (count_occurrences
       ~needle:"Log.Autoresearch.warn"
       src
     >= 2);  (* one for capacity exception, one for missing context *)
  check bool "wildcard branch message mentions skipped" true
    (count_occurrences
       ~needle:"capacity check skipped"
       src
     >= 1)

(** The wildcard branch must not simply return [true] (permissive default).
    [false] is the only acceptable constant in that arm. *)
let test_capacity_wildcard_branch_is_fail_safe () =
  let src = load_source target_file in
  (* The wildcard arm in has_background_capacity must end with [false].
     We assert the log message is present (established above) and that
     there is no bare `| _ -> true` in the function body. *)
  check bool "no permissive `| _ -> true` in capacity check" true
    (not (contains src "| _ -> true"))

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
    [ ({|[1, 2, 3]|},              "JSON array")
    ; ({|"just a string"|},        "bare string")
    ; ({|42|},                      "bare number")
    ; ({|true|},                    "bare boolean")
    ; ("",                          "empty string")
    ]
  in
  List.iter (fun (input, label) ->
    match Lib.Autoresearch.parse_model_code_response input with
    | Ok _ ->
        failf "expected %s to be rejected as unknown shape" label
    | Error _msg ->
        ()
  ) cases

let () =
  run "autoresearch_codegen"
    [
      ( "capacity-fail-safe",
        [
          test_case "wildcard branch logs warning (not silent)" `Quick
            test_capacity_wildcard_branch_logs_warning;
          test_case "wildcard branch is fail-safe (not permissive)" `Quick
            test_capacity_wildcard_branch_is_fail_safe;
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
