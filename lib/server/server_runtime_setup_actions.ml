type error = Invalid_request | Configuration_unavailable | Network_unavailable | Unsupported_connection | Disabled_connection
  | Credential_unavailable | Discovery_failed of Runtime_model_discovery.error
  | Save_failed of Runtime_setup_batch.error
let error_message = function
  | Invalid_request -> "Choose a connection and models with reported context metadata."
  | Configuration_unavailable -> "The workspace configuration could not be read."
  | Network_unavailable -> "The server has no network capability for discovery."
  | Disabled_connection -> "This provider is disabled. Enable it in runtime.toml before adding models."
  | Unsupported_connection -> "This connection needs its native account setup before web discovery."
  | Credential_unavailable -> "The selected connection's credential could not be prepared."
  | Discovery_failed error -> Runtime_model_discovery.error_message error
  | Save_failed error -> Runtime_setup_batch.error_message error
(* 400: the request or the selected connection is wrong. 409: the workspace
   moved under the request. 502: the runtime or server behind the connection
   answered badly. 503: this server cannot serve the request right now. *)
let status_of_error : error -> Httpun.Status.t = function
  | Invalid_request | Unsupported_connection | Disabled_connection | Credential_unavailable -> `Bad_request
  | Configuration_unavailable | Network_unavailable -> `Service_unavailable
  | Discovery_failed (Runtime_model_discovery.Invalid_connection
      | Runtime_model_discovery.Credential_unavailable) -> `Bad_request
  | Discovery_failed (Runtime_model_discovery.Request_failed | Runtime_model_discovery.Http_error _
      | Runtime_model_discovery.Invalid_response | Runtime_model_discovery.Repeated_page) -> `Bad_gateway
  | Save_failed (Runtime_setup_batch.Invalid_selection | Runtime_setup_batch.Invalid_configuration
      | Runtime_setup_batch.Validation_failed _ | Runtime_setup_batch.Commit_refused _) -> `Bad_request
  | Save_failed (Runtime_setup_batch.Changed_configuration | Runtime_setup_batch.Lock_unavailable) -> `Conflict
  | Save_failed (Runtime_setup_batch.Configuration_unavailable | Runtime_setup_batch.Child_not_started _
      | Runtime_setup_batch.Write_failed _) -> `Service_unavailable
  | Save_failed (Runtime_setup_batch.Verification_failed _ | Runtime_setup_batch.Verification_unreadable _) -> `Bad_gateway
let ( let* ) = Result.bind
let fields allowed required = function
  | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields))
      && List.for_all (fun (key,_) -> List.mem key allowed) fields
      && List.for_all (fun key -> List.mem_assoc key fields) required -> Ok fields
  | _ -> Error Invalid_request
let text = function
  | `String value when value<>"" && String.trim value=value
    && not (String.exists (function '\000'..'\031'|'\127' -> true | _ -> false) value) -> Ok value
  | _ -> Error Invalid_request
let list = function `List values -> Ok values | _ -> Error Invalid_request
let value key fields = match List.assoc_opt key fields with Some v -> v | None -> `Null
let config ~base_path =
  let path = Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "config") Config_dir_resolver.runtime_toml_filename in
  match Runtime.load_config_observation ~runtime_config_path:path () with
  | Error _ -> Error Configuration_unavailable
  | Ok observation -> (match Runtime_toml.parse_string observation.source_text with
    | Ok parsed -> Ok parsed | Error _ -> Error Configuration_unavailable)
let declared_provider (config:Runtime_schema.config) id =
  List.find_opt (fun (p:Runtime_schema.provider) -> p.id=id) config.providers
(* Web setup drives the connection kinds Runtime_setup_spec renders; Gemini
   needs its own setup path. Adding an api_format makes this a compile error. *)
let choice_of_api_format : Runtime_schema.api_format -> (Runtime_setup_spec.choice,error) result = function
  | Runtime_schema.Chat_completions_api -> Ok Runtime_setup_spec.Openai_compatible
  | Runtime_schema.Messages_api -> Ok Runtime_setup_spec.Messages
  | Runtime_schema.Ollama_api -> Ok Runtime_setup_spec.Ollama
  | Runtime_schema.Codex_app_server_runtime -> Ok Runtime_setup_spec.Codex
  | Runtime_schema.Claude_code_runtime -> Ok Runtime_setup_spec.Claude_code
  | Runtime_schema.Antigravity_cli_runtime -> Ok Runtime_setup_spec.Antigravity
  | Runtime_schema.Muse_serve_runtime -> Ok Runtime_setup_spec.Muse
  | Runtime_schema.Gemini_api | Runtime_schema.Vertex_gemini_api -> Error Unsupported_connection
let choice config ~id ~protocol =
  match declared_provider config id with
  | Some provider ->
    let* choice = choice_of_api_format provider.api_format in
    (match (provider.transport : Runtime_schema.transport), Runtime_setup_spec.http choice with
     | Runtime_schema.Http _,true | Runtime_schema.Cli _,false -> Ok choice
     | Runtime_schema.Http _,false | Runtime_schema.Cli _,true -> Error Unsupported_connection)
  | None ->
    (* Catalog prototypes and product client identities carry no declared
       provider; their protocol label is read by the runtime.toml parser. *)
    (match Runtime_toml.api_format_of_protocol protocol with
     | Ok api_format -> choice_of_api_format api_format
     | Error _ -> Error Unsupported_connection)
let private_key ~sw pending secret =
  match Runtime_setup_credentials.save ~secret () with
  | Error _ -> Error Credential_unavailable
  | Ok key ->
    pending := key :: !pending;
    Eio.Switch.on_release sw (fun () -> Runtime_setup_credentials.remove_uncommitted key);
    Ok ["credential_file",`String (Runtime_setup_credentials.reference_path key)]
let source_template ~sw ~pending ~workspace config request =
  let* request = fields ["integration_id";"endpoint";"api_key";"account_ref"] ["integration_id"] request in
  let* id = text (value "integration_id" request) in
  let inventory = Runtime_wizard_inventory.to_json config in
  let rows = match inventory with `Assoc fields -> (match value "integrations" fields with `List rows -> rows | _ -> []) | _ -> [] in
  let matches = List.filter_map (function `Assoc fields when value "id" fields = `String id -> Some fields | _ -> None) rows in
  let* selected = match matches with [row] -> Ok row | _ -> Error Invalid_request in
  let* () = if value "setup_support" selected=`String "unsupported" then Error Unsupported_connection else Ok () in
  let* () = if value "endpoint_redacted" selected=`Bool true then Error Unsupported_connection else Ok () in
  let* protocol = text (value "protocol" selected) in
  let* choice = choice config ~id ~protocol in
  let http = Runtime_setup_spec.http choice in
  let* () = if not http && List.mem_assoc "endpoint" request then Error Invalid_request else Ok () in
  let* endpoint = match List.assoc_opt "endpoint" request,List.assoc_opt "endpoint" selected with
    | None,existing -> Ok existing
    | Some (`String supplied),None -> let* endpoint=text (`String supplied) in Ok (Some (`String endpoint))
    | Some supplied,Some existing when supplied=existing -> Ok (Some existing)
    | _ -> Error Invalid_request in
  let endpoint_val = match endpoint with Some v -> v | None -> `Null in
  let transport = if http then ["endpoint", endpoint_val]
    else ["command",value "command" selected] in
  let metadata = if http then List.filter (fun (key,_) -> key="provider_kind" || key="request_path") selected else [] in
  let* account = match List.assoc_opt "account_ref" request with
    | None -> Ok None
    | Some (`String reference) when not http && not (List.mem_assoc "api_key" request) ->
      let* reference=Runtime_setup_accounts.reference_of_string reference |> Result.map_error (fun _ -> Credential_unavailable) in
      let* command=text (value "command" selected) in
      let* binding = Runtime_setup_accounts.resolve ~workspace ~integration_id:id ~cli_path:command reference
        |> Result.map_error (fun _ -> Credential_unavailable) in
      Ok (Some binding)
    | Some _ -> Error Invalid_request in
  let* () = match declared_provider config id with
    | Some provider when not provider.enabled ->
      (* A disabled connection can still be the client template for an explicit
         new login. Its old account must remain disabled; only a changed account
         reference (or an explicitly supplied HTTP key) creates a new provider. *)
      (match account, List.assoc_opt "api_key" request with
       | Some (Runtime_setup_accounts.Native_home selected), None
         when not (Runtime_setup_spec.account_home_matches choice provider.account_home
           (Some selected.account_home)) -> Ok ()
       | Some (Runtime_setup_accounts.Antigravity_account selected), None
         when provider.credentials <> Some (Runtime_schema.File selected.credential_file) -> Ok ()
       | None, Some (`String _) when http -> Ok ()
       | _ -> Error Disabled_connection)
    | Some _ | None -> Ok () in
  let* credentials = match account,List.assoc_opt "api_key" request with
    | Some (Runtime_setup_accounts.Antigravity_account account),None
      when choice=Runtime_setup_spec.Antigravity -> Ok ["credential_file",`String account.credential_file]
    | Some (Runtime_setup_accounts.Native_home _),None
      when choice<>Runtime_setup_spec.Antigravity -> Ok []
    | Some _,None -> Error Invalid_request
    | Some _,Some _ -> Error Invalid_request

    | None,Some (`String secret) when http -> private_key ~sw pending secret
    | None,Some _ -> Error Invalid_request
    | None,None ->
      (match declared_provider config id with
       | Some provider ->
         (match (provider.credentials : Runtime_schema.credential option),http with
          | Some (Runtime_schema.Inline secret),true -> private_key ~sw pending secret
          | Some (Runtime_schema.Inline _),false -> Error Credential_unavailable
          | Some (Runtime_schema.File path),_ -> Ok ["credential_file",`String path]
          | Some (Runtime_schema.Env name),_ -> Ok ["api_key_env",`String name]
          | None,_ -> Ok [])
       | None ->
         (match value "api_key_env" selected with
          | `String name when name<>"" -> Ok ["api_key_env",`String name] | _ -> Ok [])) in
  let* timeout = match choice with
    | Runtime_setup_spec.Ollama | Llama_cpp | Vllm | Openai_compatible | Messages | Claude_code | Codex | Muse -> Ok []
    | Antigravity ->
      (match account with
       | Some (Runtime_setup_accounts.Antigravity_account account) -> Ok ["timeout_s",`Float account.timeout_s]
       | Some (Runtime_setup_accounts.Native_home _) -> Error Invalid_request
       | None ->
         (match declared_provider config id with
          | Some provider -> (match provider.antigravity_cli with
            | Some options -> Ok ["timeout_s",`Float options.timeout_s] | None -> Error Unsupported_connection)
          | None -> Error Unsupported_connection)) in
  let* account_home = match choice,account with
    | (Runtime_setup_spec.Claude_code | Codex | Muse),Some (Runtime_setup_accounts.Native_home account) ->
      Ok ["account_home", `String account.account_home]
    | (Runtime_setup_spec.Claude_code | Codex | Muse),None ->
      (match Option.bind (declared_provider config id) (fun provider -> provider.Runtime_schema.account_home) with
       | Some home -> Ok ["account_home", `String home]
       | None when choice=Runtime_setup_spec.Muse -> Error Credential_unavailable
       | None -> Ok [])
    | (Runtime_setup_spec.Claude_code | Codex | Muse),Some (Runtime_setup_accounts.Antigravity_account _) ->
      Error Invalid_request
    | (Ollama | Llama_cpp | Vllm | Openai_compatible | Messages | Antigravity),_ -> Ok [] in
  Ok (("choice",`String (Runtime_setup_spec.choice_name choice))::transport @ metadata @ credentials @ timeout @ account_home,id,choice)
let native_json ~binary args =
  match Process_eio.run_argv_with_status_split_or_refusal (binary::args) with
  | Ok (Unix.WEXITED 0,body,_) ->
    (try Ok (Yojson.Safe.from_string body) with Yojson.Json_error _ -> Error Unsupported_connection)
  | Ok _ | Error _ -> Error Unsupported_connection
let positive = function `Int n when n>0 -> Some n | _ -> None
type reasoning_efforts = { supported : string list; default : string }
type client_model = { id : string; label : string; context : int option; reasoning_efforts : reasoning_efforts option; supports_image_input : bool option }
let client_reasoning_efforts row =
  let effort = function `String value when value<>"" -> Ok value | _ -> Error Unsupported_connection in
  match List.assoc_opt "supported_reasoning_efforts" row,List.assoc_opt "default_reasoning_effort" row with
  | None,None -> Ok None
  | Some (`List values),Some reported_default ->
    let rec supported seen = function
      | [] -> Ok []
      | value::tail ->
        let* value=effort value in
        let* ()=if List.mem value seen then Error Unsupported_connection else Ok () in
        let* tail=supported (value::seen) tail in Ok (value::tail) in
    let* supported=supported [] values in
    let* default=effort reported_default in
    (* These are the client's open vocabulary. The official model schema
       allows an empty supported list and does not require default membership. *)
    Ok (Some {supported;default})
  | None,Some _ | Some _,None | Some _,Some _ -> Error Unsupported_connection
let client_models ~catalog json =
  let* root=match json with `Assoc fields -> Ok fields | _ -> Error Unsupported_connection in
  let* models=list (value "models" root) in
  let rec project seen = function
    | [] -> Ok []
    | (`Assoc row)::tail ->
      let* ()=if List.length row=List.length (List.sort_uniq String.compare (List.map fst row))
        then Ok () else Error Unsupported_connection in
      let* id=text (value "id" row) in
      let* ()=if List.mem id seen then Error Unsupported_connection else Ok () in
      let label=match value "label" row with `String label -> label | _ -> id in
      let context=value (if catalog then "max_context" else "context") row in
      let context=positive context in
      let* reasoning_efforts=client_reasoning_efforts row in
      let* supports_image_input = match List.assoc_opt "supports_image_input" row with
        | None | Some `Null -> Ok None
        | Some (`Bool value) -> Ok (Some value)
        | Some _ -> Error Unsupported_connection in
      let* tail=project (id::seen) tail in
      Ok ({id;label;context;reasoning_efforts;supports_image_input}::tail)
    | _ -> Error Unsupported_connection in
  project [] models
let client_models_json ~source models =
  let rows=List.map (fun model ->
    let context=match model.context with Some n -> `Int n | None -> `Null in
    let efforts=match model.reasoning_efforts with
      | None -> []
      | Some {supported;default} ->
        ["supported_reasoning_efforts",`List (List.map (fun effort -> `String effort) supported);
         "default_reasoning_effort",`String default] in
    let image = match model.supports_image_input with
      | None -> [] | Some value -> ["supports_image_input", `Bool value] in
    `Assoc (["id",`String model.id;"label",`String model.label;"context",context;"tools",`Null] @ efforts @ image)) models in
  `Assoc ["source",`String source;"account_availability_verified",`Bool false;"models",`List rows]
let project_client_models ~source ~catalog json =
  let* models=client_models ~catalog json in
  Ok (client_models_json ~source models)
let native_client_catalog ~binary client =
  let* json = native_json ~binary ["runtime-model-list";client] in
  client_models ~catalog:true json
let with_catalog_image_capabilities models catalog =
  List.map (fun model ->
    let supports_image_input = match List.find_opt (fun entry -> entry.id = model.id) catalog with
      | Some entry -> entry.supports_image_input
      | None -> None in
    {model with supports_image_input}) models
let import_account ~binary ~base_path request =
  let* request=fields ["integration_id"] ["integration_id"] request in
  let* integration_id=text (value "integration_id" request) in
  let* config=config ~base_path in
  let catalog=Runtime_wizard_inventory.to_json config in
  let integrations=match catalog with `Assoc fields -> value "integrations" fields | _ -> `Null in
  let* rows=list integrations in
  let selected=List.filter_map (function `Assoc row when value "id" row=`String integration_id -> Some row | _ -> None) rows in
  let* selected=match selected with [row] when value "protocol" row=`String "antigravity-cli" -> Ok row | _ -> Error Unsupported_connection in
  let* cli_path=text (value "command" selected) in
  let import ~base_path =
    let result =
      let* json=native_json ~binary ["runtime-antigravity-account";"--base-path";base_path;"--cli-path";cli_path] in
      let* row=match json with `Assoc row when value "schema" row=`String "masc.antigravity_account.v1"
        && value "invocation_verified" row=`Bool false -> Ok row | _ -> Error Unsupported_connection in
      let* credential_file=text (value "credential_file" row) in
      let* timeout_s=match value "provider_timeout_s" row with
        | `Float seconds when Float.is_finite seconds && seconds>0. -> Ok seconds
        | _ -> Error Unsupported_connection in
      let* catalog=project_client_models ~source:"antigravity_imported_account_models" ~catalog:false (value "catalog" row) in
      Ok {Runtime_setup_accounts.credential_file;timeout_s;catalog} in
    Result.map_error (fun _ -> Runtime_setup_accounts.Import_failed) result in
  let* reference,catalog=Runtime_setup_accounts.create ~workspace:base_path ~integration_id ~cli_path ~import
    |> Result.map_error (fun _ -> Credential_unavailable) in
  Ok (`Assoc ["schema",`String "masc.web_setup_account.v1";
    "account_ref",`String (Runtime_setup_accounts.reference_to_string reference);
    "account_imported",`Bool true;"invocation_verified",`Bool false;"catalog",catalog])
let select_account ~base_path request =
  let* request=fields ["integration_id"] ["integration_id"] request in
  let* integration_id=text (value "integration_id" request) in
  let* config=config ~base_path in
  let rows = match Runtime_wizard_inventory.to_json config with
    | `Assoc row -> (match value "integrations" row with `List rows -> rows | _ -> [])
    | _ -> [] in
  let* selected = match List.filter_map (function
    | `Assoc row when value "id" row=`String integration_id -> Some row | _ -> None) rows with
    | [row] -> Ok row | _ -> Error Invalid_request in
  let* protocol=text (value "protocol" selected) in
  let* choice=choice config ~id:integration_id ~protocol in
  let configured=Option.bind (declared_provider config integration_id)
      (fun provider -> provider.Runtime_schema.account_home) in
  let* home = match choice with
    | Runtime_setup_spec.Claude_code ->
      (match Runtime_claude_code.effective_account_home configured with
       | Some home -> Ok home | None -> Error Credential_unavailable)
    | Codex ->
      (match Runtime_codex_app_server.effective_account_home configured with
       | Some home -> Ok home | None -> Error Credential_unavailable)
    | Muse ->
      (match configured with Some home -> Ok home | None ->
        (match Env_config_core.raw_value_opt "HOME" with Some home -> Ok home
         | None -> Error Credential_unavailable))
    | Antigravity | Ollama | Llama_cpp | Vllm | Openai_compatible | Messages -> Error Unsupported_connection in
  let* cli_path=text (value "command" selected) in
  let* reference=Runtime_setup_accounts.register_home ~workspace:base_path
      ~integration_id ~cli_path ~account_home:home
    |> Result.map_error (fun _ -> Credential_unavailable) in
  Ok (`Assoc ["schema", `String "masc.web_setup_account_selection.v1";
    "account_ref", `String (Runtime_setup_accounts.reference_to_string reference);
    "account_selected", `Bool true; "invocation_verified", `Bool false])

type login_target = {
  client : Runtime_setup_login_client.client;
  cli_path : string;
  spawn_path : string;
}

let login_target ~base_path ~integration_id =
  let* config = config ~base_path in
  let rows = match Runtime_wizard_inventory.to_json config with
    | `Assoc row -> (match value "integrations" row with `List rows -> rows | _ -> [])
    | _ -> [] in
  let* selected = match List.filter_map (function
    | `Assoc row when value "id" row = `String integration_id -> Some row
    | _ -> None) rows with
    | [row] -> Ok row | _ -> Error Invalid_request in
  let* protocol = text (value "protocol" selected) in
  let* selected_choice = choice config ~id:integration_id ~protocol in
  let* client = match selected_choice with
    | Runtime_setup_spec.Codex -> Ok Runtime_setup_login_client.Codex
    | Claude_code -> Ok Runtime_setup_login_client.Claude
    | Antigravity -> Ok Runtime_setup_login_client.Antigravity
    | Muse -> Ok Runtime_setup_login_client.Muse
    | Ollama | Llama_cpp | Vllm | Openai_compatible | Messages -> Error Unsupported_connection in
  let* command = text (value "command" selected) in
  let install_client = match client with
    | Runtime_setup_login_client.Codex -> Runtime_official_cli_install.Codex
    | Runtime_setup_login_client.Claude -> Runtime_official_cli_install.Claude
    | Runtime_setup_login_client.Antigravity -> Runtime_official_cli_install.Antigravity
    | Runtime_setup_login_client.Muse -> Runtime_official_cli_install.Muse in
  let spawn_path = Runtime_official_cli_install.spawn_path install_client ~command in
  Ok {client; cli_path = command; spawn_path}

let selected_home_args template = match value "account_home" template with
  | `String home -> ["--account-home"; home]
  | _ -> []

let muse_catalog ~binary template =
  let* command=text (value "command" template) in
  let* json=native_json ~binary (["runtime-muse-models";"--cli-path";command] @ selected_home_args template) in
  let* fields = match json with
    | `Assoc fields when value "schema" fields=`String "masc.muse_models.v1"
        && value "invocation_verified" fields=`Bool false
        && value "account_availability_verified" fields=`Bool false -> Ok fields
    | _ -> Error Unsupported_connection in
  let* source = match value "source" fields with
    | `String (("providerCatalog" | "bundledCatalog" | "configCatalog") as source) -> Ok source
    | _ -> Error Unsupported_connection in
  let* models=client_models ~catalog:false json in
  Ok ("muse_" ^ source,models)

let bound_model_names (config : Runtime_schema.config) template id choice =
  (* Resolve both sides with the same native-home rules used by inventory
     grouping; an omitted home can name the same account as an explicit one. *)
  let effective_home home = match choice with
    | Runtime_setup_spec.Codex -> Runtime_codex_app_server.effective_account_home home
    | Claude_code -> Runtime_claude_code.effective_account_home home
    | Muse -> home
    | Antigravity | Ollama | Llama_cpp | Vllm | Openai_compatible | Messages -> None in
  let selected_home = effective_home
      (match value "account_home" template with `String home -> Some home | _ -> None) in
  let selected_credential = match choice, value "credential_file" template with
    | Runtime_setup_spec.Antigravity, `String path -> Some path
    | _ -> None in
  let same_account (provider : Runtime_schema.provider) =
    provider.enabled
    && (match choice_of_api_format provider.api_format with
        | Ok candidate -> candidate = choice | Error _ -> false)
    && (match selected_home, selected_credential with
        | Some selected, _ -> Option.equal String.equal (Some selected)
            (effective_home provider.account_home)
        | None, Some selected -> (match provider.credentials with
            | Some (Runtime_schema.File path) -> String.equal selected path | _ -> false)
        | None, None -> String.equal provider.id id) in
  List.filter_map (fun (binding : Runtime_schema.binding) ->
    if binding.enabled
       && List.exists (fun (provider : Runtime_schema.provider) ->
            String.equal provider.id binding.provider_id && same_account provider)
            config.providers
    then Option.map (fun (model : Runtime_schema.model_spec) -> model.api_name)
           (List.find_opt (fun (model : Runtime_schema.model_spec) ->
             String.equal model.id binding.model_id) config.models)
    else None) config.bindings

let mark_bound_models config template id choice = function
  | `Assoc fields as json ->
    (match List.assoc_opt "models" fields with
     | Some (`List rows) ->
       let bound = bound_model_names config template id choice in
       let rows = List.map (function
         | `Assoc row ->
           let is_bound = match value "id" row with
             | `String name -> List.mem name bound | _ -> false in
           `Assoc (("bound", `Bool is_bound) :: List.remove_assoc "bound" row)
         | row -> row) rows in
       `Assoc (List.map (fun (key, value) ->
         if String.equal key "models" then key, `List rows else key, value) fields)
     | _ -> json)
  | json -> json

let discover ~binary ~sw:_ ~net ~base_path request =
  Eio.Switch.run (fun sw ->
    let* config=config ~base_path in
    let pending=ref [] in
    let* template,id,choice=source_template ~sw ~pending ~workspace:base_path config request in
    let* json = match choice with
    | Runtime_setup_spec.Codex ->
      let* command=text (value "command" template) in
      let* json=native_json ~binary (["runtime-codex-models";"--cli-path";command] @ selected_home_args template) in
      let* models = client_models ~catalog:false json in
      let* catalog = native_client_catalog ~binary "codex" in
      Ok (client_models_json ~source:"codex_isolated_account_model_list"
        (with_catalog_image_capabilities models catalog))
    | Muse ->
      let* source,models=muse_catalog ~binary template in
      Ok (client_models_json ~source models)
    | Claude_code ->
      let* json=native_json ~binary ["runtime-model-list";"claude-code"] in
      project_client_models ~source:"installed_claude_catalog_not_account_verification" ~catalog:true json
    | Antigravity ->
      let* command=text (value "command" template) in
      let* credential=text (value "credential_file" template) in
      let* json=native_json ~binary ["runtime-antigravity-models";"--cli-path";command;"--credential-file";credential] in
      project_client_models ~source:"antigravity_selected_account_models" ~catalog:false json
    | Ollama | Llama_cpp | Vllm | Openai_compatible | Messages ->
      let* connection=Runtime_model_discovery.connection_of_json (`Assoc (("provider_id",`String id)::template))
        |> Result.map_error (fun _ -> Unsupported_connection) in
      Runtime_model_discovery.discover ~sw ~net connection |> Result.map_error (fun error -> Discovery_failed error) in
    Ok (mark_bound_models config template id choice json))
let context ~binary ~net ~base_path request =
  Eio.Switch.run (fun sw ->
    let* request=fields ["source";"model";"load"] ["source";"model";"load"] request in
    let* model=text (value "model" request) in
    let* load=match value "load" request with `Bool value -> Ok value | _ -> Error Invalid_request in
    let* config=config ~base_path in
    let pending=ref [] in
    let* template,id,choice=source_template ~sw ~pending ~workspace:base_path config (value "source" request) in
    let observed = match choice with
      | Runtime_setup_spec.Antigravity ->
        let* command=text (value "command" template) in
        let* credential=text (value "credential_file" template) in
        native_json ~binary ["runtime-antigravity-context";"--cli-path";command;"--credential-file";credential;"--model";model]
      | Codex | Claude_code | Muse -> Error Unsupported_connection
      | Ollama | Llama_cpp | Vllm | Openai_compatible | Messages ->
        let* connection=Runtime_model_discovery.connection_of_json (`Assoc (("provider_id",`String id)::template))
          |> Result.map_error (fun _ -> Unsupported_connection) in
        Runtime_serving_context.observe ~sw ~net connection ~model ~load
          |> Result.map_error (fun error -> Discovery_failed error) in
    let verified json = match json with
      | `Assoc row when value "model" row=`String model && positive (value "context" row)<>None -> Some json
      | _ -> None in
    (match observed with
       | Ok json when verified json<>None -> Ok json
       | _ ->
         (* API catalog metadata is provider-scoped. Local transports and CLI
            windows must be observed; they never inherit model architecture. *)
         let declared = match choice with
           | Runtime_setup_spec.Openai_compatible | Messages ->
             (match Llm_provider.Model_catalog.load_default () with
              | Error _ -> None
              | Ok catalog -> Runtime_model_context_metadata.find ~provider_id:id ~model
                  (Llm_provider.Model_catalog.model_entries catalog))
           | Ollama | Llama_cpp | Vllm | Claude_code | Codex | Antigravity | Muse -> None in
         match declared with
         | Some context -> Ok (`Assoc ["model",`String model;"context",`Int context;
             "context_source",`String "installed_provider_catalog";"tools",`Null])
         | None -> observed))
let model_spec ~reported_models template request =
  let* fields=fields ["id";"context";"streaming";"supports_image_input"] ["id";"context";"streaming"] request in
  let* id=text (value "id" fields) in
  let context=value "context" fields and streaming=value "streaming" fields in
  let* ()=match context,streaming with `Int n,`Bool _ when n>0 -> Ok () | _ -> Error Invalid_request in
  let* ()=match reported_models with
    | None -> Ok ()
    | Some models ->
      (match List.find_opt (fun model -> String.equal model.id id) models with
       | Some {context=Some reported;_} when context=`Int reported -> Ok ()
       | Some _ | None -> Error Invalid_request) in
  let* image = match List.assoc_opt "supports_image_input" fields with
    | None -> Ok []
    | Some (`Bool _ as value) -> Ok ["supports_image_input", value]
    | Some _ -> Error Invalid_request in
  let* image = match reported_models with
    | None -> Ok image
    | Some models ->
      (match List.find_opt (fun model -> String.equal model.id id) models with
       | None -> Error Invalid_request
       | Some model ->
         let authoritative = match model.supports_image_input with
           | None -> [] | Some value -> ["supports_image_input", `Bool value] in
         if image = [] || image = authoritative then Ok authoritative
         else Error Invalid_request) in
  Runtime_setup_spec.of_json (`Assoc (template @ ["model",`String id;"max_context",context;
      "tools",`Bool true;"streaming",streaming] @ image)) |> Result.map_error (fun _ -> Invalid_request)
let save ~binary ~base_path request =
  Eio.Switch.run (fun sw ->
    let* body=fields ["revision";"connections";"selection";"default_runtime_id"] ["revision";"connections";"selection"] request in
    let* requested_default = match List.assoc_opt "default_runtime_id" body with
      | None -> Ok None
      | Some json -> text json |> Result.map Option.some in
    let* raw_revision=text (value "revision" body) in
    let* revision=Runtime_setup_batch.revision_of_string raw_revision |> Result.map_error (fun e -> Save_failed e) in
    let* connections=list (value "connections" body) in
    let* selection=list (value "selection" body) in
    let* config=config ~base_path in
    let pending=ref [] in
    let rec prepare = function
      | [] -> Ok []
      | connection::tail ->
        let* row=fields ["source";"models"] ["source";"models"] connection in
        let* template,provider_id,choice=source_template ~sw ~pending ~workspace:base_path config (value "source" row) in
        let* models=list (value "models" row) in
        let* ()=if models=[] then Error Invalid_request else Ok () in
        let* reported_models=match choice with
          | Runtime_setup_spec.Muse ->
            let* _,models=muse_catalog ~binary template in Ok (Some models)
          | Claude_code | Codex ->
            let client = match choice with Claude_code -> "claude-code" | _ -> "codex" in
            let* catalog = native_client_catalog ~binary client in
            (* A refreshed CLI model may be absent from the installed catalog;
               preserve unknown capability without accepting a browser assertion. *)
            let* selected = client_models ~catalog:false (`Assoc ["models",`List models]) in
            Ok (Some (with_catalog_image_capabilities selected catalog))
          | Ollama | Llama_cpp | Vllm | Openai_compatible | Messages
          | Antigravity -> Ok None in
        let rec specs = function [] -> Ok [] | model::tail ->
          let* spec=model_spec ~reported_models template model in
          let spec = match declared_provider config provider_id with
            | None -> spec
            | Some provider ->
              (match Runtime_setup_spec.for_provider spec provider with Some spec -> spec | None -> spec) in
          let* spec = Runtime_setup_spec.resolve_provider spec config.providers
            |> Result.map_error (fun _ -> Unsupported_connection) in
          let* tail=specs tail in Ok (spec::tail) in
        let* models=specs models in
        let* tail=prepare tail in Ok (models::tail) in
    let* prepared=prepare connections in
    let select = function
      | `Assoc ["runtime_id",raw] -> text raw
      | `Assoc fields when List.length fields=2 ->
        (match value "connection" fields,value "model" fields with
         | `Int c,`Int m when c>=0 && m>=0 ->
           (match List.nth_opt prepared c with
            | Some models -> (match List.nth_opt models m with
              | Some spec -> Ok (Runtime_setup_spec.render spec).runtime_id | None -> Error Invalid_request)
            | None -> Error Invalid_request)
         | _ -> Error Invalid_request)
      | _ -> Error Invalid_request in
    let rec selected = function [] -> Ok [] | row::tail ->
      let* id=select row in let* tail=selected tail in Ok (id::tail) in
    let* ids=selected selection in
    let specs=List.concat prepared in
    let* ()=if List.for_all (fun spec -> List.mem (Runtime_setup_spec.render spec).runtime_id ids) specs
      then Ok () else Error Invalid_request in
    match ids with
    | [] -> Error Invalid_request
    | primary::_ ->
      let* default_lane_id, default_runtime_id = match requested_default with
        | None -> Ok (None, primary)
        | Some requested when config.Runtime_schema.default_runtime_id = Some requested
            && List.exists (fun (lane:Runtime_schema.lane_decl) -> String.equal lane.id requested) config.lane_decls ->
          Ok (Some requested, primary)
        | Some requested when List.mem requested ids -> Ok (None, requested)
        | Some _ -> Error Invalid_request in
      let* receipt = Runtime_setup_batch.configure ~pending_credentials:!pending ?default_lane_id ~binary ~base_path
        ~expected_revision:revision ~specs ~runtime_ids:ids
        ~default_runtime_id ~verify:true ()
        |> Result.map_error (fun e -> Save_failed e) in
      Ok (Runtime_setup_batch.receipt_json receipt))
