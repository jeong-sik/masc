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

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

(* OCaml's stdlib Unix module does not expose [unsetenv] portably (see e.g.
   test_keeper_toml.ml). The masc_test_deps library carries a C stub that
   calls the libc [unsetenv], so we use that here to keep Sys.getenv_opt
   checks distinguishable between "previously unset" and "set but empty". *)
external test_unsetenv : string -> unit = "masc_test_unsetenv"

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> test_unsetenv name)
    f

let with_temp_cascade_config toml f =
  let root = Filename.temp_file "cascade-hotpath-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let config_dir = Filename.concat root "config" in
  Unix.mkdir config_dir 0o700;
  write_file (Filename.concat config_dir "cascade.toml") toml;
  let cleanup () =
    Config_dir_resolver.reset ();
    Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ();
    (try Sys.remove (Filename.concat config_dir "cascade.toml") with _ -> ());
    (try Unix.rmdir config_dir with _ -> ());
    (try Unix.rmdir root with _ -> ())
  in
  Config_dir_resolver.reset ();
  Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ();
  Fun.protect
    ~finally:cleanup
    (fun () -> with_env "MASC_CONFIG_DIR" config_dir f)

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

[tier.rerank]
members = ["cli_tool_d.haiku.for-scoring"]
strategy = "failover"

[tier.primary]
members = ["cli_tool_d.sonnet", "cli_tool_d.haiku"]
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
target = "cli_tool_d.haiku.for-scoring"
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

let test_failover_inference_max_tokens_uses_narrowest_candidate () =
  let toml =
    {|
[providers.cli_tool_d]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.wide]
max-context = 200000
api-name = "wide"
tools-support = true

[models.narrow]
max-context = 32768
api-name = "narrow"
tools-support = true

[cli_tool_d.wide.tool]
max-output = 64000
temperature = 0.2

[cli_tool_d.narrow.recovery]
max-output = 8192
temperature = 0.2

[tier.mixed]
members = ["cli_tool_d.wide.tool", "cli_tool_d.narrow.recovery"]
strategy = "failover"
|}
  in
  let snapshot = get_snapshot toml in
  let mixed = find_profile snapshot "tier.mixed" in
  check (option int) "profile max_tokens follows narrowest failover candidate"
    (Some 8192)
    mixed.Hotpath.inference_params.max_tokens;
  match mixed.Hotpath.candidates with
  | wide :: narrow :: _ ->
    check (option int) "wide candidate keeps own cap" (Some 64000)
      wide.Hotpath.provider_cfg.Llm_provider.Provider_config.max_tokens;
    check (option int) "narrow candidate keeps own cap" (Some 8192)
      narrow.Hotpath.provider_cfg.Llm_provider.Provider_config.max_tokens
  | candidates ->
    fail
      (Printf.sprintf
         "expected at least two candidates, got %d"
         (List.length candidates))

let test_tier_group_inference_max_tokens_uses_model_capability () =
  let toml =
    {|
[providers.runpod_mtp]
protocol = "provider_d-http"
endpoint = "https://example.test/v1"

[providers.provider_k-coding]
protocol = "provider_d-http"
endpoint = "https://provider_k.example.test/v1"

[models.qwen36-mtp]
max-context = 160000
api-name = "provider_h"
tools-support = true

[models.qwen36-mtp.capabilities]
max-output-tokens = 8192
supports-tool-choice = true

[models.provider_k-turbo]
max-context = 128000
api-name = "provider_k-5-turbo"
tools-support = true

[models.provider_k-turbo.capabilities]
max-output-tokens = 16384
supports-tool-choice = true

[runpod_mtp.qwen36-mtp]
is-default = true

[runpod_mtp.qwen36-mtp.keeper]
temperature = 0.3

[provider_k-coding.provider_k-turbo]
is-default = true

[provider_k-coding.provider_k-turbo.keeper]
max-output = 16384
temperature = 0.3

[tier.strict_tool_candidates]
members = ["runpod_mtp.qwen36-mtp.keeper", "provider_k-coding.provider_k-turbo.keeper"]
strategy = "failover"

[tier-group.strict_tool_candidates]
tiers = ["strict_tool_candidates"]
strategy = "failover"
|}
  in
  let snapshot = get_snapshot toml in
  let strict = find_profile snapshot "tier-group.strict_tool_candidates" in
  check
    (option int)
    "tier-group max_tokens follows narrowest model capability"
    (Some 8192)
    strict.Hotpath.inference_params.max_tokens;
  match strict.Hotpath.candidates with
  | provider_h :: provider_k :: _ ->
    check
      (option int)
      "provider_h candidate inherits model output cap"
      (Some 8192)
      provider_h.Hotpath.provider_cfg.Llm_provider.Provider_config.max_tokens;
    check
      (option int)
      "provider_k candidate keeps alias cap"
      (Some 16384)
      provider_k.Hotpath.provider_cfg.Llm_provider.Provider_config.max_tokens
  | candidates ->
    fail
      (Printf.sprintf
         "expected at least two candidates, got %d"
         (List.length candidates))

let test_model_string_format () =
  let snapshot = get_snapshot valid_toml in
  let local = find_profile snapshot "tier.local" in
  let candidate = List.hd local.Hotpath.candidates in
  check bool "model_string contains colon" true
    (String.contains candidate.Hotpath.model_string ':')

let test_provider_d_http_model_string_uses_custom_label () =
  let toml =
    {|
[providers.glm-coding]
protocol = "provider_d-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[models.glm-5-turbo]
max-context = 128000
api-name = "glm-5-turbo"
tools-support = true

[glm-coding.glm-5-turbo]

[tier.glm]
members = ["glm-coding.glm-5-turbo"]
strategy = "failover"
|}
  in
  let snapshot = get_snapshot toml in
  let profile = find_profile snapshot "tier.glm" in
  match profile.Hotpath.candidates, profile.Hotpath.weighted_entries with
  | [ candidate ], [ entry ] ->
    let expected =
      "custom:glm-5-turbo@https://api.z.ai/api/coding/paas/v4"
    in
    check string "candidate model label" expected
      candidate.Hotpath.model_string;
    check string "weighted entry model label" expected entry.model;
    check bool "pre-dispatch api-key gate accepts custom label" true
      (Result.is_ok
         (Masc_mcp.Cascade_runtime.ensure_api_keys_for_labels [ entry.model ]))
  | candidates, entries ->
    fail
      (Printf.sprintf
         "expected one candidate and one weighted entry, got %d/%d"
         (List.length candidates)
         (List.length entries))

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

let test_tier_group_priority_cycles_cover_all_tiers () =
  let snapshot = get_snapshot valid_toml in
  let primary = find_profile snapshot "tier-group.primary" in
  check int "priority tier max_cycles spans tier count"
    2 primary.Hotpath.strategy.Cascade_strategy.cycle.max_cycles

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
      capability_profiles = [];
      errors = [];
    }
  in
  let result =
    Hotpath.adapted_catalog_to_snapshot ~source_path:"/test" catalog
  in
  check bool "empty catalog -> None" true (result = None)

let test_errors_catalog_snapshot () =
  let toml = {|
[providers.cli_tool_d]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000
api-name = "model-a-haiku"
tools-support = true

[cli_tool_d.haiku]
is-default = true

[bad-provider.haiku]
is-default = true

[tier.primary]
members = ["cli_tool_d.haiku"]
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

let test_runtime_resolution_uses_direct_declarative_provider_config () =
  let toml =
    {|
[providers.ollama_cloud]
protocol = "ollama-http"
endpoint = "https://ollama.com"

[providers.ollama_cloud.credentials]
type = "env"
key = "OLLAMA_CLOUD_API_KEY"

[models.ollama-cloud-default]
api-name = "provider_k-5.1"
max-context = 128000
tools-support = true
streaming = true

[models.ollama-cloud-default.capabilities]
supports-tool-choice = true
supports-native-streaming = true

[ollama_cloud.ollama-cloud-default]
max-concurrent = 1

[tier.ollama_cloud_primary]
members = ["ollama_cloud.ollama-cloud-default"]
strategy = "failover"

[tier-group.provider_k-coding-with-spark]
tiers = ["ollama_cloud_primary"]
strategy = "failover"
fallback = false

[routes.keeper_turn]
target = "tier-group.provider_k-coding-with-spark"
|}
  in
  with_env "OLLAMA_CLOUD_API_KEY" "test-token" @@ fun () ->
  with_temp_cascade_config toml @@ fun () ->
  match
    Masc_mcp.Cascade_catalog_runtime.resolve_named_providers_strict
      ~require_tool_choice_support:true
      ~require_tool_support:true
      ~cascade_name:"tier-group.provider_k-coding-with-spark"
      ()
  with
  | Error err -> fail err
  | Ok [ cfg ] ->
    check string "provider kind" "ollama"
      (Llm_provider.Provider_config.string_of_provider_kind cfg.kind);
    check string "cloud base url preserved" "https://ollama.com" cfg.base_url;
    check string "native request path preserved" "/api/chat" cfg.request_path;
    check string "resolved credential preserved" "test-token" cfg.api_key;
    check
      (option bool)
      "tool-choice override preserved"
      (Some true)
      cfg.supports_tool_choice_override;
    check bool "required tool gate accepts direct cfg" true
      (Masc_mcp.Provider_tool_support.supports_required_tool_use
         ~require_tool_choice_support:true
         ~require_tool_support:true
         cfg)
  | Ok cfgs ->
    fail
      (Printf.sprintf
         "expected one provider config, got %d"
         (List.length cfgs))

let test_runtime_resolution_preserves_tier_id () =
  let toml =
    {|
[providers.ollama_cloud]
protocol = "ollama-http"
endpoint = "https://ollama.com"

[providers.ollama_cloud.credentials]
type = "env"
key = "OLLAMA_CLOUD_API_KEY"

[models.ollama-cloud-default]
api-name = "provider_k-5.1"
max-context = 128000
tools-support = true
streaming = true

[ollama_cloud.ollama-cloud-default]

[tier.ollama_cloud_primary]
members = ["ollama_cloud.ollama-cloud-default"]
strategy = "failover"

[tier-group.provider_k-coding-with-spark]
tiers = ["ollama_cloud_primary"]
strategy = "failover"
fallback = false
|}
  in
  with_env "OLLAMA_CLOUD_API_KEY" "test-token" @@ fun () ->
  with_temp_cascade_config toml @@ fun () ->
  match
    Masc_mcp.Cascade_catalog_runtime.resolve_named_providers_strict_with_secondary_resolver
      ~cascade_name:"tier-group.provider_k-coding-with-spark"
      ()
  with
  | Error err -> fail err
  | Ok { tiered_providers = [ tiered ]; _ } ->
    check string "tier id" "tier-group.provider_k-coding-with-spark" tiered.tier_id
  | Ok resolution ->
    fail
      (Printf.sprintf
         "expected one tiered provider, got %d"
         (List.length resolution.tiered_providers))

let test_runtime_resolution_splits_multi_tier_group_admission_ids () =
  let toml =
    {|
[providers.runpod_mtp]
protocol = "provider_d-http"
endpoint = "https://runpod.example.test/v1"

[providers.ollama_cloud]
protocol = "ollama-http"
endpoint = "https://ollama.com"

[providers.ollama_cloud.credentials]
type = "env"
key = "OLLAMA_CLOUD_API_KEY"

[models.qwen36-mtp]
api-name = "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
max-context = 160000
tools-support = true
streaming = true

[models.qwen36-mtp.capabilities]
supports-tool-choice = true
supports-native-streaming = true

[models.provider_c-cloud]
api-name = "model-c"
max-context = 128000
tools-support = true
streaming = true

[models.provider_c-cloud.capabilities]
supports-tool-choice = true
supports-native-streaming = true

[runpod_mtp.qwen36-mtp]

[ollama_cloud.provider_c-cloud]

[tier.runpod_primary]
members = ["runpod_mtp.qwen36-mtp"]
strategy = "failover"

[tier.ollama_cloud_stable]
members = ["ollama_cloud.provider_c-cloud"]
strategy = "failover"

[tier-group.strict_tool_candidates]
tiers = ["runpod_primary", "ollama_cloud_stable"]
strategy = "failover"
fallback = false
|}
  in
  with_env "OLLAMA_CLOUD_API_KEY" "test-token" @@ fun () ->
  with_temp_cascade_config toml @@ fun () ->
  match
    Masc_mcp.Cascade_catalog_runtime.resolve_named_providers_strict_with_secondary_resolver
      ~cascade_name:"tier-group.strict_tool_candidates"
      ()
  with
  | Error err -> fail err
  | Ok { tiered_providers = [ runpod; ollama ]; _ } ->
    check string "runpod admission tier id"
      "tier-group.strict_tool_candidates.tier-0" runpod.tier_id;
    check string "ollama cloud admission tier id"
      "tier-group.strict_tool_candidates.tier-1" ollama.tier_id
  | Ok resolution ->
    fail
      (Printf.sprintf
         "expected two tiered providers, got %d"
         (List.length resolution.tiered_providers))

(* --- RFC-0058 Phase 8: partial parse --- *)

(* Reproduces the 2026-05-17 keeper-skip incident: a stale [<ghost>.<m>]
   binding referencing a removed provider used to invalidate the
   entire catalog at the [try_load_declarative] surface, even though
   well-formed tier-groups elsewhere in the file resolved cleanly.
   See RFC-0058 Phase 8 §1. *)
let partial_toml = {|
[providers.ollama]
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen3]
max-context = 32768
api-name = "qwen3:8b"
tools-support = true

[ollama.qwen3]

[tier.local]
members = ["ollama.qwen3"]
strategy = "failover"

[tier-group.local-group]
tiers = ["local"]
strategy = "failover"

# Stale binding — provider [providers.ghost] does not exist.
# Before Phase 8 this single error invalidates the whole catalog.
[ghost.ghost-model]
max-concurrent = 1
|}

let write_temp_toml content =
  let path = Filename.temp_file "rfc0058_phase8" ".toml" in
  write_file path content;
  path

let test_try_load_partial_returns_snapshot_with_errors () =
  let path = write_temp_toml partial_toml in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      match Hotpath.try_load_partial path with
      | None ->
        fail
          "expected Some partial_load_result (catalog has resolvable \
           tier-group.local-group), got None"
      | Some { snapshot; errors } ->
        check bool "snapshot has profiles" true
          (List.length snapshot.Hotpath.profiles > 0);
        check bool "errors recorded" true (List.length errors > 0);
        let names = Hotpath.decl_snapshot_profile_names snapshot in
        check bool
          "tier-group.local-group surfaces in partial snapshot" true
          (List.exists (fun n -> n = "tier-group.local-group") names))

let test_try_load_declarative_collapses_partial_to_error () =
  let path = write_temp_toml partial_toml in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      match Hotpath.try_load_declarative path with
      | None -> fail "expected Some result"
      | Some (Ok _) ->
        fail
          "backward-compat shim must surface Error when partial errors \
           exist; got Ok"
      | Some (Error errors) ->
        check bool "binary shim reports errors" true
          (List.length errors > 0))

let test_try_load_partial_clean_has_no_errors () =
  let path = write_temp_toml valid_toml in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      match Hotpath.try_load_partial path with
      | None -> fail "expected Some for clean valid_toml"
      | Some { snapshot = _; errors } ->
        check int "clean parse has no errors" 0 (List.length errors))

(* --- RFC-0058 Phase 8.4: dispatch-path partial invariants ---

   These tests strengthen the snapshot invariants that downstream
   dispatch (Cascade_catalog_runtime.known_profile_names,
   lookup_active_profile, etc.) relies on. The runtime dispatch path
   reads [snapshot.profiles] without re-checking per-member
   resolvability — so if the adapter ever exposed a half-stitched tier
   (e.g. tier-group referencing an unresolvable tier) in the snapshot,
   dispatch would crash or fall through to reserved without warning.

   Phase 8.1's adapted_profile_to_profile + adapted_catalog_to_snapshot
   already enforce these invariants via [List.filter_map] +
   [None when provider_configs = []]. These tests mechanize that
   guarantee so a future refactor of the adapter cannot silently
   weaken it.

   See RFC-0058-phase-8-cascade-catalog-partial-parse.md §6.4. *)

(* Catalog with two tiers: one fully resolvable, one with all members
   referencing missing bindings. A tier-group composes both. The fully
   unresolvable tier must NOT appear in the snapshot; the tier-group
   surfaces because it has at least one resolvable tier. *)
let mixed_tier_resolvability_toml = {|
[providers.ollama]
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen3]
max-context = 32768
api-name = "qwen3:8b"
tools-support = true

[ollama.qwen3]

[tier.good]
members = ["ollama.qwen3"]
strategy = "failover"

[tier.bad]
members = ["ghost.ghost-model"]
strategy = "failover"

[tier-group.mixed]
tiers = ["good", "bad"]
strategy = "failover"
|}

let test_partial_snapshot_excludes_zero_member_tiers () =
  let path = write_temp_toml mixed_tier_resolvability_toml in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      match Hotpath.try_load_partial path with
      | None -> fail "expected Some partial result (mixed tier resolvability)"
      | Some { snapshot; errors } ->
        let names = Hotpath.decl_snapshot_profile_names snapshot in
        check bool "errors recorded for bad tier" true (List.length errors > 0);
        check bool "tier.good in snapshot" true
          (List.exists (fun n -> n = "tier.good") names);
        check bool "tier.bad excluded from snapshot (zero resolvable members)"
          true
          (not (List.exists (fun n -> n = "tier.bad") names));
        check bool "tier-group.mixed surfaces (one good tier suffices)" true
          (List.exists (fun n -> n = "tier-group.mixed") names))

let test_partial_snapshot_errors_disjoint_from_profile_names () =
  let path = write_temp_toml mixed_tier_resolvability_toml in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      match Hotpath.try_load_partial path with
      | None -> fail "expected Some result"
      | Some { snapshot; errors } ->
        let names = Hotpath.decl_snapshot_profile_names snapshot in
        (* Error subjects (provider/model names mentioned in the errors)
           must not appear as profile names. The snapshot exposes only
           resolved entries; failed bindings/tiers are reported in
           [errors], never half-published as profiles.

           This is the invariant downstream dispatch (lookup_active_profile)
           relies on: a name in [snapshot.profiles] always points at a
           fully resolved profile. *)
        (* Exhaustive over Adapter.adapter_error. Subjects that name a
           binding-like entity (provider/model/binding/alias/tier-group)
           must not appear as snapshot profile_names. Strategy_mismatch
           carries a tier name, Duplicate_route a route name, Internal an
           internal message — none of those are binding subjects, so they
           are excluded explicitly. Catch-all removed to force review on
           new variants. *)
        let error_subjects =
          errors
          |> List.filter_map (function
              | Adapter.Provider_not_found s
              | Adapter.Model_not_found s
              | Adapter.Binding_resolution_failed s
              | Adapter.Alias_resolution_failed s
              | Adapter.Tier_group_empty s -> Some s
              | Adapter.Strategy_mismatch _
              | Adapter.Duplicate_route _
              | Adapter.Internal _ -> None)
        in
        List.iter (fun subject ->
          check bool
            (Printf.sprintf "error subject %S not in snapshot profile_names"
               subject)
            false
            (List.exists (fun n -> n = subject) names))
          error_subjects)

(* Catalog where every tier-group member is unresolvable. Snapshot must
   be None (or the tier-group must be excluded from a non-empty snapshot
   produced by other valid profiles). *)
let all_tiers_unresolvable_toml = {|
[providers.ollama]
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen3]
max-context = 32768
api-name = "qwen3:8b"
tools-support = true

[ollama.qwen3]

[tier.lone-good]
members = ["ollama.qwen3"]
strategy = "failover"

[tier.all-bad]
members = ["ghost.a", "ghost.b"]
strategy = "failover"

[tier-group.doomed]
tiers = ["all-bad"]
strategy = "failover"
|}

let test_tier_group_with_all_unresolvable_tiers_excluded () =
  let path = write_temp_toml all_tiers_unresolvable_toml in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      match Hotpath.try_load_partial path with
      | None -> fail "expected Some result (tier.lone-good is resolvable)"
      | Some { snapshot; errors = _ } ->
        let names = Hotpath.decl_snapshot_profile_names snapshot in
        check bool "tier.lone-good in snapshot" true
          (List.exists (fun n -> n = "tier.lone-good") names);
        check bool "tier-group.doomed not in snapshot (all tiers fail)" true
          (not (List.exists (fun n -> n = "tier-group.doomed") names));
        check bool "tier.all-bad not in snapshot (zero members)" true
          (not (List.exists (fun n -> n = "tier.all-bad") names)))

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
        test_case
          "provider_d-http model strings use custom labels"
          `Quick
          test_provider_d_http_model_string_uses_custom_label;
        test_case "weighted_entries count" `Quick test_weighted_entries_count;
        test_case
          "failover inference max_tokens uses narrowest candidate"
          `Quick
          test_failover_inference_max_tokens_uses_narrowest_candidate;
        test_case
          "tier-group max_tokens uses model capability"
          `Quick
          test_tier_group_inference_max_tokens_uses_model_capability;
        test_case "strategy preserved" `Quick test_strategy_preserved;
        test_case
          "tier-group priority cycles cover all tiers"
          `Quick
          test_tier_group_priority_cycles_cover_all_tiers;
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
      "runtime",
      [
        test_case
          "runtime resolution uses direct declarative Provider_config"
          `Quick
          test_runtime_resolution_uses_direct_declarative_provider_config;
        test_case
          "runtime resolution preserves admission tier id"
          `Quick
          test_runtime_resolution_preserves_tier_id;
        test_case
          "runtime resolution splits multi-tier group admission ids"
          `Quick
          test_runtime_resolution_splits_multi_tier_group_admission_ids;
      ];
      "phase8_partial_parse",
      [
        test_case
          "try_load_partial surfaces snapshot + errors for partial catalog"
          `Quick
          test_try_load_partial_returns_snapshot_with_errors;
        test_case
          "try_load_declarative remains binary (Error on partial)"
          `Quick
          test_try_load_declarative_collapses_partial_to_error;
        test_case
          "try_load_partial clean parse has empty errors"
          `Quick
          test_try_load_partial_clean_has_no_errors;
      ];
      "phase8_4_dispatch_invariants",
      [
        test_case
          "partial snapshot excludes zero-member tiers"
          `Quick
          test_partial_snapshot_excludes_zero_member_tiers;
        test_case
          "errors disjoint from profile_names"
          `Quick
          test_partial_snapshot_errors_disjoint_from_profile_names;
        test_case
          "tier-group with all unresolvable tiers excluded"
          `Quick
          test_tier_group_with_all_unresolvable_tiers_excluded;
      ];
    ]
