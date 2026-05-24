(** Auto_responder Module Coverage Tests

    Tests for MASC Auto-responder:
    - mode type (Disabled, Model)
    - activity_log_file: log file path
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
   extract_nickname Tests
   ============================================================ *)

let test_extract_nickname_returns_option () =
  let response = "Some text\n  Nickname: agent_llm_a-rare-beaver\nMore text" in
  let nick = Auto_responder.extract_nickname response in
  check (option string) "returns parsed nickname"
    (Some "agent_llm_a-rare-beaver") nick

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

let test_agent_type_of_mention_claude () =
  let t = Auto_responder.agent_type_of_mention "agent_llm_a-rare-beaver" in
  check string "agent_llm_a" "agent_llm_a" t

let test_agent_type_of_mention_gemini () =
  let t = Auto_responder.agent_type_of_mention "provider_f-fast-fox" in
  check string "provider_f" "provider_f" t

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
     mode = Auto_responder.Model)

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
      test_case "model" `Quick test_mode_model;
    ];
    "activity_log_file", [
      test_case "nonempty" `Quick test_activity_log_file_nonempty;
      test_case "ends with .log" `Quick test_activity_log_file_ends_with_log;
    ];
    "extract_nickname", [
      test_case "returns option" `Quick test_extract_nickname_returns_option;
      test_case "empty" `Quick test_extract_nickname_empty;
      test_case "no match" `Quick test_extract_nickname_no_match;
      test_case "wrong format" `Quick test_extract_nickname_wrong_format;
      test_case "multiline" `Quick test_extract_nickname_multiline;
    ];
    "re-exports", [
      test_case "agent_type_of_mention agent_llm_a" `Quick test_agent_type_of_mention_claude;
      test_case "agent_type_of_mention provider_f" `Quick test_agent_type_of_mention_gemini;
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
    "source", [
      test_case "shared model runtime" `Quick test_auto_responder_uses_shared_model_runtime;
    ];
  ]
