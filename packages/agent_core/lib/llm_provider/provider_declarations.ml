type authentication =
  | No_auth
  | Caller_api_key
  | Api_key_env of string
  | Setup_token_env of string

type entry =
  { id : string
  ; aliases : string list
  ; kind : Provider_kind.t
  ; base_url : string
  ; request_path : string
  ; authentication : authentication
  ; default_model : string option
  ; max_context : int option
  ; capabilities : Capabilities.capabilities
  ; credential_scope : string option
  }

type error =
  | Unknown_capability_base of { provider_id : string; label : string }
  | Conflicting_identity of { identity : string; provider_ids : string list }

let error_to_string = function
  | Unknown_capability_base {provider_id;label} ->
    Printf.sprintf "provider %S declares unknown capability base %S" provider_id label
  | Conflicting_identity {identity;provider_ids} ->
    Printf.sprintf "provider identity %S is shared by %s" identity
      (String.concat ", " provider_ids)

module Ids = Map.Make(String)
type t = { declared : entry list; by_identity : entry Ids.t }
let normalize s = String.trim s |> String.lowercase_ascii
let ( let* ) = Result.bind

let of_model_entry (entry : Model_catalog.provider_entry) =
  let label = Option.value entry.capabilities_base ~default:entry.id in
  match Capabilities.capabilities_for_provider_label label with
  | None -> Error (Unknown_capability_base {provider_id=entry.id;label})
  | Some capabilities -> Ok
    { id=entry.id;aliases=entry.aliases;
      kind=entry.kind;base_url=entry.base_url;request_path=entry.request_path;
      authentication=(if entry.requires_api_key then Caller_api_key else No_auth);
      default_model=entry.default_model;max_context=capabilities.max_context_tokens;
      capabilities;credential_scope=None }

let of_provider_entry (entry : Provider_catalog.entry) =
  let authentication = match entry.auth with
    | Provider_catalog.No_auth -> No_auth
    | Provider_catalog.Api_key_env env -> Api_key_env env
    | Provider_catalog.Setup_token_env env -> Setup_token_env env in
  { id=entry.id;aliases=entry.aliases;
    kind=entry.kind;base_url=entry.base_url;request_path=entry.request_path;
    authentication;default_model=entry.default_model;
    max_context=(match entry.max_context with Some _ as n -> n
      | None -> entry.capabilities.max_context_tokens);
    capabilities=entry.capabilities;credential_scope=entry.credential_scope }

let admit declared =
  let rec identities entry index = function
    | [] -> Ok index
    | identity::rest ->
      (match Ids.find_opt identity index with
       | Some other -> Error (Conflicting_identity
           {identity;provider_ids=[other.id;entry.id]})
       | None -> identities entry (Ids.add identity entry index) rest) in
  let rec loop index = function
    | [] -> Ok {declared;by_identity=index}
    | entry::rest ->
      let* index = identities entry index
          (List.map normalize (entry.id::entry.aliases)) in
      loop index rest in
  loop Ids.empty declared

let of_catalogs ~models ~providers =
  let overlay = match providers with None -> []
    | Some catalog -> List.map of_provider_entry (Provider_catalog.entries catalog) in
  let replaced = List.fold_left (fun ids entry -> Ids.add (normalize entry.id) entry ids)
      Ids.empty overlay in
  let seeds = match models with None -> [] | Some catalog -> Model_catalog.provider_entries catalog in
  let rec project acc = function
    | [] -> admit (List.rev acc @ overlay)
    | seed::rest ->
      (* An exact overlay replaces the whole seed before interpretation. *)
      if Ids.mem (normalize seed.Model_catalog.id) replaced then project acc rest
      else let* entry = of_model_entry seed in project (entry::acc) rest in
  project [] seeds

let capture () =
  let models = Model_catalog.global () in
  let providers = Provider_catalog.global () in
  of_catalogs ~models ~providers

exception Invalid_declarations of error
let current () = match capture () with Ok declarations -> declarations
  | Error error -> raise (Invalid_declarations error)
let entries t = t.declared
let find t label = Ids.find_opt (normalize label) t.by_identity
let requires_api_key = function No_auth -> false
  | Caller_api_key | Api_key_env _ | Setup_token_env _ -> true
