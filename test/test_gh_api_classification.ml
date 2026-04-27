(** test_gh_api_classification — Phase A F5 token-aware [gh api]
    classifier.

    Pre-fix [is_gh_api_read_only] used [String.is_prefix cmd_lower
    ~prefix:"api"] which silently classified [api2 ...] (a hypothetical
    sibling subcommand) as a gh-api call and [graphqlx ...] as the
    graphql subcommand.  This test pins the post-fix behaviour:
    classification dispatches on tokenised structure, not literal
    prefix slices. *)

open Masc_mcp

let r = Alcotest.(check bool)

let test_basic_read_only () =
  r "api repos/foo/bar = read-only" true
    (Keeper_tool_registry.is_gh_api_read_only "api repos/foo/bar");
  r "api user = read-only" true
    (Keeper_tool_registry.is_gh_api_read_only "api user");
  r "api repos/o/r/issues = read-only" true
    (Keeper_tool_registry.is_gh_api_read_only "api repos/o/r/issues")

let test_graphql_is_mutating () =
  (* graphql is always POST, even without flags *)
  r "api graphql = mutating" false
    (Keeper_tool_registry.is_gh_api_read_only "api graphql");
  r "api graphql -f query=... = mutating" false
    (Keeper_tool_registry.is_gh_api_read_only "api graphql -f query=foo")

let test_graphqlx_is_not_graphql () =
  (* Pre-F5 [String.is_prefix "graphql"] ate this; post-F5 token match
     treats it as an unknown path, so the api-classifier still runs and
     it ends up read-only because no method/field flags are present. *)
  r "api graphqlx/foo = read-only (NOT graphql subcommand)" true
    (Keeper_tool_registry.is_gh_api_read_only "api graphqlx/foo")

let test_method_flag_makes_mutating () =
  r "api -X POST repos/o/r = mutating" false
    (Keeper_tool_registry.is_gh_api_read_only "api -x post repos/o/r");
  r "api -X=delete = mutating" false
    (Keeper_tool_registry.is_gh_api_read_only "api -x=delete repos/o/r");
  r "api --method=patch = mutating" false
    (Keeper_tool_registry.is_gh_api_read_only "api --method=patch repos/o/r");
  r "api -X GET = read-only (explicit GET)" true
    (Keeper_tool_registry.is_gh_api_read_only "api -x get repos/o/r")

let test_field_flag_makes_mutating () =
  r "api -f field=value = mutating" false
    (Keeper_tool_registry.is_gh_api_read_only "api -f title=foo repos/o/r/issues");
  r "api --field key=v = mutating" false
    (Keeper_tool_registry.is_gh_api_read_only "api --field x=1 repos/o/r")

let test_non_api_is_not_classified () =
  r "pr list is not gh api" false
    (Keeper_tool_registry.is_gh_api_read_only "pr list");
  r "issue view is not gh api" false
    (Keeper_tool_registry.is_gh_api_read_only "issue view 123");
  (* Pre-F5 [String.is_prefix "api"] would treat this as an api call;
     post-F5 token match correctly rejects it. *)
  r "api2 (hypothetical) is not gh api" false
    (Keeper_tool_registry.is_gh_api_read_only "api2 foo")

let test_strip_keeper_prefix_basic () =
  Alcotest.(check (option string)) "extracts suffix" (Some "vincent")
    (Keeper_identity.strip_keeper_prefix "keeper-vincent");
  Alcotest.(check (option string)) "extracts hyphenated suffix"
    (Some "analyst-001")
    (Keeper_identity.strip_keeper_prefix "keeper-analyst-001")

let test_strip_keeper_prefix_rejects () =
  Alcotest.(check (option string)) "no prefix → None" None
    (Keeper_identity.strip_keeper_prefix "vincent");
  Alcotest.(check (option string)) "exact prefix only → None (empty suffix)"
    None
    (Keeper_identity.strip_keeper_prefix "keeper-");
  Alcotest.(check (option string)) "empty input → None" None
    (Keeper_identity.strip_keeper_prefix "");
  Alcotest.(check (option string)) "wrong case → None (case-sensitive)" None
    (Keeper_identity.strip_keeper_prefix "Keeper-vincent")

let () =
  Alcotest.run "gh_api_classification"
    [
      ( "is_gh_api_read_only",
        [
          Alcotest.test_case "basic read-only paths" `Quick
            test_basic_read_only;
          Alcotest.test_case "graphql is mutating" `Quick
            test_graphql_is_mutating;
          Alcotest.test_case "graphqlx token is NOT graphql" `Quick
            test_graphqlx_is_not_graphql;
          Alcotest.test_case "method flag → mutating" `Quick
            test_method_flag_makes_mutating;
          Alcotest.test_case "field flag → mutating" `Quick
            test_field_flag_makes_mutating;
          Alcotest.test_case "non-api command → false" `Quick
            test_non_api_is_not_classified;
        ] );
      ( "strip_keeper_prefix",
        [
          Alcotest.test_case "extracts suffix" `Quick
            test_strip_keeper_prefix_basic;
          Alcotest.test_case "rejects non-matches" `Quick
            test_strip_keeper_prefix_rejects;
        ] );
    ]
