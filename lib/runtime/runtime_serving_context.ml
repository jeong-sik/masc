module Discovery = Runtime_model_discovery
type source = Running_model | Configured_model | Serving_endpoint | Not_reported
type observation = { model : string; context : int option; source : source; tools : bool option }
let ( let* ) = Result.bind
let fields_of_object = function
  | `Assoc fields when not (List.mem_assoc "error" fields) ->
    let names = List.map fst fields in
    if List.length names = List.length (List.sort_uniq String.compare names)
    then Ok fields else Error Discovery.Invalid_response
  | _ -> Error Discovery.Invalid_response
let object_fields body =
  try fields_of_object (Yojson.Safe.from_string body)
  with Yojson.Json_error _ -> Error Discovery.Invalid_response
let optional_context = function
  | None -> Ok None
  | Some (`Int value) when value > 0 -> Ok (Some value)
  | Some _ -> Error Discovery.Invalid_response
let one_context = function
  | [] -> Ok None | [value] -> Ok (Some value) | _ -> Error Discovery.Invalid_response
let running_context ~model models =
  let* selected = List.fold_left (fun result row ->
    let* selected = result in
    let* fields = fields_of_object row in
    let* name = match List.assoc_opt "name" fields, List.assoc_opt "model" fields with
      | Some (`String name), None | None, Some (`String name) when name <> "" -> Ok name
      | Some (`String name), Some (`String same) when name <> "" && name = same -> Ok name
      | _ -> Error Discovery.Invalid_response in
    if name <> model then Ok selected else
    let* context = optional_context (List.assoc_opt "context_length" fields) in
    Ok (context :: selected)) (Ok []) models in
  match selected with
  | [] -> Ok None | [context] -> Ok context | _ -> Error Discovery.Invalid_response
let configured_context = function
  | None -> Ok None
  | Some (`String parameters) ->
    let lines = String.split_on_char '\n' parameters in
    let* contexts = List.fold_left (fun result line ->
      let* contexts = result in
      let fields = String.map (function '\t' -> ' ' | c -> c) line
        |> String.split_on_char ' ' |> List.filter (fun value -> value <> "") in
      match fields with
      | ["num_ctx"; value] when value <> "" && String.for_all (function '0' .. '9' -> true | _ -> false) value -> (match int_of_string_opt value with
        | Some value when value > 0 -> Ok (value :: contexts) | _ -> Error Discovery.Invalid_response)
      | "num_ctx" :: _ -> Error Discovery.Invalid_response
      | _ -> Ok contexts) (Ok []) lines in
    one_context contexts
  | _ -> Error Discovery.Invalid_response
let observe_with ~get ~post (connection : Discovery.connection) ~model ~load =
  let base = Uri.of_string connection.endpoint in
  let valid = model <> "" && model = String.trim model
    && not (String.exists (function '\000' .. '\031' | '\127' -> true | _ -> false) model)
    && List.mem (Uri.scheme base) [Some "http"; Some "https"]
    && Uri.host base <> None && Uri.userinfo base = None && Uri.query base = [] && Uri.fragment base = None in
  if not valid then Error Discovery.Invalid_connection else
  let base_path = Uri.path base in
  let base_path = if String.ends_with ~suffix:"/" base_path then
    String.sub base_path 0 (String.length base_path - 1) else base_path in
  let at path = Uri.to_string (Uri.with_path base (base_path ^ path)) in
  match connection.protocol with
  | Discovery.Anthropic | Kimi -> Error Discovery.Invalid_connection
  | Ollama ->
    let body = Yojson.Safe.to_string (`Assoc ["model", `String model]) in
    let* shown = post ~url:(at "/api/show") ~body in
    let* shown = object_fields shown in
    let* tools = match List.assoc_opt "capabilities" shown with
      | None -> Ok None
      | Some (`List values) when List.for_all (function `String _ -> true | _ -> false) values ->
        Ok (Some (List.mem (`String "tools") values))
      | _ -> Error Discovery.Invalid_response in
    let* configured = configured_context (List.assoc_opt "parameters" shown) in
    let* () = if load && tools <> Some false then
      let* loaded = post ~url:(at "/api/generate")
        ~body:(Yojson.Safe.to_string (`Assoc ["model", `String model; "stream", `Bool false])) in
      let* _ = object_fields loaded in Ok () else Ok () in
    let* running = get ~url:(at "/api/ps") in
    let* running = object_fields running in
    let* models = match List.assoc_opt "models" running with
      | Some (`List models) -> Ok models | _ -> Error Discovery.Invalid_response in
    let* running = running_context ~model models in
    let context, source = match running, configured with
      | Some value, _ -> Some value, Running_model
      | None, Some value -> Some value, Configured_model
      | None, None -> None, Not_reported in
    Ok {model; context; source; tools}
  | Openai ->
    let* models = Discovery.discover_with ~get connection in
    match models with
    | [served] when served.id = model ->
      let root = if String.ends_with ~suffix:"/v1" base_path then
        String.sub base_path 0 (String.length base_path - 3) else base_path in
      let* props = get ~url:(Uri.to_string (Uri.with_path base (root ^ "/props"))) in
      let* props = object_fields props in
      let* context = match List.assoc_opt "default_generation_settings" props with
        | None -> Ok None
        | Some settings ->
          let* settings = fields_of_object settings in
          optional_context (List.assoc_opt "n_ctx" settings) in
      Ok {model; context; source=(if context = None then Not_reported else Serving_endpoint); tools=None}
    | _ -> Ok {model; context=None; source=Not_reported; tools=None}
let to_json observation =
  let optional f = function None -> `Null | Some value -> f value in
  `Assoc ["model", `String observation.model;
    "context", optional (fun value -> `Int value) observation.context;
    "tools", optional (fun value -> `Bool value) observation.tools;
    "context_source", `String (match observation.source with Running_model -> "running_model"
      | Configured_model -> "configured_model" | Serving_endpoint -> "serving_endpoint" | Not_reported -> "not_reported")]
let observe ~sw ~net connection ~model ~load =
  let* key = Discovery.resolve_credential connection in
  let* kind = match connection.protocol with
    | Discovery.Ollama -> Ok Llm_provider.Provider_config.Ollama
    | Openai -> Ok Llm_provider.Provider_config.OpenAI_compat
    | Anthropic | Kimi -> Error Discovery.Invalid_connection in
  let headers = Llm_provider.Provider_config.auth_headers_for_kind_and_key
    ~kind ~api_key:(Llm_provider.Secret.header_value key) in
  let result = function
    | Error _ -> Error Discovery.Request_failed
    | Ok (response : Llm_provider.Http_client.raw_sync_response)
        when response.status >= 200 && response.status < 300 -> Ok response.body
    | Ok response -> Error (Discovery.Http_error response.status) in
  let get ~url = Llm_provider.Http_client.get_sync ~sw ~net ~url ~headers () |> result in
  let post ~url ~body = Llm_provider.Http_client.post_sync ~sw ~net ~url
    ~headers:(("Content-Type", "application/json") :: headers) ~body () |> result in
  observe_with ~get ~post connection ~model ~load |> Result.map to_json
