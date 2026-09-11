type error = Invalid_request | Configuration_unavailable | Unsupported_connection
  | Credential_unavailable | Discovery_failed of Runtime_model_discovery.error
  | Save_failed of Runtime_setup_batch.error
let error_message = function
  | Invalid_request -> "Choose a connection and models with reported context metadata."
  | Configuration_unavailable -> "The workspace configuration could not be read."
  | Unsupported_connection -> "This connection needs its native account setup before web discovery."
  | Credential_unavailable -> "The selected connection's credential could not be prepared."
  | Discovery_failed error -> Runtime_model_discovery.error_message error
  | Save_failed error -> Runtime_setup_batch.error_message error
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
let choice = function
  | "openai-compatible-http" -> Ok "openai_compatible"
  | "messages-http" -> Ok "messages" | "ollama-http" -> Ok "ollama"
  | "codex-app-server" -> Ok "codex" | "claude-code" -> Ok "claude_code"
  | "antigravity-cli" -> Ok "antigravity" | _ -> Error Unsupported_connection
let private_key ~sw pending secret =
  match Runtime_setup_credentials.save ~secret () with
  | Error _ -> Error Credential_unavailable
  | Ok key ->
    pending := key :: !pending;
    Eio.Switch.on_release sw (fun () -> Runtime_setup_credentials.remove_uncommitted key);
    Ok ["credential_file",`String (Runtime_setup_credentials.reference_path key)]
let source_template ~sw ~pending config request =
  let* request = fields ["integration_id";"endpoint";"api_key"] ["integration_id"] request in
  let* id = text (value "integration_id" request) in
  let inventory = Runtime_wizard_inventory.to_json ~include_credential_references:true config in
  let rows = match inventory with `Assoc fields -> (match value "integrations" fields with `List rows -> rows | _ -> []) | _ -> [] in
  let matches = List.filter_map (function `Assoc fields when value "id" fields = `String id -> Some fields | _ -> None) rows in
  let* selected = match matches with [row] -> Ok row | _ -> Error Invalid_request in
  let* () = if value "setup_support" selected=`String "unsupported" then Error Unsupported_connection else Ok () in
  let* () = if value "endpoint_redacted" selected=`Bool true then Error Unsupported_connection else Ok () in
  let* protocol = text (value "protocol" selected) in
  let* choice = choice protocol in
  let http = List.mem choice ["openai_compatible";"messages";"ollama"] in
  let* () = if not http && List.mem_assoc "endpoint" request then Error Invalid_request else Ok () in
  let* endpoint = match List.assoc_opt "endpoint" request,List.assoc_opt "endpoint" selected with
    | None,existing -> Ok existing
    | Some (`String supplied),None -> let* endpoint=text (`String supplied) in Ok (Some (`String endpoint))
    | Some supplied,Some existing when supplied=existing -> Ok (Some existing)
    | _ -> Error Invalid_request in
  let endpoint_val = match endpoint with Some v -> v | None -> `Null in
  let transport = if http then ["endpoint", endpoint_val]
    else ["command",value "command" selected] in
  let metadata = if http then List.filter (fun (key,_) -> List.mem key ["provider_kind";"request_path"]) selected else [] in
  let* credentials = match List.assoc_opt "api_key" request with
    | Some (`String secret) when http -> private_key ~sw pending secret
    | Some _ -> Error Invalid_request
    | None ->
      (match value "credential_kind" selected with
       | `String "inline" ->
         (match List.find_opt (fun (p:Runtime_schema.provider) -> p.id=id) config.Runtime_schema.providers with
          | Some {credentials=Some (Runtime_schema.Inline secret);_} when http -> private_key ~sw pending secret
          | _ -> Error Credential_unavailable)
       | `String "file" ->
         (match value "credential_file" selected with
          | `String path -> Ok ["credential_file",`String path] | _ -> Error Credential_unavailable)
       | _ -> (match value "api_key_env" selected with
          | `String name when name<>"" -> Ok ["api_key_env",`String name] | _ -> Ok [])) in
  let* timeout = if choice<>"antigravity" then Ok [] else
    match List.find_opt (fun (p:Runtime_schema.provider) -> p.id=id) config.providers with
    | Some provider -> (match provider.antigravity_cli with
      | Some options -> Ok ["timeout_s",`Float options.timeout_s] | None -> Error Unsupported_connection)
    | None -> Error Unsupported_connection in
  Ok (("choice",`String choice)::transport @ metadata @ credentials @ timeout,id)
let discover ~sw:_ ~net ~base_path request =
  Eio.Switch.run (fun sw ->
    let* config=config ~base_path in
    let pending=ref [] in
    let* template,id=source_template ~sw ~pending config request in
    let* connection = Runtime_model_discovery.connection_of_json (`Assoc (("provider_id",`String id)::template))
      |> Result.map_error (fun _ -> Unsupported_connection) in
    Runtime_model_discovery.discover ~sw ~net connection |> Result.map_error (fun error -> Discovery_failed error))
let model_spec template request =
  let* fields=fields ["id";"context";"streaming"] ["id";"context";"streaming"] request in
  let* id=text (value "id" fields) in
  let context=value "context" fields and streaming=value "streaming" fields in
  let* ()=match context,streaming with `Int n,`Bool _ when n>0 -> Ok () | _ -> Error Invalid_request in
  Runtime_setup_spec.of_json (`Assoc (template @ ["model",`String id;"max_context",context;
      "tools",`Bool true;"streaming",streaming])) |> Result.map_error (fun _ -> Invalid_request)
let save ~binary ~base_path request =
  Eio.Switch.run (fun sw ->
    let* body=fields ["revision";"connections";"selection"] ["revision";"connections";"selection"] request in
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
        let* template,_=source_template ~sw ~pending config (value "source" row) in
        let* models=list (value "models" row) in
        let* ()=if models=[] then Error Invalid_request else Ok () in
        let rec specs = function [] -> Ok [] | model::tail ->
          let* spec=model_spec template model in let* tail=specs tail in Ok (spec::tail) in
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
      Runtime_setup_batch.configure ~pending_credentials:!pending ~binary ~base_path
        ~expected_revision:revision ~specs ~runtime_ids:ids
        ~default_runtime_id:primary ~verify:true ()
      |> Result.map_error (fun e -> Save_failed e)
      |> Result.map Runtime_setup_batch.receipt_json)
