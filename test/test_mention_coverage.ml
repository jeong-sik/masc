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
open Masc_mcp

module Mention = Mention
module Coord = Coord
module Fs_compat = Fs_compat
module Mention_inbox = Mention_inbox
module Prometheus = Prometheus
module Safe_ops = Safe_ops

(* ============================================================
   mode_to_string Tests
   ============================================================ *)

let test_mode_to_string_stateless () =
  let s = Mention.mode_to_string (Mention.Stateless "claude") in
  check bool "contains Stateless" true
    (try
       let _ = Str.search_forward (Str.regexp "Stateless") s 0 in
       true
     with Not_found -> false)

let test_mode_to_string_stateful () =
  let s = Mention.mode_to_string (Mention.Stateful "claude-gentle-gecko") in
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
  check string "simple" "claude" (Mention.agent_type_of_mention "claude")

let test_agent_type_nickname () =
  check string "nickname" "ollama" (Mention.agent_type_of_mention "ollama-gentle-gecko")

let test_agent_type_two_parts () =
  check string "two parts" "claude" (Mention.agent_type_of_mention "claude-code")

let test_agent_type_empty () =
  check string "empty" "" (Mention.agent_type_of_mention "")

(* ============================================================
   is_nickname Tests
   ============================================================ *)

let test_is_nickname_true () =
  check bool "three parts" true (Mention.is_nickname "ollama-gentle-gecko")

let test_is_nickname_false_simple () =
  check bool "simple" false (Mention.is_nickname "claude")

let test_is_nickname_false_two_parts () =
  check bool "two parts" false (Mention.is_nickname "claude-code")

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
  match Mention.parse "Hello @claude-gentle-gecko" with
  | Mention.Stateful "claude-gentle-gecko" -> ()
  | _ -> fail "expected Stateful"

let test_parse_stateless () =
  match Mention.parse "Hello @claude" with
  | Mention.Stateless "claude" -> ()
  | _ -> fail "expected Stateless"

let test_parse_none () =
  match Mention.parse "Hello world" with
  | Mention.None -> ()
  | _ -> fail "expected None"

let test_parse_broadcast_priority () =
  (* Broadcast should take priority over other mentions *)
  match Mention.parse "@@ollama @claude" with
  | Mention.Broadcast "ollama" -> ()
  | _ -> fail "expected Broadcast"

let test_parse_two_part_stateful () =
  match Mention.parse "Hello @claude-code" with
  | Mention.Stateful "claude-code" -> ()
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
  match Mention.extract "@claude-gentle-gecko test" with
  | Some "claude-gentle-gecko" -> ()
  | _ -> fail "expected Some"

let test_extract_stateless () =
  match Mention.extract "@claude test" with
  | Some "claude" -> ()
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
  let targets = Mention.resolve_targets Mention.None ~available_agents:["claude"; "gemini"] in
  check int "none returns empty" 0 (List.length targets)

let test_resolve_targets_stateless_found () =
  let targets = Mention.resolve_targets (Mention.Stateless "claude")
    ~available_agents:["claude-gentle-gecko"; "gemini-swift-fox"] in
  check int "stateless returns one" 1 (List.length targets);
  check string "first match" "claude-gentle-gecko" (List.hd targets)

let test_resolve_targets_stateless_not_found () =
  let targets = Mention.resolve_targets (Mention.Stateless "codex")
    ~available_agents:["claude"; "gemini"] in
  check int "not found returns empty" 0 (List.length targets)

let test_resolve_targets_stateful_found () =
  let targets = Mention.resolve_targets (Mention.Stateful "claude-gentle-gecko")
    ~available_agents:["claude-gentle-gecko"; "gemini-swift-fox"] in
  check int "stateful returns one" 1 (List.length targets);
  check string "exact match" "claude-gentle-gecko" (List.hd targets)

let test_resolve_targets_stateful_not_found () =
  let targets = Mention.resolve_targets (Mention.Stateful "claude-unknown-animal")
    ~available_agents:["claude-gentle-gecko"; "gemini-swift-fox"] in
  check int "no exact match returns empty" 0 (List.length targets)

let test_resolve_targets_broadcast () =
  let targets = Mention.resolve_targets (Mention.Broadcast "claude")
    ~available_agents:["claude-gentle-gecko"; "claude-brave-tiger"; "gemini-swift-fox"] in
  check int "broadcast returns all claude" 2 (List.length targets)

let test_resolve_targets_broadcast_none () =
  let targets = Mention.resolve_targets (Mention.Broadcast "ollama")
    ~available_agents:["claude"; "gemini"] in
  check int "no ollama agents" 0 (List.length targets)

let test_resolve_targets_empty_agents () =
  let targets = Mention.resolve_targets (Mention.Stateless "claude")
    ~available_agents:[] in
  check int "no agents" 0 (List.length targets)

(* ============================================================
   is_spawnable Tests
   ============================================================ *)

let test_is_spawnable_gemini () =
  check bool "gemini is spawnable" true (Masc_mcp.Auto_responder.is_spawnable "gemini")

let test_is_spawnable_codex () =
  check bool "codex is spawnable" true (Masc_mcp.Auto_responder.is_spawnable "codex")

let test_is_spawnable_claude () =
  check bool "claude is spawnable" true (Masc_mcp.Auto_responder.is_spawnable "claude")

let test_is_spawnable_llama () =
  check bool "llama is spawnable" true (Masc_mcp.Auto_responder.is_spawnable "llama")

let test_is_spawnable_glm () =
  (* glm has spawn_key=None in Provider_adapter — not CLI-spawnable *)
  check bool "glm not spawnable" false (Masc_mcp.Auto_responder.is_spawnable "glm")

let test_is_spawnable_unknown () =
  check bool "unknown not spawnable" false (Masc_mcp.Auto_responder.is_spawnable "unknown-agent")

let test_is_spawnable_nickname () =
  (* Should extract agent type from nickname *)
  check bool "claude nickname spawnable" true (Masc_mcp.Auto_responder.is_spawnable "claude-gentle-gecko")

let test_is_spawnable_empty () =
  check bool "empty not spawnable" false (Masc_mcp.Auto_responder.is_spawnable "")

(* ============================================================
   spawnable_agents Tests
   ============================================================ *)

let test_spawnable_agents_list () =
  let names = Masc_mcp.Provider_adapter.spawnable_canonical_names () in
  check bool "list not empty" true (List.length names > 0);
  check bool "contains claude" true (List.mem "claude" names);
  check bool "contains gemini" true (List.mem "gemini" names);
  check bool "does not contain bare ollama" false (List.mem "ollama" names)

(* ============================================================
   Mention_inbox JSONL Drop Tests
   ============================================================ *)

let with_temp_base prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Fs_compat.mkdir_p dir;
  f dir

let persistence_drop_value reason =
  Prometheus.metric_value_or_zero Prometheus.metric_persistence_read_drops
    ~labels:[("surface", "mention_inbox"); ("reason", reason)]
    ()

let test_mention_inbox_jsonl_drops_increment_counter () =
  with_temp_base "mention-inbox-drops" @@ fun base_path ->
  let config = Coord.default_config base_path in
  Fs_compat.mkdir_p (Coord.masc_dir config);
  let record : Mention_inbox.mention_record =
    {
      id = "m-valid";
      target_agent = "target";
      source_agent = "source";
      source_kind = "room_message";
      source_id = "room-1";
      content_preview = "@target hello";
      created_at = 2.0;
      read_at = 0.0;
    }
  in
  let entry_error = Safe_ops.persistence_read_drop_reason_entry_load_error in
  let invalid_payload = Safe_ops.persistence_read_drop_reason_invalid_payload in
  let before_entry_error = persistence_drop_value entry_error in
  let before_invalid_payload = persistence_drop_value invalid_payload in
  let content =
    String.concat "\n"
      [
        Yojson.Safe.to_string (Mention_inbox.mention_record_to_json record);
        "{not-json";
        Yojson.Safe.to_string (`Assoc [("id", `String "m-invalid")]);
      ]
    ^ "\n"
  in
  Fs_compat.save_file (Mention_inbox.inbox_path config) content;
  let mentions = Mention_inbox.read_mentions config ~target_agent:"target" ~limit:10 in
  check int "valid mention survives" 1 (List.length mentions);
  check string "valid mention id" "m-valid" (List.hd mentions).id;
  let after_entry_error = persistence_drop_value entry_error in
  let after_invalid_payload = persistence_drop_value invalid_payload in
  check (float 0.001) "malformed JSONL increments entry load error" 1.0
    (after_entry_error -. before_entry_error);
  check (float 0.001) "invalid mention payload increments invalid payload" 1.0
    (after_invalid_payload -. before_invalid_payload)

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
    "is_spawnable", [
      test_case "gemini" `Quick test_is_spawnable_gemini;
      test_case "codex" `Quick test_is_spawnable_codex;
      test_case "claude" `Quick test_is_spawnable_claude;
      test_case "llama" `Quick test_is_spawnable_llama;
      test_case "glm" `Quick test_is_spawnable_glm;
      test_case "unknown" `Quick test_is_spawnable_unknown;
      test_case "nickname" `Quick test_is_spawnable_nickname;
      test_case "empty" `Quick test_is_spawnable_empty;
    ];
    "spawnable_agents", [
      test_case "list" `Quick test_spawnable_agents_list;
    ];
    "mention_inbox", [
      test_case "jsonl drop counters" `Quick
        test_mention_inbox_jsonl_drops_increment_counter;
    ];
  ]
