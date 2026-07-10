(* test/test_keeper_prompt_token_integrity.ml

   P0-3: verify that [Keeper_prompt_token_integrity] finds keeper_*/masc_*
   tokens in rendered prompts/continuity, resolves known tokens, reports
   unknown tokens, and increments [masc_keeper_prompt_unknown_tool_tokens_total]. *)

module Scanner = Masc.Keeper_prompt_token_integrity
module Metrics = Masc.Otel_metric_store

let metric_name = Keeper_metrics.(to_string PromptUnknownToolTokens)
let stripped_metric_name = Keeper_metrics.(to_string PromptTokenStripped)
let keeper = "test-keeper-p0-3"

let total_unknown () = Metrics.metric_total metric_name
let total_stripped () = Metrics.metric_total stripped_metric_name

let test_known_tokens_are_not_reported () =
  let prompt =
    String.concat " "
      [ "Use keeper_board_post to post, keeper_task_claim to claim,"
      ; "masc_keeper_status to inspect."
      ; "For direct execution, call Execute."
      ]
  in
  let before = total_unknown () in
  let unknowns =
    Scanner.scan_text ~keeper_name:keeper ~source:System_prompt prompt
  in
  Alcotest.(check (list string))
    "known tokens produce no unknowns" [] unknowns;
  Alcotest.(check (float 0.0001))
    "metric unchanged" before (total_unknown ())

let test_unknown_token_reported () =
  let prompt = "Call keeper_p0_3_fictional_tool to proceed." in
  let before = total_unknown () in
  let unknowns =
    Scanner.scan_text ~keeper_name:keeper ~source:User_message prompt
  in
  Alcotest.(check (list string))
    "unknown keeper token is reported"
    [ "keeper_p0_3_fictional_tool" ]
    unknowns;
  Alcotest.(check (float 0.0001))
    "metric +1" (before +. 1.0) (total_unknown ())

let test_all_uppercase_token_is_env_var_not_reported () =
  (* All-uppercase masc_/keeper_ tokens are env-var-shaped (MASC_BASE_PATH,
     KEEPER_FOO), not tool invocations — tool names are lowercase by
     convention. They are skipped rather than flagged, so config prose
     mentioning env vars does not produce false-positive unknown-token WARNs.
     (Mixed-case stale tokens with at least one lowercase letter are still
     normalized and checked — see [test_case_insensitive_resolution].) *)
  let prompt = "Set KEEPER_P0_3_FICTIONAL_ENV before proceeding." in
  let before = total_unknown () in
  let unknowns =
    Scanner.scan_text ~keeper_name:keeper ~source:System_prompt prompt
  in
  Alcotest.(check (list string))
    "all-uppercase env-var-shaped token is not reported" [] unknowns;
  Alcotest.(check (float 0.0001))
    "metric unchanged" before (total_unknown ())

let test_wildcard_reference_is_documentation_not_tool () =
  let prompt =
    "Use WebSearch or WebFetch; do not call internal masc_web_* names or any \
     keeper_* placeholder."
  in
  let before = total_unknown () in
  let unknowns =
    Scanner.scan_text ~keeper_name:keeper ~source:System_prompt prompt
  in
  Alcotest.(check (list string))
    "wildcard references are not concrete tool tokens" [] unknowns;
  Alcotest.(check (float 0.0001))
    "metric unchanged" before (total_unknown ())

let test_unknown_masc_token_reported () =
  let prompt = "Use masc_p0_3_unknown_gadget for diagnostics." in
  let before = total_unknown () in
  let unknowns =
    Scanner.scan_text ~keeper_name:keeper ~source:Continuity prompt
  in
  Alcotest.(check (list string))
    "unknown masc token is reported"
    [ "masc_p0_3_unknown_gadget" ]
    unknowns;
  Alcotest.(check (float 0.0001))
    "metric +1" (before +. 1.0) (total_unknown ())

let test_deduplicates_within_surface () =
  (* The same unknown token repeated three times should emit only one counter
     increment for this surface. *)
  let prompt =
    "keeper_p0_3_dup appears here and keeper_p0_3_dup there and \
     keeper_p0_3_dup everywhere."
  in
  let before = total_unknown () in
  let unknowns =
    Scanner.scan_text ~keeper_name:keeper ~source:System_prompt prompt
  in
  Alcotest.(check (list string))
    "deduplicated to a single token" [ "keeper_p0_3_dup" ] unknowns;
  Alcotest.(check (float 0.0001))
    "metric +1 for the surface" (before +. 1.0) (total_unknown ())

let test_token_boundaries () =
  (* Tokens embedded inside larger words or prefixed with tool-token chars
     should not be matched. *)
  let prompt =
    "mykeeper_foo xkeeper_baz foo-keeper_bar keeper_qux"
  in
  let unknowns =
    Scanner.scan_text ~keeper_name:keeper ~source:User_message prompt
  in
  Alcotest.(check (list string))
    "only standalone keeper_qux is matched"
    [ "keeper_qux" ]
    unknowns

let test_rendered_prompt_scans_all_surfaces () =
  let system_prompt = "Known keeper_board_post is fine." in
  let user_message = "Unknown masc_p0_3_prompt_probe here." in
  let continuity_summary = "Unknown keeper_p0_3_continuity_probe here." in
  let before = total_unknown () in
  let unknowns =
    Scanner.scan_rendered_prompt
      ~keeper_name:keeper
      ~system_prompt
      ~user_message
      ~continuity_summary
  in
  Alcotest.(check (list string))
    "returns both distinct unknown tokens"
    [ "keeper_p0_3_continuity_probe"; "masc_p0_3_prompt_probe" ]
    unknowns;
  Alcotest.(check (float 0.0001))
    "metric +2 across surfaces" (before +. 2.0) (total_unknown ())

let test_case_insensitive_resolution () =
  (* Mixed-case token text should normalize to lowercase before resolution. *)
  let prompt = "Use KEEPER_BOARD_POST and Masc_Keeper_Status." in
  let unknowns =
    Scanner.scan_text ~keeper_name:keeper ~source:System_prompt prompt
  in
  Alcotest.(check (list string))
    "mixed-case known tokens resolve" [] unknowns

let test_unified_system_prompt_has_no_unresolved_tokens () =
  let prompt =
    Masc_test_deps.read_source_file "config/prompts/keeper.unified.system.md"
  in
  let unknowns =
    Scanner.scan_text ~keeper_name:keeper ~source:System_prompt prompt
  in
  Alcotest.(check (list string))
    "unified system prompt has no unresolved keeper/masc tokens"
    [] unknowns

(* ── strip_unresolved_tool_tokens (registry-driven sanitization) ── *)

let test_strip_removes_unresolved_lowercase_token () =
  (* A stale/removed lowercase tool name is replaced with a placeholder so
     the model never sees it as a callable tool and the sentence keeps its
     shape; a resolving tool in the same text is preserved. *)
  let text = "First call masc_p0_3_dead_gadget then keeper_board_post." in
  Alcotest.(check string)
    "dead token replaced, resolved tool kept"
    "First call <stale_tool_token> then keeper_board_post."
    (Scanner.strip_unresolved_tool_tokens text)

let test_strip_keeps_env_var_shaped_token () =
  (* All-uppercase env-var-shaped tokens are not tool invocations; stripping
     them would mangle legitimate configuration prose. *)
  let text = "Set MASC_BASE_PATH=/srv before launch." in
  Alcotest.(check string)
    "env var preserved verbatim" text
    (Scanner.strip_unresolved_tool_tokens text)

let test_strip_keeps_plain_capitalized_words () =
  (* 38-bug campaign #6 regression: the deleted legacy sanitizer
     ([sanitize_retired_tool_names]) removed standalone words like "Grep"
     and "Bash" from prompt prose outright, mangling legitimate sentences.
     The registry-driven pass must leave plain capitalized words untouched
     — they are not masc_/keeper_ tool tokens. *)
  let text = "Use Grep to search the repo, then Bash to run the script." in
  Alcotest.(check string)
    "plain capitalized words preserved verbatim" text
    (Scanner.strip_unresolved_tool_tokens text)

let test_strip_keeps_wildcard_reference () =
  let text = "Do not call internal masc_web_* names or keeper_* placeholders." in
  Alcotest.(check string)
    "wildcard references preserved verbatim" text
    (Scanner.strip_unresolved_tool_tokens text)

let test_strip_is_identity_when_all_resolve () =
  let text = "Use keeper_board_post and masc_keeper_status only." in
  Alcotest.(check string)
    "no change when every token resolves" text
    (Scanner.strip_unresolved_tool_tokens text)

let test_strip_emits_stripped_metric () =
  (* When [~keeper_name] is supplied, each replaced token increments
     [masc_keeper_prompt_token_stripped_total] with the tool dimension so
     the strip action remains observable even though the text was sanitized. *)
  let text = "Run masc_p0_3_dead_gadget and keeper_p0_3_dead_tool now." in
  let before = total_stripped () in
  let _ = Scanner.strip_unresolved_tool_tokens ~keeper_name:keeper text in
  Alcotest.(check (float 0.0001))
    "stripped metric +2 for two distinct dead tools"
    (before +. 2.0)
    (total_stripped ())

let () =
  Alcotest.run "keeper_prompt_token_integrity_p0_3"
    [
      ( "resolution",
        [
          Alcotest.test_case "known tokens not reported" `Quick
            test_known_tokens_are_not_reported;
          Alcotest.test_case "unknown keeper token reported" `Quick
            test_unknown_token_reported;
          Alcotest.test_case "all-uppercase token is env-var, not reported"
            `Quick test_all_uppercase_token_is_env_var_not_reported;
          Alcotest.test_case "wildcard reference is documentation, not tool"
            `Quick test_wildcard_reference_is_documentation_not_tool;
          Alcotest.test_case "unknown masc token reported" `Quick
            test_unknown_masc_token_reported;
          Alcotest.test_case "deduplicates within surface" `Quick
            test_deduplicates_within_surface;
          Alcotest.test_case "token boundaries" `Quick test_token_boundaries;
          Alcotest.test_case "rendered prompt scans all surfaces" `Quick
            test_rendered_prompt_scans_all_surfaces;
          Alcotest.test_case "case insensitive resolution" `Quick
            test_case_insensitive_resolution;
          Alcotest.test_case "unified system prompt has no unresolved tokens"
            `Quick test_unified_system_prompt_has_no_unresolved_tokens;
        ] );
      ( "sanitization",
        [
          Alcotest.test_case "strip replaces unresolved lowercase token" `Quick
            test_strip_removes_unresolved_lowercase_token;
          Alcotest.test_case "strip keeps env-var-shaped token" `Quick
            test_strip_keeps_env_var_shaped_token;
          Alcotest.test_case "strip keeps plain capitalized words (#6)" `Quick
            test_strip_keeps_plain_capitalized_words;
          Alcotest.test_case "strip keeps wildcard reference" `Quick
            test_strip_keeps_wildcard_reference;
          Alcotest.test_case "strip is identity when all resolve" `Quick
            test_strip_is_identity_when_all_resolve;
          Alcotest.test_case "strip emits stripped metric" `Quick
            test_strip_emits_stripped_metric;
        ] );
    ]
