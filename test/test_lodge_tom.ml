open Masc_mcp

(* ==== parse_tom_response tests ============================================ *)

let test_parse_clean_json () =
  let json_str =
    {|{"reaction":"upvote","confidence":0.85,"reasoning":"high interest in topic"}|}
  in
  match Lodge_tom.parse_tom_response json_str with
  | Ok (reaction, confidence, reasoning) ->
      Alcotest.(check string) "reaction" "upvote"
        (Lodge_reaction.reaction_type_to_string reaction);
      Alcotest.(check bool) "confidence > 0.8" true (confidence > 0.8);
      Alcotest.(check bool) "reasoning non-empty" true
        (String.length reasoning > 0)
  | Error e -> Alcotest.fail (Printf.sprintf "parse failed: %s" e)

let test_parse_embedded_json () =
  let response =
    {|Based on the agent's profile, here is my prediction:
{"reaction":"comment_intent","confidence":0.7,"reasoning":"moderate interest, wants to discuss"}
Hope this helps!|}
  in
  match Lodge_tom.parse_tom_response response with
  | Ok (reaction, confidence, _reasoning) ->
      Alcotest.(check string) "reaction" "comment_intent"
        (Lodge_reaction.reaction_type_to_string reaction);
      Alcotest.(check bool) "confidence in range" true
        (confidence >= 0.6 && confidence <= 0.8)
  | Error e -> Alcotest.fail (Printf.sprintf "parse failed: %s" e)

let test_parse_skip_reaction () =
  let json_str =
    {|{"reaction":"skip","confidence":0.9,"reasoning":"no relevant topics"}|}
  in
  match Lodge_tom.parse_tom_response json_str with
  | Ok (reaction, confidence, _) ->
      Alcotest.(check string) "reaction" "skip"
        (Lodge_reaction.reaction_type_to_string reaction);
      Alcotest.(check bool) "high confidence" true (confidence >= 0.85)
  | Error e -> Alcotest.fail (Printf.sprintf "parse failed: %s" e)

let test_parse_pass_reaction () =
  let json_str =
    {|{"reaction":"pass","confidence":0.5,"reasoning":"neutral"}|}
  in
  match Lodge_tom.parse_tom_response json_str with
  | Ok (reaction, _, _) ->
      Alcotest.(check string) "reaction" "pass"
        (Lodge_reaction.reaction_type_to_string reaction)
  | Error e -> Alcotest.fail (Printf.sprintf "parse failed: %s" e)

let test_parse_confidence_clamped () =
  let json_str =
    {|{"reaction":"upvote","confidence":1.5,"reasoning":"very sure"}|}
  in
  match Lodge_tom.parse_tom_response json_str with
  | Ok (_, confidence, _) ->
      Alcotest.(check bool) "confidence clamped to 1.0" true
        (confidence <= 1.0)
  | Error e -> Alcotest.fail (Printf.sprintf "parse failed: %s" e)

let test_parse_missing_reasoning () =
  let json_str =
    {|{"reaction":"upvote","confidence":0.8}|}
  in
  match Lodge_tom.parse_tom_response json_str with
  | Ok (reaction, _, reasoning) ->
      Alcotest.(check string) "reaction" "upvote"
        (Lodge_reaction.reaction_type_to_string reaction);
      Alcotest.(check bool) "default reasoning" true
        (String.length reasoning > 0)
  | Error e -> Alcotest.fail (Printf.sprintf "parse failed: %s" e)

let test_parse_invalid_reaction () =
  let json_str =
    {|{"reaction":"unknown_action","confidence":0.5,"reasoning":"test"}|}
  in
  match Lodge_tom.parse_tom_response json_str with
  | Error _ -> () (* expected: unknown reaction type *)
  | Ok _ -> Alcotest.fail "should have failed on unknown reaction type"

let test_parse_invalid_input () =
  match Lodge_tom.parse_tom_response "not json at all" with
  | Error _ -> () (* expected *)
  | Ok _ -> Alcotest.fail "should have failed on invalid input"

(* ==== format_agent_profile tests ========================================== *)

let test_format_profile_basic () =
  let sig_ : Lodge_reaction.agent_signature = {
    agent_name = "dreamer";
    reaction_patterns = [("ocaml", 0.9); ("ai", 0.7); ("rust", 0.3)];
    upvote_ratio = 0.6;
    comment_tendency = 0.25;
    recent_reactions = [];
    generated_self_summary = None;
    total_reactions = 10;
    last_updated = 0.0;
  } in
  let profile = Lodge_tom.format_agent_profile sig_ in
  Alcotest.(check bool) "contains upvote ratio" true
    (let lowered = String.lowercase_ascii profile in
     try ignore (Str.search_forward (Str.regexp_string "upvote ratio") lowered 0); true
     with Not_found -> false);
  Alcotest.(check bool) "contains ocaml" true
    (try ignore (Str.search_forward (Str.regexp_string "ocaml") profile 0); true
     with Not_found -> false)

let test_format_profile_with_summary () =
  let sig_ : Lodge_reaction.agent_signature = {
    agent_name = "philosopher";
    reaction_patterns = [];
    upvote_ratio = 0.4;
    comment_tendency = 0.5;
    recent_reactions = [];
    generated_self_summary = Some "I ponder deeply about abstractions.";
    total_reactions = 20;
    last_updated = 0.0;
  } in
  let profile = Lodge_tom.format_agent_profile sig_ in
  Alcotest.(check bool) "contains self-description" true
    (try ignore (Str.search_forward (Str.regexp_string "Self-description") profile 0); true
     with Not_found -> false)

(* ==== Test runner ========================================================= *)

let () =
  Alcotest.run "lodge_tom"
    [
      ( "parse_tom_response",
        [
          Alcotest.test_case "clean json" `Quick test_parse_clean_json;
          Alcotest.test_case "embedded json" `Quick test_parse_embedded_json;
          Alcotest.test_case "skip reaction" `Quick test_parse_skip_reaction;
          Alcotest.test_case "pass reaction" `Quick test_parse_pass_reaction;
          Alcotest.test_case "confidence clamped" `Quick test_parse_confidence_clamped;
          Alcotest.test_case "missing reasoning" `Quick test_parse_missing_reasoning;
          Alcotest.test_case "invalid reaction" `Quick test_parse_invalid_reaction;
          Alcotest.test_case "invalid input" `Quick test_parse_invalid_input;
        ] );
      ( "format_agent_profile",
        [
          Alcotest.test_case "basic profile" `Quick test_format_profile_basic;
          Alcotest.test_case "with summary" `Quick test_format_profile_with_summary;
        ] );
    ]
