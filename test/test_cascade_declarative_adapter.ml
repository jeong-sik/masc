(** RFC-0058 Phase 2: Declarative adapter unit tests.

    Tests the adapter that converts a parsed [cascade_config] into an
    [adapted_catalog] that mirrors the runtime's expected shape.

    The adapter resolves declared TOML providers directly into
    [Provider_config.t] values. Undeclared legacy provider bindings fail closed
    instead of re-parsing synthetic provider:model strings. Tests use provider
    IDs from the typed provider-kind surface (cli_tool_d, cli_tool_a, ollama,
    etc.). *)

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

   Provider IDs must match runtime binding cascade prefix values:
   cli_tool_d, cli_tool_a, cli_tool_b, ollama, provider_k-coding, etc.

   Model api_names must be valid runtime model ids for the declared provider. *)

let valid_toml =
  {|
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
  check bool "has tier-group.primary" true (List.mem "tier-group.primary" tier_names)
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
  let primary =
    List.find
      (fun (p : adapted_profile) -> p.name = "tier-group.primary")
      catalog.profiles
  in
  (* primary has 2 members + local has 1 member = 3 provider_configs *)
  check int "primary has 3 provider_configs" 3 (List.length primary.provider_configs)
;;

let test_valid_routes () =
  let catalog = adapt_toml valid_toml in
  let route_targets = List.map snd catalog.routes in
  check
    bool
    "routes to tier-group.primary"
    true
    (List.mem "tier-group.primary" route_targets)
;;

let test_valid_system_targets () =
  let catalog = adapt_toml valid_toml in
  let targets = List.map snd catalog.system_targets in
  check
    bool
    "system target is alias key"
    true
    (List.mem "cli_tool_d.haiku.for-scoring" targets)
;;

let test_valid_default_profile () =
  let catalog = adapt_toml valid_toml in
  check bool "has default profile" true (catalog.default_profile <> None)
;;

let test_registered_http_provider_uses_toml_endpoint_without_api_key () =
  let toml =
    {|
[providers.provider_k-coding]
protocol = "provider_d-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[providers.provider_k-coding.credentials]
type = "env"
key = "ZAI_API_KEY"

[models.provider_k-5-turbo]
max-context = 128000
api-name = "provider_k-5-turbo"
tools-support = true

[provider_k-coding.provider_k-5-turbo]
max-concurrent = 2

[tier.medium]
members = ["provider_k-coding.provider_k-5-turbo"]
strategy = "failover"
|}
  in
  let catalog = adapt_toml toml in
  no_errors catalog.errors;
  let medium =
    List.find (fun (p : adapted_profile) -> p.name = "tier.medium") catalog.profiles
  in
  match medium.provider_configs with
  | [ (cfg, _) ] ->
    check
      bool
      "keeps registered GLM kind"
      true
      (cfg.Llm_provider.Provider_config.kind = Llm_provider.Provider_config.Provider_k);
    check
      string
      "uses TOML endpoint"
      "https://api.z.ai/api/coding/paas/v4"
      cfg.Llm_provider.Provider_config.base_url;
    check string "uses model api-name" "provider_k-5-turbo" cfg.model_id
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
[providers.provider_k-coding]
protocol = "provider_d-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[models.provider_k-5-turbo]
max-context = 128000
api-name = "provider_k-5-turbo"
tools-support = true

[provider_k-coding.provider_k-5-turbo]
max-concurrent = 2

[tier.medium]
members = ["provider_k-coding.provider_k-5-turbo"]
strategy = "failover"
|}
    in
    let catalog = adapt_toml toml in
    no_errors catalog.errors;
    let medium =
      List.find (fun (p : adapted_profile) -> p.name = "tier.medium") catalog.profiles
    in
    match medium.provider_configs with
    | [ (cfg, _) ] ->
      check
        bool
        "keeps registered GLM kind"
        true
        (cfg.Llm_provider.Provider_config.kind = Llm_provider.Provider_config.Provider_k);
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

let test_ollama_cloud_http_provider_adds_bearer_auth_header () =
  with_env "OLLAMA_CLOUD_API_KEY" "ollama-cloud-adapter-test-key" @@ fun () ->
  with_env "OLLAMA_API_KEY" "fallback-ollama-api-key" @@ fun () ->
    let toml =
      {|
[providers.ollama_cloud]
protocol = "ollama-http"
endpoint = "https://ollama.com"

[providers.ollama_cloud.credentials]
type = "env"
key = "OLLAMA_CLOUD_API_KEY"

[models.provider_k-5-1-cloud]
max-context = 262144
api-name = "provider_k-5.1:cloud"
tools-support = true

[ollama_cloud.provider_k-5-1-cloud]
max-concurrent = 1

[tier.provider_k-coding-with-spark]
members = ["ollama_cloud.provider_k-5-1-cloud"]
strategy = "failover"
|}
    in
    let catalog = adapt_toml toml in
    no_errors catalog.errors;
    let coding_tier =
      List.find
        (fun (p : adapted_profile) -> p.name = "tier.provider_k-coding-with-spark")
        catalog.profiles
    in
    match coding_tier.provider_configs with
    | [ (cfg, _) ] ->
      check
        bool
        "uses Ollama wire kind"
        true
        (cfg.Llm_provider.Provider_config.kind = Llm_provider.Provider_config.Ollama);
      check
        string
        "uses Ollama Cloud endpoint"
        "https://ollama.com"
        cfg.Llm_provider.Provider_config.base_url;
      check string "uses Ollama chat path" "/api/chat" cfg.request_path;
      check string "materializes cloud API key" "ollama-cloud-adapter-test-key" cfg.api_key;
      check
        bool
        "Authorization bearer header present"
        true
        (List.mem
           ("Authorization", "Bearer ollama-cloud-adapter-test-key")
           cfg.headers)
    | configs ->
      fail
        (Printf.sprintf
           "expected one resolved provider config, got %d"
           (List.length configs))
;;

let test_ollama_cloud_openai_protocol_uses_chat_completions () =
  with_env "OLLAMA_CLOUD_API_KEY" "ollama-cloud-adapter-test-key" @@ fun () ->
    let toml =
      {|
[providers.ollama_cloud]
protocol = "provider_d-http"
endpoint = "https://ollama.com/v1"

[providers.ollama_cloud.credentials]
type = "env"
key = "OLLAMA_CLOUD_API_KEY"

[models.qwen3-5]
max-context = 128000
api-name = "qwen3.5"
tools-support = true

[models.qwen3-5.capabilities]
supports-tool-choice = true

[ollama_cloud.qwen3-5]
max-concurrent = 1

[tier.ollama_cloud_primary]
members = ["ollama_cloud.qwen3-5"]
strategy = "failover"
|}
    in
    let catalog = adapt_toml toml in
    no_errors catalog.errors;
    let primary =
      List.find
        (fun (p : adapted_profile) -> p.name = "tier.ollama_cloud_primary")
        catalog.profiles
    in
    match primary.provider_configs with
    | [ (cfg, _) ] ->
      check
        bool
        "explicit provider_d-http wins over ollama_cloud registry defaults"
        true
        (cfg.Llm_provider.Provider_config.kind
         = Llm_provider.Provider_config.Provider_d_compat);
      check string "uses versioned endpoint" "https://ollama.com/v1" cfg.base_url;
      check string "uses chat completions path" "/chat/completions" cfg.request_path;
      check
        (option bool)
        "tool_choice support preserved"
        (Some true)
        cfg.Llm_provider.Provider_config.supports_tool_choice_override
    | configs ->
      fail
        (Printf.sprintf
           "expected one resolved provider config, got %d"
           (List.length configs))
;;

let test_model_capabilities_tool_choice_reaches_provider_config () =
  let toml =
    {|
[providers.provider_k-coding]
protocol = "provider_d-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[models.provider_k-5-1]
max-context = 128000
api-name = "provider_k-5.1"
tools-support = true

[models.provider_k-5-1.capabilities]
supports-tool-choice = true

[provider_k-coding.provider_k-5-1]
max-concurrent = 1

[tier.provider_k-coding-primary]
members = ["provider_k-coding.provider_k-5-1"]
strategy = "failover"
|}
  in
  let catalog = adapt_toml toml in
  no_errors catalog.errors;
  let tier =
    List.find
      (fun (p : adapted_profile) -> p.name = "tier.provider_k-coding-primary")
      catalog.profiles
  in
  match tier.provider_configs with
  | [ (cfg, _) ] ->
    check
      (option bool)
      "supports-tool-choice override is preserved"
      (Some true)
      cfg.Llm_provider.Provider_config.supports_tool_choice_override;
    check bool "tool-choice gate accepts declared model capability" true
      (Masc_mcp.Provider_tool_support.supports_required_tool_use
         ~require_tool_choice_support:true
         ~require_tool_support:true
         cfg)
  | configs ->
    fail
      (Printf.sprintf
         "expected one resolved provider config, got %d"
         (List.length configs))
;;

let test_declared_http_provider_v1_endpoint_dedupes_request_path () =
  let toml =
    {|
[providers.local-provider_d]
protocol = "provider_d-http"
endpoint = "http://127.0.0.1:18080/v1"

[providers.local-provider_d.credentials]
type = "env"
key = "LOCAL_OPENAI_API_KEY"

[models.remote]
max-context = 4096
api-name = "remote-model"
tools-support = true

[local-provider_d.remote]

[tier.medium]
members = ["local-provider_d.remote"]
strategy = "failover"
|}
  in
  let catalog = adapt_toml toml in
  no_errors catalog.errors;
  let medium =
    List.find (fun (p : adapted_profile) -> p.name = "tier.medium") catalog.profiles
  in
  match medium.provider_configs with
  | [ (cfg, _) ] ->
    check
      bool
      "uses OpenAI-compatible fallback kind"
      true
      (cfg.Llm_provider.Provider_config.kind
       = Llm_provider.Provider_config.Provider_d_compat);
    check
      string
      "keeps versioned TOML endpoint"
      "http://127.0.0.1:18080/v1"
      cfg.Llm_provider.Provider_config.base_url;
    check
      string
      "strips duplicated version prefix from request_path"
      "/chat/completions"
      cfg.Llm_provider.Provider_config.request_path
  | configs ->
    fail
      (Printf.sprintf
         "expected one resolved provider config, got %d"
         (List.length configs))
;;

let test_cli_provider_resolves_without_runtime_binary () =
  let toml =
    {|
[providers.cli_tool_d]
protocol = "provider_a-cli"
command = "__missing_claude_for_adapter_test__"

[models.haiku]
max-context = 200000
api-name = "model-a-haiku"
tools-support = true

[cli_tool_d.haiku]
max-concurrent = 1

[tier.primary]
members = ["cli_tool_d.haiku"]
strategy = "failover"
|}
  in
  let catalog = adapt_toml toml in
  no_errors catalog.errors;
  let primary =
    List.find (fun (p : adapted_profile) -> p.name = "tier.primary") catalog.profiles
  in
  match primary.provider_configs with
  | [ (cfg, _) ] ->
    check
      bool
      "uses CLI provider kind from declarative provider id"
      true
      (cfg.Llm_provider.Provider_config.kind = Llm_provider.Provider_config.Cli_tool_d);
    check string "uses model api-name" "model-a-haiku" cfg.model_id;
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
[models.haiku]
max-context = 200000
api-name = "model-a-haiku"

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
[providers.cli_tool_d]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000
api-name = "model-a-haiku"

[cli_tool_d.nonexistent-model]
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
          ; protocol = "provider_a"
          ; api_format = Messages_api
          ; transport = Cli "x"
          ; is_non_interactive = false
          ; credentials = None
          ; capabilities = None
          ; log = None
          ; healthcheck = None
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
          ; keeper_assignable = None
          }
        ]
    ; tier_groups = []
    ; routes = []
    ; system_targets = []
    ; profiles = []
    }
  in
  let catalog = adapt_config cfg in
  has_alias_failed "x.m.a" catalog.errors
;;

(* --- Strategy mapping --- *)

let test_strategy_mapping () =
  let toml =
    {|
[providers.cli_tool_d]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000
api-name = "model-a-haiku"

[cli_tool_d.haiku]

[tier.failover-t]
members = ["cli_tool_d.haiku"]
strategy = "failover"

[tier.priority-t]
members = ["cli_tool_d.haiku"]
strategy = "priority_tier"
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
  check_kind "tier.priority-t" Cascade_strategy.Priority_tier
;;

let test_provider_d_http_tier_group_uses_endpoint_scoped_health_keys () =
  let toml =
    {|
[providers.runpod]
protocol = "provider_d-http"
endpoint = "https://runpod.example.test/v1"

[providers.glm]
protocol = "provider_d-http"
endpoint = "https://api.z.ai/api/coding/paas/v4"

[models.runpod-qwen]
max-context = 128000
api-name = "runpod-qwen"
tools-support = true

[models.glm-5-turbo]
max-context = 128000
api-name = "glm-5-turbo"
tools-support = true

[runpod.runpod-qwen]
[glm.glm-5-turbo]

[tier.runpod]
members = ["runpod.runpod-qwen"]
strategy = "failover"

[tier.glm]
members = ["glm.glm-5-turbo"]
strategy = "failover"

[tier-group.custom-priority]
tiers = ["runpod", "glm"]
strategy = "priority_tier"
|}
  in
  let catalog = adapt_toml toml in
  no_errors catalog.errors;
  let profile =
    List.find
      (fun (p : adapted_profile) -> p.name = "tier-group.custom-priority")
      catalog.profiles
  in
  match profile.strategy.Cascade_strategy.tiers with
  | [ [ first ]; [ second ] ] ->
    check bool "tier health keys are endpoint-scoped"
      true
      (not (String.equal first second));
    check bool "runpod tier key includes endpoint"
      true
      (String.contains first '@');
    check bool "glm tier key includes endpoint"
      true
      (String.contains second '@')
  | tiers ->
    fail
      (Printf.sprintf
         "expected two single-entry tiers, got %d tiers"
         (List.length tiers))
;;

(* --- Multiple errors accumulated --- *)

let test_multiple_errors () =
  let toml =
    {|
[providers.good]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000
api-name = "model-a-haiku"

[bad-provider.haiku]
is-default = true

[cli_tool_d.nonexistent]
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
        [ { id = "cli_tool_d"
          ; display_name = "Claude Code"
          ; protocol = "provider_a"
          ; api_format = Messages_api
          ; transport = Cli "agent_llm_a"
          ; is_non_interactive = false
          ; credentials = None
          ; capabilities = None
          ; log = None
          ; healthcheck = None
          ; headers = None
          }
        ]
    ; models =
        [ { id = "haiku"
          ; api_name = "model-a-haiku"
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
        [ { provider_id = "cli_tool_d"
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
          ; members = [ "cli_tool_d.haiku" ]
          ; strategy = Failover
          ; max_concurrent = None
          ; cycle_policy = None
          ; sticky_ttl_ms = None
          ; scoring_params = None
          ; keeper_assignable = None
          }
        ]
    ; tier_groups = []
    ; routes =
        [ { name = "dup"; target = "tier.primary" }
        ; { name = "dup"; target = "tier.primary" }
        ]
    ; system_targets = []
    ; profiles = []
    }
  in
  let catalog = adapt_config cfg in
  has_duplicate_route "dup" catalog.errors
;;

(* --- Empty tier-group produces empty provider_configs --- *)

let test_empty_tier_group () =
  let toml =
    {|
[providers.cli_tool_d]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000
api-name = "model-a-haiku"

[cli_tool_d.haiku]

[tier.real]
members = ["cli_tool_d.haiku"]
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
            "ollama_cloud HTTP provider adds bearer auth header"
            `Quick
            test_ollama_cloud_http_provider_adds_bearer_auth_header
        ; test_case
            "ollama_cloud provider_d-http uses chat completions"
            `Quick
            test_ollama_cloud_openai_protocol_uses_chat_completions
        ; test_case
            "model supports-tool-choice reaches provider config"
            `Quick
            test_model_capabilities_tool_choice_reaches_provider_config
        ; test_case
            "declared HTTP provider dedupes request path"
            `Quick
            test_declared_http_provider_v1_endpoint_dedupes_request_path
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
      , [ test_case "supported variants" `Quick test_strategy_mapping
        ; test_case
            "provider_d-http tier-group keys are endpoint-scoped"
            `Quick
            test_provider_d_http_tier_group_uses_endpoint_scoped_health_keys
        ] )
    ; "edge_cases", [ test_case "empty tier-group" `Quick test_empty_tier_group ]
    ]
;;
