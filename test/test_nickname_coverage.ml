(** Nickname Module Coverage Tests

    Tests for MASC Nickname Generator (Docker-style adjective+animal):
    - generate: agent_type-adjective-animal
    - generate_unique: with hex suffix
    - is_generated_nickname: pattern detection
    - extract_agent_type: parse agent type from nickname
*)

open Alcotest

module Nickname = Nickname

(* ============================================================
   generate Tests
   ============================================================ *)

let test_generate_format () =
  let nick = Nickname.generate "claude" in
  let parts = String.split_on_char '-' nick in
  check int "3 parts" 3 (List.length parts);
  check string "starts with agent_type" "claude" (List.hd parts)

let test_generate_different_agent_types () =
  let claude = Nickname.generate "claude" in
  let gemini = Nickname.generate "gemini" in
  check bool "claude starts with claude" true (String.sub claude 0 6 = "claude");
  check bool "gemini starts with gemini" true (String.sub gemini 0 6 = "gemini")

let test_generate_randomness () =
  let nick1 = Nickname.generate "test" in
  let nick2 = Nickname.generate "test" in
  (* It's possible but unlikely they're the same *)
  check bool "nicks generated" true (String.length nick1 > 5 && String.length nick2 > 5)

let test_generate_empty_agent_type () =
  let nick = Nickname.generate "" in
  (* Should still work, starting with - *)
  check bool "starts with dash" true (nick.[0] = '-')

(* ============================================================
   generate_unique Tests
   ============================================================ *)

let test_generate_unique_format () =
  let nick = Nickname.generate_unique "claude" in
  let parts = String.split_on_char '-' nick in
  check int "4 parts" 4 (List.length parts);
  check string "starts with agent_type" "claude" (List.hd parts)

let test_generate_unique_suffix_length () =
  let nick = Nickname.generate_unique "test" in
  let parts = String.split_on_char '-' nick in
  let suffix = List.nth parts 3 in
  check int "suffix is 4 chars" 4 (String.length suffix)

let test_generate_unique_different () =
  let nick1 = Nickname.generate_unique "test" in
  let nick2 = Nickname.generate_unique "test" in
  check bool "unique nicknames" true (nick1 <> nick2)

(* ============================================================
   is_generated_nickname Tests
   ============================================================ *)

let test_is_generated_nickname_valid () =
  let nick = Nickname.generate "claude" in
  check bool "generated is valid" true (Nickname.is_generated_nickname nick)

let test_is_generated_nickname_manual () =
  check bool "three parts valid" true (Nickname.is_generated_nickname "claude-swift-fox");
  check bool "four parts valid" true (Nickname.is_generated_nickname "claude-swift-fox-a3b2")

let test_is_generated_nickname_short () =
  check bool "two parts invalid" false (Nickname.is_generated_nickname "claude-opus");
  check bool "one part invalid" false (Nickname.is_generated_nickname "claude")

let test_is_generated_nickname_empty () =
  check bool "empty invalid" false (Nickname.is_generated_nickname "")

(* The strict variant is what auth code uses. It must accept real generated
   nicknames (dictionary adjective + animal) while rejecting structured
   operator names like [keeper-<id>-agent], which only happen to share the
   3-part shape. Pre-fix the auth path used the loose [is_generated_nickname],
   misclassified those names, sent each keeper subprocess through the
   bearer-token rewrite path, and produced [silent:auth_token_resolve_error]
   storms (~20 events / 5min observed in fleet logs 2026-04-26). *)
let test_is_dictionary_generated_nickname_accepts_real () =
  check bool "claude-swift-fox" true
    (Nickname.is_dictionary_generated_nickname "claude-swift-fox");
  check bool "claude-swift-fox-a3b2" true
    (Nickname.is_dictionary_generated_nickname "claude-swift-fox-a3b2");
  check bool "qa-king-warm-heron multi-part type" true
    (Nickname.is_dictionary_generated_nickname "qa-king-warm-heron");
  check bool "fresh generated" true
    (Nickname.is_dictionary_generated_nickname (Nickname.generate "claude"));
  check bool "fresh unique" true
    (Nickname.is_dictionary_generated_nickname
       (Nickname.generate_unique "claude"))

let test_is_dictionary_generated_nickname_rejects_structured () =
  check bool "keeper-sangsu-agent" false
    (Nickname.is_dictionary_generated_nickname "keeper-sangsu-agent");
  check bool "keeper-issue_king-agent" false
    (Nickname.is_dictionary_generated_nickname "keeper-issue_king-agent");
  check bool "keeper-verifier-agent" false
    (Nickname.is_dictionary_generated_nickname "keeper-verifier-agent");
  check bool "keeper-nick0cave-agent" false
    (Nickname.is_dictionary_generated_nickname "keeper-nick0cave-agent");
  check bool "admin-board-keeper" false
    (Nickname.is_dictionary_generated_nickname "admin-board-keeper");
  check bool "non-list adj/animal" false
    (Nickname.is_dictionary_generated_nickname "claude-foo-bar");
  check bool "two parts" false
    (Nickname.is_dictionary_generated_nickname "claude-opus");
  check bool "empty" false
    (Nickname.is_dictionary_generated_nickname "")

(* ============================================================
   extract_agent_type Tests
   ============================================================ *)

let test_extract_agent_type_generated () =
  let nick = Nickname.generate "claude" in
  match Nickname.extract_agent_type nick with
  | Some at -> check string "extracted claude" "claude" at
  | None -> fail "should extract agent_type"

let test_extract_agent_type_manual () =
  match Nickname.extract_agent_type "gemini-brave-tiger" with
  | Some at -> check string "extracted gemini" "gemini" at
  | None -> fail "should extract agent_type"

let test_extract_agent_type_legacy () =
  match Nickname.extract_agent_type "claude" with
  | Some at -> check string "legacy claude" "claude" at
  | None -> fail "should extract legacy agent_type"

let test_extract_agent_type_empty () =
  (* Note: split_on_char returns [""] for empty string, so this returns Some "" *)
  match Nickname.extract_agent_type "" with
  | Some "" -> ()  (* Empty string returns Some "" *)
  | Some _ -> fail "should return Some empty string"
  | None -> fail "should return Some, not None"

let test_extract_agent_type_unique () =
  let nick = Nickname.generate_unique "codex" in
  match Nickname.extract_agent_type nick with
  | Some at -> check string "extracted codex" "codex" at
  | None -> fail "should extract from unique"

let test_extract_agent_type_hyphenated_manual () =
  match Nickname.extract_agent_type "qa-king-warm-heron" with
  | Some at -> check string "extracted qa-king" "qa-king" at
  | None -> fail "should extract hyphenated stable prefix"

let test_extract_agent_type_hyphenated_unique () =
  let nick = Nickname.generate_unique "qa-king" in
  match Nickname.extract_agent_type nick with
  | Some at -> check string "extracted qa-king from unique" "qa-king" at
  | None -> fail "should extract hyphenated stable prefix from unique"

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Nickname Coverage" [
    "generate", [
      test_case "format" `Quick test_generate_format;
      test_case "different agent types" `Quick test_generate_different_agent_types;
      test_case "randomness" `Quick test_generate_randomness;
      test_case "empty agent type" `Quick test_generate_empty_agent_type;
    ];
    "generate_unique", [
      test_case "format" `Quick test_generate_unique_format;
      test_case "suffix length" `Quick test_generate_unique_suffix_length;
      test_case "different" `Quick test_generate_unique_different;
    ];
    "is_generated_nickname", [
      test_case "valid generated" `Quick test_is_generated_nickname_valid;
      test_case "manual valid" `Quick test_is_generated_nickname_manual;
      test_case "short invalid" `Quick test_is_generated_nickname_short;
      test_case "empty invalid" `Quick test_is_generated_nickname_empty;
    ];
    "is_dictionary_generated_nickname", [
      test_case "accepts real" `Quick
        test_is_dictionary_generated_nickname_accepts_real;
      test_case "rejects structured" `Quick
        test_is_dictionary_generated_nickname_rejects_structured;
    ];
    "extract_agent_type", [
      test_case "generated" `Quick test_extract_agent_type_generated;
      test_case "manual" `Quick test_extract_agent_type_manual;
      test_case "legacy" `Quick test_extract_agent_type_legacy;
      test_case "empty" `Quick test_extract_agent_type_empty;
      test_case "unique" `Quick test_extract_agent_type_unique;
      test_case "hyphenated manual" `Quick test_extract_agent_type_hyphenated_manual;
      test_case "hyphenated unique" `Quick test_extract_agent_type_hyphenated_unique;
    ];
  ]
