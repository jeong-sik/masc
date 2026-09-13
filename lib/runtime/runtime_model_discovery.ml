type protocol = Openai | Anthropic | Kimi | Ollama
type provider = Anonymous_endpoint | Named_provider of string
type connection = { protocol : protocol; provider : provider; endpoint : string;
                    credential : Runtime_schema.credential option }
type model = { id : string; label : string; context : int option; tools : bool option;
               listed_at : Yojson.Safe.t option }
type error = Invalid_connection | Credential_unavailable | Request_failed
  | Http_error of int | Invalid_response | Repeated_page
let error_message = function
  | Invalid_connection -> "Choose a supported HTTP connection without credentials embedded in its URL."
  | Credential_unavailable -> "The connection's credential is unavailable. Sign in or save an API key, then refresh."
  | Request_failed -> "The model-list request failed. Check the connection and try again."
  | Http_error status -> Printf.sprintf "The model-list endpoint returned HTTP %d. Check account access and API credit." status
  | Invalid_response -> "The model-list endpoint returned an unsupported response."
  | Repeated_page -> "The model-list endpoint repeated its pagination cursor."
let ( let* ) = Result.bind
let safe_text value = value <> "" && value = String.trim value
  && not (String.exists (function '\000' .. '\031' | '\127' -> true | _ -> false) value)
let string fields key = match List.assoc_opt key fields with
  | Some (`String value) when safe_text value -> Some value | _ -> None
let endpoint_valid endpoint =
  let uri = Uri.of_string endpoint in
  List.mem (Uri.scheme uri) [Some "http"; Some "https"]
  && Option.is_some (Uri.host uri) && Uri.userinfo uri = None
  && Uri.query uri = [] && Uri.fragment uri = None
let optional_reference fields key =
  match List.assoc_opt key fields with
  | None -> Ok None
  | Some (`String value) when safe_text value -> Ok (Some value)
  | Some _ -> Error Invalid_connection
let connection_of_json = function
  | `Assoc fields ->
    let keys = List.map fst fields in
    let* () = if List.length keys = List.length (List.sort_uniq String.compare keys)
      then Ok () else Error Invalid_connection in
    let* credential_file = optional_reference fields "credential_file" in
    let* api_key_env = optional_reference fields "api_key_env" in
    let* provider_id = optional_reference fields "provider_id" in
    let protocol = match string fields "choice", string fields "provider_kind" with
      | Some ("openai_compatible" | "vllm" | "llama_cpp"), _ -> Some Openai
      | Some "ollama", _ -> Some Ollama
      | Some "messages", Some "anthropic" -> Some Anthropic
      | Some "messages", Some "kimi" -> Some Kimi
      | _ -> None in
    (match protocol, string fields "endpoint" with
     | Some protocol, Some endpoint when endpoint_valid endpoint ->
       let credential = match credential_file, api_key_env with
         | Some path, None when not (Filename.is_relative path) -> Ok (Some (Runtime_schema.File path))
         | None, Some name -> Ok (Some (Runtime_schema.Env name))
         | None, None -> Ok None
         | _ -> Error Invalid_connection in
       let* credential = credential in
       Ok { protocol; endpoint; credential;
            provider = (match provider_id with Some id -> Named_provider id | None -> Anonymous_endpoint) }
     | _ -> Error Invalid_connection)
  | _ -> Error Invalid_connection
let model protocol = function
  | `Assoc fields ->
    let id = string fields (match protocol with Ollama -> "name" | _ -> "id") in
    (match id with
     | None -> Error Invalid_response
     | Some id ->
       (* sound-partial: display_name, then name, then the id itself *)
       let label = match string fields "display_name" with
         | Some label -> label
         | None -> (match string fields "name" with
             | Some label -> label
             | None -> id) in
       (* Only explicit window fields count. Creation/listing timestamps do not
          become release dates, and parameter counts do not become windows. *)
       let contexts = ["context_length"; "max_model_len"] |> List.filter_map (fun key ->
         match List.assoc_opt key fields with Some (`Int value) when value > 0 -> Some value | _ -> None)
         |> List.sort_uniq Int.compare in
       let context = match contexts with [value] -> Some value | _ -> None in
       let tools = match List.assoc_opt "supported_parameters" fields with
         | Some (`List values) when List.for_all (function `String _ -> true | _ -> false) values ->
           Some (List.mem (`String "tools") values)
         | _ -> None in
       let listed_at = match List.assoc_opt "created" fields with
         | Some ((`Int _ | `String _) as date) -> Some date | _ -> None in
       Ok {id; label; context; tools; listed_at})
  | _ -> Error Invalid_response
let parse_page protocol body =
  try match Yojson.Safe.from_string body with
  | `Assoc fields ->
    let* rows = match List.assoc_opt (match protocol with Ollama -> "models" | _ -> "data") fields with
      | Some (`List rows) -> Ok rows | _ -> Error Invalid_response in
    let* reversed = List.fold_left (fun result row ->
      let* models = result in let* row = model protocol row in Ok (row :: models)) (Ok []) rows in
    let* next = match protocol, List.assoc_opt "has_more" fields with
      | (Anthropic | Kimi), Some (`Bool true) ->
        (match string fields "last_id" with Some id -> Ok (Some id) | None -> Error Invalid_response)
      | _, (None | Some (`Bool false)) -> Ok None
      | _ -> Error Invalid_response in
    Ok (List.rev reversed, next)
  | _ -> Error Invalid_response
  with Yojson.Json_error _ -> Error Invalid_response
let discover_with ~get connection =
  if not (endpoint_valid connection.endpoint) then Error Invalid_connection else
  let base = Uri.of_string connection.endpoint in
  let path = Uri.path base in
  let path = if String.ends_with ~suffix:"/" path then String.sub path 0 (String.length path - 1) else path in
  let suffix = match connection.protocol with
    | Ollama -> "/api/tags"
    | Openai -> "/models"
    | Anthropic | Kimi -> if String.ends_with ~suffix:"/v1" path then "/models" else "/v1/models" in
  let base = Uri.with_path base (path ^ suffix) in
  let rec pages seen cursor all =
    let url = match cursor with None -> base | Some id -> Uri.add_query_param' base ("after_id", id) in
    let* body = get ~url:(Uri.to_string url) in
    let* models, next = parse_page connection.protocol body in
    let all = List.rev_append models all in
    match next with
    | None -> Ok (List.rev all)
    | Some cursor when List.mem cursor seen -> Error Repeated_page
    | Some cursor -> pages (cursor :: seen) (Some cursor) all in
  pages [] None []
let to_json models =
  let optional convert = function None -> `Null | Some value -> convert value in
  `Assoc ["source", `String "account_or_server_model_list";
    "account_availability_verified", `Bool false;
    "models", `List (List.map (fun model -> `Assoc [
      "id", `String model.id; "label", `String model.label;
      "context", optional (fun value -> `Int value) model.context;
      "tools", optional (fun value -> `Bool value) model.tools;
      "provider_listed_at", optional Fun.id model.listed_at;
      "release_date", `Null]) models)]
let resolve_credential connection =
  let requirement = match connection.provider, connection.credential with
    | Anonymous_endpoint, None -> Runtime_adapter.Not_required
    | Anonymous_endpoint, Some credential -> Runtime_adapter.explicit_credential_requirement credential
    | Named_provider provider_id, credential ->
      Runtime_adapter.credential_requirement ~provider_id credential in
  Runtime_adapter.resolve_credential_requirement requirement
  |> Result.map_error (fun _ -> Credential_unavailable)

let discover ~sw ~net connection =
  let* api_key = resolve_credential connection in
  let kind = match connection.protocol with
    | Openai -> Llm_provider.Provider_config.OpenAI_compat
    | Anthropic -> Anthropic | Kimi -> Kimi | Ollama -> Ollama in
  let headers = Llm_provider.Provider_config.auth_headers_for_kind_and_key
    ~kind ~api_key:(Llm_provider.Secret.header_value api_key) in
  let headers = match connection.protocol with
    | Anthropic | Kimi -> ("anthropic-version", Llm_provider.Api_common.api_version) :: headers
    | Openai | Ollama -> headers in
  let get ~url = match Llm_provider.Http_client.get_sync ~sw ~net ~url ~headers () with
    | Error _ -> Error Request_failed
    | Ok response when response.status >= 200 && response.status < 300 -> Ok response.body
    | Ok response -> Error (Http_error response.status) in
  discover_with ~get connection |> Result.map to_json
