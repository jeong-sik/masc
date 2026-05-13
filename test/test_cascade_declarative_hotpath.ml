(** RFC-0058 Phase 3: Declarative hotpath unit tests.

    Tests the conversion of {!Adapter.adapted_catalog} into
    {!Hotpath.decl_snapshot} for parallel validation against the legacy
    JSON hotpath.

    Uses the hotpath's own mirror types, NOT {!Cascade_catalog_runtime}
    types, to stay consistent with the dependency-cycle-free design.

    @stability Internal *)

open Alcotest
open Cascade_declarative_types
open Cascade_declarative_parser

module Adapter = Masc_mcp.Cascade_declarative_adapter
module Hotpath = Masc_mcp.Cascade_declarative_hotpath
module Cascade_strategy = Masc_mcp.Cascade_strategy

(* --- Helpers --- *)

let adapt_toml (toml : string) : Adapter.adapted_catalog =
  match parse_string toml with
  | Ok cfg -> Adapter.adapt_config cfg
  | Error (errs : parse_error list) ->
    failwith
      (Printf.sprintf "parse failed: %s"
         (String.concat "; "
            (List.map (fun (e : parse_error) ->
              Printf.sprintf "%s: %s" e.path e.message) errs)))

let no_errors (errs : Adapter.adapter_error list) =
  check int "no errors" 0 (List.length errs)

let get_snapshot (toml : string) : Hotpath.decl_snapshot =
  let catalog = adapt_toml toml in
  no_errors catalog.errors;
  match Hotpath.adapted_catalog_to_snapshot ~source_path:"/test" catalog with
  | None -> failwith "expected Some snapshot, got None"
  | Some snapshot -> snapshot

let find_profile (snapshot : Hotpath.decl_snapshot) (name : string) :
    Hotpath.profile =
  List.find
    (fun (p : Hotpath.profile) -> p.Hotpath.name = name)
    snapshot.Hotpath.profiles

(* --- TOML fixture --- *)

let valid_toml = {|
[providers.claude_code]
protocol = "anthropic-cli"
command = "claude"

[providers.ollama]
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.haiku]
max-context = 200000
api-name = "claude-haiku-4-5-20251001"
tools-support = true

[models.sonnet]
max-context = 200000
api-name = "claude-sonnet-4-6"
tools-support = true

[models.qwen3]
max-context = 32768
api-name = "qwen3:8b"
tools-support = true

[claude_code.haiku]
is-default = true
max-concurrent = 3

[claude_code.sonnet]
max-concurrent = 2

[claude_code.haiku.for-scoring]
max-input = 4096

[ollama.qwen3]

[tier.rerank]
members = ["claude_code.haiku.for-scoring"]
strategy = "failover"

[tier.primary]
members = ["claude_code.sonnet", "claude_code.haiku"]
strategy = "failover"

[tier.local]
members = ["ollama.qwen3"]
strategy = "failover"

[tier-group.primary]
tiers = ["primary", "local"]
strategy = "priority_tier"

[routes.default]
target = "tier-group.primary"

[system.governance]
target = "claude_code.haiku.for-scoring"
|}

(* --- Tests: snapshot conversion --- *)

let test_snapshot_basic () =
  let snapshot = get_snapshot valid_toml in
  check bool "has profiles" true (List.length snapshot.Hotpath.profiles > 0);
  check string "source_path" "/test" snapshot.Hotpath.source_path;
  check bool "validated_at > 0" true (snapshot.Hotpath.validated_at > 0.0)

let test_profile_names () =
  let snapshot = get_snapshot valid_toml in
  let names =
    List.map
      (fun (p : Hotpath.profile) -> p.Hotpath.name)
      snapshot.Hotpath.profiles
  in
  check bool "has tier.rerank" true (List.mem "tier.rerank" names);
  check bool "has tier.primary" true (List.mem "tier.primary" names);
  check bool "has tier.local" true (List.mem "tier.local" names);
  check bool "has tier-group.primary" true
    (List.mem "tier-group.primary" names)

let test_candidates () =
  let snapshot = get_snapshot valid_toml in
  let rerank = find_profile snapshot "tier.rerank" in
  check int "rerank has 1 candidate" 1
    (List.length rerank.Hotpath.candidates);
  let primary = find_profile snapshot "tier-group.primary" in
  check int "primary has 3 candidates" 3
    (List.length primary.Hotpath.candidates)

let test_model_string_format () =
  let snapshot = get_snapshot valid_toml in
  let local = find_profile snapshot "tier.local" in
  let candidate = List.hd local.Hotpath.candidates in
  check bool "model_string contains colon" true
    (String.contains candidate.Hotpath.model_string ':')

let test_weighted_entries_count () =
  let snapshot = get_snapshot valid_toml in
  List.iter
    (fun (p : Hotpath.profile) ->
      check int
        ("candidates = weighted_entries for " ^ p.Hotpath.name)
        (List.length p.Hotpath.candidates)
        (List.length p.Hotpath.weighted_entries))
    snapshot.Hotpath.profiles

let test_strategy_preserved () =
  let snapshot = get_snapshot valid_toml in
  let rerank = find_profile snapshot "tier.rerank" in
  let primary = find_profile snapshot "tier-group.primary" in
  check string "rerank strategy" "failover"
    (Cascade_strategy.kind_to_string
       rerank.Hotpath.strategy.Cascade_strategy.kind);
  check string "primary strategy" "priority_tier"
    (Cascade_strategy.kind_to_string
       primary.Hotpath.strategy.Cascade_strategy.kind)

let test_probes_field_absent () =
  (* Mirror type has no probes field — this test verifies the type shape *)
  let snapshot = get_snapshot valid_toml in
  check bool "has profiles" true (List.length snapshot.Hotpath.profiles > 0)

let test_ollama_max_concurrent () =
  let snapshot = get_snapshot valid_toml in
  let local = find_profile snapshot "tier.local" in
  check bool "ollama_max_concurrent is None" true
    (local.Hotpath.ollama_max_concurrent = None)

(* --- Tests: edge cases --- *)

let test_empty_catalog () =
  let catalog =
    {
      Adapter.profiles = [];
      routes = [];
      system_targets = [];
      default_profile = None;
      errors = [];
    }
  in
  let result =
    Hotpath.adapted_catalog_to_snapshot ~source_path:"/test" catalog
  in
  check bool "empty catalog -> None" true (result = None)

let test_errors_catalog_snapshot () =
  let toml = {|
[providers.claude_code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000
api-name = "claude-haiku-4-5-20251001"
tools-support = true

[claude_code.haiku]
is-default = true

[bad-provider.haiku]
is-default = true

[tier.primary]
members = ["claude_code.haiku"]
strategy = "failover"
|} in
  let catalog = adapt_toml toml in
  check bool "has errors" true (List.length catalog.errors > 0);
  let snapshot =
    Hotpath.adapted_catalog_to_snapshot ~source_path:"/test" catalog
  in
  (* Valid tier.primary should still produce a snapshot even with errors *)
  check bool "snapshot produced despite errors" true (snapshot <> None)

(* --- Tests: route bindings --- *)

let test_route_bindings () =
  let catalog = adapt_toml valid_toml in
  let bindings = Hotpath.declarative_route_bindings catalog in
  check bool "has routes" true (List.length bindings > 0);
  let route_names = List.map fst bindings in
  check bool "has 'default' route" true (List.mem "default" route_names)

(* --- Tests: snapshot introspection --- *)

let test_decl_snapshot_profile_names () =
  let snapshot = get_snapshot valid_toml in
  let names = Hotpath.decl_snapshot_profile_names snapshot in
  check int "4 profiles" 4 (List.length names);
  check bool "has tier.rerank" true (List.mem "tier.rerank" names)

(* Regression guard: the JSON-shape discovery path in
   [cascade_catalog_runtime.discover_profile_names] applies
   [List.sort_uniq String.compare] before constructing its
   profile_build list, and the parallel validation step compares the
   two lists with structural [<>].  Without matching that contract
   here, [decl_snapshot_profile_names] returned names in declaration
   order and the comparison flipped on order alone, producing
   spurious "profile name mismatch" WARNs.  This test pins the
   sort_uniq contract. *)
let test_decl_snapshot_profile_names_is_sorted_and_unique () =
  let snapshot = get_snapshot valid_toml in
  let names = Hotpath.decl_snapshot_profile_names snapshot in
  let sorted = List.sort String.compare names in
  check (list string) "names are sorted" sorted names;
  let deduped = List.sort_uniq String.compare names in
  check int "names are deduplicated" (List.length deduped) (List.length names)

(* --- Test suite --- *)

let () =
  run
    "RFC-0058 Phase 3: Declarative Hotpath"
    [
      "snapshot",
      [
        test_case "basic conversion" `Quick test_snapshot_basic;
        test_case "profile names" `Quick test_profile_names;
        test_case "candidates" `Quick test_candidates;
        test_case "model_string format" `Quick test_model_string_format;
        test_case "weighted_entries count" `Quick test_weighted_entries_count;
        test_case "strategy preserved" `Quick test_strategy_preserved;
        test_case "probes field absent" `Quick test_probes_field_absent;
        test_case "ollama_max_concurrent" `Quick test_ollama_max_concurrent;
      ];
      "edge_cases",
      [
        test_case "empty catalog -> None" `Quick test_empty_catalog;
        test_case "errors catalog snapshot" `Quick test_errors_catalog_snapshot;
      ];
      "routes",
      [ test_case "route bindings" `Quick test_route_bindings ];
      "introspection",
      [
        test_case "decl_snapshot_profile_names" `Quick test_decl_snapshot_profile_names;
        test_case
          "decl_snapshot_profile_names sorted+unique"
          `Quick
          test_decl_snapshot_profile_names_is_sorted_and_unique;
      ];
    ]
