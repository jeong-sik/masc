type requirement =
  | Not_required
  | Unknown_provider
  | Required_undeclared
  | Required_env of string
  | Required_inline
  | Required_file

type admission =
  { provider_id : string
  ; requirement : requirement
  ; quota_scope : Runtime_quota_window.scope
  }

type materialized =
  { api_key : Llm_provider.Secret.t
  ; admission : admission
  }

type selected_reference =
  | Selected_env of string
  | Selected_inline
  | Selected_file of string

let read_file path =
  if Filename.is_relative path then Error "API credential file must use an absolute path"
  else
    match Fs_compat.load_owned_regular_file_with_snapshot
        ~ownership_root:(Filename.dirname path) path with
    | Error _ -> Error "API credential file could not be read as an owned regular file"
    | Ok None -> Error "API credential file is missing"
    | Ok (Some {snapshot;_})
      when snapshot.owner_uid <> Unix.geteuid () || snapshot.permissions land 0o077 <> 0 ->
      Error "API credential file must be owned by the current user and private"
    | Ok (Some {content;_}) ->
      let value = String.trim content in
      if value = "" then Error "API credential file is empty"
      else
        let structured_json =
          try match Yojson.Safe.from_string value with
            | `Assoc _ | `List _ -> true
            | _ -> false
          with Yojson.Json_error _ -> false in
        if structured_json then
          Error "API credential file must contain a raw API key, not a JSON credential document"
        else Ok value

let select_reference = function
  | Runtime_schema.Env key ->
    let candidates = match key with
      | "OLLAMA_CLOUD_API_KEY" -> ["OLLAMA_CLOUD_API_KEY"; "OLLAMA_API_KEY"]
      | key -> [key] in
    let selected = List.find_map (fun env -> match Sys.getenv_opt env with
      | Some value when String.trim value <> "" -> Some (env,value)
      | Some _ | None -> None) candidates in
    let env,value = match selected with Some pair -> pair | None -> key,"" in
    Ok (value, Selected_env env)
  | Runtime_schema.Inline value -> Ok (value, Selected_inline)
  | Runtime_schema.File path -> Result.map (fun value -> value, Selected_file path) (read_file path)

let materialize ~provider_id ~requires_api_key ~credential =
  let complete api_key requirement reference =
    {api_key=Llm_provider.Secret.of_string api_key;admission={provider_id;requirement;
      quota_scope=Runtime_quota_window.scope_of_credential ~provider_id reference}} in
  match credential with
  | None ->
    let requirement = match requires_api_key with
      | Some false -> Not_required | Some true -> Required_undeclared | None -> Unknown_provider in
    Ok (complete "" requirement None)
  | Some credential ->
    Result.map (fun (value,reference) -> match reference with
      | Selected_env env -> complete value (Required_env env) (Some (Runtime_schema.Env env))
      | Selected_inline -> complete value Required_inline None
      | Selected_file path -> complete value Required_file (Some (Runtime_schema.File path)))
      (select_reference credential)

let provider_id admission = admission.provider_id
let requirement admission = admission.requirement
let quota_scope admission = admission.quota_scope

let require_nonempty value =
  if Llm_provider.Secret.is_empty value then Error "Required provider credential is unavailable"
  else Ok value

let require_key materialized =
  match materialized.admission.requirement with
  | Unknown_provider -> Error "No provider credential is configured and the provider has no catalog entry"
  | Required_undeclared ->
    let provider_id = materialized.admission.provider_id in
    Error (Printf.sprintf
      "provider %S requires an API key and declares no credential: add [providers.%s.credentials] with the environment variable that holds it"
      provider_id provider_id)
  | Not_required -> Ok materialized.api_key
  | Required_env _ | Required_inline | Required_file -> require_nonempty materialized.api_key

let resolve_explicit credential =
  Result.bind (select_reference credential)
    (fun (value,_) -> require_nonempty (Llm_provider.Secret.of_string value))
