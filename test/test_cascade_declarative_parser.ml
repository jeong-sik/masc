(** RFC-0058 v2 declarative TOML parser unit tests.

    Validates all 5 layers of the TOML schema parse correctly,
    including error accumulation and edge cases. *)

open Alcotest
open Cascade_declarative_types
open Cascade_declarative_parser

(* --- Helpers --- *)

let float_testable = float 0.001
let opt_float = option float_testable
let opt_int = option int
let opt_string = option string

let ok_config (result : (cascade_config, parse_error list) result) : cascade_config =
  match result with
  | Ok cfg -> cfg
  | Error errs ->
    let msg =
      List.map (fun e -> Printf.sprintf "%s: %s" e.path e.message) errs
      |> String.concat "; "
    in
    failwith ("expected Ok, got Error: " ^ msg)
;;

let is_error (result : (cascade_config, parse_error list) result) : parse_error list =
  match result with
  | Ok _ -> failwith "expected Error, got Ok"
  | Error errs -> errs
;;

let has_error_at (path : string) (errs : parse_error list) =
  check bool ("error at " ^ path) true (List.exists (fun e -> e.path = path) errs)
;;

(* --- Minimal valid TOML --- *)

let minimal_toml =
  {|
[providers.test-provider]
protocol = "anthropic-cli"
command = "test-cmd"

[models.test-model]
max-context = 4096

[test-provider.test-model]
|}
;;

let full_toml =
  {|
[providers.claude-code]
provider-name = "Anthropic Claude Code CLI"
protocol = "anthropic-cli"
command = "claude"
is-non-interactive = true

[providers.claude-code.credentials]
type = "env"
key = "ANTHROPIC_API_KEY"

[providers.ollama]
provider-name = "Ollama Local"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.haiku]
api-name = "claude-haiku-4-5-20251001"
tools-support = true
max-context = 200000
streaming = true

[models.sonnet]
api-name = "claude-sonnet-4-6"
tools-support = true
max-context = 200000
thinking-support = true
max-thinking-budget = 16000
streaming = true

[models.qwen3-8b]
api-name = "qwen3:8b"
tools-support = true
max-context = 32768
streaming = true

[claude-code.haiku]
is-default = true
max-concurrent = 3
price-input = 0.80
price-output = 4.00

[claude-code.sonnet]
max-concurrent = 2
price-input = 3.00
price-output = 15.00

[claude-code.haiku.for-scoring]
max-input = 4096
max-output = 1024

[claude-code.haiku.for-governance]
max-input = 8192
temperature = 0.1

[ollama.qwen3-8b]
keep-alive = "5m"
num-ctx = 32768

[tier.rerank]
keeper-assignable = false
members = ["claude-code.haiku.for-scoring"]
strategy = "failover"

[tier.primary]
members = ["claude-code.sonnet", "claude-code.haiku"]
strategy = "failover"
max-concurrent = 5

[tier.local]
members = ["ollama.qwen3-8b"]
strategy = "failover"

[tier-group.primary]
tiers = ["primary", "local"]
strategy = "priority_tier"
fallback = true
keeper-assignable = true

[routes.default]
target = "tier-group.primary"

[system.governance]
target = "claude-code.haiku.for-governance"
|}
;;

(* --- Tests --- *)

let test_minimal_parse () =
  let cfg = ok_config (parse_string minimal_toml) in
  check int "providers" 1 (List.length cfg.providers);
  check int "models" 1 (List.length cfg.models);
  check int "bindings" 1 (List.length cfg.bindings);
  check int "aliases" 0 (List.length cfg.aliases);
  check int "tiers" 0 (List.length cfg.tiers);
  check int "tier_groups" 0 (List.length cfg.tier_groups);
  check int "routes" 0 (List.length cfg.routes);
  check int "system_targets" 0 (List.length cfg.system_targets)
;;

let test_layer1_providers () =
  let cfg = ok_config (parse_string full_toml) in
  check int "providers" 2 (List.length cfg.providers);
  let claude = provider_of_id cfg "claude-code" in
  check bool "claude exists" true (claude <> None);
  (match claude with
   | Some p ->
     check string "display_name" "Anthropic Claude Code CLI" p.display_name;
     check bool "non-interactive" true p.is_non_interactive;
     (match p.transport with
      | Cli cmd -> check string "cli cmd" "claude" cmd
      | Http _ -> failwith "expected Cli transport")
   | None -> ());
  let ollama = provider_of_id cfg "ollama" in
  check bool "ollama exists" true (ollama <> None);
  match ollama with
  | Some p ->
    check string "display_name" "Ollama Local" p.display_name;
    (match p.transport with
     | Http url -> check string "http url" "http://localhost:11434" url
     | Cli _ -> failwith "expected Http transport")
  | None -> ()
;;

let test_layer2_models () =
  let cfg = ok_config (parse_string full_toml) in
  check int "models" 3 (List.length cfg.models);
  (match model_of_id cfg "haiku" with
   | Some m ->
     check string "haiku api_name" "claude-haiku-4-5-20251001" m.api_name;
     check bool "haiku tools" true m.tools_support;
     check int "haiku max_context" 200000 m.max_context;
     check bool "haiku streaming" true m.streaming
   | None -> failwith "missing haiku");
  match model_of_id cfg "sonnet" with
  | Some m ->
    check bool "sonnet thinking" true m.thinking_support;
    check opt_int "sonnet thinking_budget" (Some 16000) m.max_thinking_budget
  | None -> failwith "missing sonnet"
;;

let test_layer3_bindings () =
  let cfg = ok_config (parse_string full_toml) in
  check int "bindings" 3 (List.length cfg.bindings);
  (match binding_of_key cfg "claude-code" "haiku" with
   | Some b ->
     check bool "is_default" true b.is_default;
     check int "max_concurrent" 3 b.max_concurrent;
     check opt_float "price_input" (Some 0.80) b.price_input;
     check opt_float "price_output" (Some 4.00) b.price_output
   | None -> failwith "missing default binding");
  match binding_of_key cfg "ollama" "qwen3-8b" with
  | Some b ->
    check opt_string "keep_alive" (Some "5m") b.keep_alive;
    check opt_int "num_ctx" (Some 32768) b.num_ctx
  | None -> failwith "missing ollama binding"
;;

let test_layer4_aliases () =
  let cfg = ok_config (parse_string full_toml) in
  check int "aliases" 2 (List.length cfg.aliases);
  (match alias_of_key cfg "claude-code" "haiku" "for-scoring" with
   | Some a ->
     check opt_int "max_input" (Some 4096) a.max_input;
     check opt_int "max_output" (Some 1024) a.max_output
   | None -> failwith "missing rerank alias");
  match alias_of_key cfg "claude-code" "haiku" "for-governance" with
  | Some a ->
    check opt_int "max_input" (Some 8192) a.max_input;
    check opt_float "temperature" (Some 0.1) a.temperature
  | None -> failwith "missing governance alias"
;;

let test_layer5_tiers () =
  let cfg = ok_config (parse_string full_toml) in
  check int "tiers" 3 (List.length cfg.tiers);
  (match List.find_opt (fun (t : cascade_tier) -> t.name = "rerank") cfg.tiers with
   | Some t ->
     check
       (list string)
       "rerank members"
       [ "claude-code.haiku.for-scoring" ]
       t.members;
     check (option bool) "rerank keeper_assignable" (Some false)
       t.keeper_assignable;
     check
       string
       "rerank strategy"
       "Cascade_declarative_types.Failover"
       (show_cascade_strategy t.strategy)
   | None -> failwith "missing rerank tier");
  match List.find_opt (fun (t : cascade_tier) -> t.name = "primary") cfg.tiers with
  | Some t ->
    check
      (list string)
      "primary members"
      [ "claude-code.sonnet"; "claude-code.haiku" ]
      t.members;
    check opt_int "primary max_concurrent" (Some 5) t.max_concurrent
  | None -> failwith "missing primary tier"
;;

let test_layer5_tier_groups () =
  let cfg = ok_config (parse_string full_toml) in
  check int "tier_groups" 1 (List.length cfg.tier_groups);
  match
    List.find_opt (fun (g : cascade_tier_group) -> g.name = "primary") cfg.tier_groups
  with
  | Some g ->
    check (list string) "tiers" [ "primary"; "local" ] g.tiers;
    check bool "fallback" true g.fallback;
    check (option bool) "keeper_assignable" (Some true) g.keeper_assignable;
    check
      string
      "strategy"
      "Cascade_declarative_types.Priority_tier"
      (show_cascade_strategy g.strategy)
  | None -> failwith "missing primary tier group"
;;

let test_routes () =
  let cfg = ok_config (parse_string full_toml) in
  check int "routes" 1 (List.length cfg.routes);
  match List.find_opt (fun (r : cascade_route) -> r.name = "default") cfg.routes with
  | Some r -> check string "route target" "tier-group.primary" r.target
  | None -> failwith "missing default route"
;;

let test_system_targets () =
  let cfg = ok_config (parse_string full_toml) in
  check int "system_targets" 1 (List.length cfg.system_targets);
  match
    List.find_opt (fun (r : cascade_route) -> r.name = "governance") cfg.system_targets
  with
  | Some r -> check string "target" "claude-code.haiku.for-governance" r.target
  | None -> failwith "missing governance system target"
;;

let test_credentials () =
  let cfg = ok_config (parse_string full_toml) in
  match provider_of_id cfg "claude-code" with
  | Some p ->
    (match p.credentials with
     | Some (Env key) -> check string "env key" "ANTHROPIC_API_KEY" key
     | _ -> failwith "expected Env credential")
  | None -> failwith "missing claude provider"
;;

(* --- Error cases --- *)

let test_unknown_protocol () =
  let toml =
    {|
[providers.bad]
protocol = "unknown-protocol"
command = "bad-cmd"
|}
  in
  let errs = is_error (parse_string toml) in
  has_error_at "providers.bad.protocol" errs
;;

let test_missing_transport () =
  let toml =
    {|
[providers.no-transport]
protocol = "anthropic-cli"
|}
  in
  let errs = is_error (parse_string toml) in
  has_error_at "providers.no-transport" errs
;;

let test_both_transport () =
  let toml =
    {|
[providers.both]
protocol = "anthropic-cli"
endpoint = "http://example.com"
command = "cmd"
|}
  in
  let errs = is_error (parse_string toml) in
  has_error_at "providers.both" errs
;;

let test_missing_max_context () =
  let toml =
    {|
[models.bad-model]
tools-support = true
|}
  in
  let errs = is_error (parse_string toml) in
  has_error_at "models.bad-model.max-context" errs
;;

let test_unknown_strategy () =
  let toml =
    {|
[tier.bad-strategy]
members = ["x"]
strategy = "nonexistent_strategy"
|}
  in
  let errs = is_error (parse_string toml) in
  has_error_at "tier.bad-strategy.strategy" errs
;;

let test_invalid_toml_syntax () =
  let toml = "this is not valid toml [[[" in
  let errs = is_error (parse_string toml) in
  has_error_at "<parse>" errs
;;

let test_empty_toml () =
  let cfg = ok_config (parse_string "") in
  check int "providers" 0 (List.length cfg.providers);
  check int "models" 0 (List.length cfg.models);
  check int "bindings" 0 (List.length cfg.bindings)
;;

(* Regression: top-level scalar/array entries must not be treated as
   provider-alias tables.  Without the table filter in
   [parse_bindings_and_aliases], values such as [comment = "..."] crash
   [Otoml.get_table] inside [parse_provider_alias_table].  RFC-0058 §9.4. *)
let test_top_level_scalar_does_not_crash () =
  let toml =
    {|
comment = "edited in dashboard"

[providers.example]
protocol = "openai-http"
transport = "http"
endpoint = "https://example.com"

[models.example-model]
max-context = 4096

[example.example-model]
max-input = 4096
max-output = 1024
|}
  in
  let cfg = ok_config (parse_string toml) in
  check int "providers" 1 (List.length cfg.providers);
  check int "models" 1 (List.length cfg.models);
  check int "bindings" 1 (List.length cfg.bindings)
;;

(* Companion: top-level array entries must also be filtered out without
   crashing.  [Otoml.get_table] on a [TomlArray] would type-error. *)
let test_top_level_array_does_not_crash () =
  let toml =
    {|
tags = ["a", "b"]

[providers.example]
protocol = "openai-http"
transport = "http"
endpoint = "https://example.com"

[models.example-model]
max-context = 4096

[example.example-model]
max-input = 4096
max-output = 1024
|}
  in
  let cfg = ok_config (parse_string toml) in
  check int "providers" 1 (List.length cfg.providers);
  check int "models" 1 (List.length cfg.models);
  check int "bindings" 1 (List.length cfg.bindings)
;;

let test_lookup_helpers () =
  let cfg = ok_config (parse_string full_toml) in
  check bool "provider_of_id found" true (provider_of_id cfg "claude-code" <> None);
  check bool "model_of_id found" true (model_of_id cfg "haiku" <> None);
  check bool "binding_of_key found" true (binding_of_key cfg "claude-code" "haiku" <> None);
  check
    bool
    "alias_of_key found"
    true
    (alias_of_key cfg "claude-code" "haiku" "for-scoring" <> None);
  check bool "provider_of_id missing" true (provider_of_id cfg "nonexistent" = None);
  check bool "model_of_id missing" true (model_of_id cfg "nonexistent" = None);
  check
    bool
    "binding_of_key missing"
    true
    (binding_of_key cfg "claude-code" "nonexistent" = None);
  check
    bool
    "alias_of_key missing"
    true
    (alias_of_key cfg "claude-code" "haiku" "nonexistent" = None)
;;

let test_key_formatters () =
  let cfg = ok_config (parse_string full_toml) in
  (match binding_of_key cfg "claude-code" "haiku" with
   | Some b -> check string "binding_key" "claude-code.haiku" (binding_key b)
   | None -> failwith "missing binding");
  match alias_of_key cfg "claude-code" "haiku" "for-scoring" with
  | Some a -> check string "alias_key" "claude-code.haiku.for-scoring" (alias_key a)
  | None -> failwith "missing alias"
;;

let test_api_format_of_protocol () =
  check
    bool
    "anthropic-cli"
    true
    (api_format_of_protocol "anthropic-cli" = Ok Messages_api);
  check
    bool
    "anthropic-http"
    true
    (api_format_of_protocol "anthropic-http" = Ok Messages_api);
  check
    bool
    "openai-http"
    true
    (api_format_of_protocol "openai-http" = Ok Chat_completions_api);
  check
    bool
    "google-cli"
    true
    (api_format_of_protocol "google-cli" = Ok Chat_completions_api);
  check bool "kimi-cli" true (api_format_of_protocol "kimi-cli" = Ok Chat_completions_api);
  check bool "ollama-http" true (api_format_of_protocol "ollama-http" = Ok Ollama_api);
  check bool "unknown" true (api_format_of_protocol "unknown" |> Result.is_error)
;;

let test_all_strategies_parse () =
  let strategies =
    [ "failover", Failover
    ; "capacity_aware", Capacity_aware
    ; "weighted_random", Weighted_random
    ; "circuit_breaker_cycling", Circuit_breaker_cycling
    ; "priority_tier", Priority_tier
    ; "sticky", Sticky
    ; "round_robin", Round_robin
    ]
  in
  List.iter
    (fun (name, expected) ->
       let toml =
         Printf.sprintf
           {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]

[tier.t]
members = ["p.m"]
strategy = "%s"
|}
           name
       in
       let cfg = ok_config (parse_string toml) in
       match cfg.tiers with
       | [ t ] ->
         check
           string
           (name ^ " strategy")
           (show_cascade_strategy expected)
           (show_cascade_strategy t.strategy)
       | _ -> failwith "expected exactly one tier")
    strategies
;;

(* --- Strategy-specific field tests --- *)

let test_cycle_policy () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]

[tier.t]
members = ["p.m"]
strategy = "circuit_breaker_cycling"
max-cycles = 3
backoff-base-ms = 500
backoff-cap-ms = 10000
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.tiers with
  | [ t ] ->
    (match t.cycle_policy with
     | Some cp ->
       check int "max_cycles" 3 cp.max_cycles;
       check int "backoff_base_ms" 500 cp.backoff_base_ms;
       check int "backoff_cap_ms" 10000 cp.backoff_cap_ms
     | None -> failwith "expected cycle_policy")
  | _ -> failwith "expected exactly one tier"
;;

let test_cycle_policy_absent () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]

[tier.t]
members = ["p.m"]
strategy = "failover"
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.tiers with
  | [ t ] -> check bool "no cycle_policy" true (t.cycle_policy = None)
  | _ -> failwith "expected exactly one tier"
;;

let test_cycle_policy_partial_ignored () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]

[tier.t]
members = ["p.m"]
strategy = "circuit_breaker_cycling"
max-cycles = 3
backoff-base-ms = 500
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.tiers with
  | [ t ] -> check bool "partial yields None" true (t.cycle_policy = None)
  | _ -> failwith "expected exactly one tier"
;;

let test_sticky_ttl_ms () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]

[tier.t]
members = ["p.m"]
strategy = "sticky"
sticky-ttl-ms = 600000
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.tiers with
  | [ t ] -> check opt_int "sticky_ttl_ms" (Some 600000) t.sticky_ttl_ms
  | _ -> failwith "expected exactly one tier"
;;

let test_sticky_ttl_ms_absent () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]

[tier.t]
members = ["p.m"]
strategy = "sticky"
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.tiers with
  | [ t ] -> check opt_int "no sticky_ttl_ms" None t.sticky_ttl_ms
  | _ -> failwith "expected exactly one tier"
;;

let test_scoring_params () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]

[tier.t]
members = ["p.m"]
strategy = "weighted_random"
latency-baseline-ms = 200.0
rate-limit-recency-window-s = 60.0
rate-limit-decay-base = 0.5
rate-limit-skip-after = 3
server-error-recency-window-s = 120.0
server-error-decay-base = 0.3
server-error-skip-after = 5
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.tiers with
  | [ t ] ->
    (match t.scoring_params with
     | Some sp ->
       check float_testable "latency_baseline" 200.0 sp.latency_baseline_ms;
       check float_testable "rl_recency" 60.0 sp.rate_limit_recency_window_s;
       check float_testable "rl_decay" 0.5 sp.rate_limit_decay_base;
       check int "rl_skip" 3 sp.rate_limit_skip_after;
       check float_testable "se_recency" 120.0 sp.server_error_recency_window_s;
       check float_testable "se_decay" 0.3 sp.server_error_decay_base;
       check int "se_skip" 5 sp.server_error_skip_after
     | None -> failwith "expected scoring_params")
  | _ -> failwith "expected exactly one tier"
;;

let test_scoring_params_partial_ignored () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]

[tier.t]
members = ["p.m"]
strategy = "weighted_random"
latency-baseline-ms = 200.0
rate-limit-recency-window-s = 60.0
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.tiers with
  | [ t ] -> check bool "partial scoring yields None" true (t.scoring_params = None)
  | _ -> failwith "expected exactly one tier"
;;

(* --- Capabilities tests (#14608 tool/event fields + RFC-0058 §2.4 Phase 5.1 dispatch fields) --- *)

let test_capabilities_present () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[providers.p.capabilities]
supports-inline-tools = true
supports-runtime-mcp-tools = true
supports-runtime-tool-events = false
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.providers with
  | [ p ] ->
    (match p.capabilities with
     | Some c ->
       check bool "inline tools" true c.supports_inline_tools;
       check bool "runtime mcp tools" true c.supports_runtime_mcp_tools;
       check bool "runtime tool events" false c.supports_runtime_tool_events;
       (* Unspecified field defaults to false *)
       check
         bool
         "runtime mcp http headers default false"
         false
         c.supports_runtime_mcp_http_headers
     | None -> failwith "expected capabilities to be parsed")
  | _ -> failwith "expected exactly one provider"
;;

let test_capabilities_absent () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.providers with
  | [ p ] ->
    check
      (option string)
      "no capabilities sub-table → None"
      None
      (Option.map show_cascade_capabilities p.capabilities)
  | _ -> failwith "expected exactly one provider"
;;

let test_capabilities_full () =
  (* All 9 fields (4 from #14608 + 5 from A.1) populated. *)
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[providers.p.capabilities]
supports-inline-tools = true
supports-runtime-mcp-tools = true
supports-runtime-tool-events = true
supports-runtime-mcp-http-headers = true
requires-per-keeper-bridging-for-bound-actor-tools = true
identity-runtime-mcp-header-keys = ["authorization", "x-masc-agent-name"]
argv-prompt-preflight = true
uses-anthropic-caching = true
max-turns-per-attempt = 30
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.providers with
  | [ p ] ->
    (match p.capabilities with
     | None -> failwith "expected capabilities record"
     | Some c ->
       check bool "supports_inline_tools" true c.supports_inline_tools;
       check bool "supports_runtime_mcp_tools" true c.supports_runtime_mcp_tools;
       check bool "supports_runtime_tool_events" true c.supports_runtime_tool_events;
       check
         bool
         "supports_runtime_mcp_http_headers"
         true
         c.supports_runtime_mcp_http_headers;
       check
         bool
         "requires_per_keeper_bridging"
         true
         c.requires_per_keeper_bridging_for_bound_actor_tools;
       check
         (list string)
         "identity_runtime_mcp_header_keys"
         [ "authorization"; "x-masc-agent-name" ]
         c.identity_runtime_mcp_header_keys;
       check bool "argv_prompt_preflight" true c.argv_prompt_preflight;
       check bool "uses_anthropic_caching" true c.uses_anthropic_caching;
       check (option int) "max_turns_per_attempt" (Some 30) c.max_turns_per_attempt)
  | _ -> failwith "expected exactly one provider"
;;

let test_capabilities_partial_defaults () =
  (* Only uses-anthropic-caching declared; the rest fall back to schema defaults. *)
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[providers.p.capabilities]
uses-anthropic-caching = true
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.providers with
  | [ p ] ->
    (match p.capabilities with
     | None -> failwith "expected capabilities record"
     | Some c ->
       check bool "uses_anthropic_caching set" true c.uses_anthropic_caching;
       check
         bool
         "supports_runtime_mcp_http_headers default false"
         false
         c.supports_runtime_mcp_http_headers;
       check
         (list string)
         "identity_runtime_mcp_header_keys default []"
         []
         c.identity_runtime_mcp_header_keys;
       check
         (option int)
         "max_turns_per_attempt default None"
         None
         c.max_turns_per_attempt)
  | _ -> failwith "expected exactly one provider"
;;

let test_capabilities_max_turns_zero_rejected () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[providers.p.capabilities]
max-turns-per-attempt = 0
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.providers with
  | [ p ] ->
    (match p.capabilities with
     | None -> failwith "expected capabilities record"
     | Some c ->
       check
         (option int)
         "non-positive max_turns_per_attempt ignored"
         None
         c.max_turns_per_attempt)
  | _ -> failwith "expected exactly one provider"
;;

let test_capabilities_max_turns_negative_rejected () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[providers.p.capabilities]
max-turns-per-attempt = -5
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.providers with
  | [ p ] ->
    (match p.capabilities with
     | None -> failwith "expected capabilities record"
     | Some c ->
       check
         (option int)
         "negative max_turns_per_attempt ignored"
         None
         c.max_turns_per_attempt)
  | _ -> failwith "expected exactly one provider"
;;

let test_headers_present () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-http"
endpoint = "https://api.anthropic.com"

[providers.p.headers]
anthropic-version = "2023-06-01"
anthropic-beta = "prompt-caching-2024-07-31"
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.providers with
  | [ p ] ->
    (match p.headers with
     | Some hs ->
       (* Sorted by key for determinism *)
       check
         (list (pair string string))
         "headers sorted"
         [ "anthropic-beta", "prompt-caching-2024-07-31"
         ; "anthropic-version", "2023-06-01"
         ]
         hs
     | None -> failwith "expected headers to be parsed")
  | _ -> failwith "expected exactly one provider"
;;

let test_headers_absent () =
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.providers with
  | [ p ] -> check bool "no headers sub-table → None" true (p.headers = None)
  | _ -> failwith "expected exactly one provider"
;;

let test_headers_declared_but_empty () =
  (* [providers.p.headers] declared but contains zero entries.
     Must distinguish from "absent": result is Some [], not None. *)
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[providers.p.headers]
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.providers with
  | [ p ] ->
    check
      (option (list (pair string string)))
      "declared but empty → Some []"
      (Some [])
      p.headers
  | _ -> failwith "expected exactly one provider"
;;

(* --- Model capabilities (M1 prep — RFC-0058 Phase 5.3 Model axis) --- *)

let test_model_capabilities_present () =
  let toml =
    {|
[models.m]
max-context = 4096

[models.m.capabilities]
max-output-tokens = 8192
supports-parallel-tool-calls = true
supports-image-input = true
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.models with
  | [ m ] ->
    (match m.capabilities with
     | Some c ->
       check (option int) "max-output-tokens" (Some 8192) c.max_output_tokens;
       check bool "parallel tool calls" true c.supports_parallel_tool_calls;
       check bool "image input" true c.supports_image_input;
       check bool "native streaming default false" false c.supports_native_streaming;
       check bool "caching default false" false c.supports_caching;
       check
         bool
         "response_format json default false"
         false
         c.supports_response_format_json
     | None -> failwith "expected model capabilities to be parsed")
  | _ -> failwith "expected exactly one model"
;;

let test_model_capabilities_absent () =
  let toml =
    {|
[models.m]
max-context = 4096
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.models with
  | [ m ] ->
    check
      (option string)
      "no capabilities sub-table → None"
      None
      (Option.map show_cascade_model_capabilities m.capabilities)
  | _ -> failwith "expected exactly one model"
;;

let test_model_capabilities_max_output_zero_rejected () =
  let toml =
    {|
[models.m]
max-context = 4096

[models.m.capabilities]
max-output-tokens = 0
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.models with
  | [ m ] ->
    (match m.capabilities with
     | Some c ->
       check (option int) "max-output-tokens=0 rejected → None" None c.max_output_tokens
     | None -> failwith "expected capabilities record")
  | _ -> failwith "expected exactly one model"
;;

let test_model_capabilities_for_id_lookup () =
  let toml =
    {|
[models.m]
max-context = 4096

[models.m.capabilities]
supports-caching = true
|}
  in
  let cfg = ok_config (parse_string toml) in
  match model_capabilities_for_id cfg "m" with
  | Some c -> check bool "supports caching via lookup" true c.supports_caching
  | None -> failwith "expected Some capabilities via model_capabilities_for_id"
;;

let test_model_capabilities_for_id_unknown () =
  let toml =
    {|
[models.m]
max-context = 4096
|}
  in
  let cfg = ok_config (parse_string toml) in
  check
    (option string)
    "unknown model id → None"
    None
    (Option.map
       show_cascade_model_capabilities
       (model_capabilities_for_id cfg "does-not-exist"))
;;

(* --- M1c: match_prefixes + longest-prefix-first lookup --- *)

let test_match_prefixes_parses () =
  let toml =
    {|
[models.sonnet-family]
api-name = "claude-sonnet-4-6"
max-context = 200000
match-prefixes = ["claude-sonnet-4", "claude-sonnet-3.5"]
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.models with
  | [ m ] ->
    check
      (list string)
      "match-prefixes parsed in order"
      [ "claude-sonnet-4"; "claude-sonnet-3.5" ]
      m.match_prefixes
  | _ -> failwith "expected exactly one model"
;;

let test_match_prefixes_absent_defaults_empty () =
  let toml =
    {|
[models.m]
max-context = 4096
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.models with
  | [ m ] -> check (list string) "match_prefixes default []" [] m.match_prefixes
  | _ -> failwith "expected exactly one model"
;;

let test_match_prefixes_empty_strings_dropped () =
  let toml =
    {|
[models.m]
api-name = "x"
max-context = 4096
match-prefixes = ["", "good-prefix", "  "]
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.models with
  | [ m ] ->
    check (list string) "blank entries filtered" [ "good-prefix" ] m.match_prefixes
  | _ -> failwith "expected exactly one model"
;;

let test_model_spec_for_api_name_exact () =
  (* Exact api_name match beats any prefix match. *)
  let toml =
    {|
[models.sonnet]
api-name = "claude-sonnet-4-6"
max-context = 200000

[models.sonnet-family]
api-name = "claude-sonnet-4-other"
max-context = 200000
match-prefixes = ["claude-sonnet-4"]
|}
  in
  let cfg = ok_config (parse_string toml) in
  match model_spec_for_api_name cfg "claude-sonnet-4-6" with
  | Some m -> check string "exact api_name wins" "sonnet" m.id
  | None -> failwith "expected exact-match resolution"
;;

let test_model_spec_for_api_name_longest_prefix () =
  (* When multiple prefixes match, longest wins (mirrors OAS if/elsif
     ordering: glm-5-turbo checked before glm-5 catchall). *)
  let toml =
    {|
[models.glm-5-turbo]
api-name = "glm-5-turbo"
max-context = 128000
match-prefixes = ["glm-5-turbo"]

[models.glm-5-family]
api-name = "glm-5-family-default"
max-context = 200000
match-prefixes = ["glm-5"]
|}
  in
  let cfg = ok_config (parse_string toml) in
  match model_spec_for_api_name cfg "glm-5-turbo-2026" with
  | Some m -> check string "longer prefix wins" "glm-5-turbo" m.id
  | None -> failwith "expected longest-prefix resolution"
;;

let test_model_spec_for_api_name_no_match () =
  let toml =
    {|
[models.m]
api-name = "x"
max-context = 4096
match-prefixes = ["claude-"]
|}
  in
  let cfg = ok_config (parse_string toml) in
  check
    (option string)
    "no prefix or exact match → None"
    None
    (Option.map
       (fun (m : cascade_model_spec) -> m.id)
       (model_spec_for_api_name cfg "gpt-5"))
;;

let test_model_capabilities_for_api_name_via_prefix () =
  let toml =
    {|
[models.gpt-5-family]
api-name = "gpt-5-family-default"
max-context = 1050000
match-prefixes = ["gpt-5"]

[models.gpt-5-family.capabilities]
supports-parallel-tool-calls = true
supports-image-input = true
|}
  in
  let cfg = ok_config (parse_string toml) in
  match model_capabilities_for_api_name cfg "gpt-5.3-codex-spark" with
  | Some c ->
    check bool "parallel via prefix lookup" true c.supports_parallel_tool_calls;
    check bool "image via prefix lookup" true c.supports_image_input
  | None -> failwith "expected capabilities via prefix lookup"
;;

(* --- M1b: expanded schema fields (15 additions) --- *)

let test_model_capabilities_m1b_full () =
  (* Exercise all 15 fields added in M1b. Asserts each field is reachable
     via TOML and that defaults stay separate from declared-true values. *)
  let toml =
    {|
[models.m]
max-context = 4096

[models.m.capabilities]
supports-tool-choice = true
supports-extended-thinking = true
supports-reasoning-budget = true
thinking-control-format = "thinking-object"
supports-audio-input = true
supports-video-input = true
supports-multimodal-inputs = true
supports-structured-output = true
supports-prompt-caching = true
prompt-cache-alignment = 1024
supports-top-k = true
supports-min-p = true
supports-seed = true
emits-usage-tokens = false
supports-computer-use = true
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.models with
  | [ m ] ->
    (match m.capabilities with
     | Some c ->
       check bool "tool_choice" true c.supports_tool_choice;
       check bool "extended_thinking" true c.supports_extended_thinking;
       check bool "reasoning_budget" true c.supports_reasoning_budget;
       check
         string
         "thinking_control_format"
         "Cascade_declarative_types.Thinking_object"
         (show_cascade_thinking_control_format c.thinking_control_format);
       check bool "audio_input" true c.supports_audio_input;
       check bool "video_input" true c.supports_video_input;
       check bool "multimodal_inputs" true c.supports_multimodal_inputs;
       check bool "structured_output" true c.supports_structured_output;
       check bool "prompt_caching" true c.supports_prompt_caching;
       check (option int) "prompt_cache_alignment" (Some 1024) c.prompt_cache_alignment;
       check bool "top_k" true c.supports_top_k;
       check bool "min_p" true c.supports_min_p;
       check bool "seed" true c.supports_seed;
       (* Default-true field set explicitly to false here — the value
          difference confirms parse path honors caller-declared values. *)
       check bool "emits_usage_tokens declared false" false c.emits_usage_tokens;
       check bool "computer_use" true c.supports_computer_use
     | None -> failwith "expected capabilities record")
  | _ -> failwith "expected exactly one model"
;;

let test_model_capabilities_emits_usage_default_true () =
  (* emits_usage_tokens is the only default-true bool in the schema —
     mirrors OAS default_capabilities (most direct APIs emit usage; CLI
     wrappers explicitly opt out). Without an explicit declaration the
     parsed value must be true. *)
  let toml =
    {|
[models.m]
max-context = 4096

[models.m.capabilities]
supports-tool-choice = true
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.models with
  | [ m ] ->
    (match m.capabilities with
     | Some c ->
       check bool "emits_usage_tokens default true" true c.emits_usage_tokens;
       (* Defaults-false sanity check against drift *)
       check bool "audio_input default false" false c.supports_audio_input;
       check bool "computer_use default false" false c.supports_computer_use
     | None -> failwith "expected capabilities record")
  | _ -> failwith "expected exactly one model"
;;

let test_thinking_control_format_variants () =
  let qualified v = "Cascade_declarative_types." ^ v in
  let cases =
    [ "no-thinking-control", qualified "No_thinking_control"
    ; "thinking-object", qualified "Thinking_object"
    ; "chat-template-kwargs", qualified "Chat_template_kwargs"
    ; (* Unknown values warn + fall back to No_thinking_control. *)
      "garbage-value", qualified "No_thinking_control"
    ]
  in
  List.iter
    (fun (raw, expected) ->
       let toml =
         Printf.sprintf
           {|
[models.m]
max-context = 4096

[models.m.capabilities]
thinking-control-format = "%s"
|}
           raw
       in
       let cfg = ok_config (parse_string toml) in
       match cfg.models with
       | [ m ] ->
         (match m.capabilities with
          | Some c ->
            check
              string
              (Printf.sprintf "thinking-control-format=%S → %s" raw expected)
              expected
              (show_cascade_thinking_control_format c.thinking_control_format)
          | None -> failwith "expected capabilities record")
       | _ -> failwith "expected exactly one model")
    cases
;;

let test_prompt_cache_alignment_zero_rejected () =
  let toml =
    {|
[models.m]
max-context = 4096

[models.m.capabilities]
prompt-cache-alignment = 0
|}
  in
  let cfg = ok_config (parse_string toml) in
  match cfg.models with
  | [ m ] ->
    (match m.capabilities with
     | Some c ->
       check
         (option int)
         "prompt-cache-alignment=0 rejected → None"
         None
         c.prompt_cache_alignment
     | None -> failwith "expected capabilities record")
  | _ -> failwith "expected exactly one model"
;;

(* --- capabilities_for_provider_id lookup helper (Phase 5.1 A.3 prep) --- *)

let test_capabilities_for_provider_id_present () =
  (* Provider declares capabilities sub-table → lookup returns Some caps. *)
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[providers.p.capabilities]
requires-per-keeper-bridging-for-bound-actor-tools = true
|}
  in
  let cfg = ok_config (parse_string toml) in
  match capabilities_for_provider_id cfg "p" with
  | Some c ->
    check
      bool
      "requires per-keeper bridging"
      true
      c.requires_per_keeper_bridging_for_bound_actor_tools
  | None -> failwith "expected Some capabilities"
;;

let test_capabilities_for_provider_id_absent () =
  (* Provider exists but ships no capabilities sub-table → None. *)
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"
|}
  in
  let cfg = ok_config (parse_string toml) in
  check
    (option string)
    "provider without capabilities → None"
    None
    (Option.map show_cascade_capabilities (capabilities_for_provider_id cfg "p"))
;;

let test_capabilities_for_provider_id_unknown_provider () =
  (* Provider id not in cfg.providers → None.
     Collapsed with the "declared without caps" case by design — A.3
     callers treat both as "use defaults". *)
  let toml =
    {|
[providers.p]
protocol = "anthropic-cli"
command = "c"
|}
  in
  let cfg = ok_config (parse_string toml) in
  check
    (option string)
    "unknown provider id → None"
    None
    (Option.map
       show_cascade_capabilities
       (capabilities_for_provider_id cfg "does-not-exist"))
;;

(* --- Test suite --- *)

let () =
  run
    "RFC-0058 Declarative Parser"
    [ "minimal", [ test_case "minimal valid parse" `Quick test_minimal_parse ]
    ; ( "layer1_providers"
      , [ test_case "providers + transport" `Quick test_layer1_providers ] )
    ; "layer2_models", [ test_case "model specs" `Quick test_layer2_models ]
    ; "layer3_bindings", [ test_case "bindings" `Quick test_layer3_bindings ]
    ; "layer4_aliases", [ test_case "aliases" `Quick test_layer4_aliases ]
    ; ( "layer5_tiers"
      , [ test_case "tiers" `Quick test_layer5_tiers
        ; test_case "tier groups" `Quick test_layer5_tier_groups
        ] )
    ; ( "routes"
      , [ test_case "routes" `Quick test_routes
        ; test_case "system targets" `Quick test_system_targets
        ] )
    ; "credentials", [ test_case "env credential" `Quick test_credentials ]
    ; ( "errors"
      , [ test_case "unknown protocol" `Quick test_unknown_protocol
        ; test_case "missing transport" `Quick test_missing_transport
        ; test_case "both transports" `Quick test_both_transport
        ; test_case "missing max-context" `Quick test_missing_max_context
        ; test_case "unknown strategy" `Quick test_unknown_strategy
        ; test_case "invalid TOML syntax" `Quick test_invalid_toml_syntax
        ; test_case "empty TOML" `Quick test_empty_toml
        ; test_case
            "top-level scalar tolerated"
            `Quick
            test_top_level_scalar_does_not_crash
        ; test_case "top-level array tolerated" `Quick test_top_level_array_does_not_crash
        ] )
    ; ( "lookup"
      , [ test_case "lookup helpers" `Quick test_lookup_helpers
        ; test_case "key formatters" `Quick test_key_formatters
        ; test_case "api_format_of_protocol" `Quick test_api_format_of_protocol
        ] )
    ; ( "strategies"
      , [ test_case "all 7 strategies parse" `Quick test_all_strategies_parse ] )
    ; ( "cycle_policy"
      , [ test_case "parses all-or-nothing" `Quick test_cycle_policy
        ; test_case "absent yields None" `Quick test_cycle_policy_absent
        ; test_case "partial yields None" `Quick test_cycle_policy_partial_ignored
        ] )
    ; ( "sticky_ttl"
      , [ test_case "parses sticky-ttl-ms" `Quick test_sticky_ttl_ms
        ; test_case "absent yields None" `Quick test_sticky_ttl_ms_absent
        ] )
    ; ( "scoring_params"
      , [ test_case "parses all 7 fields" `Quick test_scoring_params
        ; test_case "partial yields None" `Quick test_scoring_params_partial_ignored
        ] )
    ; ( "capabilities"
      , [ test_case "present parses with defaults" `Quick test_capabilities_present
        ; test_case "absent yields None" `Quick test_capabilities_absent
        ; test_case "full parse (all 9 fields)" `Quick test_capabilities_full
        ; test_case "partial defaults" `Quick test_capabilities_partial_defaults
        ; test_case
            "max-turns 0 rejected"
            `Quick
            test_capabilities_max_turns_zero_rejected
        ; test_case
            "max-turns negative rejected"
            `Quick
            test_capabilities_max_turns_negative_rejected
        ] )
    ; ( "headers"
      , [ test_case "present sorted by key" `Quick test_headers_present
        ; test_case "absent yields None" `Quick test_headers_absent
        ; test_case
            "declared but empty yields Some []"
            `Quick
            test_headers_declared_but_empty
        ] )
    ; ( "capabilities_for_provider_id (A.3 prep)"
      , [ test_case
            "present provider with caps returns Some"
            `Quick
            test_capabilities_for_provider_id_present
        ; test_case
            "present provider without caps returns None"
            `Quick
            test_capabilities_for_provider_id_absent
        ; test_case
            "unknown provider id returns None"
            `Quick
            test_capabilities_for_provider_id_unknown_provider
        ] )
    ; ( "model_capabilities (M1b — Model axis prep, expanded)"
      , [ test_case
            "[models.<id>.capabilities] sub-table parses 6 fields"
            `Quick
            test_model_capabilities_present
        ; test_case "absent sub-table yields None" `Quick test_model_capabilities_absent
        ; test_case
            "max-output-tokens=0 rejected → None"
            `Quick
            test_model_capabilities_max_output_zero_rejected
        ; test_case
            "model_capabilities_for_id returns Some for declared"
            `Quick
            test_model_capabilities_for_id_lookup
        ; test_case
            "model_capabilities_for_id returns None for unknown"
            `Quick
            test_model_capabilities_for_id_unknown
        ; test_case
            "M1b expanded — all 15 added fields reachable + value differentiation"
            `Quick
            test_model_capabilities_m1b_full
        ; test_case
            "M1b expanded — emits_usage_tokens default-true (sole exception)"
            `Quick
            test_model_capabilities_emits_usage_default_true
        ; test_case
            "M1b expanded — thinking_control_format 4 variants (incl. fallback)"
            `Quick
            test_thinking_control_format_variants
        ; test_case
            "M1b expanded — prompt-cache-alignment=0 rejected → None"
            `Quick
            test_prompt_cache_alignment_zero_rejected
        ; test_case
            "M1c — match-prefixes parses sorted list"
            `Quick
            test_match_prefixes_parses
        ; test_case
            "M1c — match-prefixes absent defaults to []"
            `Quick
            test_match_prefixes_absent_defaults_empty
        ; test_case
            "M1c — match-prefixes empty/blank strings dropped"
            `Quick
            test_match_prefixes_empty_strings_dropped
        ; test_case
            "M1c — model_spec_for_api_name: exact api_name wins"
            `Quick
            test_model_spec_for_api_name_exact
        ; test_case
            "M1c — model_spec_for_api_name: longest prefix wins"
            `Quick
            test_model_spec_for_api_name_longest_prefix
        ; test_case
            "M1c — model_spec_for_api_name: no match → None"
            `Quick
            test_model_spec_for_api_name_no_match
        ; test_case
            "M1c — model_capabilities_for_api_name via prefix"
            `Quick
            test_model_capabilities_for_api_name_via_prefix
        ] )
    ]
;;
