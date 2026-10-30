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
  check string "possessive apostrophe kept" "@alpha's"
    (Board_addressing.trim_token_edges "@alpha's");
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
  (* A bare "@" leaves nothing after the prefix. It used to reach callers as
     an empty candidate that every one of them dropped, and board_audience
     dropped it through Agent_id.of_string — a validator, which logs what it
     refuses. A post with an email or a decorative "@" cost a WARN per
     occurrence for a target that never existed. *)
  check_parse "bare at addresses no one" "none" "@ bare at";
  check_parse "a decorative at among words addresses no one" "none"
    "see @ here and @ there";
  check_parse "trailing punctuation trimmed" "targets:alice" "ok @alice, thanks";
  check_parse "possessive stays distinct" "targets:alpha's" "@alpha's note"

let test_parse_broadcast () =
  check_parse "exact broadcast" "broadcast" "release note @@all";
  check_parse "broadcast selector compare is case-insensitive" "broadcast"
    "release note @@ALL";
  check_parse "unsupported selector" "unsupported:delta" "release note @@delta";
  check_parse "unsupported selectors lowercased" "unsupported:delta"
    "release note @@Delta";
  check_parse "empty broadcast selector fails closed" "unsupported:" "release @@";
  check_parse "mixed all and unsupported fails closed" "unsupported:all,delta"
    "@@all @@delta";
  check_parse "broadcast precedence over direct targets" "broadcast"
    "@@all and @alpha";
  check_parse "unsupported broadcast hides direct targets" "unsupported:delta"
    "@@delta and @alpha"

(* Code spans are not address text. Every one of these strings appeared in a
   live Board comment that was rejected whole: @internals/libs/datadogRum
   is an npm scope, @/lib/constants is a path alias, @@ is an OCaml operator.
   Board validates candidates fail-closed, which is right for a mistyped
   address and wrong for an @ that was never an address. *)
let test_parse_code_spans () =
  check_parse "npm scope in a code span is not a target" "none"
    "see `@internals/libs/datadogRum` for the setup";
  check_parse "path alias in a code span is not a target" "none"
    "the fix renames `@/lib/constents` to `@/lib/constants`";
  check_parse "operator in a code span is not a broadcast selector" "none"
    "use `f @@ x` instead of the parens";
  check_parse "fenced block is not address text" "none"
    "before\n```\n@@all\n@alpha\n```\nafter";
  (* A real address outside the span still parses. *)
  check_parse "target outside a code span still parses" "targets:alpha"
    "@alpha please look at `@/lib/constants`";
  check_parse "broadcast outside a code span still parses" "broadcast"
    "@@all see `@internals/libs/errors`";
  (* Blanking must separate, not delete: a span between two tokens keeps them
     apart instead of splicing them into one. Here the trailing @internals/...
     sits outside the span, so it is still a candidate and still fails closed
     -- the point is that it is a separate candidate rather than glued onto
     alpha. *)
  check_parse "blanked span separates rather than joins"
    "targets:alpha,internals/libs/datadogRum"
    "@alpha`x`@internals/libs/datadogRum";
  (* An unterminated span addresses nobody after it: fail-closed direction. *)
  check_parse "unterminated span swallows the rest" "none"
    "opening `@alpha and never closing"

let check_routing label expected content =
  check (option string) label expected (Board_addressing.routing_target content)

(* The contract of the removed regex extractor, kept for the one-recipient
   consumers, plus the shapes that made it name the wrong recipient. *)
let test_routing_target () =
  check_routing "direct" (Some "ollama") "@ollama status?";
  check_routing "full hyphenated target"
    (Some "canary-feature-20260813-202635")
    "@canary-feature-20260813-202635 please ack";
  check_routing "underscore and digits" (Some "agent_v2") "hello @agent_v2";
  check_routing "first direct mention wins" (Some "ollama")
    "@ollama please ask @canary-feature-20260813-202635";
  check_routing "plain text" None "Hello world";
  check_routing "email is not a mention" None "mail test@example.com";
  check_routing "bare marker" None "@";
  check_routing "embedded marker" None "prefix@agent";
  check_routing "a particle after the name is not part of it" (Some "alpha")
    "@alpha에게 부탁해요";
  check_routing "the author's casing is kept" (Some "MiXeD-Agent")
    "@MiXeD-Agent inspect this"

let test_routing_target_selectors () =
  check_routing "fleet selector" (Some "all") "release note @@all";
  check_routing "fleet selector in any casing" (Some "all") "release note @@ALL";
  check_routing "another selector is the name for the caller to reject"
    (Some "gemini") "notice @@gemini";
  check_routing "selector lowercased" (Some "delta") "release note @@Delta";
  check_routing "selector wins over a direct mention" (Some "gemini")
    "@ollama please notify @@gemini";
  (* The first selector written wins, not the first in sort order. *)
  check_routing "first selector written" (Some "zeta") "@@zeta then @@alpha";
  check_routing "a named selector written before the fleet one wins"
    (Some "gemini") "@@gemini @@all";
  (* The removed extractor took no ['-'] in a selector, so such a token was
     prose to it and the direct target after it was found. *)
  check_routing "a hyphenated selector is prose" None "@@all-agents";
  check_routing "a hyphenated selector does not hide a direct target"
    (Some "alpha") "@@canary-feature-2026 @alpha";
  (* The [@@] that opens a diff hunk header names nobody, and it must hide
     neither a selector nor a direct target written beside it. *)
  check_routing "hunk header names nobody" None
    "moved the hunk '@@ -1435,6 +1435,7 @@' by hand";
  check_routing "an empty selector does not hide a real one" (Some "delta")
    "the hunk '@@ -1,2 +1,2 @@' then @@delta";
  check_routing "a hunk header before a direct target" (Some "alpha")
    "see '@@ -1,3 +1,4 @@' @alpha please look";
  check_routing "a hunk header after a direct target" (Some "alpha")
    "@alpha see '@@ -1 +1 @@'";
  check_routing "a bare selector token beside a direct target" (Some "alpha")
    "@@ @alpha"

(* A dune alias in a code span is not a recipient, and it must not hide the
   recipient written after it. *)
let test_routing_target_code_spans () =
  check_routing "alias in a code span names nobody" None
    "run `dune build @check` first";
  check_routing "alias in a fence names nobody" None
    "```\ndune build @runtest\n```";
  check_routing "a mention after a code span is still found" (Some "alpha")
    "main fails `dune build @check` today\n\n@alpha @beta look";
  (* An opening backtick with no closer addresses nobody after it. That is the
     grammar's fail-closed direction, shared with the Board: a stray backtick
     in prose silences the mentions behind it. *)
  check_routing "a stray backtick silences what follows" None "don`t @alpha";
  check_routing "an unterminated span silences what follows" None
    "the `foo option is gone, ask @alpha";
  check_routing "a mention before the stray backtick still counts"
    (Some "alpha") "@alpha don`t wait"

(* The name reaches code that builds a file name from it, such as a Keeper's
   metadata path, so a path separator or a dot must never pass. A token that is
   not a name is prose and is skipped, as the Board skips it, so it never hides
   a name written beside it. *)
let test_routing_target_names () =
  check_routing "a parent path is not a name" None "@../../etc/passwd please";
  check_routing "an absolute path is not a name" None "@/etc/passwd please";
  check_routing "a path with a separator is not a name" None "see @bin/all now";
  check_routing "a dotted name is not a name" None "ping @team.alpha now";
  check_routing "a scoped Board id is not a Keeper name" None "@keeper:delta please";
  check_routing "a possessive is not a name" None "@alpha's note";
  check_routing "a selector with a separator is not a name" None "see @@bin/all";
  check_routing "an npm scope is prose and does not hide a name" (Some "alpha")
    "see @types/node, cc @alpha";
  check_routing "a path before a name does not hide it" (Some "alpha")
    "@bin/all then @alpha";
  check_routing "a possessive before a name does not hide it" (Some "bob")
    "@alice's @bob";
  check_routing "a mention glued to the word before it is prose" None
    "to:@alpha";
  check_routing "a mention glued to non-ASCII text is prose" None "foo안녕@alpha"

(* The quadratic algorithm [blank_code_regions] replaced. It tried every
   position of a run of backticks on its own. Kept here to pin that the
   linear one blanks exactly the same bytes. *)
let reference_blank_code_regions text =
  let length = String.length text in
  let buffer = Bytes.of_string text in
  let blank_range start stop =
    for index = start to min stop (length - 1) do
      Bytes.set buffer index ' '
    done
  in
  let run_length_at index =
    let rec count offset =
      if index + offset < length && text.[index + offset] = '`' then count (offset + 1)
      else offset
    in
    count 0
  in
  let rec scan index =
    if index >= length then ()
    else if text.[index] = '`' then (
      let opener = run_length_at index in
      let rec find_close cursor =
        if cursor >= length then None
        else if text.[cursor] = '`' && run_length_at cursor = opener then Some cursor
        else find_close (cursor + 1)
      in
      match find_close (index + opener) with
      | Some closer ->
        blank_range index (closer + opener - 1);
        scan (closer + opener)
      | None -> blank_range index (length - 1))
    else scan (index + 1)
  in
  scan 0;
  Bytes.to_string buffer

(* Every text over three characters up to length 10, which holds every
   arrangement of runs of backticks that matter: a run shorter than, equal to
   and longer than the opener, before, between and after other characters. *)
let test_blank_code_regions_matches_reference () =
  let alphabet = [ '`'; 'a'; ' ' ] in
  let checked = ref 0 in
  let rec extend reversed remaining =
    let text = String.of_seq (List.to_seq (List.rev reversed)) in
    let expected = reference_blank_code_regions text in
    let actual = Board_addressing.blank_code_regions text in
    incr checked;
    if not (String.equal expected actual) then
      failf "blank_code_regions differs for %S: reference %S, got %S" text expected
        actual;
    if remaining > 0 then
      List.iter (fun character -> extend (character :: reversed) (remaining - 1)) alphabet
  in
  extend [] 10;
  check bool "every text was compared" true (!checked > 80_000);
  (* A longer run closes a shorter opener with its last backticks. *)
  check string "a longer run closes a shorter opener" "    y"
    (Board_addressing.blank_code_regions "`x``y")

let () =
  run "board_addressing"
    [ ( "tokenization",
        [ test_case "trim_token_edges" `Quick test_trim_token_edges;
          test_case "tokens_of_text" `Quick test_tokens_of_text ] );
      ( "parse",
        [ test_case "targets" `Quick test_parse_targets;
          test_case "broadcast" `Quick test_parse_broadcast;
          test_case "code spans" `Quick test_parse_code_spans ] );
      ( "routing_target",
        [ test_case "direct targets" `Quick test_routing_target;
          test_case "selectors" `Quick test_routing_target_selectors;
          test_case "code spans" `Quick test_routing_target_code_spans;
          test_case "names" `Quick test_routing_target_names ] );
      ( "blank_code_regions",
        [ test_case "matches the quadratic reference" `Quick
            test_blank_code_regions_matches_reference ] ) ]
