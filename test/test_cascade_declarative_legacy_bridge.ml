(** Regression coverage for [Cascade_declarative_legacy_bridge] —
    RFC-0058 Phase 5 catalog discovery bridge. *)

open Alcotest

let tmpfile content =
  let path = Filename.temp_file "cascade-bridge-" ".toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  path

(* Minimal 5-layer declarative TOML covering provider, model, binding,
   alias, tier, tier-group.  Mirrors the production cascade.toml shape
   but trimmed to the two providers needed for the bridge assertions
   (cloud_fast + cloud_thinking). *)
let minimal_toml =
  {|
[providers.claude_code]
display-name = "Claude Code CLI"
protocol = "anthropic-cli"
command = "claude"
is-non-interactive = true
[providers.claude_code.credentials]
type = "env"
key = "ANTHROPIC_API_KEY"
[providers.claude_code.liveness]
class = "cloud_fast"

[providers.codex_cli]
display-name = "OpenAI Codex CLI"
protocol = "openai-http"
command = "codex"
is-non-interactive = true
[providers.codex_cli.credentials]
type = "env"
key = "OPENAI_API_KEY"
[providers.codex_cli.liveness]
class = "cloud_fast"

[models.sonnet]
api-name = "claude-sonnet-4-5"
tools-support = true
max-context = 200000
[models.haiku]
api-name = "claude-haiku-4-5"
tools-support = true
max-context = 200000
[models.codex-spark]
api-name = "gpt-5-codex"
tools-support = true
max-context = 256000

[claude_code.sonnet]
max-concurrent = 4
[claude_code.haiku]
max-concurrent = 6
[codex_cli.codex-spark]
max-concurrent = 8

[claude_code.haiku.for-tool-rerank]
temperature = 0.0

[tier.big_three]
members = ["codex_cli.codex-spark", "claude_code.sonnet"]
strategy = "failover"

[tier.tool_rerank]
members = ["claude_code.haiku.for-tool-rerank"]
strategy = "failover"

[tier-group.big_three]
tiers = ["big_three"]
strategy = "failover"
fallback = false

[tier-group.tool_rerank]
tiers = ["tool_rerank"]
strategy = "failover"
fallback = false

[routes.keeper_turn]
target = "tier-group.big_three"
[routes.tool_rerank_use]
target = "tier-group.tool_rerank"
|}

let with_cascade body =
  let path = tmpfile minimal_toml in
  Fun.protect ~finally:(fun () -> try Sys.remove path with _ -> ()) (fun () -> body path)

let test_declarative_profile_names_surfaces_tier_and_tier_group () =
  with_cascade @@ fun config_path ->
  let names =
    Masc_mcp.Cascade_declarative_legacy_bridge.declarative_profile_names
      ~config_path
  in
  check bool "discovers tier.big_three" true
    (List.mem "tier.big_three" names);
  check bool "discovers tier-group.big_three" true
    (List.mem "tier-group.big_three" names);
  check bool "discovers tier-group.tool_rerank" true
    (List.mem "tier-group.tool_rerank" names)

let test_declarative_profile_names_returns_empty_when_unparseable () =
  let path = tmpfile "this is not valid TOML at all !!!" in
  Fun.protect ~finally:(fun () -> try Sys.remove path with _ -> ())
  @@ fun () ->
  let names =
    Masc_mcp.Cascade_declarative_legacy_bridge.declarative_profile_names
      ~config_path:path
  in
  check (list string) "empty list on parse failure" [] names

let test_weighted_entries_for_tier_returns_model_strings () =
  with_cascade @@ fun config_path ->
  let entries =
    Masc_mcp.Cascade_declarative_legacy_bridge.weighted_entries_for_profile
      ~config_path ~name:"tier.big_three"
  in
  match entries with
  | None -> Alcotest.fail "expected Some entries for tier.big_three"
  | Some es ->
    let models = List.map (fun (e : Masc_mcp.Cascade_weighted_entry.t) -> e.model) es in
    (* Bridge emits cascade_prefix:api_name per RFC-0058 §2.4 *)
    check bool "tier.big_three contains codex_cli model" true
      (List.exists (fun m -> String.equal m "codex_cli:gpt-5-codex") models);
    check bool "tier.big_three contains claude_code sonnet" true
      (List.exists (fun m -> String.equal m "claude_code:claude-sonnet-4-5") models);
    check int "tier.big_three has exactly 2 entries" 2 (List.length es)

let test_weighted_entries_for_tier_group_expands_member_tiers () =
  with_cascade @@ fun config_path ->
  let entries =
    Masc_mcp.Cascade_declarative_legacy_bridge.weighted_entries_for_profile
      ~config_path ~name:"tier-group.big_three"
  in
  match entries with
  | None -> Alcotest.fail "expected Some entries for tier-group.big_three"
  | Some es ->
    let models = List.map (fun (e : Masc_mcp.Cascade_weighted_entry.t) -> e.model) es in
    check bool "tier-group.big_three contains codex_cli model" true
      (List.exists (fun m -> String.equal m "codex_cli:gpt-5-codex") models);
    check bool "tier-group.big_three contains claude_code sonnet" true
      (List.exists (fun m -> String.equal m "claude_code:claude-sonnet-4-5") models)

let test_weighted_entries_for_unknown_returns_none () =
  with_cascade @@ fun config_path ->
  let entries =
    Masc_mcp.Cascade_declarative_legacy_bridge.weighted_entries_for_profile
      ~config_path ~name:"tier.does_not_exist"
  in
  check bool "None for unknown profile" true (Option.is_none entries)

let test_alias_member_resolves_to_underlying_binding () =
  with_cascade @@ fun config_path ->
  let entries =
    Masc_mcp.Cascade_declarative_legacy_bridge.weighted_entries_for_profile
      ~config_path ~name:"tier.tool_rerank"
  in
  match entries with
  | None -> Alcotest.fail "expected Some entries for tier.tool_rerank"
  | Some es ->
    let models = List.map (fun (e : Masc_mcp.Cascade_weighted_entry.t) -> e.model) es in
    (* Alias [claude_code.haiku.for-tool-rerank] resolves to the underlying
       binding [claude_code.haiku] — alias overrides don't change the
       model_string, only runtime params. *)
    check (list string) "alias collapses to underlying model_string"
      [ "claude_code:claude-haiku-4-5" ] models

let () =
  Alcotest.run "Cascade_declarative_legacy_bridge"
    [
      ( "discovery",
        [
          test_case "declarative_profile_names surfaces tier and tier-group"
            `Quick test_declarative_profile_names_surfaces_tier_and_tier_group;
          test_case "declarative_profile_names empty on unparseable" `Quick
            test_declarative_profile_names_returns_empty_when_unparseable;
        ] );
      ( "resolution",
        [
          test_case "weighted_entries_for tier emits model strings" `Quick
            test_weighted_entries_for_tier_returns_model_strings;
          test_case "weighted_entries_for tier-group expands member tiers"
            `Quick test_weighted_entries_for_tier_group_expands_member_tiers;
          test_case "weighted_entries_for unknown returns None" `Quick
            test_weighted_entries_for_unknown_returns_none;
          test_case "alias member resolves to underlying binding" `Quick
            test_alias_member_resolves_to_underlying_binding;
        ] );
    ]
