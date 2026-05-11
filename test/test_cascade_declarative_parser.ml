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

let ok_config (result : (cascade_config, parse_error list) result) :
    cascade_config =
  match result with
  | Ok cfg -> cfg
  | Error errs ->
    let msg =
      List.map (fun e -> Printf.sprintf "%s: %s" e.path e.message) errs
      |> String.concat "; "
    in
    failwith ("expected Ok, got Error: " ^ msg)

let is_error (result : (cascade_config, parse_error list) result) :
    parse_error list =
  match result with
  | Ok _ ->
    failwith "expected Error, got Ok"
  | Error errs -> errs

let has_error_at (path : string) (errs : parse_error list) =
  check bool
    ("error at " ^ path)
    true
    (List.exists (fun e -> e.path = path) errs)

(* --- Minimal valid TOML --- *)

let minimal_toml = {|
[providers.test-provider]
protocol = "anthropic-cli"
command = "test-cmd"

[models.test-model]
max-context = 4096

[test-provider.test-model]
|}

let full_toml = {|
[providers.claude-code]
provider-name = "Anthropic Claude Code CLI"
protocol = "anthropic-cli"
command = "claude"
is-non-interactive = true

[providers.claude-code.credentials]
type = "env"
key = "ANTHROPIC_API_KEY"

[providers.claude-code.liveness]
class = "cloud_fast"

[providers.ollama]
provider-name = "Ollama Local"
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[providers.ollama.liveness]
class = "local_27b"

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

[claude-code.haiku.for-tool-rerank]
max-input = 4096
max-output = 1024

[claude-code.haiku.for-governance]
max-input = 8192
temperature = 0.1

[ollama.qwen3-8b]
keep-alive = "5m"
num-ctx = 32768

[tier.rerank]
members = ["claude-code.haiku.for-tool-rerank"]
strategy = "failover"

[tier.primary]
members = ["claude-code.sonnet", "claude-code.haiku"]
strategy = "failover"
max-concurrent = 5

[tier.local]
members = ["ollama.qwen3-8b"]
strategy = "failover"

[tier-group.big-three]
tiers = ["primary", "local"]
strategy = "priority_tier"
fallback = true

[routes.default]
target = "tier-group.big-three"

[system.governance]
target = "claude-code.haiku.for-governance"
|}

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

let test_layer1_providers () =
  let cfg = ok_config (parse_string full_toml) in
  check int "providers" 2 (List.length cfg.providers);
  let claude = provider_of_id cfg "claude-code" in
  check bool "claude exists" true (claude <> None);
  (match claude with
   | Some p ->
     check string "display_name" "Anthropic Claude Code CLI" p.display_name;
     check bool "non-interactive" true p.is_non_interactive;
     check (option string) "claude liveness" (Some "Cascade_declarative_types.Cloud_fast")
       (Option.map show_cascade_liveness_class p.liveness_class);
     (match p.transport with
      | Cli cmd -> check string "cli cmd" "claude" cmd
      | Http _ -> failwith "expected Cli transport")
   | None -> ());
  let ollama = provider_of_id cfg "ollama" in
  check bool "ollama exists" true (ollama <> None);
  (match ollama with
   | Some p ->
     check string "display_name" "Ollama Local" p.display_name;
     check (option string) "ollama liveness" (Some "Cascade_declarative_types.Local_27b")
       (Option.map show_cascade_liveness_class p.liveness_class);
     (match p.transport with
      | Http url -> check string "http url" "http://localhost:11434" url
      | Cli _ -> failwith "expected Http transport")
   | None -> ())

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
  (match model_of_id cfg "sonnet" with
   | Some m ->
     check bool "sonnet thinking" true m.thinking_support;
     check opt_int "sonnet thinking_budget" (Some 16000)
       m.max_thinking_budget
   | None -> failwith "missing sonnet")

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
  (match binding_of_key cfg "ollama" "qwen3-8b" with
   | Some b ->
     check opt_string "keep_alive" (Some "5m") b.keep_alive;
     check opt_int "num_ctx" (Some 32768) b.num_ctx
   | None -> failwith "missing ollama binding")

let test_layer4_aliases () =
  let cfg = ok_config (parse_string full_toml) in
  check int "aliases" 2 (List.length cfg.aliases);
  (match alias_of_key cfg "claude-code" "haiku" "for-tool-rerank" with
   | Some a ->
     check opt_int "max_input" (Some 4096) a.max_input;
     check opt_int "max_output" (Some 1024) a.max_output
   | None -> failwith "missing rerank alias");
  (match alias_of_key cfg "claude-code" "haiku" "for-governance" with
   | Some a ->
     check opt_int "max_input" (Some 8192) a.max_input;
     check opt_float "temperature" (Some 0.1) a.temperature
   | None -> failwith "missing governance alias")

let test_layer5_tiers () =
  let cfg = ok_config (parse_string full_toml) in
  check int "tiers" 3 (List.length cfg.tiers);
  (match List.find_opt (fun (t : cascade_tier) -> t.name = "rerank") cfg.tiers with
   | Some t ->
     check (list string) "rerank members"
       ["claude-code.haiku.for-tool-rerank"] t.members;
     check string "rerank strategy" "Cascade_declarative_types.Failover"
       (show_cascade_strategy t.strategy)
   | None -> failwith "missing rerank tier");
  (match List.find_opt (fun (t : cascade_tier) -> t.name = "primary") cfg.tiers with
   | Some t ->
     check (list string) "primary members"
       ["claude-code.sonnet"; "claude-code.haiku"] t.members;
     check opt_int "primary max_concurrent" (Some 5) t.max_concurrent
   | None -> failwith "missing primary tier")

let test_layer5_tier_groups () =
  let cfg = ok_config (parse_string full_toml) in
  check int "tier_groups" 1 (List.length cfg.tier_groups);
  (match List.find_opt (fun (g : cascade_tier_group) -> g.name = "big-three") cfg.tier_groups with
   | Some g ->
     check (list string) "tiers" ["primary"; "local"] g.tiers;
     check bool "fallback" true g.fallback;
     check string "strategy" "Cascade_declarative_types.Priority_tier"
       (show_cascade_strategy g.strategy)
   | None -> failwith "missing big-three tier group")

let test_routes () =
  let cfg = ok_config (parse_string full_toml) in
  check int "routes" 1 (List.length cfg.routes);
  (match List.find_opt (fun (r : cascade_route) -> r.name = "default") cfg.routes with
   | Some r ->
     check string "route target" "tier-group.big-three" r.target
   | None -> failwith "missing default route")

let test_system_targets () =
  let cfg = ok_config (parse_string full_toml) in
  check int "system_targets" 1 (List.length cfg.system_targets);
  (match List.find_opt (fun (r : cascade_route) -> r.name = "governance") cfg.system_targets with
   | Some r ->
     check string "target" "claude-code.haiku.for-governance" r.target
   | None -> failwith "missing governance system target")

let test_credentials () =
  let cfg = ok_config (parse_string full_toml) in
  (match provider_of_id cfg "claude-code" with
   | Some p ->
     (match p.credentials with
      | Some (Env key) -> check string "env key" "ANTHROPIC_API_KEY" key
      | _ -> failwith "expected Env credential")
   | None -> failwith "missing claude provider")

(* --- Error cases --- *)

let test_unknown_protocol () =
  let toml = {|
[providers.bad]
protocol = "unknown-protocol"
command = "bad-cmd"
|} in
  let errs = is_error (parse_string toml) in
  has_error_at "providers.bad.protocol" errs

let test_missing_transport () =
  let toml = {|
[providers.no-transport]
protocol = "anthropic-cli"
|} in
  let errs = is_error (parse_string toml) in
  has_error_at "providers.no-transport" errs

let test_both_transport () =
  let toml = {|
[providers.both]
protocol = "anthropic-cli"
endpoint = "http://example.com"
command = "cmd"
|} in
  let errs = is_error (parse_string toml) in
  has_error_at "providers.both" errs

let test_missing_max_context () =
  let toml = {|
[models.bad-model]
tools-support = true
|} in
  let errs = is_error (parse_string toml) in
  has_error_at "models.bad-model.max-context" errs

let test_unknown_strategy () =
  let toml = {|
[tier.bad-strategy]
members = ["x"]
strategy = "nonexistent_strategy"
|} in
  let errs = is_error (parse_string toml) in
  has_error_at "tier.bad-strategy.strategy" errs

let test_invalid_toml_syntax () =
  let toml = "this is not valid toml [[[" in
  let errs = is_error (parse_string toml) in
  has_error_at "<parse>" errs

let test_empty_toml () =
  let cfg = ok_config (parse_string "") in
  check int "providers" 0 (List.length cfg.providers);
  check int "models" 0 (List.length cfg.models);
  check int "bindings" 0 (List.length cfg.bindings)

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

let test_lookup_helpers () =
  let cfg = ok_config (parse_string full_toml) in
  check bool "provider_of_id found" true
    (provider_of_id cfg "claude-code" <> None);
  check bool "model_of_id found" true
    (model_of_id cfg "haiku" <> None);
  check bool "binding_of_key found" true
    (binding_of_key cfg "claude-code" "haiku" <> None);
  check bool "alias_of_key found" true
    (alias_of_key cfg "claude-code" "haiku" "for-tool-rerank" <> None);
  check bool "provider_of_id missing" true
    (provider_of_id cfg "nonexistent" = None);
  check bool "model_of_id missing" true
    (model_of_id cfg "nonexistent" = None);
  check bool "binding_of_key missing" true
    (binding_of_key cfg "claude-code" "nonexistent" = None);
  check bool "alias_of_key missing" true
    (alias_of_key cfg "claude-code" "haiku" "nonexistent" = None)

let test_key_formatters () =
  let cfg = ok_config (parse_string full_toml) in
  (match binding_of_key cfg "claude-code" "haiku" with
   | Some b ->
     check string "binding_key" "claude-code.haiku" (binding_key b)
   | None -> failwith "missing binding");
  (match alias_of_key cfg "claude-code" "haiku" "for-tool-rerank" with
   | Some a ->
     check string "alias_key" "claude-code.haiku.for-tool-rerank"
       (alias_key a)
   | None -> failwith "missing alias")

let test_api_format_of_protocol () =
  check bool "anthropic-cli" true
    (api_format_of_protocol "anthropic-cli" = Ok Messages_api);
  check bool "anthropic-http" true
    (api_format_of_protocol "anthropic-http" = Ok Messages_api);
  check bool "openai-http" true
    (api_format_of_protocol "openai-http" = Ok Chat_completions_api);
  check bool "google-cli" true
    (api_format_of_protocol "google-cli" = Ok Chat_completions_api);
  check bool "kimi-cli" true
    (api_format_of_protocol "kimi-cli" = Ok Chat_completions_api);
  check bool "ollama-http" true
    (api_format_of_protocol "ollama-http" = Ok Ollama_api);
  check bool "unknown" true
    (api_format_of_protocol "unknown" |> Result.is_error)

let test_all_strategies_parse () =
  let strategies =
    [ "failover", Failover;
      "capacity_aware", Capacity_aware;
      "weighted_random", Weighted_random;
      "circuit_breaker_cycling", Circuit_breaker_cycling;
      "priority_tier", Priority_tier;
      "sticky", Sticky;
      "round_robin", Round_robin;
    ]
  in
  List.iter (fun (name, expected) ->
    let toml = Printf.sprintf {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]

[tier.t]
members = ["p.m"]
strategy = "%s"
|} name in
    let cfg = ok_config (parse_string toml) in
    match cfg.tiers with
    | [ t ] ->
      check string
        (name ^ " strategy")
        (show_cascade_strategy expected)
        (show_cascade_strategy t.strategy)
    | _ -> failwith "expected exactly one tier")
    strategies

(* --- Strategy-specific field tests --- *)

let test_cycle_policy () =
  let toml = {|
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
|} in
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

let test_cycle_policy_absent () =
  let toml = {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]

[tier.t]
members = ["p.m"]
strategy = "failover"
|} in
  let cfg = ok_config (parse_string toml) in
  match cfg.tiers with
  | [ t ] ->
    check bool "no cycle_policy" true (t.cycle_policy = None)
  | _ -> failwith "expected exactly one tier"

let test_cycle_policy_partial_ignored () =
  let toml = {|
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
|} in
  let cfg = ok_config (parse_string toml) in
  match cfg.tiers with
  | [ t ] ->
    check bool "partial yields None" true (t.cycle_policy = None)
  | _ -> failwith "expected exactly one tier"

let test_sticky_ttl_ms () =
  let toml = {|
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
|} in
  let cfg = ok_config (parse_string toml) in
  match cfg.tiers with
  | [ t ] ->
    check opt_int "sticky_ttl_ms" (Some 600000) t.sticky_ttl_ms
  | _ -> failwith "expected exactly one tier"

let test_sticky_ttl_ms_absent () =
  let toml = {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]

[tier.t]
members = ["p.m"]
strategy = "sticky"
|} in
  let cfg = ok_config (parse_string toml) in
  match cfg.tiers with
  | [ t ] ->
    check opt_int "no sticky_ttl_ms" None t.sticky_ttl_ms
  | _ -> failwith "expected exactly one tier"

let test_scoring_params () =
  let toml = {|
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
|} in
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

let test_scoring_params_partial_ignored () =
  let toml = {|
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
|} in
  let cfg = ok_config (parse_string toml) in
  match cfg.tiers with
  | [ t ] ->
    check bool "partial scoring yields None" true (t.scoring_params = None)
  | _ -> failwith "expected exactly one tier"

(* --- Liveness class tests --- *)

let test_liveness_class_unknown () =
  let toml = {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[providers.p.liveness]
class = "nonexistent_class"
|} in
  let cfg = ok_config (parse_string toml) in
  match cfg.providers with
  | [ p ] ->
    check (option string) "unknown liveness yields None" None
      (Option.map show_cascade_liveness_class p.liveness_class)
  | _ -> failwith "expected exactly one provider"

let test_liveness_class_absent () =
  let toml = {|
[providers.p]
protocol = "anthropic-cli"
command = "c"
|} in
  let cfg = ok_config (parse_string toml) in
  match cfg.providers with
  | [ p ] ->
    check (option string) "no liveness sub-table → None" None
      (Option.map show_cascade_liveness_class p.liveness_class)
  | _ -> failwith "expected exactly one provider"

(* --- Test suite --- *)

let () =
  run "RFC-0058 Declarative Parser"
    [ "minimal", [
        test_case "minimal valid parse" `Quick test_minimal_parse;
      ];
      "layer1_providers", [
        test_case "providers + transport" `Quick test_layer1_providers;
      ];
      "layer2_models", [
        test_case "model specs" `Quick test_layer2_models;
      ];
      "layer3_bindings", [
        test_case "bindings" `Quick test_layer3_bindings;
      ];
      "layer4_aliases", [
        test_case "aliases" `Quick test_layer4_aliases;
      ];
      "layer5_tiers", [
        test_case "tiers" `Quick test_layer5_tiers;
        test_case "tier groups" `Quick test_layer5_tier_groups;
      ];
      "routes", [
        test_case "routes" `Quick test_routes;
        test_case "system targets" `Quick test_system_targets;
      ];
      "credentials", [
        test_case "env credential" `Quick test_credentials;
      ];
      "errors", [
        test_case "unknown protocol" `Quick test_unknown_protocol;
        test_case "missing transport" `Quick test_missing_transport;
        test_case "both transports" `Quick test_both_transport;
        test_case "missing max-context" `Quick test_missing_max_context;
        test_case "unknown strategy" `Quick test_unknown_strategy;
        test_case "invalid TOML syntax" `Quick test_invalid_toml_syntax;
        test_case "empty TOML" `Quick test_empty_toml;
        test_case "top-level scalar tolerated" `Quick
          test_top_level_scalar_does_not_crash;
        test_case "top-level array tolerated" `Quick
          test_top_level_array_does_not_crash;
      ];
      "lookup", [
        test_case "lookup helpers" `Quick test_lookup_helpers;
        test_case "key formatters" `Quick test_key_formatters;
        test_case "api_format_of_protocol" `Quick test_api_format_of_protocol;
      ];
      "strategies", [
        test_case "all 7 strategies parse" `Quick test_all_strategies_parse;
      ];
      "cycle_policy", [
        test_case "parses all-or-nothing" `Quick test_cycle_policy;
        test_case "absent yields None" `Quick test_cycle_policy_absent;
        test_case "partial yields None" `Quick test_cycle_policy_partial_ignored;
      ];
      "sticky_ttl", [
        test_case "parses sticky-ttl-ms" `Quick test_sticky_ttl_ms;
        test_case "absent yields None" `Quick test_sticky_ttl_ms_absent;
      ];
      "scoring_params", [
        test_case "parses all 7 fields" `Quick test_scoring_params;
        test_case "partial yields None" `Quick test_scoring_params_partial_ignored;
      ];
      "liveness_class", [
        test_case "unknown value yields None" `Quick test_liveness_class_unknown;
        test_case "absent yields None" `Quick test_liveness_class_absent;
      ];
    ]
