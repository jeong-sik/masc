(** Model_spec — OAS-backed model identity and resolution.

    Types and parsing remain for MASC-specific alias resolution
    (Provider_adapter) and "default"/"default:override" forms.
    Metadata (URLs, API keys, context sizes, costs) is sourced
    from OAS Provider_registry and Pricing — single source of truth.

    @since 2.117.0 — original extraction from Cascade
    @since 2.123.0 — rewritten as OAS facade *)

open Printf

(* ================================================================ *)
(* Types                                                             *)
(* ================================================================ *)

type provider =
  | Llama
  | Claude
  | OpenAI
  | Gemini
  | Glm_cloud
  | OpenRouter
  | Custom of string

type model_spec = {
  provider : provider;
  model_id : string;
  max_context : int;
  api_url : string;
  api_key_env : string option;
  cost_per_1k_input : float;
  cost_per_1k_output : float;
}

(* ================================================================ *)
(* String conversion                                                 *)
(* ================================================================ *)

let string_of_provider = function
  | Llama -> "llama"
  | Claude -> "claude"
  | OpenAI -> "openai"
  | Gemini -> "gemini"
  | Glm_cloud -> "glm_cloud"
  | OpenRouter -> "openrouter"
  | Custom s -> sprintf "custom(%s)" s

(* ================================================================ *)
(* OAS Provider facade                                               *)
(* All OAS Llm_provider references are confined to this section.     *)
(* ================================================================ *)

let default_registry = Llm_provider.Provider_registry.default ()

(** Build a model_spec from OAS registry entry + pricing. *)
let make_of_entry
    (entry : Llm_provider.Provider_registry.entry)
    ~model_id ~provider : model_spec =
  let pricing = Llm_provider.Pricing.pricing_for_model model_id in
  let api_key_env =
    let e = entry.defaults.api_key_env in
    if e = "" then None else Some e
  in
  { provider;
    model_id;
    max_context = entry.max_context;
    api_url = entry.defaults.base_url;
    api_key_env;
    cost_per_1k_input = pricing.input_per_million /. 1000.0;
    cost_per_1k_output = pricing.output_per_million /. 1000.0 }

(** Build from registry name with fallback for unknown entries. *)
let make_of_registry ~registry_name ~model_id ~provider : model_spec =
  match Llm_provider.Provider_registry.find default_registry registry_name with
  | Some entry -> make_of_entry entry ~model_id ~provider
  | None ->
    let pricing = Llm_provider.Pricing.pricing_for_model model_id in
    { provider; model_id; max_context = 128_000;
      api_url = "http://127.0.0.1:8085";
      api_key_env = None;
      cost_per_1k_input = pricing.input_per_million /. 1000.0;
      cost_per_1k_output = pricing.output_per_million /. 1000.0 }

(* ================================================================ *)
(* Preset specs — sourced from OAS Provider_registry + Pricing       *)
(* ================================================================ *)

let llama_default =
  make_of_registry ~registry_name:"llama"
    ~model_id:Env_config.Llama.default_model ~provider:Llama

let claude_opus =
  let base = make_of_registry ~registry_name:"claude"
    ~model_id:Env_config.Claude.default_model ~provider:Claude in
  (* Opus pricing tier — use full wire model ID for lookup *)
  let pricing = Llm_provider.Pricing.pricing_for_model "claude-opus-4-6" in
  { base with
    cost_per_1k_input = pricing.input_per_million /. 1000.0;
    cost_per_1k_output = pricing.output_per_million /. 1000.0 }

let claude_sonnet =
  let pricing = Llm_provider.Pricing.pricing_for_model "claude-sonnet-4-6" in
  { claude_opus with
    cost_per_1k_input = pricing.input_per_million /. 1000.0;
    cost_per_1k_output = pricing.output_per_million /. 1000.0 }

let openai_default =
  make_of_registry ~registry_name:"openrouter"
    ~model_id:Env_config.OpenAI.default_model ~provider:OpenAI

let glm_cloud =
  make_of_registry ~registry_name:"glm"
    ~model_id:Env_config.Glm.default_model ~provider:Glm_cloud

let gemini_pro =
  make_of_registry ~registry_name:"gemini"
    ~model_id:Env_config.Gemini.default_model ~provider:Gemini

(* ================================================================ *)
(* OAS Cascade_config bridge                                         *)
(* Converts OAS Provider_config.t → MASC model_spec.                 *)
(* ================================================================ *)

(** Map OAS provider_kind to MASC provider enum.
    OAS provider_kind is coarser (Anthropic, OpenAI_compat, Gemini)
    so we use the registry name to disambiguate OpenAI_compat
    sub-families (Llama, OpenAI, Glm_cloud, OpenRouter). *)
let provider_of_oas ~(registry_name : string)
    ~(kind : Llm_provider.Provider_config.provider_kind) : provider =
  match kind with
  | Anthropic -> Claude
  | Gemini -> Gemini
  | Glm -> Glm_cloud
  | Claude_code -> Claude
  | OpenAI_compat -> (
      match registry_name with
      | "llama" -> Llama
      | "glm" -> Glm_cloud
      | "openrouter" -> OpenRouter
      | _ -> OpenAI)

(** Convert an OAS Provider_config.t + registry entry into a MASC model_spec.
    Uses the registry for max_context and api_key_env, and Pricing for costs. *)
let model_spec_of_provider_config ~(registry_name : string)
    (pc : Llm_provider.Provider_config.t) : model_spec =
  let provider = provider_of_oas ~registry_name ~kind:pc.kind in
  let entry = Llm_provider.Provider_registry.find default_registry registry_name in
  let max_context =
    match entry with Some e -> e.max_context | None -> 128_000
  in
  let api_key_env =
    match entry with
    | Some e when e.defaults.api_key_env <> "" -> Some e.defaults.api_key_env
    | _ -> None
  in
  let pricing = Llm_provider.Pricing.pricing_for_model pc.model_id in
  { provider;
    model_id = pc.model_id;
    max_context;
    api_url = pc.base_url;
    api_key_env;
    cost_per_1k_input = pricing.input_per_million /. 1000.0;
    cost_per_1k_output = pricing.output_per_million /. 1000.0 }

(** Map MASC Provider_adapter canonical names to OAS registry names.
    Returns None when no mapping exists (caller handles the error). *)
let oas_registry_name_of_canonical = function
  | "llama"      -> Some "llama"
  | "claude-api" -> Some "claude"
  | "gemini-api" -> Some "gemini"
  | "glm"        -> Some "glm"
  | "openrouter" -> Some "openrouter"
  | "codex-api"  -> Some "openrouter"
  | _            -> None

(* ================================================================ *)
(* Model spec parsing                                                *)
(* Delegates core provider:model parsing to OAS                      *)
(* Cascade_config.parse_model_string_exn, keeping MASC-specific      *)
(* alias resolution and model shortcut handling.                     *)
(* ================================================================ *)

(** Parse a provider:model string via OAS, with MASC alias and shortcut
    handling layered on top.  The flow is:
    1. Resolve MASC provider aliases (Provider_adapter) to canonical name
    2. Apply MASC model shortcuts (gemini:pro, claude:opus, glm:auto)
    3. Normalize canonical name → OAS registry name
    4. Delegate to OAS Cascade_config.parse_model_string_exn
    5. Convert Provider_config.t → model_spec *)
let parse_provider_model ~(original : string) ~(provider_str : string)
    ~(model_id : string) : (model_spec, string) result =
  (* Step 1: resolve MASC alias to canonical adapter name *)
  match Provider_adapter.resolve_direct_adapter provider_str with
  | Some adapter -> (
      (* Step 2: apply MASC model shortcuts *)
      match adapter.canonical_name with
      | "gemini-api" when model_id = "pro" -> Ok gemini_pro
      | "gemini-api" when model_id = "flash" ->
          let flash = Env_config_governance.Gemini.flash_model in
          Ok { gemini_pro with
               model_id = (if flash = "" then "flash" else flash) }
      | "claude-api" when model_id = "opus" -> Ok claude_opus
      | "claude-api" when model_id = "sonnet" -> Ok claude_sonnet
      | "glm" when model_id = "auto" ->
          Ok { glm_cloud with model_id = "" }
      | canonical -> (
          (* Step 3: map to OAS registry name *)
          match oas_registry_name_of_canonical canonical with
          | None ->
              Error (sprintf
                "Cannot parse model spec: %s (unsupported adapter '%s')"
                original provider_str)
          | Some registry_name ->
              (* Step 4: delegate to OAS *)
              let oas_label = sprintf "%s:%s" registry_name model_id in
              match
                Llm_provider.Cascade_config.parse_model_string_exn oas_label
              with
              | Error msg ->
                  Error (sprintf "Cannot parse model spec: %s (%s)"
                           original msg)
              | Ok pc ->
                  (* Step 5: convert back with MASC provider enum *)
                  Ok (model_spec_of_provider_config ~registry_name pc)))
  | None -> (
      (* No MASC adapter found — try custom or direct OAS parse *)
      match provider_str with
      | "custom" ->
          let oas_label = sprintf "custom:%s" model_id in
          (match
             Llm_provider.Cascade_config.parse_model_string_exn oas_label
           with
          | Error msg ->
              Error (sprintf "Cannot parse model spec: %s (%s)" original msg)
          | Ok pc ->
              let actual_model = pc.model_id in
              let api_url =
                if pc.base_url <> "" then pc.base_url
                else Env_config_runtime.Custom_model.default_server_url
              in
              let pricing =
                Llm_provider.Pricing.pricing_for_model actual_model
              in
              Ok { provider = Custom actual_model;
                   model_id = actual_model;
                   max_context = 128_000;
                   api_url;
                   api_key_env = None;
                   cost_per_1k_input = pricing.input_per_million /. 1000.0;
                   cost_per_1k_output = pricing.output_per_million /. 1000.0 })
      | _ ->
          Error (sprintf
            "Cannot parse model spec: %s (unsupported provider '%s'; \
             supported: llama, claude, gemini, glm, openrouter, custom)"
            original provider_str))

let rec model_spec_of_string s =
  let s = String.trim s in
  if String.equal (String.lowercase_ascii s) "default" then
    match Provider_adapter.default_model_label_result () with
    | Ok label -> model_spec_of_string label
    | Error _ as e -> e
  else if
    String.length s > 8
    && String.equal
         (String.lowercase_ascii (String.sub s 0 8))
         "default:"
  then
    let override_model =
      String.sub s 8 (String.length s - 8) |> String.trim
    in
    (match Provider_adapter.default_model_override_label_result override_model with
    | Ok label -> model_spec_of_string label
    | Error _ as e -> e)
  else
  match String.index_opt s ':' with
  | None ->
    Error
      (sprintf
         "Cannot parse model spec: %s (expected provider:model or default[:model])"
         s)
  | Some idx ->
    if idx = 0 || idx >= String.length s - 1 then
      Error
        (sprintf
           "Cannot parse model spec: %s (expected provider:model or default[:model])"
           s)
    else
      let provider_str = String.sub s 0 idx |> String.lowercase_ascii in
      let model_id =
        String.sub s (idx + 1) (String.length s - idx - 1)
        |> String.trim
      in
      if model_id = "" then
        Error
          (sprintf
             "Cannot parse model spec: %s (expected provider:model or default[:model])"
             s)
      else
        parse_provider_model ~original:s ~provider_str ~model_id

(* ================================================================ *)
(* Cascade config path resolution                                    *)
(* Shared between Model_spec and Oas_worker.                         *)
(* ================================================================ *)

(** Locate config/cascade.json via CWD or ME_ROOT.
    Returns [Some path] when the file exists on disk. *)
let cascade_config_path () : string option =
  let base dir name = Filename.concat (Filename.concat dir "config") name in
  let cwd = Sys.getcwd () in
  let me_root =
    Sys.getenv_opt "ME_ROOT"
    |> Option.value
         ~default:(Sys.getenv_opt "HOME" |> Option.value ~default:"/tmp")
  in
  let masc_root = Filename.concat me_root "workspace/yousleepwhen/masc-mcp" in
  let candidates =
    [ base cwd "cascade.json";
      base masc_root "cascade.json" ]
  in
  List.find_opt Sys.file_exists candidates

(* ================================================================ *)
(* Default model label helpers                                       *)
(* Delegates to OAS Cascade_config.resolve_model_strings when a      *)
(* cascade config file is available, falling back to                  *)
(* Provider_adapter env-driven label lists.                          *)
(* ================================================================ *)

let configured_default_model_label () =
  match Provider_adapter.configured_default_model_label_result () with
  | Ok label -> Some label
  | Error _ -> None

(** Resolve model labels via OAS Cascade_config when Eio runtime is active
    and cascade config file exists.  Falls back to [defaults] when called
    outside Eio (e.g. top-level module initialization in tests). *)
let resolve_cascade_labels ~name ~defaults =
  match cascade_config_path () with
  | None -> defaults
  | Some config_path -> (
      try
        Llm_provider.Cascade_config.resolve_model_strings
          ~config_path ~name ~defaults ()
      with
      | Eio.Cancel.Cancelled (Eio.Mutex.Poisoned _) -> defaults
      | Eio.Cancel.Cancelled _ as e -> raise e
      | Effect.Unhandled _ | Eio.Mutex.Poisoned _ -> defaults
      | _ ->
          (* Eio.Mutex requires Eio context; gracefully fall back when
             called during module init (before Eio.main). *)
          defaults)

let default_execution_model_labels () =
  resolve_cascade_labels ~name:"default"
    ~defaults:(Provider_adapter.preferred_execution_model_labels ())

let default_verifier_model_labels () =
  resolve_cascade_labels ~name:"verifier"
    ~defaults:(Provider_adapter.preferred_verifier_model_labels ())

(* ================================================================ *)
(* Available spec filtering                                          *)
(* ================================================================ *)

let available_model_specs_of_strings model_strs =
  model_strs
  |> List.filter_map (fun model_str ->
         match model_spec_of_string model_str with
         | Error err ->
             Log.ModelClient.warn "ignoring invalid model spec %s: %s"
               model_str err;
             None
         | Ok spec -> (
             match spec.api_key_env with
             | Some env_name ->
                 let value = Sys.getenv_opt env_name |> Option.value ~default:"" in
                 if String.trim value = "" then (
                   Log.ModelClient.debug "skipping %s: %s not set"
                     model_str env_name;
                   None)
                 else Some spec
             | None -> Some spec))

let first_available_model_spec labels =
  match available_model_specs_of_strings labels with
  | spec :: _ -> Ok spec
  | [] ->
      Error
        "No default model available. Set MASC_DEFAULT_CASCADE, \
         MASC_DEFAULT_PROVIDER/MASC_DEFAULT_MODEL, or provider credentials for the \
         preferred fallback chain, or pass an explicit model."

(* ================================================================ *)
(* Default model spec resolvers                                      *)
(* ================================================================ *)

let default_execution_model_spec () =
  first_available_model_spec (default_execution_model_labels ())

let default_verifier_model_spec () =
  first_available_model_spec (default_verifier_model_labels ())

let default_local_model_spec () =
  (* Resolution order (cascade-aware):
     1. Explicit user config (MASC_DEFAULT_CASCADE / MASC_DEFAULT_PROVIDER+MODEL)
     2. Cascade "default" profile from config/cascade.json (hot-reloadable)
     3. Env-driven execution chain (Provider_adapter)
     4. Hardcoded glm_cloud fallback *)
  match configured_default_model_label () with
  | Some label -> (
      match model_spec_of_string label with
      | Ok spec -> spec
      | Error _ -> (
          match default_execution_model_spec () with
          | Ok spec -> spec
          | Error _ -> glm_cloud))
  | None -> (
      match default_execution_model_spec () with
      | Ok spec -> spec
      | Error _ -> glm_cloud)

(* ================================================================ *)
(* Cascade config (OAS Provider facade)                              *)
(* ================================================================ *)

(** Load cascade profile from OAS config file.
    Returns model label strings (e.g. ["llama:qwen3.5"; "glm:glm-4.7"]). *)
let load_cascade_profile ~config_path ~name : string list =
  Llm_provider.Cascade_config.load_profile ~config_path ~name

(* ================================================================ *)
(* Convenience accessors — callers need scalar values, not model_spec *)
(* ================================================================ *)

let resolve_primary_spec labels =
  match available_model_specs_of_strings labels with
  | p :: _ -> p
  | [] -> default_local_model_spec ()

let resolve_primary_max_context labels =
  (resolve_primary_spec labels).max_context

let resolve_primary_model_id labels =
  (resolve_primary_spec labels).model_id

let find_model_id_for_used ~labels ~model_used =
  let specs = available_model_specs_of_strings labels in
  let used =
    if String.ends_with ~suffix:":latest" model_used then
      String.sub model_used 0 (String.length model_used - String.length ":latest")
    else model_used
  in
  match List.find_opt (fun (m : model_spec) ->
    m.model_id = model_used || m.model_id = used
  ) specs with
  | Some m -> m.model_id
  | None -> (resolve_primary_spec labels).model_id

let cost_usd_of_model_id ~model_id ~input_tokens ~output_tokens =
  let pricing = Llm_provider.Pricing.pricing_for_model model_id in
  Llm_provider.Pricing.estimate_cost ~pricing ~input_tokens ~output_tokens ()

(* ================================================================ *)
(* OAS Migration Bridge (Phase 1)                                    *)
(* Bidirectional conversion: Model_spec.model_spec <-> OAS types.    *)
(* Callers should migrate from Model_spec.model_spec to              *)
(* Llm_provider.Provider_config.t or Agent_sdk.Provider.config.      *)
(* ================================================================ *)

(** Map MASC provider enum to OAS provider_kind.
    Inverse of {!provider_of_oas}. Note that multiple MASC providers
    map to OpenAI_compat (Llama, OpenAI, OpenRouter, Custom).
    Glm_cloud maps to Glm (dedicated kind since OAS v0.83.0). *)
let provider_kind_of_masc : provider -> Llm_provider.Provider_config.provider_kind =
  function
  | Claude -> Anthropic
  | Gemini -> Gemini
  | Glm_cloud -> Glm
  | Llama | OpenAI | OpenRouter | Custom _ -> OpenAI_compat

(** Map MASC provider enum to OAS registry name.
    Used for Provider_registry lookups during conversion. *)
let registry_name_of_provider : provider -> string = function
  | Llama -> "llama"
  | Claude -> "claude"
  | Gemini -> "gemini"
  | Glm_cloud -> "glm"
  | OpenAI -> "openrouter"
  | OpenRouter -> "openrouter"
  | Custom _ -> "custom"

(** Convert a MASC model_spec to an OAS Provider_config.t.

    This is the forward migration path: callers holding a model_spec
    can obtain the OAS wire-level config for passing to
    Llm_provider.Complete.complete or Cascade_config functions.

    Fields not present in model_spec (temperature, top_p, etc.)
    use Provider_config.make defaults. *)
let to_provider_config (spec : model_spec) : Llm_provider.Provider_config.t =
  let kind = provider_kind_of_masc spec.provider in
  let api_key =
    match spec.api_key_env with
    | Some env_name ->
      Sys.getenv_opt env_name |> Option.value ~default:""
    | None -> ""
  in
  Llm_provider.Provider_config.make
    ~kind
    ~model_id:spec.model_id
    ~base_url:spec.api_url
    ~api_key
    ~request_path:(match kind with
      | Anthropic -> "/v1/messages"
      | Gemini -> "/v1beta/chat/completions"
      | Glm -> "/chat/completions"
      | OpenAI_compat -> "/v1/chat/completions"
      | Claude_code -> "")
    ()

(** Convert an OAS Provider_config.t back to a MASC model_spec.

    This is the backward-compat path: modules that still expect
    model_spec can receive one from OAS-native callers. The
    registry_name is required to disambiguate OpenAI_compat sub-families.

    Pricing and max_context are looked up from OAS registries. *)
let of_provider_config ?(registry_name : string option)
    (pc : Llm_provider.Provider_config.t) : model_spec =
  let rn = match registry_name with
    | Some n -> n
    | None -> (
        match pc.kind with
        | Anthropic -> "claude"
        | Gemini -> "gemini"
        | Glm -> "glm"
        | Claude_code -> "claude"
        | OpenAI_compat -> "openrouter")
  in
  model_spec_of_provider_config ~registry_name:rn pc

(** Extract pricing info from a model_spec as an OAS Pricing.pricing record.
    Avoids callers reaching into model_spec.cost_per_1k_* fields directly. *)
let pricing_of_spec (spec : model_spec) : Llm_provider.Pricing.pricing =
  Llm_provider.Pricing.pricing_for_model spec.model_id

(** Extract max_context from a model_spec.
    Callers should migrate to Provider_registry.entry.max_context
    or Capabilities.capabilities.max_context_tokens. *)
let max_context (spec : model_spec) : int = spec.max_context
