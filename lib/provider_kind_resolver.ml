(** Sum-typed provider-kind resolver. See .mli for the contract. *)

type resolution =
  | Registered of {
      provider_name : string;
      model_id : string;
      kind : Llm_provider.Provider_config.provider_kind;
    }
  | Custom_url of { model_id : string; base_url : string }
  | Unknown of string

(* Reuse the same split semantics as Cascade_config.split_provider_model
   so that both paths agree on what "provider:model" means. Duplicated
   here (rather than imported) to avoid a circular dependency between
   this module and Cascade_config, which delegates to us. *)
let split_provider_model (s : string) : (string * string) option =
  match String.index_opt s ':' with
  | None -> None
  | Some idx ->
    if idx = 0 || idx >= String.length s - 1 then None
    else
      let provider_name =
        String.sub s 0 idx |> String.trim |> String.lowercase_ascii
      in
      let model_id =
        String.sub s (idx + 1) (String.length s - idx - 1) |> String.trim
      in
      if model_id = "" then None else Some (provider_name, model_id)

let resolve_builtin_provider provider_name model_id =
  match provider_name with
  | "kimi" ->
    Some
      (Registered
         {
           provider_name;
           model_id;
           kind = Llm_provider.Provider_config.OpenAI_compat;
         })
  | _ -> None

let resolve (spec : string) : resolution =
  let s = String.trim spec in
  match split_provider_model s with
  | None ->
    Unknown
      (Printf.sprintf
         "malformed spec %S: expected \"provider:model\" or \"custom:model@url\""
         spec)
  | Some ("custom", rest) ->
    let model_id, base_url = Cascade_model_resolve.parse_custom_model rest in
    if model_id = "" then
      Unknown
        (Printf.sprintf "malformed custom spec %S: empty model id" spec)
    else
      Custom_url { model_id; base_url }
  | Some (provider_name, model_id) ->
    (match resolve_builtin_provider provider_name model_id with
     | Some resolution -> resolution
     | None ->
       (* Registry is the SSOT for pinned providers. We never override its
          [kind] from a substring of [provider_name] or [model_id].
          A small number of repo-local compatibility providers such as
          [kimi] are handled above until the pinned OAS registry exposes
          them first-class. *)
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
              provider_name spec))

let kind_of_spec (spec : string) :
    Llm_provider.Provider_config.provider_kind option =
  match resolve spec with
  | Registered { kind; _ } -> Some kind
  | Custom_url _ -> Some Llm_provider.Provider_config.OpenAI_compat
  | Unknown _ -> None
