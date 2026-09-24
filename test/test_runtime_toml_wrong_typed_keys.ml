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

let with_credentials usage_read =
  "[providers.p.credentials]\ntype = \"env\"\nkey = \"P_KEY\"\n\n" ^ usage_read
;;

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
  ; provider_case
      "providers.p.usage-read.shape = 1"
      (with_credentials "[providers.p.usage-read]\nshape = 1\nurl = \"https://example.invalid/usage\"")
      "providers.p.usage-read.shape: shape must be a string"
  ; provider_case
      "providers.p.usage-read.shape unknown"
      (with_credentials
         "[providers.p.usage-read]\nshape = \"openrouter\"\nurl = \"https://example.invalid/usage\"")
      "providers.p.usage-read.shape: unknown shape \"openrouter\" — expected one of \
       openrouter-key, zai-quota-limit, kimi-coding-usages, ollama-usage"
  ; provider_case
      "providers.p.usage-read.url http"
      (with_credentials
         "[providers.p.usage-read]\nshape = \"ollama-usage\"\nurl = \"http://example.invalid/usage\"")
      "providers.p.usage-read.url: url must be an absolute https:// URL"
  ; provider_case
      "providers.p.usage-read.url relative"
      (with_credentials "[providers.p.usage-read]\nshape = \"ollama-usage\"\nurl = \"/api/usage\"")
      "providers.p.usage-read.url: url must be an absolute https:// URL"
  ; provider_case
      "providers.p.usage-read.url missing"
      (with_credentials "[providers.p.usage-read]\nshape = \"ollama-usage\"")
      "providers.p.usage-read.url: missing required field 'url'"
  ; provider_case
      "providers.p.usage-read.url on another host"
      (with_credentials
         "[providers.p.usage-read]\nshape = \"ollama-usage\"\nurl = \"https://usage.example.test/usage\"")
      "providers.p.usage-read.url: url host \"usage.example.test\" must be the provider endpoint host \"example.invalid\""
  ; provider_case
      "providers.p.usage-read without credentials"
      "[providers.p.usage-read]\nshape = \"ollama-usage\"\nurl = \"https://example.invalid/usage\""
      "providers.p.usage-read: usage-read needs the provider's [credentials]"
  ; { label = "providers.p.usage-read on codex-app-server"
    ; toml =
        config
          ~provider_lines:
            "protocol = \"codex-app-server\"\ncommand = \"/usr/bin/true\"\n\
             is-non-interactive = true\n\
             [providers.p.usage-read]\nshape = \"ollama-usage\"\n\
             url = \"https://example.invalid/usage\""
          ~model_lines:""
    ; refusal_names =
        "providers.p.usage-read: usage-read is only for an API-key HTTP provider"
    }
  ; { label = "providers.p.usage-read on claude-code"
    ; toml =
        config
          ~provider_lines:
            "protocol = \"claude-code\"\ncommand = \"/usr/bin/true\"\n\
             is-non-interactive = true\n\
             [providers.p.usage-read]\nshape = \"ollama-usage\"\n\
             url = \"https://example.invalid/usage\""
          ~model_lines:""
    ; refusal_names =
        "providers.p.usage-read: usage-read is only for an API-key HTTP provider"
    }
  ; provider_case
      "providers.p.usage-read unknown key"
      (with_credentials
         "[providers.p.usage-read]\nshape = \"ollama-usage\"\nurl = \"https://example.invalid/usage\"\nmethod = \"GET\"")
      "providers.p.usage-read.method: unknown usage-read key \"method\""
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
      "models.m.streaming = 1"
      "streaming = 1"
      "models.m.streaming: streaming must be a boolean"
  ; model_case
      "models.m.reasoning-effort = 1"
      "reasoning-effort = 1"
      "models.m.reasoning-effort: reasoning-effort must be a string"
  ; model_case
      "models.m.reasoning-uncontrolled = 1"
      "reasoning-uncontrolled = 1"
      "models.m.reasoning-uncontrolled: reasoning-uncontrolled must be a boolean"
  ; model_case
      "models.m.capabilities.supports-tool-choice = 1"
      "[models.m.capabilities]\nsupports-tool-choice = 1"
      "models.m.capabilities.supports-tool-choice: supports-tool-choice must be a boolean"
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

(* A well-formed [usage-read] reaches the provider record as its variant. *)
let test_usage_read_parses_to_the_shape () =
  let toml =
    config
      ~provider_lines:
        (well_typed_provider ^ "\n"
         ^ with_credentials
             "[providers.p.usage-read]\nshape = \"zai-quota-limit\"\n\
              url = \"https://example.invalid/api/monitor/usage/quota/limit\"")
      ~model_lines:""
  in
  match Runtime_toml.parse_string toml with
  | Error errors ->
    failf
      "expected the config to load: %s"
      (String.concat "; " (List.map (fun (e : Runtime_toml.parse_error) -> e.message) errors))
  | Ok config ->
    let provider = List.find (fun (p : Runtime_schema.provider) -> p.id = "p") config.providers in
    check bool "usage_read" true
      (Option.equal
         Runtime_schema.equal_usage_read
         provider.usage_read
         (Some
            { Runtime_schema.shape = Zai_quota_limit
            ; url = "https://example.invalid/api/monitor/usage/quota/limit"
            }))
;;

let () =
  run
    "runtime_toml_wrong_typed_keys"
    [ "a wrong-typed leaf is a refusal that names the key", List.map test_of_case cases
    ; ( "usage-read"
      , [ test_case "a declared usage-read parses to its shape" `Quick
            test_usage_read_parses_to_the_shape
        ] )
    ]
;;
