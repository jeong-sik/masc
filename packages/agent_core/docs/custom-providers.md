# Custom Providers

OAS accepts third-party HTTP endpoints through the same exact
`Llm_provider.Provider_config.t` used by built-in provider kinds. Agent
execution does not consult a callback-based implementation registry and does
not choose a provider when `Agent.options.provider_config` is absent.

Use one of these paths:

1. Construct `Provider_config.t` directly when the embedding application
   already owns the endpoint and credential.
2. Declare connection and capability facts in a provider catalog, resolve one
   exact binding, then attach its required credential.

Both paths are single-provider. Retry, failover, and provider selection remain
caller-owned.

## Direct Exact Configuration

An OpenAI-compatible vLLM endpoint needs no provider-specific SDK registration:

```ocaml
open Agent_sdk

let provider_config =
  Llm_provider.Provider_config.make
    ~kind:OpenAI_compat
    ~provider_id:"vllm-local"
    ~model_id:"my-finetuned-model"
    ~base_url:"http://127.0.0.1:8000"
    ~request_path:"/v1/chat/completions"
    ()

let agent =
  Agent.create
    ~net
    ~config:(Types.default_config ~model:provider_config.model_id)
    ~options:{ Agent.default_options with provider_config = Some provider_config }
    ~tools:[]
    ()
```

For authenticated endpoints, obtain the credential at the application boundary
and pass it as `~api_key`. Missing credentials must stop configuration:

```ocaml
let anthropic_config () =
  match Sys.getenv_opt "ANTHROPIC_API_KEY" with
  | None | Some "" -> Error "ANTHROPIC_API_KEY is required"
  | Some api_key ->
      Ok
        (Llm_provider.Provider_config.make
           ~kind:Anthropic
           ~provider_id:"anthropic"
           ~model_id:"claude-sonnet-4-6"
           ~base_url:"https://api.anthropic.com"
           ~api_key
           ())
```

OAS never derives provider identity from the URL or model name.

## Catalog Binding

Prefer the provider catalog when endpoint, auth mode, and capabilities are
deployment data. See [`docs/provider-catalog.md`](provider-catalog.md) for the
closed JSON schema.

```json
{
  "schema_version": 1,
  "providers": [
    {
      "id": "vllm-local",
      "kind": "openai_compat",
      "base_url": "http://127.0.0.1:8000",
      "request_path": "/v1/chat/completions",
      "auth": {"type": "api_key_env", "env": "VLLM_API_KEY"},
      "default_model": "my-finetuned-model",
      "capabilities_base": "openai_chat",
      "capabilities": {
        "supports_tools": true,
        "supports_tool_choice": true
      }
    }
  ]
}
```

Load the file explicitly during bootstrap. Parse failure, unknown provider,
missing model, and missing credential are all errors:

```ocaml
open Agent_sdk

let ( let* ) = Result.bind

let credential_for_binding (binding : Provider_runtime_binding.t) =
  match binding.auth with
  | No_auth -> Ok ""
  | Api_key_env name | Setup_token_env name ->
      (match Sys.getenv_opt name with
       | Some value when value <> "" -> Ok value
       | None | Some "" -> Error (Printf.sprintf "%s is required" name))

let resolve_catalog_provider ~path ~provider_id ~model =
  let* catalog = Llm_provider.Provider_catalog.load_file path in
  Llm_provider.Provider_catalog.set_global catalog;
  let* binding =
    match Provider_runtime_binding.find_catalog provider_id with
    | Some binding -> Ok binding
    | None -> Error (Printf.sprintf "unknown catalog provider: %s" provider_id)
  in
  let* provider_config =
    Provider_runtime_binding.to_provider_config ~model binding
    |> Result.map_error Error.to_string
  in
  let* api_key = credential_for_binding binding in
  Ok
    { provider_config with
      api_key = Llm_provider.Secret.of_string api_key
    }
```

`Provider_runtime_binding.to_provider_config` preserves the catalog identity,
wire kind, endpoint, request path, model, context limit, and declared
capabilities. Credential material is attached separately so catalog metadata
never becomes a secret store.

## Failure Contract

- `Agent.options.provider_config = None` does not mean “local” or
  “Anthropic”; execution returns a configuration error.
- `Provider_runtime_binding.find_catalog` returning `None` is terminal for that
  selection. Do not fall back to a similarly named provider.
- A missing auth environment variable is terminal. Do not replace it with an
  empty token.
- Unknown models are not rewritten or expanded. Supply an exact model or a
  catalog `default_model`.
- Catalog parse errors reject the whole catalog; malformed rows are not
  skipped.

There is no custom response-parser callback on the Agent provider carrier.
Endpoints must implement one of the typed OAS wire kinds. A genuinely new wire
protocol belongs in a provider backend with an explicit typed contract, not in
a process-global callback registry.
