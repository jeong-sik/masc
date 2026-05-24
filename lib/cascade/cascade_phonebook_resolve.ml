(** Phonebook Resolve — bridge from phonebook types to OAS runtime.

    Converts phonebook providers/models into [Llm_provider.Provider_config.t]
    so the existing transport layer can execute requests.

    This is the Phase 4 integration point: phonebook has typed data
    (endpoint, flavor, auth_env), OAS transport needs [Provider_config.t].
    No registry lookup — phonebook IS the registry. *)

open Cascade_phonebook_types

(* ── Provider_config construction ──────────────────────────────── *)

let provider_kind_of_flavor = function
  | Llama_cpp -> Llm_provider.Provider_config.Provider_d_compat
  | Ollama -> Llm_provider.Provider_config.Ollama
  | Vllm -> Llm_provider.Provider_config.Provider_d_compat
  | Openai -> Llm_provider.Provider_config.Provider_d_compat
  | Deep_seek -> Llm_provider.Provider_config.Provider_d_compat
  | Zai_glm -> Llm_provider.Provider_config.Provider_k
  | Qwen -> Llm_provider.Provider_config.Provider_h

let api_key_of_auth_env (auth_env : string option) : string =
  match auth_env with
  | None -> ""
  | Some env ->
    (match Sys.getenv_opt env with
     | Some v when v <> "" -> v
     | _ -> "")

let request_path_of_flavor (base_url : string) (flavor : cascade_server_flavor) : string =
  match flavor with
  | Ollama -> "/api/chat"
  | _ ->
    Cascade_config_provider_binding.normalize_openai_compat_request_path
      ~base_url
      ~request_path:Masc_network_defaults.openai_chat_completions_path

let provider_config_of_phonebook
    ?(temperature = Llm_provider.Constants.Inference.default_temperature)
    ?max_tokens
    (pb : cascade_phonebook)
    (model : cascade_phonebook_model)
  : Llm_provider.Provider_config.t option =
  match provider_of_model pb model with
  | None -> None
  | Some p ->
    let kind = provider_kind_of_flavor p.flavor in
    let base_url = p.endpoint in
    let request_path = request_path_of_flavor base_url p.flavor in
    let api_key = api_key_of_auth_env p.auth_env in
    let max_output =
      match model.capabilities.max_output_tokens with
      | Some n -> n
      | None -> pb.defaults.max_output_tokens
    in
    Some
      (Llm_provider.Provider_config.make
         ~kind
         ~model_id:model.model_id
         ~base_url
         ~request_path
         ~api_key
         ~temperature
         ~max_tokens:(Option.value max_tokens ~default:max_output)
         ())

(* ── Model string generation ──────────────────────────────────── *)

let model_string_of_phonebook_model (model : cascade_phonebook_model) : string =
  model.provider ^ ":" ^ model.model_id

(* ── Tier-group resolution ─────────────────────────────────────── *)

let resolve_provider_configs_for_task
    ?temperature
    ?max_tokens
    (pb : cascade_phonebook)
    (task : Cascade_routing_policy.task_use)
  : Llm_provider.Provider_config.t list =
  let models =
    Cascade_routing_policy.resolve_models_for_task
      pb
      Cascade_routing_policy.default_routing_policies
      task
  in
  List.filter_map
    (provider_config_of_phonebook ?temperature ?max_tokens pb)
    models

let resolve_model_strings_for_task
    (pb : cascade_phonebook)
    (task : Cascade_routing_policy.task_use)
  : string list =
  let models =
    Cascade_routing_policy.resolve_models_for_task
      pb
      Cascade_routing_policy.default_routing_policies
      task
  in
  List.map model_string_of_phonebook_model models
