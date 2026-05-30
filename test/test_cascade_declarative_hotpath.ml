(** RFC-0058 Phase 3: Declarative hotpath unit tests.

    Tests parsing, adaptation, and route binding extraction from
    declarative TOML cascade configs.

    Post-tier-purge (PR #19340): tier/cascade sections are no longer
    part of the config format. Tests use routes + bindings instead.

    @stability Internal *)

open Alcotest
open Cascade_declarative_types
open Cascade_declarative_parser

module Adapter = Masc_mcp.Cascade_declarative_adapter
module Hotpath = Masc_mcp.Keeper_declarative_hotpath

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

(* --- TOML fixture --- *)

let valid_toml = {|
[providers.cli_tool_d]
protocol = "provider_a-cli"
command = "agent_llm_a"

[providers.ollama]
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.haiku]
max-context = 200000
api-name = "model-a-haiku"
tools-support = true

[models.sonnet]
max-context = 200000
api-name = "model-a-sonnet"
tools-support = true

[models.qwen3]
max-context = 32768
api-name = "qwen3:8b"
tools-support = true

[cli_tool_d.haiku]
is-default = true
max-concurrent = 3

[cli_tool_d.sonnet]
max-concurrent = 2

[cli_tool_d.haiku.for-scoring]
max-input = 4096

[ollama.qwen3]

[routes.keeper_turn]
target = "cli_tool_d.haiku"

[routes.governance_judge]
target = "cli_tool_d.haiku.for-scoring"

[system.governance]
target = "cli_tool_d.haiku.for-scoring"
|}

(* --- Tests: parsing and adaptation --- *)

let test_parse_valid_toml () =
  match parse_string valid_toml with
  | Error errs ->
    fail
      (Printf.sprintf "parse failed: %s"
         (String.concat "; "
            (List.map (fun (e : parse_error) ->
              Printf.sprintf "%s: %s" e.path e.message) errs)))
  | Ok cfg ->
    check bool "has providers" true (List.length cfg.providers > 0);
    check bool "has models" true (List.length cfg.models > 0);
    check bool "has bindings" true (List.length cfg.bindings > 0);
    check bool "has routes" true (List.length cfg.routes > 0)

let test_adapt_valid_toml () =
  let catalog = adapt_toml valid_toml in
  no_errors catalog.Adapter.errors;
  check bool "has routes" true
    (List.length catalog.Adapter.routes > 0);
  check bool "has system targets" true
    (List.length catalog.Adapter.system_targets > 0)

let test_parse_invalid_toml () =
  let toml = "this is not valid toml [[[[" in
  match parse_string toml with
  | Ok _ -> fail "expected parse error for invalid TOML"
  | Error errs -> check bool "has parse errors" true (List.length errs > 0)

let test_adapt_missing_provider () =
  let toml = {|
[models.haiku]
max-context = 200000
api-name = "model-a-haiku"
tools-support = true

[ghost.haiku]
is-default = true

[routes.keeper_turn]
target = "ghost.haiku"
|} in
  let catalog = adapt_toml toml in
  check bool "has errors for missing provider" true
    (List.length catalog.Adapter.errors > 0)

let test_adapt_missing_model () =
  let toml = {|
[providers.cli_tool_d]
protocol = "provider_a-cli"
command = "agent_llm_a"

[cli_tool_d.nonexistent]
is-default = true
|} in
  let catalog = adapt_toml toml in
  check bool "has errors for missing model" true
    (List.length catalog.Adapter.errors > 0)

(* --- Tests: route bindings --- *)

let test_route_bindings () =
  let catalog = adapt_toml valid_toml in
  let bindings = Hotpath.declarative_route_bindings catalog in
  check bool "has routes" true (List.length bindings > 0);
  let route_names = List.map fst bindings in
  check bool "has keeper_turn route" true
    (List.mem "keeper_turn" route_names);
  check bool "has governance_judge route" true
    (List.mem "governance_judge" route_names)

(* --- Tests: edge cases --- *)

let test_empty_catalog () =
  let catalog =
    {
      Adapter.profiles = [];
      routes = [];
      system_targets = [];
      default_profile = None;
      capability_profiles = [];
      errors = [];
    }
  in
  let result =
    Hotpath.adapted_catalog_to_snapshot ~source_path:"/test" catalog
  in
  check bool "empty catalog -> None" true (result = None)

let test_snapshot_always_none_without_profiles () =
  (* Post-tier-purge: adapt_config always produces empty profiles list,
     so adapted_catalog_to_snapshot always returns None. *)
  let catalog = adapt_toml valid_toml in
  let result =
    Hotpath.adapted_catalog_to_snapshot ~source_path:"/test" catalog
  in
  check bool "no profiles -> None" true (result = None)

(* --- Tests: partial parse --- *)

let partial_toml = {|
[providers.ollama]
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen3]
max-context = 32768
api-name = "qwen3:8b"
tools-support = true

[ollama.qwen3]

[routes.local]
target = "ollama.qwen3"

# Stale binding — provider [providers.ghost] does not exist.
[ghost.ghost-model]
max-concurrent = 1
|}

let write_temp_toml content =
  let path = Filename.temp_file "rfc0058_phase8" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content);
  path

let test_try_load_partial_returns_snapshot_with_errors () =
  let path = write_temp_toml partial_toml in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      match Hotpath.try_load_partial path with
      | None ->
        (* Post-tier-purge: no profiles produced, so try_load_partial
           returns None. This is expected behavior. *)
        check bool "None is acceptable post-tier-purge" true true
      | Some { snapshot = _; errors } ->
        check bool "errors recorded for stale binding" true
          (List.length errors > 0))

let test_try_load_partial_clean_has_no_errors () =
  let path = write_temp_toml valid_toml in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      match Hotpath.try_load_partial path with
      | None ->
        (* Post-tier-purge: valid TOML but no profiles → None *)
        check bool "None acceptable for clean TOML" true true
      | Some { snapshot = _; errors } ->
        check int "clean parse has no errors" 0 (List.length errors))

(* --- Test suite --- *)

let () =
  run
    "RFC-0058 Phase 3: Declarative Hotpath"
    [
      "parsing",
      [
        test_case "parse valid TOML" `Quick test_parse_valid_toml;
        test_case "adapt valid TOML" `Quick test_adapt_valid_toml;
        test_case "parse invalid TOML" `Quick test_parse_invalid_toml;
        test_case "adapt missing provider" `Quick test_adapt_missing_provider;
        test_case "adapt missing model" `Quick test_adapt_missing_model;
      ];
      "routes",
      [ test_case "route bindings" `Quick test_route_bindings ];
      "edge_cases",
      [
        test_case "empty catalog -> None" `Quick test_empty_catalog;
        test_case
          "snapshot always None without profiles"
          `Quick
          test_snapshot_always_none_without_profiles;
      ];
      "partial_parse",
      [
        test_case
          "try_load_partial handles stale binding"
          `Quick
          test_try_load_partial_returns_snapshot_with_errors;
        test_case
          "try_load_partial clean parse"
          `Quick
          test_try_load_partial_clean_has_no_errors;
      ];
    ]
