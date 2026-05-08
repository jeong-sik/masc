(** Auto_responder Module Coverage Tests

    Tests for MASC Auto-responder:
    - mode type (Disabled, Spawn, Model)
    - activity_log_file: log file path
    - build_response_prompt: prompt string builder
    - extract_nickname: nickname extraction from response
    - re-exports from Mention
*)

open Alcotest

module Auto_responder = Masc_mcp.Auto_responder

let file_contains_pattern file_rel pattern =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root file_rel in
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let content = In_channel.input_all ic in
        let rec loop idx =
          let remaining = String.length content - idx in
          let plen = String.length pattern in
          remaining >= plen
          && (String.sub content idx plen = pattern || loop (idx + 1))
        in
        if String.length pattern = 0 then true else loop 0)

(* ============================================================
   mode Type Tests
   ============================================================ *)

let test_mode_disabled () =
  let m : Auto_responder.mode = Auto_responder.Disabled in
  check bool "disabled" true (m = Auto_responder.Disabled)

let test_mode_spawn () =
  let m : Auto_responder.mode = Auto_responder.Spawn in
  check bool "spawn" true (m = Auto_responder.Spawn)

let test_mode_model () =
  let m : Auto_responder.mode = Auto_responder.Model in
  check bool "model" true (m = Auto_responder.Model)

(* ============================================================
   activity_log_file Tests
   ============================================================ *)

let test_activity_log_file_nonempty () =
  let path = Auto_responder.activity_log_file () in
  check bool "nonempty" true (String.length path > 0)

let test_activity_log_file_ends_with_log () =
  let path = Auto_responder.activity_log_file () in
  check bool "ends with .log" true
    (String.length path > 4 &&
     String.sub path (String.length path - 4) 4 = ".log")

(* ============================================================
   build_response_prompt Tests
   ============================================================ *)

let test_build_response_prompt_nonempty () =
  let prompt = Auto_responder.build_response_prompt ~from_agent:"alice" ~content:"hello" ~mention:"bob" in
  check bool "nonempty" true (String.length prompt > 0)

let test_build_response_prompt_contains_from () =
  let prompt = Auto_responder.build_response_prompt ~from_agent:"alice" ~content:"test" ~mention:"bob" in
  check bool "contains from" true
    (try
      let _ = Str.search_forward (Str.regexp "alice") prompt 0 in true
    with Not_found -> false)

let test_build_response_prompt_contains_content () =
  let prompt = Auto_responder.build_response_prompt ~from_agent:"alice" ~content:"unique_message_xyz" ~mention:"bob" in
  check bool "contains content" true
    (try
      let _ = Str.search_forward (Str.regexp "unique_message_xyz") prompt 0 in true
    with Not_found -> false)

let test_build_response_prompt_contains_mention () =
  let prompt = Auto_responder.build_response_prompt ~from_agent:"alice" ~content:"test" ~mention:"bob" in
  check bool "contains mention" true
    (try
      let _ = Str.search_forward (Str.regexp "bob") prompt 0 in true
    with Not_found -> false)

let test_build_response_prompt_contains_join () =
  let prompt = Auto_responder.build_response_prompt ~from_agent:"alice" ~content:"test" ~mention:"bob" in
  check bool "contains join" true
    (try
      let _ = Str.search_forward (Str.regexp "masc_join") prompt 0 in true
    with Not_found -> false)

let test_build_response_prompt_contains_broadcast () =
  let prompt = Auto_responder.build_response_prompt ~from_agent:"alice" ~content:"test" ~mention:"bob" in
  check bool "contains broadcast" true
    (try
      let _ = Str.search_forward (Str.regexp "masc_broadcast") prompt 0 in true
    with Not_found -> false)

let test_build_response_prompt_contains_leave () =
  let prompt = Auto_responder.build_response_prompt ~from_agent:"alice" ~content:"test" ~mention:"bob" in
  check bool "contains leave" true
    (try
      let _ = Str.search_forward (Str.regexp "masc_leave") prompt 0 in true
    with Not_found -> false)

(* ============================================================
   extract_nickname Tests
   ============================================================ *)

let test_extract_nickname_returns_option () =
  let response = "Some text\n  Nickname: claude-rare-beaver\nMore text" in
  let nick = Auto_responder.extract_nickname response in
  check (option string) "returns parsed nickname"
    (Some "claude-rare-beaver") nick

let test_extract_nickname_empty () =
  let nick = Auto_responder.extract_nickname "" in
  check (option string) "empty" None nick

let test_extract_nickname_no_match () =
  let response = "No nickname here\nJust some text" in
  let nick = Auto_responder.extract_nickname response in
  check (option string) "no match" None nick

let test_extract_nickname_wrong_format () =
  let response = "Nickname: test" in  (* Missing leading spaces *)
  let nick = Auto_responder.extract_nickname response in
  check (option string) "wrong format still accepted" (Some "test") nick

let test_extract_nickname_multiline () =
  let response = "Line1\nLine2\nLine3" in
  let nick = Auto_responder.extract_nickname response in
  check (option string) "multiline" None nick

(* ============================================================
   Re-exports Tests (from Mention)
   ============================================================ *)

let test_spawnable_agents_nonempty () =
  let agents = Masc_mcp.Provider_adapter.spawnable_canonical_names () in
  check bool "nonempty" true (List.length agents > 0)

let test_spawnable_agents_contains_claude () =
  let agents = Masc_mcp.Provider_adapter.spawnable_canonical_names () in
  check bool "contains claude" true (List.mem "claude" agents)

let test_agent_type_of_mention_claude () =
  let t = Auto_responder.agent_type_of_mention "claude-rare-beaver" in
  check string "claude" "claude" t

let test_agent_type_of_mention_gemini () =
  let t = Auto_responder.agent_type_of_mention "gemini-fast-fox" in
  check string "gemini" "gemini" t

let test_is_spawnable_claude () =
  check bool "claude" true (Auto_responder.is_spawnable "claude")

let test_is_spawnable_unknown () =
  check bool "unknown" false (Auto_responder.is_spawnable "unknown-agent-xyz")

(* ============================================================
   chain_limit and chain_window_sec Tests
   ============================================================ *)

let test_chain_limit_positive () =
  check bool "positive" true (Auto_responder.chain_limit > 0)

let test_chain_window_positive () =
  check bool "positive" true (Auto_responder.chain_window_sec > 0.0)

(* ============================================================
   is_enabled Tests
   ============================================================ *)

let test_is_enabled_type () =
  let enabled = Auto_responder.is_enabled () in
  let _ : bool = enabled in
  ()

(* ============================================================
   get_mode Tests
   ============================================================ *)

let test_get_mode_returns_valid () =
  let mode = Auto_responder.get_mode () in
  check bool "is valid mode" true
    (mode = Auto_responder.Disabled ||
     mode = Auto_responder.Spawn ||
     mode = Auto_responder.Model)

(* ============================================================
   Edge Cases
   ============================================================ *)

let test_build_response_prompt_long_content () =
  let long_content = String.make 1000 'x' in
  let prompt = Auto_responder.build_response_prompt ~from_agent:"a" ~content:long_content ~mention:"b" in
  check bool "handles long content" true (String.length prompt > 1000)

let test_auto_responder_uses_shared_model_runtime () =
  check bool "uses Keeper_turn_driver.run_named" true
    (file_contains_pattern "lib/auto_responder.ml"
       {|Keeper_turn_driver.run_named ~cascade_name|});
  check bool "no direct run_prompt_cascade" false
    (file_contains_pattern "lib/auto_responder.ml" "Llm_orchestration.run_prompt_cascade");
  check bool "legacy Llm_direct dispatch removed"
    false
    (file_contains_pattern "lib/auto_responder.ml" "Llm_direct.dispatch")

(* ============================================================
   Test Runners
   ============================================================ *)

let () =
  run "Auto_responder Coverage" [
    "mode", [
      test_case "disabled" `Quick test_mode_disabled;
      test_case "spawn" `Quick test_mode_spawn;
      test_case "model" `Quick test_mode_model;
    ];
    "activity_log_file", [
      test_case "nonempty" `Quick test_activity_log_file_nonempty;
      test_case "ends with .log" `Quick test_activity_log_file_ends_with_log;
    ];
    "build_response_prompt", [
      test_case "nonempty" `Quick test_build_response_prompt_nonempty;
      test_case "contains from" `Quick test_build_response_prompt_contains_from;
      test_case "contains content" `Quick test_build_response_prompt_contains_content;
      test_case "contains mention" `Quick test_build_response_prompt_contains_mention;
      test_case "contains join" `Quick test_build_response_prompt_contains_join;
      test_case "contains broadcast" `Quick test_build_response_prompt_contains_broadcast;
      test_case "contains leave" `Quick test_build_response_prompt_contains_leave;
    ];
    "extract_nickname", [
      test_case "returns option" `Quick test_extract_nickname_returns_option;
      test_case "empty" `Quick test_extract_nickname_empty;
      test_case "no match" `Quick test_extract_nickname_no_match;
      test_case "wrong format" `Quick test_extract_nickname_wrong_format;
      test_case "multiline" `Quick test_extract_nickname_multiline;
    ];
    "re-exports", [
      test_case "spawnable_agents nonempty" `Quick test_spawnable_agents_nonempty;
      test_case "spawnable_agents contains claude" `Quick test_spawnable_agents_contains_claude;
      test_case "agent_type_of_mention claude" `Quick test_agent_type_of_mention_claude;
      test_case "agent_type_of_mention gemini" `Quick test_agent_type_of_mention_gemini;
      test_case "is_spawnable claude" `Quick test_is_spawnable_claude;
      test_case "is_spawnable unknown" `Quick test_is_spawnable_unknown;
    ];
    "chain_config", [
      test_case "limit positive" `Quick test_chain_limit_positive;
      test_case "window positive" `Quick test_chain_window_positive;
    ];
    "is_enabled", [
      test_case "returns bool" `Quick test_is_enabled_type;
    ];
    "get_mode", [
      test_case "returns valid" `Quick test_get_mode_returns_valid;
    ];
    "edge_cases", [
      test_case "long content" `Quick test_build_response_prompt_long_content;
    ];
    "source", [
      test_case "shared model runtime" `Quick test_auto_responder_uses_shared_model_runtime;
    ];
  ]
