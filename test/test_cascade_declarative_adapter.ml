(** RFC-0058 Phase 2: Declarative adapter unit tests.

    Tests the adapter that converts a parsed [cascade_config] into an
    [adapted_catalog] that mirrors the runtime's expected shape.

    The adapter resolves declared TOML providers directly into
    [Provider_config.t] values, falling back to
    [Cascade_config.parse_model_string] only for legacy providers that are not
    declared in TOML. Tests use provider IDs from the typed provider-kind
    surface (claude_code, codex_cli, ollama, etc.). *)

open Alcotest
open Cascade_declarative_types
open Cascade_declarative_parser
module Adapter = Masc_mcp.Cascade_declarative_adapter
module Cascade_strategy = Masc_mcp.Cascade_strategy

(* Re-export for convenience *)
open Adapter

(* --- Helpers --- *)

let has_error (f : adapter_error -> bool) (errs : adapter_error list) =
  check bool "has matching error" true (List.exists f errs)
;;

let has_provider_not_found (id : string) (errs : adapter_error list) =
  has_error
    (function
      | Provider_not_found s -> s = id
      | _ -> false)
    errs
;;

let has_model_not_found (id : string) (errs : adapter_error list) =
  has_error
    (function
      | Model_not_found s -> s = id
      | _ -> false)
    errs
;;

let has_binding_failed (key : string) (errs : adapter_error list) =
  has_error
    (function
      | Binding_resolution_failed s -> s = key
      | _ -> false)
    errs
;;

let has_alias_failed (key : string) (errs : adapter_error list) =
  has_error
    (function
      | Alias_resolution_failed s -> s = key
      | _ -> false)
    errs
;;

let has_duplicate_route (name : string) (errs : adapter_error list) =
  has_error
    (function
      | Duplicate_route s -> s = name
      | _ -> false)
    errs
;;

let no_errors (errs : adapter_error list) = check int "no errors" 0 (List.length errs)

let adapt_toml (toml : string) : adapted_catalog =
  match parse_string toml with
  | Ok cfg -> adapt_config cfg
  | Error (errs : parse_error list) ->
    failwith
      (Printf.sprintf
         "parse failed: %s"
         (String.concat
            "; "
            (List.map
               (fun (e : parse_error) -> Printf.sprintf "%s: %s" e.path e.message)
               errs)))
;;

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f
;;

(* --- TOML fixtures ---

   Provider IDs must match [Provider_adapter] cascade_prefix values:
   claude_code, codex_cli, gemini_cli, ollama, glm-coding, etc.

   Model api_names must be valid runtime model ids for the declared provider. *)

let valid_toml =
  {|
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

[claude_code.haiku.for-tool-rerank]
max-input = 4096

[ollama.qwen3]

[tier.rerank]
members = ["claude_code.haiku.for-tool-rerank"]
strategy = "failover"

[tier.primary]
members = ["claude_code.sonnet", "claude_code.haiku"]
strategy = "failover"

[tier.local]
members = ["ollama.qwen3"]
strategy = "failover"

[tier-group.big-three]
tiers = ["primary", "local"]
strategy = "priority_tier"

[routes.default]
target = "tier-group.big-three"

[system.governance]
target = "claude_code.haiku.for-tool-rerank"
|}
;;

(* --- Test: valid config produces non-empty catalog --- *)

let test_valid_catalog_structure () =
  let catalog = adapt_toml valid_toml in
  no_errors catalog.errors;
  check bool "has profiles" true (List.length catalog.profiles > 0);
  check bool "has routes" true (List.length catalog.routes > 0);
  check bool "has system targets" true (List.length catalog.system_targets > 0)
;;

let test_valid_tier_profiles () =
  let catalog = adapt_toml valid_toml in
  let tier_names = List.map (fun (p : adapted_profile) -> p.name) catalog.profiles in
  check bool "has tier.rerank" true (List.mem "tier.rerank" tier_names);
  check bool "has tier.primary" true (List.mem "tier.primary" tier_names);
  check bool "has tier.local" true (List.mem "tier.local" tier_names);
  check bool "has tier-group.big-three" true (List.mem "tier-group.big-three" tier_names)
;;

let test_valid_tier_members_resolved () =
  let catalog = adapt_toml valid_toml in
  let rerank =
    List.find (fun (p : adapted_profile) -> p.name = "tier.rerank") catalog.profiles
  in
  check int "rerank has 1 provider_config" 1 (List.length rerank.provider_configs)
;;

let test_valid_tier_group_flattened () =
  let catalog = adapt_toml valid_toml in
  let big_three =
    List.find
      (fun (p : adapted_profile) -> p.name = "tier-group.big-three")
      catalog.profiles
  in
  (* primary has 2 members + local has 1 member = 3 provider_configs *)
  check int "big-three has 3 provider_configs" 3 (List.length big_three.provider_configs)
;;

let test_valid_routes () =
  let catalog = adapt_toml valid_toml in
  let route_targets = List.map snd catalog.routes in
  check
    bool
    "routes to tier-group.big-three"
    true
    (List.mem "tier-group.big-three" route_targets)
;;

let test_valid_system_targets () =
  let catalog = adapt_toml valid_toml in
  let targets = List.map snd catalog.system_targets in
  check
    bool
    "system target is alias key"
    true
    (List.mem "claude_code.haiku.for-tool-rerank" targets)
;;

let test_valid_default_profile () =
  let catalog = adapt_toml valid_toml in
  check bool "has default profile" true (catalog.default_profile <> None)
;;

let test_registered_http_provider_uses_toml_endpoint_without_api_key () =
  let toml =
    {|
[providers.glm-coding]
protocol = "openai-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[providers.glm-coding.credentials]
type = "env"
key = "ZAI_API_KEY"

[models.glm-5-turbo]
max-context = 128000
api-name = "glm-5-turbo"
tools-support = true

[glm-coding.glm-5-turbo]
max-concurrent = 2

[tier.medium]
members = ["glm-coding.glm-5-turbo"]
strategy = "failover"
|}
  in
  let catalog = adapt_toml toml in
  no_errors catalog.errors;
  let medium =
    List.find (fun (p : adapted_profile) -> p.name = "tier.medium") catalog.profiles
  in
  match medium.provider_configs with
  | [ cfg ] ->
    check
      bool
      "keeps registered GLM kind"
      true
      (cfg.Llm_provider.Provider_config.kind = Llm_provider.Provider_config.Glm);
    check
      string
      "uses TOML endpoint"
      "https://api.z.ai/api/coding/paas/v4"
      cfg.Llm_provider.Provider_config.base_url;
    check string "uses model api-name" "glm-5-turbo" cfg.model_id
  | configs ->
    fail
      (Printf.sprintf
         "expected one resolved provider config, got %d"
         (List.length configs))
;;

let test_registered_http_provider_without_credentials_uses_registry_api_key_env () =
  with_env "ZAI_API_KEY" "zai-review-test-key" (fun () ->
    let toml =
      {|
[providers.glm-coding]
protocol = "openai-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[models.glm-5-turbo]
max-context = 128000
api-name = "glm-5-turbo"
tools-support = true

[glm-coding.glm-5-turbo]
max-concurrent = 2

[tier.medium]
members = ["glm-coding.glm-5-turbo"]
strategy = "failover"
|}
    in
    let catalog = adapt_toml toml in
    no_errors catalog.errors;
    let medium =
      List.find (fun (p : adapted_profile) -> p.name = "tier.medium") catalog.profiles
    in
    match medium.provider_configs with
    | [ cfg ] ->
      check
        bool
        "keeps registered GLM kind"
        true
        (cfg.Llm_provider.Provider_config.kind = Llm_provider.Provider_config.Glm);
      check
        string
        "uses TOML endpoint"
        "https://api.z.ai/api/coding/paas/v4"
        cfg.Llm_provider.Provider_config.base_url;
      check string "uses registry api_key_env fallback" "zai-review-test-key" cfg.api_key
    | configs ->
      fail
        (Printf.sprintf
           "expected one resolved provider config, got %d"
           (List.length configs)))
;;

let test_cli_provider_resolves_without_runtime_binary () =
  let toml =
    {|
[providers.claude_code]
protocol = "anthropic-cli"
command = "__missing_claude_for_adapter_test__"

[models.haiku]
max-context = 200000
api-name = "claude-haiku-4-5-20251001"
tools-support = true

[claude_code.haiku]
max-concurrent = 1

[tier.primary]
members = ["claude_code.haiku"]
strategy = "failover"
|}
  in
  let catalog = adapt_toml toml in
  no_errors catalog.errors;
  let primary =
    List.find (fun (p : adapted_profile) -> p.name = "tier.primary") catalog.profiles
  in
  match primary.provider_configs with
  | [ cfg ] ->
    check
      bool
      "uses CLI provider kind from declarative provider id"
      true
      (cfg.Llm_provider.Provider_config.kind = Llm_provider.Provider_config.Claude_code);
    check string "uses model api-name" "claude-haiku-4-5-20251001" cfg.model_id;
    check string "CLI providers do not need an HTTP base URL" "" cfg.base_url
  | configs ->
    fail
      (Printf.sprintf
         "expected one resolved provider config, got %d"
         (List.length configs))
;;

(* --- Error: unknown provider --- *)

let test_unknown_provider () =
  let toml =
    {|
[providers.nonexistent]
protocol = "anthropic-cli"
command = "x"

[models.haiku]
max-context = 200000
api-name = "claude-haiku-4-5-20251001"

[nonexistent.haiku]
is-default = true
|}
  in
  let catalog = adapt_toml toml in
  has_provider_not_found "nonexistent" catalog.errors
;;

(* --- Error: unknown model --- *)

let test_unknown_model () =
  let toml =
    {|
[providers.claude_code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000
api-name = "claude-haiku-4-5-20251001"

[claude_code.nonexistent-model]
is-default = true
|}
  in
  let catalog = adapt_toml toml in
  has_model_not_found "nonexistent-model" catalog.errors
;;

(* --- Error: alias resolution fails when parent missing --- *)

let test_alias_parent_missing () =
  let cfg =
    { providers =
        [ { id = "x"
          ; display_name = "X"
          ; protocol = "anthropic"
          ; api_format = Messages_api
          ; transport = Cli "x"
          ; is_non_interactive = false
          ; credentials = None
          ; capabilities = None
          ; headers = None
          }
        ]
    ; models =
        [ { id = "m"
          ; api_name = "test-model"
          ; max_context = 4096
          ; tools_support = true
          ; thinking_support = false
          ; max_thinking_budget = None
          ; streaming = true
          ; capabilities = None
          ; match_prefixes = []
          }
        ]
    ; bindings = []
    ; aliases =
        [ { provider_id = "x"
          ; model_id = "m"
          ; name = "a"
          ; max_input = None
          ; max_output = None
          ; temperature = None
          ; thinking_enabled = None
          ; thinking_budget = None
          }
        ]
    ; tiers =
        [ { name = "t"
          ; members = [ "x.m.a" ]
          ; strategy = Failover
          ; max_concurrent = None
          ; cycle_policy = None
          ; sticky_ttl_ms = None
          ; scoring_params = None
          }
        ]
    ; tier_groups = []
    ; routes = []
    ; system_targets = []
    }
  in
  let catalog = adapt_config cfg in
  has_alias_failed "x.m.a" catalog.errors
;;

(* --- Strategy mapping --- *)

let test_strategy_mapping () =
  let toml =
    {|
[providers.claude_code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000
api-name = "claude-haiku-4-5-20251001"

[claude_code.haiku]

[tier.failover-t]
members = ["claude_code.haiku"]
strategy = "failover"

[tier.capacity-t]
members = ["claude_code.haiku"]
strategy = "capacity_aware"

[tier.weighted-t]
members = ["claude_code.haiku"]
strategy = "weighted_random"

[tier.circuit-t]
members = ["claude_code.haiku"]
strategy = "circuit_breaker_cycling"

[tier.priority-t]
members = ["claude_code.haiku"]
strategy = "priority_tier"

[tier.sticky-t]
members = ["claude_code.haiku"]
strategy = "sticky"

[tier.round-robin-t]
members = ["claude_code.haiku"]
strategy = "round_robin"
|}
  in
  let catalog = adapt_toml toml in
  no_errors catalog.errors;
  let by_name name =
    List.find (fun (p : adapted_profile) -> p.name = name) catalog.profiles
  in
  let equal_kind a b =
    Cascade_strategy.kind_to_string a = Cascade_strategy.kind_to_string b
  in
  let check_kind (name : string) (expected : Cascade_strategy.kind) =
    let profile = by_name name in
    check
      (Alcotest.testable
         (fun fmt k -> Fmt.pf fmt "%s" (Cascade_strategy.kind_to_string k))
         equal_kind)
      (name ^ " strategy kind")
      expected
      profile.strategy.Cascade_strategy.kind
  in
  check_kind "tier.failover-t" Cascade_strategy.Failover;
  check_kind "tier.capacity-t" Cascade_strategy.Capacity_aware;
  check_kind "tier.weighted-t" Cascade_strategy.Weighted_random;
  check_kind "tier.circuit-t" Cascade_strategy.Circuit_breaker_cycling;
  check_kind "tier.priority-t" Cascade_strategy.Priority_tier;
  check_kind "tier.sticky-t" Cascade_strategy.Sticky;
  check_kind "tier.round-robin-t" Cascade_strategy.Round_robin
;;

(* --- Cycle policy passthrough --- *)

let test_cycle_policy () =
  let toml =
    {|
[providers.claude_code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000
api-name = "claude-haiku-4-5-20251001"

[claude_code.haiku]

[tier.cycling-t]
members = ["claude_code.haiku"]
strategy = "circuit_breaker_cycling"
max-cycles = 5
backoff-base-ms = 1000
backoff-cap-ms = 30000
|}
  in
  let catalog = adapt_toml toml in
  no_errors catalog.errors;
  let profile =
    List.find (fun (p : adapted_profile) -> p.name = "tier.cycling-t") catalog.profiles
  in
  let cp = profile.strategy.Cascade_strategy.cycle in
  check int "max_cycles" 5 cp.Cascade_strategy.max_cycles;
  check int "backoff_base_ms" 1000 cp.Cascade_strategy.backoff_base_ms;
  check int "backoff_cap_ms" 30000 cp.Cascade_strategy.backoff_cap_ms
;;

(* --- Scoring params passthrough --- *)

let test_scoring_params () =
  let toml =
    {|
[providers.claude_code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000
api-name = "claude-haiku-4-5-20251001"

[claude_code.haiku]

[tier.scored-t]
members = ["claude_code.haiku"]
strategy = "weighted_random"
latency-baseline-ms = 300.0
rate-limit-recency-window-s = 120.0
rate-limit-decay-base = 0.7
rate-limit-skip-after = 5
server-error-recency-window-s = 240.0
server-error-decay-base = 0.4
server-error-skip-after = 8
|}
  in
  let catalog = adapt_toml toml in
  no_errors catalog.errors;
  let profile =
    List.find (fun (p : adapted_profile) -> p.name = "tier.scored-t") catalog.profiles
  in
  let sp = profile.strategy.Cascade_strategy.scoring in
  check
    (Alcotest.float 0.001)
    "latency_baseline_ms"
    300.0
    sp.Cascade_strategy.latency_baseline_ms;
  check
    (Alcotest.float 0.001)
    "rate_limit_decay_base"
    0.7
    sp.Cascade_strategy.rate_limit_decay_base;
  check int "rate_limit_skip_after" 5 sp.Cascade_strategy.rate_limit_skip_after
;;

(* --- Sticky TTL --- *)

let test_sticky_ttl () =
  let toml =
    {|
[providers.claude_code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000
api-name = "claude-haiku-4-5-20251001"

[claude_code.haiku]

[tier.sticky-t]
members = ["claude_code.haiku"]
strategy = "sticky"
sticky-ttl-ms = 600000
|}
  in
  let catalog = adapt_toml toml in
  no_errors catalog.errors;
  let profile =
    List.find (fun (p : adapted_profile) -> p.name = "tier.sticky-t") catalog.profiles
  in
  check int "sticky_ttl_ms" 600000 profile.strategy.Cascade_strategy.sticky_ttl_ms
;;

(* --- Multiple errors accumulated --- *)

let test_multiple_errors () =
  let toml =
    {|
[providers.good]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000
api-name = "claude-haiku-4-5-20251001"

[bad-provider.haiku]
is-default = true

[claude_code.nonexistent]
is-default = true
|}
  in
  let catalog = adapt_toml toml in
  has_provider_not_found "bad-provider" catalog.errors;
  has_model_not_found "nonexistent" catalog.errors;
  check bool "multiple errors" true (List.length catalog.errors >= 2)
;;

(* --- Duplicate route detection --- *)

let test_duplicate_routes () =
  let cfg =
    { providers =
        [ { id = "claude_code"
          ; display_name = "Claude Code"
          ; protocol = "anthropic"
          ; api_format = Messages_api
          ; transport = Cli "claude"
          ; is_non_interactive = false
          ; credentials = None
          ; capabilities = None
          ; headers = None
          }
        ]
    ; models =
        [ { id = "haiku"
          ; api_name = "claude-haiku-4-5-20251001"
          ; max_context = 200000
          ; tools_support = true
          ; thinking_support = false
          ; max_thinking_budget = None
          ; streaming = true
          ; capabilities = None
          ; match_prefixes = []
          }
        ]
    ; bindings =
        [ { provider_id = "claude_code"
          ; model_id = "haiku"
          ; is_default = true
          ; max_concurrent = 1
          ; price_input = None
          ; price_output = None
          ; keep_alive = None
          ; num_ctx = None
          }
        ]
    ; aliases = []
    ; tiers =
        [ { name = "primary"
          ; members = [ "claude_code.haiku" ]
          ; strategy = Failover
          ; max_concurrent = None
          ; cycle_policy = None
          ; sticky_ttl_ms = None
          ; scoring_params = None
          }
        ]
    ; tier_groups = []
    ; routes =
        [ { name = "dup"; target = "tier.primary" }
        ; { name = "dup"; target = "tier.primary" }
        ]
    ; system_targets = []
    }
  in
  let catalog = adapt_config cfg in
  has_duplicate_route "dup" catalog.errors
;;

(* --- Empty tier-group produces empty provider_configs --- *)

let test_empty_tier_group () =
  let toml =
    {|
[providers.claude_code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000
api-name = "claude-haiku-4-5-20251001"

[claude_code.haiku]

[tier.real]
members = ["claude_code.haiku"]
strategy = "failover"

[tier-group.empty]
tiers = ["real"]
strategy = "priority_tier"
|}
  in
  let catalog = adapt_toml toml in
  (* tier-group.empty has tier "real" with 1 member — not actually empty *)
  check
    bool
    "has tier-group.empty profile"
    true
    (List.exists
       (fun (p : adapted_profile) -> p.name = "tier-group.empty")
       catalog.profiles)
;;

(* --- Test suite --- *)

let () =
  run
    "RFC-0058 Phase 2: Declarative Adapter"
    [ ( "valid_catalog"
      , [ test_case "structure" `Quick test_valid_catalog_structure
        ; test_case "tier profiles" `Quick test_valid_tier_profiles
        ; test_case "tier members resolved" `Quick test_valid_tier_members_resolved
        ; test_case "tier-group flattened" `Quick test_valid_tier_group_flattened
        ; test_case "routes" `Quick test_valid_routes
        ; test_case "system targets" `Quick test_valid_system_targets
        ; test_case "default profile" `Quick test_valid_default_profile
        ; test_case
            "registered HTTP provider uses TOML endpoint"
            `Quick
            test_registered_http_provider_uses_toml_endpoint_without_api_key
        ; test_case
            "registered HTTP provider uses registry api_key_env fallback"
            `Quick
            test_registered_http_provider_without_credentials_uses_registry_api_key_env
        ; test_case
            "CLI provider resolves without runtime binary"
            `Quick
            test_cli_provider_resolves_without_runtime_binary
        ] )
    ; ( "errors"
      , [ test_case "unknown provider" `Quick test_unknown_provider
        ; test_case "unknown model" `Quick test_unknown_model
        ; test_case "alias parent missing" `Quick test_alias_parent_missing
        ; test_case "multiple errors" `Quick test_multiple_errors
        ; test_case "duplicate routes" `Quick test_duplicate_routes
        ] )
    ; ( "strategy"
      , [ test_case "all 7 variants" `Quick test_strategy_mapping
        ; test_case "cycle policy" `Quick test_cycle_policy
        ; test_case "scoring params" `Quick test_scoring_params
        ; test_case "sticky ttl" `Quick test_sticky_ttl
        ] )
    ; "edge_cases", [ test_case "empty tier-group" `Quick test_empty_tier_group ]
    ]
;;
