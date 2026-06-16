(* test/test_keeper_prompt_token_integrity.ml

   P0-3: verify that [Keeper_prompt_token_integrity] finds keeper_*/masc_*
   tokens in rendered prompts/continuity, resolves known tokens, reports
   unknown tokens, and increments [masc_keeper_prompt_unknown_tool_tokens_total]. *)

module Scanner = Masc.Keeper_prompt_token_integrity
module Metrics = Masc.Otel_metric_store

let metric_name = Keeper_metrics.(to_string PromptUnknownToolTokens)
let keeper = "test-keeper-p0-3"

let total_unknown () = Metrics.metric_total metric_name

let test_known_tokens_are_not_reported () =
  let prompt =
    String.concat " "
      [ "Use keeper_board_post to post, keeper_task_claim to claim,"
      ; "masc_keeper_status to inspect, and extend_turns when needed."
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

let test_unknown_capitalized_token_reported () =
  (* Prefix matching must be case-insensitive so capitalized stale tokens are
     caught, not silently missed. *)
  let prompt = "Call KEEPER_P0_3_FICTIONAL_TOOL to proceed." in
  let before = total_unknown () in
  let unknowns =
    Scanner.scan_text ~keeper_name:keeper ~source:System_prompt prompt
  in
  Alcotest.(check (list string))
    "capitalized unknown keeper token is reported"
    [ "keeper_p0_3_fictional_tool" ]
    unknowns;
  Alcotest.(check (float 0.0001))
    "metric +1" (before +. 1.0) (total_unknown ())

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

let () =
  Alcotest.run "keeper_prompt_token_integrity_p0_3"
    [
      ( "resolution",
        [
          Alcotest.test_case "known tokens not reported" `Quick
            test_known_tokens_are_not_reported;
          Alcotest.test_case "unknown keeper token reported" `Quick
            test_unknown_token_reported;
          Alcotest.test_case "unknown capitalized keeper token reported" `Quick
            test_unknown_capitalized_token_reported;
          Alcotest.test_case "unknown masc token reported" `Quick
            test_unknown_masc_token_reported;
          Alcotest.test_case "deduplicates within surface" `Quick
            test_deduplicates_within_surface;
          Alcotest.test_case "token boundaries" `Quick test_token_boundaries;
          Alcotest.test_case "rendered prompt scans all surfaces" `Quick
            test_rendered_prompt_scans_all_surfaces;
          Alcotest.test_case "case insensitive resolution" `Quick
            test_case_insensitive_resolution;
        ] );
    ]
