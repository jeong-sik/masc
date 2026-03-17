(** Tests for Lodge_topic module — Heuristic/LLM/Hybrid Topic Extraction *)

open Alcotest
open Masc_mcp

(* Helper: run f with MASC_TOPIC_MODE set, restore after (even on exception) *)
let with_topic_mode mode f =
  let prev = Sys.getenv_opt "MASC_TOPIC_MODE" in
  Unix.putenv "MASC_TOPIC_MODE" mode;
  Fun.protect f ~finally:(fun () ->
    match prev with
    | Some v -> Unix.putenv "MASC_TOPIC_MODE" v
    | None -> Unix.putenv "MASC_TOPIC_MODE" "hybrid")

(* ============================================
   Parsing tests — pure functions, no I/O
   ============================================ *)

let test_parse_clean_json () =
  let topics = Lodge_topic.parse_topics_response {|["ocaml","eio"]|} in
  check int "2 topics" 2 (List.length topics);
  check bool "contains ocaml" true (List.mem "ocaml" topics);
  check bool "contains eio" true (List.mem "eio" topics)

let test_parse_json_in_prose () =
  let topics = Lodge_topic.parse_topics_response {|Here are the topics: ["agent","mcp"]|} in
  check int "2 topics" 2 (List.length topics);
  check bool "contains agent" true (List.mem "agent" topics);
  check bool "contains mcp" true (List.mem "mcp" topics)

let test_parse_malformed () =
  let topics = Lodge_topic.parse_topics_response "not json at all" in
  check int "0 topics" 0 (List.length topics)

let test_parse_empty_array () =
  let topics = Lodge_topic.parse_topics_response "[]" in
  check int "0 topics" 0 (List.length topics)

let test_parse_truncation () =
  (* 10+ items should be truncated to 8 *)
  let json = {|["a","b","c","d","e","f","g","h","i","j","k"]|} in
  let topics = Lodge_topic.parse_topics_response json in
  check int "truncated to 8" 8 (List.length topics)

let test_parse_oversized_topic () =
  (* Topics longer than 50 chars should be filtered out *)
  let long_topic = String.make 51 'x' in
  let json = Printf.sprintf {|["%s", "ocaml"]|} long_topic in
  let topics = Lodge_topic.parse_topics_response json in
  check int "only 1 valid topic" 1 (List.length topics);
  check bool "contains ocaml" true (List.mem "ocaml" topics)

let test_parse_mixed_types () =
  (* Non-string items in array should be filtered *)
  let topics = Lodge_topic.parse_topics_response {|["ocaml", 42, true, "eio"]|} in
  check int "2 string topics" 2 (List.length topics);
  check bool "contains ocaml" true (List.mem "ocaml" topics);
  check bool "contains eio" true (List.mem "eio" topics)

let test_parse_whitespace_and_case () =
  (* Should trim and lowercase *)
  let topics = Lodge_topic.parse_topics_response {|["  OCaml  ", "EIO"]|} in
  check int "2 topics" 2 (List.length topics);
  check bool "lowercased ocaml" true (List.mem "ocaml" topics);
  check bool "lowercased eio" true (List.mem "eio" topics)

let test_parse_empty_string_topic () =
  (* Empty strings should be filtered *)
  let topics = Lodge_topic.parse_topics_response {|["", "ocaml", ""]|} in
  check int "1 valid topic" 1 (List.length topics)

let test_parse_nested_brackets () =
  (* Inner brackets like type[T] should not confuse the parser *)
  let topics = Lodge_topic.parse_topics_response {|["type[t]", "foo"]|} in
  check int "2 topics from nested brackets" 2 (List.length topics);
  check bool "contains type[t]" true (List.mem "type[t]" topics);
  check bool "contains foo" true (List.mem "foo" topics)

let test_parse_json_with_trailing_text () =
  (* Trailing text after the array should be ignored *)
  let topics = Lodge_topic.parse_topics_response {|["ocaml","eio"] some extra text|} in
  check int "2 topics ignoring trailing" 2 (List.length topics);
  check bool "contains ocaml" true (List.mem "ocaml" topics);
  check bool "contains eio" true (List.mem "eio" topics)

let test_parse_number_array () =
  (* An array of numbers should yield 0 string topics *)
  let topics = Lodge_topic.parse_topics_response {|[1, 2, 3]|} in
  check int "0 topics from number array" 0 (List.length topics)

let test_parse_deeply_nested () =
  (* Brackets inside strings should be handled *)
  let topics = Lodge_topic.parse_topics_response
    {|["list[int]", "map[string, list[float]]", "simple"]|} in
  check int "3 topics" 3 (List.length topics);
  check bool "simple present" true (List.mem "simple" topics)

let test_parse_prose_before_and_after () =
  let topics = Lodge_topic.parse_topics_response
    {|Sure, here are topics: ["graphql", "api"] Hope that helps.|} in
  check int "2 topics" 2 (List.length topics);
  check bool "graphql" true (List.mem "graphql" topics);
  check bool "api" true (List.mem "api" topics)

(* ============================================
   find_array_bounds tests
   ============================================ *)

let test_find_array_simple () =
  match Lodge_topic.find_array_bounds {|["a","b"]|} with
  | Some (0, 8) -> ()
  | Some (s, e) -> fail (Printf.sprintf "wrong bounds: %d,%d" s e)
  | None -> fail "expected Some"

let test_find_array_nested () =
  match Lodge_topic.find_array_bounds {|["x[y]","z"]|} with
  | Some (0, 11) -> ()
  | Some (s, e) -> fail (Printf.sprintf "wrong bounds: %d,%d" s e)
  | None -> fail "expected Some"

let test_find_array_none () =
  match Lodge_topic.find_array_bounds "no brackets here" with
  | None -> ()
  | Some _ -> fail "expected None"

let test_find_array_with_prefix () =
  match Lodge_topic.find_array_bounds {|topics: ["a"]|} with
  | Some (8, 12) -> ()
  | Some (s, e) -> fail (Printf.sprintf "wrong bounds: %d,%d" s e)
  | None -> fail "expected Some"

(* ============================================
   truncate_topics tests
   ============================================ *)

let test_truncate_over () =
  let topics = List.init 12 (fun i -> Printf.sprintf "t%d" i) in
  let result = Lodge_topic.truncate_topics topics in
  check int "truncated to 8" 8 (List.length result)

let test_truncate_exact () =
  let topics = List.init 8 (fun i -> Printf.sprintf "t%d" i) in
  let result = Lodge_topic.truncate_topics topics in
  check int "exactly 8" 8 (List.length result)

let test_truncate_under () =
  let topics = ["a"; "b"; "c"] in
  let result = Lodge_topic.truncate_topics topics in
  check int "unchanged 3" 3 (List.length result)

(* ============================================
   filter_topic_items tests
   ============================================ *)

let test_filter_valid () =
  let items = [`String "ocaml"; `String "eio"] in
  let result = Lodge_topic.filter_topic_items items in
  check int "2 items" 2 (List.length result)

let test_filter_mixed () =
  let items = [`String "ocaml"; `Int 42; `Bool true; `String "eio"] in
  let result = Lodge_topic.filter_topic_items items in
  check int "2 string items" 2 (List.length result)

let test_filter_empty_and_oversized () =
  let long = `String (String.make 60 'z') in
  let items = [`String ""; long; `String "ok"] in
  let result = Lodge_topic.filter_topic_items items in
  check int "only 1 valid" 1 (List.length result);
  check bool "ok present" true (List.mem "ok" result)

(* ============================================
   topics_response_is_valid tests
   ============================================ *)

let make_llm_response content =
  Llm_client.{
    content = [Agent_sdk.Types.Text content];
    tool_calls = [];
    usage = {
      input_tokens = 0; output_tokens = 0; total_tokens = 0;
      cache_creation_input_tokens = 0; cache_read_input_tokens = 0;
    };
    model_used = "test";
    latency_ms = 0;
  }

let test_validate_valid () =
  let r = make_llm_response {|["ocaml", "eio"]|} in
  check bool "valid response" true (Lodge_topic.topics_response_is_valid r)

let test_validate_empty_array () =
  let r = make_llm_response {|[]|} in
  check bool "empty array is invalid" false (Lodge_topic.topics_response_is_valid r)

let test_validate_garbage () =
  let r = make_llm_response "I don't know what to say" in
  check bool "garbage is invalid" false (Lodge_topic.topics_response_is_valid r)

let test_validate_number_array () =
  let r = make_llm_response {|[1, 2, 3]|} in
  check bool "number array is invalid" false (Lodge_topic.topics_response_is_valid r)

(* ============================================
   Heuristic tests — keyword matching
   ============================================ *)

let test_heuristic_ocaml () =
  let topics = Lodge_topic.extract_topics_heuristic "I love OCaml and Eio" in
  check bool "contains ocaml" true (List.mem "ocaml" topics);
  check bool "contains eio" true (List.mem "eio" topics)

let test_heuristic_empty () =
  let topics = Lodge_topic.extract_topics_heuristic "Hello world" in
  check int "no topics" 0 (List.length topics)

let test_heuristic_multiple () =
  let topics = Lodge_topic.extract_topics_heuristic "GraphQL API with Neo4j and React frontend" in
  check bool "contains graphql" true (List.mem "graphql" topics);
  check bool "contains neo4j" true (List.mem "neo4j" topics);
  check bool "contains react" true (List.mem "react" topics);
  check bool "contains api" true (List.mem "api" topics)

let test_heuristic_case_insensitive () =
  let topics = Lodge_topic.extract_topics_heuristic "RUST and DOCKER" in
  check bool "contains rust" true (List.mem "rust" topics);
  check bool "contains docker" true (List.mem "docker" topics)

(* ============================================
   Compound keyword tests
   ============================================ *)

let test_compound_kebab_case () =
  let topics = Lodge_topic.extract_topics_heuristic
    "We use functional-programming with a strong type-system" in
  check bool "compound: functional-programming" true
    (List.mem "functional-programming" topics);
  check bool "compound: type-system" true
    (List.mem "type-system" topics)

let test_compound_space_separated () =
  (* Should also match "functional programming" (space form) *)
  let topics = Lodge_topic.extract_topics_heuristic
    "Functional programming is great for error handling" in
  check bool "compound: functional-programming" true
    (List.mem "functional-programming" topics);
  check bool "compound: error-handling" true
    (List.mem "error-handling" topics)

let test_compound_before_singles () =
  (* Compounds should appear before single-word matches *)
  let topics = Lodge_topic.extract_topics_heuristic
    "machine-learning with python and tensorflow" in
  check bool "first topic is compound" true
    (List.hd topics = "machine-learning")

(* ============================================
   Frequency scoring tests
   ============================================ *)

let test_frequency_ordering () =
  (* "ocaml" appears 3x, "rust" 1x — ocaml should rank higher *)
  let topics = Lodge_topic.extract_topics_heuristic
    "OCaml is great. I wrote OCaml today. OCaml and Rust are both fast." in
  let ocaml_idx = List.filteri (fun _ t -> t = "ocaml") topics |> List.length in
  let rust_idx = List.filteri (fun _ t -> t = "rust") topics |> List.length in
  check bool "ocaml found" true (ocaml_idx > 0);
  check bool "rust found" true (rust_idx > 0);
  (* Verify ocaml appears before rust in the list *)
  let rec find_index lst target i = match lst with
    | [] -> -1
    | x :: _ when x = target -> i
    | _ :: rest -> find_index rest target (i + 1)
  in
  let o_i = find_index topics "ocaml" 0 in
  let r_i = find_index topics "rust" 0 in
  check bool "ocaml before rust (more frequent)" true (o_i < r_i)

let test_count_occurrences () =
  check int "3 occurrences" 3
    (Lodge_topic.count_occurrences "ocaml ocaml ocaml" "ocaml");
  check int "0 occurrences" 0
    (Lodge_topic.count_occurrences "python is great" "ocaml");
  check int "1 occurrence" 1
    (Lodge_topic.count_occurrences "a" "a")

(* ============================================
   Merge tests
   ============================================ *)

let test_merge_deduplication () =
  let merged = Lodge_topic.merge_topics
    ~primary:["ocaml"; "eio"; "rust"]
    ~secondary:["rust"; "react"; "ocaml"]
  in
  (* ocaml, eio, rust, react = 4 unique *)
  check int "4 unique after merge" 4 (List.length merged);
  check bool "primary order preserved" true (List.hd merged = "ocaml");
  (* rust from secondary is deduplicated *)
  check bool "no duplicates" true
    (List.length merged = List.length (List.sort_uniq String.compare merged))

let test_merge_caps_at_max () =
  let primary = ["a"; "b"; "c"; "d"; "e"; "f"; "g"; "h"] in
  let secondary = ["i"; "j"; "k"] in
  let merged = Lodge_topic.merge_topics ~primary ~secondary in
  check int "capped at 8" 8 (List.length merged)

let test_merge_empty_primary () =
  let merged = Lodge_topic.merge_topics
    ~primary:[] ~secondary:["rust"; "react"] in
  check int "2 from secondary" 2 (List.length merged)

(* ============================================
   Mode dispatch tests
   ============================================ *)

let test_mode_dispatch_heuristic () =
  with_topic_mode "heuristic" (fun () ->
    let topics = Lodge_topic.extract_topics "I love OCaml and Eio" in
    check bool "contains ocaml" true (List.mem "ocaml" topics);
    check bool "contains eio" true (List.mem "eio" topics))

let test_mode_env_parsing () =
  with_topic_mode "heuristic" (fun () ->
    check bool "heuristic mode" true (Lodge_topic.get_topic_mode () = Lodge_topic.Heuristic));
  with_topic_mode "llm" (fun () ->
    check bool "llm mode" true (Lodge_topic.get_topic_mode () = Lodge_topic.Llm));
  with_topic_mode "hybrid" (fun () ->
    check bool "hybrid mode" true (Lodge_topic.get_topic_mode () = Lodge_topic.Hybrid));
  with_topic_mode "unknown" (fun () ->
    check bool "unknown defaults to hybrid" true (Lodge_topic.get_topic_mode () = Lodge_topic.Hybrid))

(* ============================================
   Prompt generation tests
   ============================================ *)

let test_build_prompt_contains_content () =
  let prompt = Lodge_topic.build_topic_prompt "OCaml is great for systems programming" in
  check bool "contains content" true
    (try ignore (Str.search_forward (Str.regexp_string "OCaml is great") prompt 0); true
     with Not_found -> false)

let test_build_prompt_truncates_long_content () =
  let long_content = String.make 2000 'x' in
  let prompt = Lodge_topic.build_topic_prompt long_content in
  (* Prompt should not contain the full 2000 chars *)
  check bool "prompt is shorter than content + overhead" true
    (String.length prompt < 2000 + 500)

let test_build_prompt_has_json_instruction () =
  let prompt = Lodge_topic.build_topic_prompt "test content" in
  check bool "mentions JSON array" true
    (try ignore (Str.search_forward (Str.regexp_string "JSON array") prompt 0); true
     with Not_found -> false)

let test_build_prompt_has_empty_array_instruction () =
  let prompt = Lodge_topic.build_topic_prompt "test content" in
  check bool "mentions empty array []" true
    (try ignore (Str.search_forward (Str.regexp_string "[]") prompt 0); true
     with Not_found -> false)

let test_build_prompt_has_bad_examples () =
  let prompt = Lodge_topic.build_topic_prompt "test content" in
  check bool "has bad examples" true
    (try ignore (Str.search_forward (Str.regexp_string "Bad examples") prompt 0); true
     with Not_found -> false)

(* ============================================
   LLM extraction tests (short content skip)
   ============================================ *)

let test_llm_skip_short_content () =
  with_topic_mode "llm" (fun () ->
    let result = Lodge_topic.extract_topics_llm "hi" in
    check bool "short content returns Ok" true (Result.is_ok result);
    check int "empty topics" 0 (List.length (Result.get_ok result)))

(* ============================================
   Test suite
   ============================================ *)

let () =
  run "Lodge_topic" [
    "parsing", [
      test_case "clean json" `Quick test_parse_clean_json;
      test_case "json in prose" `Quick test_parse_json_in_prose;
      test_case "malformed" `Quick test_parse_malformed;
      test_case "empty array" `Quick test_parse_empty_array;
      test_case "truncation" `Quick test_parse_truncation;
      test_case "oversized topic" `Quick test_parse_oversized_topic;
      test_case "mixed types" `Quick test_parse_mixed_types;
      test_case "whitespace and case" `Quick test_parse_whitespace_and_case;
      test_case "empty string topic" `Quick test_parse_empty_string_topic;
      test_case "nested brackets" `Quick test_parse_nested_brackets;
      test_case "trailing text" `Quick test_parse_json_with_trailing_text;
      test_case "number array" `Quick test_parse_number_array;
      test_case "deeply nested brackets" `Quick test_parse_deeply_nested;
      test_case "prose before and after" `Quick test_parse_prose_before_and_after;
    ];
    "find_array_bounds", [
      test_case "simple array" `Quick test_find_array_simple;
      test_case "nested brackets" `Quick test_find_array_nested;
      test_case "no brackets" `Quick test_find_array_none;
      test_case "with prefix text" `Quick test_find_array_with_prefix;
    ];
    "truncate_topics", [
      test_case "over max" `Quick test_truncate_over;
      test_case "exact max" `Quick test_truncate_exact;
      test_case "under max" `Quick test_truncate_under;
    ];
    "filter_topic_items", [
      test_case "valid items" `Quick test_filter_valid;
      test_case "mixed types" `Quick test_filter_mixed;
      test_case "empty and oversized" `Quick test_filter_empty_and_oversized;
    ];
    "topics_response_is_valid", [
      test_case "valid response" `Quick test_validate_valid;
      test_case "empty array invalid" `Quick test_validate_empty_array;
      test_case "garbage invalid" `Quick test_validate_garbage;
      test_case "number array invalid" `Quick test_validate_number_array;
    ];
    "heuristic", [
      test_case "ocaml keywords" `Quick test_heuristic_ocaml;
      test_case "empty" `Quick test_heuristic_empty;
      test_case "multiple keywords" `Quick test_heuristic_multiple;
      test_case "case insensitive" `Quick test_heuristic_case_insensitive;
    ];
    "compound", [
      test_case "kebab-case match" `Quick test_compound_kebab_case;
      test_case "space separated match" `Quick test_compound_space_separated;
      test_case "compounds before singles" `Quick test_compound_before_singles;
    ];
    "frequency", [
      test_case "frequency ordering" `Quick test_frequency_ordering;
      test_case "count_occurrences" `Quick test_count_occurrences;
    ];
    "merge", [
      test_case "deduplication" `Quick test_merge_deduplication;
      test_case "caps at max" `Quick test_merge_caps_at_max;
      test_case "empty primary" `Quick test_merge_empty_primary;
    ];
    "mode", [
      test_case "dispatch heuristic" `Quick test_mode_dispatch_heuristic;
      test_case "env parsing" `Quick test_mode_env_parsing;
    ];
    "prompt", [
      test_case "contains content" `Quick test_build_prompt_contains_content;
      test_case "truncates long content" `Quick test_build_prompt_truncates_long_content;
      test_case "has json instruction" `Quick test_build_prompt_has_json_instruction;
      test_case "has empty array instruction" `Quick test_build_prompt_has_empty_array_instruction;
      test_case "has bad examples" `Quick test_build_prompt_has_bad_examples;
    ];
    "llm", [
      test_case "skip short content" `Quick test_llm_skip_short_content;
    ];
  ]
