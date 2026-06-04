(** Sum-typed provider-kind resolver inside the runtime/OAS boundary.
    See .mli for the contract. *)

type resolution =
  | Registered of {
      provider_name : string;
      model_id : string;
      kind : Llm_provider.Provider_config.provider_kind;
    }
  | Custom_url of { model_id : string; base_url : string }
  | Unknown of string

let resolve (spec : string) : resolution =
  let s = String.trim spec in
  match Runtime_model_id_split.split_provider_model s with
  | None ->
    Unknown
      (Printf.sprintf
         "malformed spec %S: expected \"provider:model\" or \"custom:model@url\""
         spec)
  | Some ("custom", rest) ->
    let model_id, base_url = Runtime_model_resolve.parse_custom_model rest in
    if model_id = "" then
      Unknown
        (Printf.sprintf "malformed custom spec %S: empty model id" spec)
    else
      Custom_url { model_id; base_url }
  | Some (provider_name, model_id) ->
    (* Registry is the SSOT for pinned providers. We never override its
       [kind] from a substring of [provider_name] or [model_id]. *)
    let registry = Llm_provider.Provider_registry.default () in
    match Llm_provider.Provider_registry.find registry provider_name with
    | Some entry ->
      Registered
        {
          provider_name;
          model_id;
          kind = entry.defaults.kind;
        }
    | None ->
      Unknown
        (Printf.sprintf
           "unknown provider %S in spec %S; not found in Provider_registry"
           provider_name spec)

let kind_of_spec (spec : string) :
    Llm_provider.Provider_config.provider_kind option =
  match resolve spec with
  | Registered { kind; _ } -> Some kind
  | Custom_url _ -> Some Llm_provider.Provider_config.OpenAI_compat
  | Unknown _ -> None

let uses_anthropic_caching_for_kind kind =
  let cfg =
    Llm_provider.Provider_config.make ~kind ~model_id:"auto" ~base_url:"" ()
  in
  let caps =
    Agent_sdk.Provider_runtime_binding.capabilities_for_provider_config cfg
  in
  caps.supports_prompt_caching || caps.supports_caching

let uses_anthropic_caching_for_spec spec =
  kind_of_spec spec |> Option.map uses_anthropic_caching_for_kind
