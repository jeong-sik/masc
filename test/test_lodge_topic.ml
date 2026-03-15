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
    ];
    "heuristic", [
      test_case "ocaml keywords" `Quick test_heuristic_ocaml;
      test_case "empty" `Quick test_heuristic_empty;
      test_case "multiple keywords" `Quick test_heuristic_multiple;
      test_case "case insensitive" `Quick test_heuristic_case_insensitive;
    ];
    "mode", [
      test_case "dispatch heuristic" `Quick test_mode_dispatch_heuristic;
      test_case "env parsing" `Quick test_mode_env_parsing;
    ];
    "prompt", [
      test_case "contains content" `Quick test_build_prompt_contains_content;
      test_case "truncates long content" `Quick test_build_prompt_truncates_long_content;
      test_case "has json instruction" `Quick test_build_prompt_has_json_instruction;
    ];
    "llm", [
      test_case "skip short content" `Quick test_llm_skip_short_content;
    ];
  ]
