(* A wrong-typed leaf in runtime.toml is an operator mistake, and the loader
   refuses it by key path: [Runtime_toml.parse_string] returns [Error] rows
   whose path names the leaf and whose message says which type the key
   takes. Every row below writes one wrong-typed leaf and checks the
   "<path>: <key> must be <kind>" prefix of that refusal. *)

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

(* Enough of a runtime.toml to load; each row replaces one leaf of it. The
   model id is the table key, so [models.m] is one model named "m" that
   [runtime.default] reaches as "p.m". *)
let config ~provider_lines ~model_lines =
  Printf.sprintf
    {|
[providers.p]
%s

[models.m]
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

(* What the operator wrote, and the "<path>: <key> must be <kind>" prefix
   the refusal has to carry. *)
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
    ; refusal_names = "providers.p.endpoint: endpoint must be a string"
    }
  ; { label = "providers.p.command = 1"
    ; toml =
        config
          ~provider_lines:"protocol = \"openai-compatible-http\"\ncommand = 1"
          ~model_lines:""
    ; refusal_names = "providers.p.command: command must be a string"
    }
  ; { label = "providers.p.protocol = 1"
    ; toml =
        config
          ~provider_lines:"protocol = 1\nendpoint = \"https://example.invalid/v1\""
          ~model_lines:""
    ; refusal_names = "providers.p.protocol: protocol must be a string"
    }
  ; provider_case
      "providers.p.display-name = 1"
      "display-name = 1"
      "providers.p.display-name: display-name must be a string"
  ; provider_case
      "providers.p.provider-name = 1"
      "provider-name = 1"
      "providers.p.provider-name: provider-name must be a string"
  ; provider_case
      "providers.p.is-non-interactive = \"yes\""
      "is-non-interactive = \"yes\""
      "providers.p.is-non-interactive: is-non-interactive must be a boolean"
  ; provider_case
      "providers.p.healthcheck.path = 1"
      "[providers.p.healthcheck]\npath = 1"
      "providers.p.healthcheck.path: path must be a string"
  ; provider_case
      "providers.p.credentials.type = 1"
      "[providers.p.credentials]\ntype = 1"
      "providers.p.credentials.type: type must be a string"
  ; provider_case
      "providers.p.capabilities.supports-inline-tools = 1"
      "[providers.p.capabilities]\nsupports-inline-tools = 1"
      "providers.p.capabilities.supports-inline-tools: supports-inline-tools must be a \
       boolean"
  ; model_case
      "models.m.api-name = 1"
      "api-name = 1"
      "models.m.api-name: api-name must be a string"
  ; model_case
      "models.m.model-name = 1"
      "model-name = 1"
      "models.m.model-name: model-name must be a string"
  ; model_case
      "models.m.tools-support = \"yes\""
      "tools-support = \"yes\""
      "models.m.tools-support: tools-support must be a boolean"
  ; model_case
      "models.m.thinking-support = \"yes\""
      "thinking-support = \"yes\""
      "models.m.thinking-support: thinking-support must be a boolean"
  ; model_case
      "models.m.preserve-thinking = 1"
      "preserve-thinking = 1"
      "models.m.preserve-thinking: preserve-thinking must be a boolean"
  ; model_case
      "models.m.max-thinking-budget = \"x\""
      "max-thinking-budget = \"x\""
      "models.m.max-thinking-budget: max-thinking-budget must be an integer"
  ; model_case
      "models.m.streaming = 1"
      "streaming = 1"
      "models.m.streaming: streaming must be a boolean"
  ; model_case
      "models.m.reasoning-effort = 1"
      "reasoning-effort = 1"
      "models.m.reasoning-effort: reasoning-effort must be a string"
  ; model_case
      "models.m.capabilities.supports-tool-choice = 1"
      "[models.m.capabilities]\nsupports-tool-choice = 1"
      "models.m.capabilities.supports-tool-choice: supports-tool-choice must be a boolean"
  ; model_case
      "models.m.capabilities.supports-reasoning-budget = 1"
      "[models.m.capabilities]\nsupports-reasoning-budget = 1"
      "models.m.capabilities.supports-reasoning-budget: supports-reasoning-budget must be \
       a boolean"
  ; model_case
      "models.m.capabilities.emits-usage-tokens = 1"
      "[models.m.capabilities]\nemits-usage-tokens = 1"
      "models.m.capabilities.emits-usage-tokens: emits-usage-tokens must be a boolean"
  ; model_case
      "models.m.capabilities.max-output-tokens = \"x\""
      "[models.m.capabilities]\nmax-output-tokens = \"x\""
      "models.m.capabilities.max-output-tokens: max-output-tokens must be an integer"
  ; { label = "exec.ssh.endpoints.e.host = 1"
    ; toml =
        config ~provider_lines:well_typed_provider ~model_lines:""
        ^ "\n[exec.ssh.endpoints.e]\nhost = 1\nuser = \"u\"\n"
    ; refusal_names = "exec.ssh.endpoints.e.host: host must be a string"
    }
  ; { label = "providers = 1"
    ; toml = "providers = 1\n\n[models.m]\n\n[runtime]\ndefault = \"p.m\"\n"
    ; refusal_names = "providers: [providers] must be a TOML table"
    }
  ; { label = "models = 1"
    ; toml =
        "models = 1\n\n[providers.p]\n" ^ well_typed_provider
        ^ "\n\n[runtime]\ndefault = \"p.m\"\n"
    ; refusal_names = "models: [models] must be a TOML table"
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
