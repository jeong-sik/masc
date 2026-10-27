(** Read-only runtime provider bindings. *)

module PC = Llm_provider.Provider_catalog
module PR = Llm_provider.Provider_registry
module PConfig = Llm_provider.Provider_config
module PD = Llm_provider.Provider_declarations

type provider_kind = PConfig.provider_kind
type capabilities = Llm_provider.Capabilities.capabilities

type auth =
  | No_auth
  | Api_key
  | Setup_token

type t =
  { id : string
  ; aliases : string list
  ; kind : provider_kind
  ; base_url : string
  ; request_path : string
  ; requires_api_key : bool
  ; auth : auth
  ; default_model : string option
  ; discovery_timeout_s : float option
  ; max_context : int option
  ; capabilities : capabilities
  ; available : bool
  ; credential_scope : string option
  ; declarations : PD.t
  }

let normalize value = String.trim value |> String.lowercase_ascii

let trim_non_empty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed
;;

let binding_of_declaration declarations (entry : PD.entry) =
  let auth = match entry.authentication with
    | PD.No_auth -> No_auth
    | Caller_api_key | Api_key_env _ -> Api_key
    | Setup_token_env _ -> Setup_token in
  { id=normalize entry.id;aliases=List.map normalize entry.aliases;kind=entry.kind;base_url=entry.base_url;
    request_path=entry.request_path;
    requires_api_key=PD.requires_api_key entry.authentication;auth;
    default_model=entry.default_model;discovery_timeout_s=entry.discovery_timeout_s;
    max_context=entry.max_context;
    capabilities=entry.capabilities;
    available=PR.authentication_available entry.authentication;
    credential_scope=entry.credential_scope;declarations }
;;

let all_from_declarations declarations =
  PD.entries declarations |> List.map (binding_of_declaration declarations)
  |> List.sort (fun a b -> String.compare a.id b.id)
;;

let find_in_declarations declarations label =
  PD.find declarations label |> Option.map (binding_of_declaration declarations)
;;

let all () = all_from_declarations (PD.current ())
let find label = find_in_declarations (PD.current ()) label

let find_catalog label =
  match PC.global () with
  | None -> None
  | Some providers ->
    (match PD.of_catalogs ~models:None ~providers:(Some providers) with
     | Ok declarations -> find_in_declarations declarations label
     | Error error -> raise (PD.Invalid_declarations error))
;;

let binding_for_provider_config (cfg : PConfig.t) = Option.bind cfg.provider_id find

let canonical_explicit_provider_id (cfg : PConfig.t) =
  match cfg.provider_id with
  | Some provider_id ->
    (match find provider_id with
     | Some binding -> Some binding.id
     | None -> Some (normalize provider_id))
  | None -> None
;;

let provider_id_of_provider_config cfg =
  match canonical_explicit_provider_id cfg with
  | Some provider_id -> provider_id
  | None -> PConfig.string_of_provider_kind cfg.kind
;;

let capabilities_for_provider_config config =
  fst (PConfig.resolve_request_capabilities config)
;;

let resolve_model binding ~requested_model =
  match Option.bind requested_model trim_non_empty with
  | Some model -> Ok model
  | None ->
    (match Option.bind binding.default_model trim_non_empty with
     | Some model -> Ok model
     | None ->
       Error
         (Error.Config
            (InvalidConfig
               { field = "model"
               ; detail =
                   Printf.sprintf
                     "provider %S requires an exact model or a catalog-declared \
                      default_model"
                     binding.id
               })))
;;

let to_provider_config ?model binding =
  Result.map
    (fun model_id ->
       let request_path = trim_non_empty binding.request_path in
       let max_context = binding.max_context in
       let policy = match PD.request_policy binding.declarations
           ~provider_id:binding.id ~model_id with
         | Some policy -> policy
         | None -> invalid_arg "runtime binding must belong to its admitted declarations" in
       PConfig.make
         ~kind:binding.kind
         ~provider_id:binding.id
         ~model_id
         ~base_url:binding.base_url
         ?request_path
         ?max_context
         ()
       |> PConfig.with_request_policy policy)
    (resolve_model binding ~requested_model:model)
;;
