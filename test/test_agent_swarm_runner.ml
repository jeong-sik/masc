(** Tests for Runner module: config parsing, provider resolution.

    All tests are pure (no I/O). parse_args and resolve_provider
    are deterministic functions that can be tested without Eio. *)

open Masc_mcp
open Agent_swarm_runner

let runner_config_testable : runner_config Alcotest.testable =
  Alcotest.testable
    (fun fmt c ->
      Format.fprintf fmt
        "{goal=%S; provider=%S; workdir=%S; max_turns=%d; \
         fleet=%b; members=%d; masc_url=%S; verbose=%b}"
        c.goal c.provider_name c.workdir c.max_turns
        c.fleet_mode c.num_members c.masc_url c.verbose)
    (fun a b ->
      a.goal = b.goal
      && a.provider_name = b.provider_name
      && a.workdir = b.workdir
      && a.max_turns = b.max_turns
      && a.fleet_mode = b.fleet_mode
      && a.num_members = b.num_members
      && a.masc_url = b.masc_url
      && a.verbose = b.verbose)

let result_config =
  Alcotest.result runner_config_testable Alcotest.string

let test_parse_minimal () =
  let argv = [| "fleet_runner"; "--goal"; "fix the bug" |] in
  let expected = { default_config with goal = "fix the bug" } in
  Alcotest.check result_config "minimal parse"
    (Ok expected) (parse_args argv)

let test_parse_full () =
  let argv = [|
    "fleet_runner";
    "--goal"; "deploy v2";
    "--provider"; "sonnet";
    "--workdir"; "/tmp/work";
    "--max-turns"; "5";
    "--fleet";
    "--masc-url"; "http://example.com:9000";
    "--verbose"
  |] in
  let expected = {
    goal = "deploy v2";
    provider_name = "sonnet";
    workdir = "/tmp/work";
    max_turns = 5;
    fleet_mode = true;
    num_members = 3;
    masc_url = "http://example.com:9000";
    verbose = true;
  } in
  Alcotest.check result_config "full parse"
    (Ok expected) (parse_args argv)

let test_parse_missing_goal () =
  let argv = [| "fleet_runner"; "--provider"; "haiku" |] in
  Alcotest.check result_config "missing goal"
    (Error "Missing required --goal argument")
    (parse_args argv)

let test_parse_invalid_max_turns () =
  let argv = [| "fleet_runner"; "--goal"; "x"; "--max-turns"; "abc" |] in
  Alcotest.check result_config "invalid max-turns"
    (Error "Invalid --max-turns: abc")
    (parse_args argv)

let test_parse_members () =
  let argv = [| "fleet_runner"; "--goal"; "test"; "--fleet"; "--members"; "5" |] in
  let expected = { default_config with
    goal = "test";
    fleet_mode = true;
    num_members = 5;
  } in
  Alcotest.check result_config "members parse"
    (Ok expected) (parse_args argv)

let test_parse_members_invalid () =
  let argv = [| "fleet_runner"; "--goal"; "test"; "--members"; "abc" |] in
  Alcotest.check result_config "invalid members"
    (Error "Invalid --members: abc") (parse_args argv)

let test_parse_members_zero () =
  let argv = [| "fleet_runner"; "--goal"; "test"; "--members"; "0" |] in
  Alcotest.check result_config "zero members"
    (Error "Invalid --members: 0") (parse_args argv)

let test_provider_resolve () =
  let known = ["local-qwen"; "local-mlx"; "sonnet"; "haiku"; "opus"; "llama"; "openrouter"] in
  List.iter (fun name ->
    let result = resolve_provider name in
    Alcotest.(check bool) (Printf.sprintf "%s resolves" name)
      true (Option.is_some result)
  ) known

let test_provider_unknown () =
  let result = resolve_provider "nonexistent" in
  Alcotest.(check bool) "unknown returns None"
    true (Option.is_none result)

let () =
  Alcotest.run "runner" [
    "parse_args", [
      Alcotest.test_case "minimal" `Quick test_parse_minimal;
      Alcotest.test_case "full" `Quick test_parse_full;
      Alcotest.test_case "missing goal" `Quick test_parse_missing_goal;
      Alcotest.test_case "invalid max-turns" `Quick test_parse_invalid_max_turns;
      Alcotest.test_case "members" `Quick test_parse_members;
      Alcotest.test_case "invalid members" `Quick test_parse_members_invalid;
      Alcotest.test_case "zero members" `Quick test_parse_members_zero;
    ];
    "resolve_provider", [
      Alcotest.test_case "known providers" `Quick test_provider_resolve;
      Alcotest.test_case "unknown provider" `Quick test_provider_unknown;
    ];
  ]
