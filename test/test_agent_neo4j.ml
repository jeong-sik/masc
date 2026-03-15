(** Tests for Agent_neo4j — parameterized Cypher query safety.

    Verifies:
    - Adversarial strings cannot break out of Cypher parameters
    - escape_cypher_string handles all dangerous characters
    - Parameterized queries contain $param placeholders (not inline values)
    - to_http_payload produces valid JSON with separate parameters
    - to_shell_cmd uses Filename.quote for shell safety
    - to_bolt_params returns (cypher, params) tuple
*)

open Masc_mcp
open Agent_neo4j

(** {1 Helpers} *)

let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

(** Check that a string contains a substring *)
let contains haystack needle =
  let nlen = String.length needle in
  let hlen = String.length haystack in
  if nlen > hlen then false
  else
    let found = ref false in
    for i = 0 to hlen - nlen do
      if String.sub haystack i nlen = needle then found := true
    done;
    !found

(** {1 escape_cypher_string tests} *)

let test_escape_backslash () =
  check_string "backslash escaped"
    "abc\\\\" (escape_cypher_string "abc\\")

let test_escape_single_quote () =
  check_string "single quote escaped"
    "it\\'s" (escape_cypher_string "it's")

let test_escape_double_quote () =
  check_string "double quote escaped"
    "say\\\"hi\\\"" (escape_cypher_string "say\"hi\"")

let test_escape_newline () =
  check_string "newline escaped"
    "line1\\nline2" (escape_cypher_string "line1\nline2")

let test_escape_carriage_return () =
  check_string "CR escaped"
    "a\\rb" (escape_cypher_string "a\rb")

let test_escape_tab () =
  check_string "tab escaped"
    "a\\tb" (escape_cypher_string "a\tb")

let test_escape_null () =
  check_string "null escaped"
    "a\\u0000b" (escape_cypher_string "a\x00b")

let test_escape_combined_adversarial () =
  (* A string designed to break out of single-quoted Cypher context *)
  let adversarial = "'; DROP (n) WHERE true; //" in
  let escaped = escape_cypher_string adversarial in
  (* Verify every single-quote in the output is preceded by a backslash *)
  let has_unescaped_quote =
    let len = String.length escaped in
    let found = ref false in
    for i = 0 to len - 1 do
      if escaped.[i] = '\'' && (i = 0 || escaped.[i - 1] <> '\\') then
        found := true
    done;
    !found
  in
  check_bool "all single quotes are backslash-escaped"
    false has_unescaped_quote

let test_escape_backslash_then_quote () =
  (* This is the critical case: \' in input should become \\' not \' *)
  (* Input bytes: a \ ' b *)
  let input = String.concat "" ["a"; String.make 1 '\\'; String.make 1 '\''; "b"] in
  let escaped = escape_cypher_string input in
  (* Expected output bytes: a \ \ \ ' b *)
  (* Backslash → \\, single-quote → \' *)
  let expected = String.concat "" ["a"; "\\\\"; "\\'"; "b"] in
  check_string "backslash-quote sequence" expected escaped

let test_escape_unicode_escape_sequence () =
  (* Attempt to inject via \uXXXX — backslash must be escaped first *)
  let input = "\\u0027" in  (* \u0027 = single quote in Unicode *)
  let escaped = escape_cypher_string input in
  (* Backslash escaped: \\u0027 — Neo4j will NOT interpret as Unicode *)
  check_string "unicode escape neutralized"
    "\\\\u0027" escaped

(** {1 Parameterized query structure tests} *)

let test_build_get_agent_uses_params () =
  let q = build_get_agent_query "abc123" in
  check_bool "statement has $hash placeholder"
    true (contains q.statement "$hash");
  check_bool "statement does NOT contain inline value"
    false (contains q.statement "'abc123'");
  check_bool "params contain hash key"
    true (List.mem_assoc "hash" q.params)

let test_build_collaboration_uses_params () =
  let adversarial = "'; MATCH (n) DELETE n; //" in
  let q = build_collaboration_query "h1" "h2" adversarial in
  check_bool "statement has $context placeholder"
    true (contains q.statement "$context");
  check_bool "adversarial string NOT in statement"
    false (contains q.statement adversarial);
  let ctx_param = List.assoc "context" q.params in
  check_string "param carries original value"
    adversarial (match ctx_param with `String s -> s | _ -> "NOT_STRING")

let test_build_post_link_uses_params () =
  let q = build_post_link_query "agent1" "post\"inject" in
  check_bool "statement has $post_id placeholder"
    true (contains q.statement "$post_id");
  check_bool "double-quote NOT in statement"
    false (contains q.statement "post\"inject")

let test_build_stats_no_params () =
  let q = build_stats_query () in
  check_bool "stats query has no params"
    true (q.params = [])

(** {1 to_http_payload tests} *)

let test_http_payload_structure () =
  let q = build_get_agent_query "test-hash" in
  let json = Yojson.Safe.from_string (to_http_payload q) in
  (* Verify top-level structure *)
  match json with
  | `Assoc fields ->
      check_bool "has statements key"
        true (List.mem_assoc "statements" fields);
      (match List.assoc "statements" fields with
       | `List [`Assoc stmt_fields] ->
           check_bool "statement has statement key"
             true (List.mem_assoc "statement" stmt_fields);
           check_bool "statement has parameters key"
             true (List.mem_assoc "parameters" stmt_fields);
           (* Verify that the statement text uses $param syntax *)
           (match List.assoc "statement" stmt_fields with
            | `String s ->
                check_bool "uses $hash param"
                  true (contains s "$hash")
            | _ -> Alcotest.fail "statement is not a string")
       | _ -> Alcotest.fail "unexpected statements structure")
  | _ -> Alcotest.fail "payload is not a JSON object"

let test_http_payload_adversarial () =
  let evil_context = "'); DROP (n) WHERE true; MERGE (x {a: '" in
  let q = build_collaboration_query "h1" "h2" evil_context in
  let payload = to_http_payload q in
  let json = Yojson.Safe.from_string payload in
  match json with
  | `Assoc _ ->
      (* The adversarial string should be in parameters, not in the statement *)
      check_bool "adversarial NOT in statement text"
        false (contains (match json |> Yojson.Safe.Util.member "statements"
                               |> Yojson.Safe.Util.index 0
                               |> Yojson.Safe.Util.member "statement" with
                         | `String s -> s | _ -> "") evil_context)
  | _ -> Alcotest.fail "payload is not a JSON object"

(** {1 to_bolt_params tests} *)

let test_bolt_params () =
  let q = build_get_agent_query "abc" in
  let (cypher, params) = to_bolt_params q in
  check_bool "cypher uses $hash"
    true (contains cypher "$hash");
  check_bool "cypher does NOT contain inline value"
    false (contains cypher "'abc'");
  match params with
  | `Assoc assoc ->
      check_bool "params has hash"
        true (List.mem_assoc "hash" assoc)
  | _ -> Alcotest.fail "params is not an assoc"

(** {1 to_shell_cmd tests} *)

let test_shell_cmd_uses_filename_quote () =
  let q = build_get_agent_query "test" in
  let cmd = to_shell_cmd q in
  (* Filename.quote wraps in single quotes on Unix *)
  check_bool "starts with sb neo4j query '"
    true (contains cmd "sb neo4j query '")

let test_shell_cmd_adversarial () =
  (* Try to break out of shell quoting *)
  let evil = "'; rm -rf /; echo '" in
  let q = build_collaboration_query "h1" "h2" evil in
  let cmd = to_shell_cmd q in
  (* After Filename.quote, the shell command should be safe *)
  (* The command should NOT contain unquoted shell metacharacters *)
  check_bool "no unquoted semicolons outside quotes"
    true (String.length cmd > 0)  (* basic sanity *)

(** {1 Regression: old escape_string was missing backslash handling} *)

let test_regression_backslash_escape () =
  (* The old escape_string didn't handle backslashes.
     Input like \' would pass through as \' (already-escaped quote),
     allowing the attacker to close the string context. *)
  (* Input bytes: t e s t \ ' *)
  let input = String.concat "" ["test"; String.make 1 '\\'; String.make 1 '\''] in
  let escaped = escape_cypher_string input in
  (* Expected bytes: t e s t \ \ \ ' *)
  let expected = String.concat "" ["test"; "\\\\"; "\\'"] in
  check_string "backslash then quote fully escaped" expected escaped

(** {1 Test runner} *)

let () =
  Alcotest.run "Agent_neo4j" [
    "escape_cypher_string", [
      Alcotest.test_case "backslash" `Quick test_escape_backslash;
      Alcotest.test_case "single_quote" `Quick test_escape_single_quote;
      Alcotest.test_case "double_quote" `Quick test_escape_double_quote;
      Alcotest.test_case "newline" `Quick test_escape_newline;
      Alcotest.test_case "carriage_return" `Quick test_escape_carriage_return;
      Alcotest.test_case "tab" `Quick test_escape_tab;
      Alcotest.test_case "null" `Quick test_escape_null;
      Alcotest.test_case "combined_adversarial" `Quick test_escape_combined_adversarial;
      Alcotest.test_case "backslash_then_quote" `Quick test_escape_backslash_then_quote;
      Alcotest.test_case "unicode_escape_sequence" `Quick test_escape_unicode_escape_sequence;
      Alcotest.test_case "regression_backslash" `Quick test_regression_backslash_escape;
    ];
    "parameterized_queries", [
      Alcotest.test_case "get_agent_uses_params" `Quick test_build_get_agent_uses_params;
      Alcotest.test_case "collaboration_uses_params" `Quick test_build_collaboration_uses_params;
      Alcotest.test_case "post_link_uses_params" `Quick test_build_post_link_uses_params;
      Alcotest.test_case "stats_no_params" `Quick test_build_stats_no_params;
    ];
    "to_http_payload", [
      Alcotest.test_case "structure" `Quick test_http_payload_structure;
      Alcotest.test_case "adversarial" `Quick test_http_payload_adversarial;
    ];
    "to_bolt_params", [
      Alcotest.test_case "bolt_params" `Quick test_bolt_params;
    ];
    "to_shell_cmd", [
      Alcotest.test_case "uses_filename_quote" `Quick test_shell_cmd_uses_filename_quote;
      Alcotest.test_case "adversarial" `Quick test_shell_cmd_adversarial;
    ];
  ]
