(* Issue #25601: regression pins for the shared @-mention addressing
   grammar extracted from the drifted keeper_lane_mentions /
   board_audience clones.

   Pinned here:
   1. Tokenization goldens — edge trimming + whitespace splitting, with
      case PRESERVED (the unification: case normalization is an identity
      concern owned by each caller's id type, not by the grammar).
   2. Address classification — [@@all] (any casing) is the only broadcast;
      other [@@] selectors fail closed as [Unsupported_broadcast];
      broadcast selectors win over direct targets.
   3. Raw target candidates keep the author's casing and are neither
      validated nor deduplicated — that is the identity layer's job
      ([Keeper_id] folds case, [Agent_id] preserves it; both pinned by
      their own boundary tests). *)

open Alcotest

let strings = list string

let test_trim_token_edges () =
  check string "trailing punctuation" "@alice" (Board_addressing.trim_token_edges "@alice,");
  check string "wrapping parens" "@alice" (Board_addressing.trim_token_edges "(@alice)");
  check string "email keeps internal dot" "email@alice.com"
    (Board_addressing.trim_token_edges "email@alice.com");
  check string "possessive apostrophe kept" "@sangsu's"
    (Board_addressing.trim_token_edges "@sangsu's");
  check string "all non-word" "" (Board_addressing.trim_token_edges "...")

let test_tokens_of_text () =
  check strings "whitespace variants split"
    [ "hey"; "@alice"; "look" ]
    (Board_addressing.tokens_of_text "hey\t@alice\nlook");
  check strings "case is preserved"
    [ "PING"; "@ALICE"; "NOW" ]
    (Board_addressing.tokens_of_text "PING @ALICE NOW");
  check strings "empty tokens dropped" [ "@alice" ]
    (Board_addressing.tokens_of_text "   @alice   ")

let raw_address_to_string = function
  | Board_addressing.No_explicit_address -> "none"
  | Board_addressing.Broadcast_all -> "broadcast"
  | Board_addressing.Raw_targets targets ->
    "targets:" ^ String.concat "," targets
  | Board_addressing.Unsupported_broadcast selectors ->
    "unsupported:" ^ String.concat "," selectors

let check_parse label expected content =
  check string label expected (raw_address_to_string (Board_addressing.parse content))

let test_parse_targets () =
  check_parse "unaddressed" "none" "plain Board update";
  check_parse "single target" "targets:alpha" "hey @alpha look";
  check_parse "target case preserved" "targets:MiXeD-Agent"
    "@MiXeD-Agent inspect this";
  check_parse "duplicate casings not deduplicated (identity-level concern)"
    "targets:ALPHA,alpha" "@ALPHA and @alpha";
  check_parse "token order preserved" "targets:beta,alpha" "@beta and @alpha";
  check_parse "email is one token" "none" "send to email@alice.com";
  check_parse "mid-token at is not a target" "none" "mid@alice token";
  check_parse "bare at is the empty candidate" "targets:" "@ bare at";
  check_parse "trailing punctuation trimmed" "targets:alice" "ok @alice, thanks";
  check_parse "possessive stays distinct" "targets:sangsu's" "@sangsu's note"

let test_parse_broadcast () =
  check_parse "exact broadcast" "broadcast" "release note @@all";
  check_parse "broadcast selector compare is case-insensitive" "broadcast"
    "release note @@ALL";
  check_parse "unsupported selector" "unsupported:analyst" "release note @@analyst";
  check_parse "unsupported selectors lowercased" "unsupported:analyst"
    "release note @@Analyst";
  check_parse "empty broadcast selector fails closed" "unsupported:" "release @@";
  check_parse "mixed all and unsupported fails closed" "unsupported:all,analyst"
    "@@all @@analyst";
  check_parse "broadcast precedence over direct targets" "broadcast"
    "@@all and @alpha";
  check_parse "unsupported broadcast hides direct targets" "unsupported:analyst"
    "@@analyst and @alpha"

let () =
  run "board_addressing"
    [ ( "tokenization",
        [ test_case "trim_token_edges" `Quick test_trim_token_edges;
          test_case "tokens_of_text" `Quick test_tokens_of_text ] );
      ( "parse",
        [ test_case "targets" `Quick test_parse_targets;
          test_case "broadcast" `Quick test_parse_broadcast ] ) ]
