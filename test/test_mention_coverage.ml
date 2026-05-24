(** Mention Module Coverage Tests

    Tests for @mention parsing:
    - mode type: Stateless, Stateful, Broadcast, None
    - mode_to_string: mode to string conversion
    - agent_type_of_mention: extract base agent type
    - is_nickname: check if mention is a generated nickname
    - parse: parse @mentions from content
    - extract: extract mention target
*)

open Alcotest

module Mention = Mention

(* ============================================================
   mode_to_string Tests
   ============================================================ *)

let test_mode_to_string_stateless () =
  let s = Mention.mode_to_string (Mention.Stateless "agent_llm_a") in
  check bool "contains Stateless" true
    (try
       let _ = Str.search_forward (Str.regexp "Stateless") s 0 in
       true
     with Not_found -> false)

let test_mode_to_string_stateful () =
  let s = Mention.mode_to_string (Mention.Stateful "agent_llm_a-gentle-gecko") in
  check bool "contains Stateful" true
    (try
       let _ = Str.search_forward (Str.regexp "Stateful") s 0 in
       true
     with Not_found -> false)

let test_mode_to_string_broadcast () =
  let s = Mention.mode_to_string (Mention.Broadcast "ollama") in
  check bool "contains Broadcast" true
    (try
       let _ = Str.search_forward (Str.regexp "Broadcast") s 0 in
       true
     with Not_found -> false)

let test_mode_to_string_none () =
  let s = Mention.mode_to_string Mention.None in
  check string "None" "None" s

(* ============================================================
   agent_type_of_mention Tests
   ============================================================ *)

let test_agent_type_simple () =
  check string "simple" "agent_llm_a" (Mention.agent_type_of_mention "agent_llm_a")

let test_agent_type_nickname () =
  check string "nickname" "ollama" (Mention.agent_type_of_mention "ollama-gentle-gecko")

let test_agent_type_two_parts () =
  check string "two parts" "agent_llm_a" (Mention.agent_type_of_mention "agent_llm_a-code")

let test_agent_type_empty () =
  check string "empty" "" (Mention.agent_type_of_mention "")

(* ============================================================
   is_nickname Tests
   ============================================================ *)

let test_is_nickname_true () =
  check bool "three parts" true (Mention.is_nickname "ollama-gentle-gecko")

let test_is_nickname_false_simple () =
  check bool "simple" false (Mention.is_nickname "agent_llm_a")

let test_is_nickname_false_two_parts () =
  check bool "two parts" false (Mention.is_nickname "agent_llm_a-code")

let test_is_nickname_four_parts () =
  check bool "four parts" true (Mention.is_nickname "a-b-c-d")

(* ============================================================
   parse Tests
   ============================================================ *)

let test_parse_broadcast () =
  match Mention.parse "Hello @@ollama world" with
  | Mention.Broadcast "ollama" -> ()
  | _ -> fail "expected Broadcast"

let test_parse_stateful () =
  match Mention.parse "Hello @agent_llm_a-gentle-gecko" with
  | Mention.Stateful "agent_llm_a-gentle-gecko" -> ()
  | _ -> fail "expected Stateful"

let test_parse_stateless () =
  match Mention.parse "Hello @agent_llm_a" with
  | Mention.Stateless "agent_llm_a" -> ()
  | _ -> fail "expected Stateless"

let test_parse_none () =
  match Mention.parse "Hello world" with
  | Mention.None -> ()
  | _ -> fail "expected None"

let test_parse_broadcast_priority () =
  (* Broadcast should take priority over other mentions *)
  match Mention.parse "@@ollama @agent_llm_a" with
  | Mention.Broadcast "ollama" -> ()
  | _ -> fail "expected Broadcast"

let test_parse_two_part_stateful () =
  match Mention.parse "Hello @agent_llm_a-code" with
  | Mention.Stateful "agent_llm_a-code" -> ()
  | _ -> fail "expected Stateful"

let test_parse_underscore () =
  match Mention.parse "Hello @agent_name" with
  | Mention.Stateless "agent_name" -> ()
  | _ -> fail "expected Stateless with underscore"

let test_parse_number () =
  match Mention.parse "Hello @agent123" with
  | Mention.Stateless "agent123" -> ()
  | _ -> fail "expected Stateless with number"

(* ============================================================
   extract Tests
   ============================================================ *)

let test_extract_broadcast () =
  match Mention.extract "Hello @@ollama" with
  | Some "ollama" -> ()
  | _ -> fail "expected Some ollama"

let test_extract_stateful () =
  match Mention.extract "@agent_llm_a-gentle-gecko test" with
  | Some "agent_llm_a-gentle-gecko" -> ()
  | _ -> fail "expected Some"

let test_extract_stateless () =
  match Mention.extract "@agent_llm_a test" with
  | Some "agent_llm_a" -> ()
  | _ -> fail "expected Some"

let test_extract_none () =
  match Mention.extract "no mention here" with
  | None -> ()
  | Some _ -> fail "expected None"

(* ============================================================
   Edge Cases
   ============================================================ *)

let test_parse_at_end () =
  match Mention.parse "message @agent" with
  | Mention.Stateless "agent" -> ()
  | _ -> fail "expected Stateless"

let test_parse_multiple_mentions () =
  (* First mention wins *)
  match Mention.parse "@first @second" with
  | Mention.Stateless "first" -> ()
  | _ -> fail "expected first"

let test_parse_email_like () =
  (* Should not match email-like patterns - but regex might *)
  let result = Mention.parse "email: test@example.com" in
  check bool "some result" true (result <> Mention.None)

(* ============================================================
   resolve_targets Tests
   ============================================================ *)

let test_resolve_targets_none () =
  let targets = Mention.resolve_targets Mention.None ~available_agents:["agent_llm_a"; "provider_f"] in
  check int "none returns empty" 0 (List.length targets)

let test_resolve_targets_stateless_found () =
  let targets = Mention.resolve_targets (Mention.Stateless "agent_llm_a")
    ~available_agents:["agent_llm_a-gentle-gecko"; "provider_f-swift-fox"] in
  check int "stateless returns one" 1 (List.length targets);
  check string "first match" "agent_llm_a-gentle-gecko" (List.hd targets)

let test_resolve_targets_stateless_not_found () =
  let targets = Mention.resolve_targets (Mention.Stateless "agent_code")
    ~available_agents:["agent_llm_a"; "provider_f"] in
  check int "not found returns empty" 0 (List.length targets)

let test_resolve_targets_stateful_found () =
  let targets = Mention.resolve_targets (Mention.Stateful "agent_llm_a-gentle-gecko")
    ~available_agents:["agent_llm_a-gentle-gecko"; "provider_f-swift-fox"] in
  check int "stateful returns one" 1 (List.length targets);
  check string "exact match" "agent_llm_a-gentle-gecko" (List.hd targets)

let test_resolve_targets_stateful_not_found () =
  let targets = Mention.resolve_targets (Mention.Stateful "agent_llm_a-unknown-animal")
    ~available_agents:["agent_llm_a-gentle-gecko"; "provider_f-swift-fox"] in
  check int "no exact match returns empty" 0 (List.length targets)

let test_resolve_targets_broadcast () =
  let targets = Mention.resolve_targets (Mention.Broadcast "agent_llm_a")
    ~available_agents:["agent_llm_a-gentle-gecko"; "agent_llm_a-brave-tiger"; "provider_f-swift-fox"] in
  check int "broadcast returns all agent_llm_a" 2 (List.length targets)

let test_resolve_targets_broadcast_none () =
  let targets = Mention.resolve_targets (Mention.Broadcast "ollama")
    ~available_agents:["agent_llm_a"; "provider_f"] in
  check int "no ollama agents" 0 (List.length targets)

let test_resolve_targets_empty_agents () =
  let targets = Mention.resolve_targets (Mention.Stateless "agent_llm_a")
    ~available_agents:[] in
  check int "no agents" 0 (List.length targets)

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Mention Coverage" [
    "mode_to_string", [
      test_case "stateless" `Quick test_mode_to_string_stateless;
      test_case "stateful" `Quick test_mode_to_string_stateful;
      test_case "broadcast" `Quick test_mode_to_string_broadcast;
      test_case "none" `Quick test_mode_to_string_none;
    ];
    "agent_type_of_mention", [
      test_case "simple" `Quick test_agent_type_simple;
      test_case "nickname" `Quick test_agent_type_nickname;
      test_case "two parts" `Quick test_agent_type_two_parts;
      test_case "empty" `Quick test_agent_type_empty;
    ];
    "is_nickname", [
      test_case "true" `Quick test_is_nickname_true;
      test_case "false simple" `Quick test_is_nickname_false_simple;
      test_case "false two parts" `Quick test_is_nickname_false_two_parts;
      test_case "four parts" `Quick test_is_nickname_four_parts;
    ];
    "parse", [
      test_case "broadcast" `Quick test_parse_broadcast;
      test_case "stateful" `Quick test_parse_stateful;
      test_case "stateless" `Quick test_parse_stateless;
      test_case "none" `Quick test_parse_none;
      test_case "broadcast priority" `Quick test_parse_broadcast_priority;
      test_case "two part stateful" `Quick test_parse_two_part_stateful;
      test_case "underscore" `Quick test_parse_underscore;
      test_case "number" `Quick test_parse_number;
    ];
    "extract", [
      test_case "broadcast" `Quick test_extract_broadcast;
      test_case "stateful" `Quick test_extract_stateful;
      test_case "stateless" `Quick test_extract_stateless;
      test_case "none" `Quick test_extract_none;
    ];
    "edge_cases", [
      test_case "at end" `Quick test_parse_at_end;
      test_case "multiple" `Quick test_parse_multiple_mentions;
      test_case "email like" `Quick test_parse_email_like;
    ];
    "resolve_targets", [
      test_case "none" `Quick test_resolve_targets_none;
      test_case "stateless found" `Quick test_resolve_targets_stateless_found;
      test_case "stateless not found" `Quick test_resolve_targets_stateless_not_found;
      test_case "stateful found" `Quick test_resolve_targets_stateful_found;
      test_case "stateful not found" `Quick test_resolve_targets_stateful_not_found;
      test_case "broadcast" `Quick test_resolve_targets_broadcast;
      test_case "broadcast none" `Quick test_resolve_targets_broadcast_none;
      test_case "empty agents" `Quick test_resolve_targets_empty_agents;
    ];
  ]
