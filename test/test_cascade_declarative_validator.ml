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
[providers.agent_llm_a-code]
protocol = "provider_a-cli"
command = "agent_llm_a"

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

[agent_llm_a-code.haiku]
is-default = true
max-concurrent = 3

[agent_llm_a-code.sonnet]
max-concurrent = 2

[agent_llm_a-code.haiku.for-scoring]
max-input = 4096

[ollama.qwen3-8b]
max-concurrent = 1

[profiles.primary]
provider_filter = "agent_llm_a-code"

[profiles.local]
provider_filter = "ollama"

[routes.keeper_turn]
target = "agent_llm_a-code.haiku"

[system.governance]
target = "agent_llm_a-code.haiku.for-scoring"
|}

let test_valid_config () =
  let errs = validate_toml valid_toml in
  no_errors errs

(* --- R1: Binding → unknown provider --- *)

let test_r1_unknown_provider () =
  let toml = {|
[providers.good]
protocol = "provider_a-cli"
command = "agent_llm_a"

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
[providers.agent_llm_a-code]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000

[agent_llm_a-code.nonexistent-model]
is-default = true
|} in
  let errs = validate_toml toml in
  has_rule_at "R2" "agent_llm_a-code.nonexistent-model" errs

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
    (* #19327: tier-group fields removed from cascade_config. *)
    routes = [];
    system_targets = [];
    profiles = [];
  } in
  let errs = Cascade_declarative_validator.validate cfg in
  has_rule "R3" errs

(* --- R4: Alias max-input > model max-context --- *)

let test_r4_max_input_exceeds () =
  let toml = {|
[providers.agent_llm_a-code]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 4096

[agent_llm_a-code.haiku]
is-default = true

[agent_llm_a-code.haiku.too-big]
max-input = 999999
|} in
  let errs = validate_toml toml in
  has_rule "R4" errs

let test_r4_max_input_ok () =
  let toml = {|
[providers.agent_llm_a-code]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000

[agent_llm_a-code.haiku]
is-default = true
max-concurrent = 1

[agent_llm_a-code.haiku.ok-alias]
max-input = 4096
|} in
  let errs = validate_toml toml in
  no_errors errs

(* --- R7: Route target does not resolve --- *)

let test_r7_unknown_route_target () =
  let toml = {|
[providers.agent_llm_a-code]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000

[agent_llm_a-code.haiku]
is-default = true

[routes.dead-end]
target = "cascade.nowhere"
|} in
  let errs = validate_toml toml in
  has_rule "R7" errs

let test_r7_route_to_binding () =
  let toml = {|
[providers.agent_llm_a-code]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000

[agent_llm_a-code.haiku]
is-default = true
max-concurrent = 1

[routes.direct]
target = "agent_llm_a-code.haiku"
|} in
  let errs = validate_toml toml in
  no_errors errs

(* --- R8: System target does not resolve --- *)

let test_r8_unknown_system_target () =
  let toml = {|
[providers.agent_llm_a-code]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000

[agent_llm_a-code.haiku]
is-default = true

[system.broken]
target = "nonexistent.binding"
|} in
  let errs = validate_toml toml in
  has_rule "R8" errs

let test_r8_system_to_alias () =
  let toml = {|
[providers.agent_llm_a-code]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000

[agent_llm_a-code.haiku]
is-default = true
max-concurrent = 1

[agent_llm_a-code.haiku.gov]
max-input = 8192

[system.governance]
target = "agent_llm_a-code.haiku.gov"
|} in
  let errs = validate_toml toml in
  no_errors errs

(* --- R9: Multiple is-default per provider --- *)

let test_r9_multiple_defaults () =
  let toml = {|
[providers.agent_llm_a-code]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000

[models.sonnet]
max-context = 200000

[agent_llm_a-code.haiku]
is-default = true

[agent_llm_a-code.sonnet]
is-default = true
|} in
  let errs = validate_toml toml in
  has_rule "R9" errs

let test_r9_single_default_ok () =
  let toml = {|
[providers.agent_llm_a-code]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000

[models.sonnet]
max-context = 200000

[agent_llm_a-code.haiku]
is-default = true
max-concurrent = 1

[agent_llm_a-code.sonnet]
max-concurrent = 1
|} in
  let errs = validate_toml toml in
  no_errors errs

(* --- Multiple errors at once --- *)

let test_multiple_errors () =
  let toml = {|
[providers.good]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000

[bad-provider.haiku]
is-default = true

[agent_llm_a-code.nonexistent]
is-default = true

[system.broken]
target = "no.such.binding"
|} in
  let errs = validate_toml toml in
  has_rule "R1" errs;
  has_rule "R2" errs;
  has_rule "R8" errs;
  check bool "multiple errors" true (List.length errs >= 3)

(* --- Test suite --- *)

(* --- R12: Protocol ↔ transport consistency --- *)

let test_r12_cli_protocol_with_cli_transport () =
  let toml = {|
[providers.agent_llm_a-code]
protocol = "provider_a-cli"
command = "agent_llm_a"

[models.haiku]
max-context = 200000

[agent_llm_a-code.haiku]
is-default = true
max-concurrent = 1
|} in
  let errs = validate_toml toml in
  check bool "no R12 errors" false
    (List.exists (fun (e : validation_error) -> e.rule = "R12") errs)

let test_r12_http_protocol_with_http_transport () =
  let toml = {|
[providers.ollama]
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen3]
max-context = 32768

[ollama.qwen3]
max-concurrent = 1
|} in
  let errs = validate_toml toml in
  check bool "no R12 errors" false
    (List.exists (fun (e : validation_error) -> e.rule = "R12") errs)

let test_r12_cli_protocol_with_http_transport () =
  let toml = {|
[providers.bad]
protocol = "provider_a-cli"
endpoint = "http://localhost:8080"

[models.m]
max-context = 4096

[bad.m]
max-concurrent = 1
|} in
  let errs = validate_toml toml in
  has_rule_at "R12" "providers.bad.protocol" errs

let test_r12_http_protocol_with_cli_transport () =
  let toml = {|
[providers.bad]
protocol = "provider_d-http"
command = "my-cli"

[models.m]
max-context = 4096

[bad.m]
max-concurrent = 1
|} in
  let errs = validate_toml toml in
  has_rule_at "R12" "providers.bad.protocol" errs

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
      "R7_route_targets", [
        test_case "unknown route target" `Quick test_r7_unknown_route_target;
        test_case "route to binding" `Quick test_r7_route_to_binding;
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
      "R12_protocol_transport", [
        test_case "cli protocol with cli transport ok" `Quick test_r12_cli_protocol_with_cli_transport;
        test_case "http protocol with http transport ok" `Quick test_r12_http_protocol_with_http_transport;
        test_case "cli protocol with http transport mismatch" `Quick test_r12_cli_protocol_with_http_transport;
        test_case "http protocol with cli transport mismatch" `Quick test_r12_http_protocol_with_cli_transport;
      ];
    ]
