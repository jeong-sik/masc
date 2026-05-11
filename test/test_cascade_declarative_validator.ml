(** RFC-0058 v2 cross-reference validator unit tests.

    Tests all 9 validation rules (R1-R9) on various TOML configs,
    including valid configs that produce zero errors and invalid configs
    that trigger specific rules. *)

open Alcotest
open Cascade_declarative_types
open Cascade_declarative_parser
open Cascade_declarative_validator

(* --- Helpers --- *)

let has_rule (rule : string) (errs : validation_error list) =
  check bool
    ("has rule " ^ rule)
    true
    (List.exists (fun e -> e.rule = rule) errs)

let has_rule_at (rule : string) (path : string) (errs : validation_error list) =
  check bool
    (Printf.sprintf "has rule %s at %s" rule path)
    true
    (List.exists (fun e -> e.rule = rule && e.path = path) errs)

let no_errors (errs : validation_error list) =
  check int "no errors" 0 (List.length errs)

let validate_toml (toml : string) : validation_error list =
  match parse_string toml with
  | Ok cfg -> validate cfg
  | Error (errs : parse_error list) ->
    failwith
      (Printf.sprintf "parse failed: %s"
         (String.concat "; "
            (List.map (fun (e : parse_error) ->
              Printf.sprintf "%s: %s" e.path e.message) errs)))

(* --- Valid config: 0 errors --- *)

let valid_toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[providers.ollama]
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.haiku]
max-context = 200000
tools-support = true

[models.sonnet]
max-context = 200000
tools-support = true

[models.qwen3-8b]
max-context = 32768
tools-support = true

[claude-code.haiku]
is-default = true
max-concurrent = 3

[claude-code.sonnet]
max-concurrent = 2

[claude-code.haiku.for-tool-rerank]
max-input = 4096

[ollama.qwen3-8b]
max-concurrent = 1

[tier.rerank]
members = ["claude-code.haiku.for-tool-rerank"]
strategy = "failover"

[tier.primary]
members = ["claude-code.sonnet", "claude-code.haiku"]
strategy = "failover"

[tier.local]
members = ["ollama.qwen3-8b"]
strategy = "failover"

[tier-group.big-three]
tiers = ["primary", "local"]
strategy = "priority_tier"

[routes.default]
target = "tier-group.big-three"

[system.governance]
target = "claude-code.haiku.for-tool-rerank"
|}

let test_valid_config () =
  let errs = validate_toml valid_toml in
  no_errors errs

(* --- R1: Binding → unknown provider --- *)

let test_r1_unknown_provider () =
  let toml = {|
[providers.good]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[bad-provider.haiku]
is-default = true
|} in
  let errs = validate_toml toml in
  has_rule_at "R1" "bad-provider.haiku" errs

(* --- R2: Binding → unknown model --- *)

let test_r2_unknown_model () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[claude-code.nonexistent-model]
is-default = true
|} in
  let errs = validate_toml toml in
  has_rule_at "R2" "claude-code.nonexistent-model" errs

(* --- R3: Alias → unknown binding --- *)
(* Parser synthesizes a parent binding when [p.m.a] exists without [p.m],
   so R3 only triggers if the synthesized binding's provider/model are invalid.
   Here we test a valid binding + alias that references a different, missing binding
   by constructing the config directly (bypassing parser synthesis). *)

let test_r3_unknown_binding () =
  let cfg = {
    Cascade_declarative_types.providers = [];
    models = [];
    bindings = [];
    aliases = [{
      Cascade_declarative_types.provider_id = "x";
      model_id = "y";
      name = "z";
      max_input = None;
      max_output = None;
      temperature = None;
      thinking_enabled = None;
      thinking_budget = None;
    }];
    tiers = [];
    tier_groups = [];
    routes = [];
    system_targets = [];
  } in
  let errs = Cascade_declarative_validator.validate cfg in
  has_rule "R3" errs

(* --- R4: Alias max-input > model max-context --- *)

let test_r4_max_input_exceeds () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 4096

[claude-code.haiku]
is-default = true

[claude-code.haiku.too-big]
max-input = 999999
|} in
  let errs = validate_toml toml in
  has_rule "R4" errs

let test_r4_max_input_ok () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[claude-code.haiku]
is-default = true
max-concurrent = 1

[claude-code.haiku.ok-alias]
max-input = 4096
|} in
  let errs = validate_toml toml in
  no_errors errs

(* --- R5: Tier member does not resolve --- *)

let test_r5_unknown_tier_member () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[claude-code.haiku]
is-default = true

[tier.bad-tier]
members = ["claude-code.haiku", "nonexistent.binding"]
strategy = "failover"
|} in
  let errs = validate_toml toml in
  has_rule "R5" errs

let test_r5_alias_member_ok () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[claude-code.haiku]
is-default = true
max-concurrent = 1

[claude-code.haiku.alias-a]
max-input = 4096

[tier.t]
members = ["claude-code.haiku.alias-a"]
strategy = "failover"
|} in
  let errs = validate_toml toml in
  no_errors errs

(* --- R6: Tier-group references unknown tier --- *)

let test_r6_unknown_tier () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[claude-code.haiku]
is-default = true

[tier.real]
members = ["claude-code.haiku"]
strategy = "failover"

[tier-group.broken]
tiers = ["real", "phantom"]
strategy = "failover"
|} in
  let errs = validate_toml toml in
  has_rule "R6" errs

(* --- R7: Route target does not resolve --- *)

let test_r7_unknown_route_target () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[claude-code.haiku]
is-default = true

[routes.dead-end]
target = "tier-group.nowhere"
|} in
  let errs = validate_toml toml in
  has_rule "R7" errs

let test_r7_route_to_binding () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[claude-code.haiku]
is-default = true
max-concurrent = 1

[routes.direct]
target = "claude-code.haiku"
|} in
  let errs = validate_toml toml in
  no_errors errs

let test_r7_route_to_tier () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[claude-code.haiku]
is-default = true
max-concurrent = 1

[tier.primary]
members = ["claude-code.haiku"]
strategy = "failover"

[routes.via-tier]
target = "tier.primary"
|} in
  let errs = validate_toml toml in
  no_errors errs

(* --- R8: System target does not resolve --- *)

let test_r8_unknown_system_target () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[claude-code.haiku]
is-default = true

[system.broken]
target = "nonexistent.binding"
|} in
  let errs = validate_toml toml in
  has_rule "R8" errs

let test_r8_system_to_alias () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[claude-code.haiku]
is-default = true
max-concurrent = 1

[claude-code.haiku.gov]
max-input = 8192

[system.governance]
target = "claude-code.haiku.gov"
|} in
  let errs = validate_toml toml in
  no_errors errs

(* --- R9: Multiple is-default per provider --- *)

let test_r9_multiple_defaults () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[models.sonnet]
max-context = 200000

[claude-code.haiku]
is-default = true

[claude-code.sonnet]
is-default = true
|} in
  let errs = validate_toml toml in
  has_rule "R9" errs

let test_r9_single_default_ok () =
  let toml = {|
[providers.claude-code]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[models.sonnet]
max-context = 200000

[claude-code.haiku]
is-default = true
max-concurrent = 1

[claude-code.sonnet]
max-concurrent = 1
|} in
  let errs = validate_toml toml in
  no_errors errs

(* --- Multiple errors at once --- *)

let test_multiple_errors () =
  let toml = {|
[providers.good]
protocol = "anthropic-cli"
command = "claude"

[models.haiku]
max-context = 200000

[bad-provider.haiku]
is-default = true

[claude-code.nonexistent]
is-default = true

[system.broken]
target = "no.such.binding"
|} in
  let errs = validate_toml toml in
  has_rule "R1" errs;
  has_rule "R2" errs;
  has_rule "R8" errs;
  check bool "multiple errors" true (List.length errs >= 3)

(* --- R10: Strategy-field consistency --- *)

let test_r10_cycle_policy_on_wrong_strategy () =
  let toml = {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]
max-concurrent = 1

[tier.t]
members = ["p.m"]
strategy = "failover"
max-cycles = 3
backoff-base-ms = 500
backoff-cap-ms = 10000
|} in
  let errs = validate_toml toml in
  has_rule_at "R10" "tier.t.cycle-policy" errs

let test_r10_cycle_policy_on_correct_strategy () =
  let toml = {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]
max-concurrent = 1

[tier.t]
members = ["p.m"]
strategy = "circuit_breaker_cycling"
max-cycles = 3
backoff-base-ms = 500
backoff-cap-ms = 10000
|} in
  let errs = validate_toml toml in
  no_errors errs

let test_r10_sticky_ttl_on_wrong_strategy () =
  let toml = {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]
max-concurrent = 1

[tier.t]
members = ["p.m"]
strategy = "failover"
sticky-ttl-ms = 600000
|} in
  let errs = validate_toml toml in
  has_rule_at "R10" "tier.t.sticky-ttl-ms" errs

let test_r10_sticky_ttl_on_correct_strategy () =
  let toml = {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]
max-concurrent = 1

[tier.t]
members = ["p.m"]
strategy = "sticky"
sticky-ttl-ms = 600000
|} in
  let errs = validate_toml toml in
  no_errors errs

let test_r10_scoring_on_wrong_strategy () =
  let toml = {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]
max-concurrent = 1

[tier.t]
members = ["p.m"]
strategy = "failover"
latency-baseline-ms = 200.0
rate-limit-recency-window-s = 60.0
rate-limit-decay-base = 0.5
rate-limit-skip-after = 3
server-error-recency-window-s = 120.0
server-error-decay-base = 0.3
server-error-skip-after = 5
|} in
  let errs = validate_toml toml in
  has_rule_at "R10" "tier.t.scoring-params" errs

let test_r10_scoring_on_correct_strategy () =
  let toml = {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]
max-concurrent = 1

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
  let errs = validate_toml toml in
  no_errors errs

let test_r10_no_strategy_fields_is_ok () =
  let toml = {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]
max-concurrent = 1

[tier.t]
members = ["p.m"]
strategy = "failover"
|} in
  let errs = validate_toml toml in
  no_errors errs

let test_r10_multiple_mismatches () =
  let toml = {|
[providers.p]
protocol = "anthropic-cli"
command = "c"

[models.m]
max-context = 4096

[p.m]
max-concurrent = 1

[tier.t]
members = ["p.m"]
strategy = "failover"
max-cycles = 3
backoff-base-ms = 500
backoff-cap-ms = 10000
sticky-ttl-ms = 600000
|} in
  let errs = validate_toml toml in
  has_rule "R10" errs;
  check bool "multiple R10 errors" true
    (List.length (List.filter (fun e -> e.rule = "R10") errs) >= 2)

(* --- Test suite --- *)

let () =
  run "RFC-0058 Declarative Validator"
    [ "valid", [
        test_case "full valid config" `Quick test_valid_config;
      ];
      "R1_binding_provider", [
        test_case "unknown provider" `Quick test_r1_unknown_provider;
      ];
      "R2_binding_model", [
        test_case "unknown model" `Quick test_r2_unknown_model;
      ];
      "R3_alias_binding", [
        test_case "unknown binding" `Quick test_r3_unknown_binding;
      ];
      "R4_alias_max_input", [
        test_case "max-input exceeds max-context" `Quick test_r4_max_input_exceeds;
        test_case "max-input within max-context" `Quick test_r4_max_input_ok;
      ];
      "R5_tier_members", [
        test_case "unknown tier member" `Quick test_r5_unknown_tier_member;
        test_case "alias as tier member" `Quick test_r5_alias_member_ok;
      ];
      "R6_tier_group_refs", [
        test_case "unknown tier in group" `Quick test_r6_unknown_tier;
      ];
      "R7_route_targets", [
        test_case "unknown route target" `Quick test_r7_unknown_route_target;
        test_case "route to binding" `Quick test_r7_route_to_binding;
        test_case "route to tier" `Quick test_r7_route_to_tier;
      ];
      "R8_system_targets", [
        test_case "unknown system target" `Quick test_r8_unknown_system_target;
        test_case "system to alias" `Quick test_r8_system_to_alias;
      ];
      "R9_single_default", [
        test_case "multiple defaults per provider" `Quick test_r9_multiple_defaults;
        test_case "single default ok" `Quick test_r9_single_default_ok;
      ];
      "multi", [
        test_case "multiple errors at once" `Quick test_multiple_errors;
      ];
      "R10_strategy_fields", [
        test_case "cycle_policy on wrong strategy" `Quick test_r10_cycle_policy_on_wrong_strategy;
        test_case "cycle_policy on correct strategy" `Quick test_r10_cycle_policy_on_correct_strategy;
        test_case "sticky_ttl on wrong strategy" `Quick test_r10_sticky_ttl_on_wrong_strategy;
        test_case "sticky_ttl on correct strategy" `Quick test_r10_sticky_ttl_on_correct_strategy;
        test_case "scoring on wrong strategy" `Quick test_r10_scoring_on_wrong_strategy;
        test_case "scoring on correct strategy" `Quick test_r10_scoring_on_correct_strategy;
        test_case "no strategy fields is ok" `Quick test_r10_no_strategy_fields_is_ok;
        test_case "multiple mismatches" `Quick test_r10_multiple_mismatches;
      ];
    ]
