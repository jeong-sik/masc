(* A wrong-typed leaf in runtime.toml is an operator mistake, and the loader
   has to refuse it by key path. Every row below used to let
   [Otoml.Type_error] out of [Runtime_toml.parse_toml]: [parse_file] catches
   only [Otoml.Parse_error] and [Sys_error], so boot, hot reload, the SSH lane
   and the egress lane died with the exception and no path in the message. *)

open Alcotest

let load_errors content =
  match Runtime_toml.parse_string content with
  | Error errors ->
    String.concat
      "; "
      (List.map
         (fun (e : Runtime_toml.parse_error) -> e.path ^ ": " ^ e.message)
         errors)
  | Ok _ -> failf "expected the config to be refused, it loaded"
;;

(* Enough of a runtime.toml to load; each row replaces one leaf of it. *)
let config ~provider_lines ~model_lines =
  Printf.sprintf
    {|
[providers.p]
%s

[models.p.m]
id = "m"
%s

[runtime]
default = "p.m"
|}
    provider_lines
    model_lines
;;

let well_typed_provider =
  {|protocol = "openai-compatible-http"
endpoint = "https://example.invalid/v1"|}
;;

(* What the operator wrote, and the key path the refusal has to name. *)
type case =
  { label : string
  ; toml : string
  ; refusal_names : string
  }

let provider_case label extra refusal_names =
  { label
  ; toml =
      config ~provider_lines:(well_typed_provider ^ "\n" ^ extra) ~model_lines:""
  ; refusal_names
  }
;;

let model_case label extra refusal_names =
  { label; toml = config ~provider_lines:well_typed_provider ~model_lines:extra; refusal_names }
;;

let cases =
  [ { label = "providers.p.endpoint = 1"
    ; toml =
        config
          ~provider_lines:"protocol = \"openai-compatible-http\"\nendpoint = 1"
          ~model_lines:""
    ; refusal_names = "providers.p.endpoint"
    }
  ; { label = "providers.p.command = 1"
    ; toml =
        config
          ~provider_lines:"protocol = \"openai-compatible-http\"\ncommand = 1"
          ~model_lines:""
    ; refusal_names = "providers.p.command"
    }
  ; { label = "providers.p.protocol = 1"
    ; toml =
        config
          ~provider_lines:"protocol = 1\nendpoint = \"https://example.invalid/v1\""
          ~model_lines:""
    ; refusal_names = "providers.p.protocol"
    }
  ; provider_case "providers.p.display-name = 1" "display-name = 1" "providers.p.display-name"
  ; provider_case
      "providers.p.provider-name = 1"
      "provider-name = 1"
      "providers.p.provider-name"
  ; provider_case
      "providers.p.is-non-interactive = \"yes\""
      "is-non-interactive = \"yes\""
      "providers.p.is-non-interactive"
  ; provider_case
      "providers.p.healthcheck.path = 1"
      "[providers.p.healthcheck]\npath = 1"
      "providers.p.healthcheck.path"
  ; provider_case
      "providers.p.credentials.type = 1"
      "[providers.p.credentials]\ntype = 1"
      "providers.p.credentials.type"
  ; provider_case
      "providers.p.capabilities.supports-inline-tools = 1"
      "[providers.p.capabilities]\nsupports-inline-tools = 1"
      "providers.p.capabilities.supports-inline-tools"
  ; model_case "models.p.m.api-name = 1" "api-name = 1" "models.p.m.api-name"
  ; model_case "models.p.m.model-name = 1" "model-name = 1" "models.p.m.model-name"
  ; model_case
      "models.p.m.tools-support = \"yes\""
      "tools-support = \"yes\""
      "models.p.m.tools-support"
  ; model_case
      "models.p.m.thinking-support = \"yes\""
      "thinking-support = \"yes\""
      "models.p.m.thinking-support"
  ; model_case
      "models.p.m.preserve-thinking = 1"
      "preserve-thinking = 1"
      "models.p.m.preserve-thinking"
  ; model_case
      "models.p.m.max-thinking-budget = \"x\""
      "max-thinking-budget = \"x\""
      "models.p.m.max-thinking-budget"
  ; model_case "models.p.m.streaming = 1" "streaming = 1" "models.p.m.streaming"
  ; model_case
      "models.p.m.reasoning-effort = 1"
      "reasoning-effort = 1"
      "models.p.m.reasoning-effort"
  ; model_case
      "models.p.m.capabilities.supports-tool-choice = 1"
      "[models.p.m.capabilities]\nsupports-tool-choice = 1"
      "models.p.m.capabilities.supports-tool-choice"
  ; model_case
      "models.p.m.capabilities.supports-reasoning-budget = 1"
      "[models.p.m.capabilities]\nsupports-reasoning-budget = 1"
      "models.p.m.capabilities.supports-reasoning-budget"
  ; model_case
      "models.p.m.capabilities.emits-usage-tokens = 1"
      "[models.p.m.capabilities]\nemits-usage-tokens = 1"
      "models.p.m.capabilities.emits-usage-tokens"
  ; model_case
      "models.p.m.capabilities.max-output-tokens = \"x\""
      "[models.p.m.capabilities]\nmax-output-tokens = \"x\""
      "models.p.m.capabilities.max-output-tokens"
  ; { label = "exec.ssh.endpoints.e.host = 1"
    ; toml =
        config ~provider_lines:well_typed_provider ~model_lines:""
        ^ "\n[exec.ssh.endpoints.e]\nhost = 1\nuser = \"u\"\n"
    ; refusal_names = "exec.ssh.endpoints.e.host"
    }
  ; { label = "providers = 1"
    ; toml = "providers = 1\n\n[models.p.m]\nid = \"m\"\n\n[runtime]\ndefault = \"p.m\"\n"
    ; refusal_names = "[providers] must be a TOML table"
    }
  ; { label = "models = 1"
    ; toml =
        "models = 1\n\n[providers.p]\n" ^ well_typed_provider
        ^ "\n\n[runtime]\ndefault = \"p.m\"\n"
    ; refusal_names = "[models] must be a TOML table"
    }
  ]
;;

let test_of_case { label; toml; refusal_names } =
  test_case label `Quick (fun () ->
    let errors = load_errors toml in
    check bool
      (Printf.sprintf "the refusal names %s (got: %s)" refusal_names errors)
      true
      (String_util.contains_substring errors refusal_names))
;;

let () =
  run
    "runtime_toml_wrong_typed_keys"
    [ "a wrong-typed leaf is a refusal that names the key", List.map test_of_case cases ]
;;
