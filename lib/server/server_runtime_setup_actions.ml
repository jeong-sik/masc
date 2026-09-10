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
let value key fields = Option.value ~default:`Null (List.assoc_opt key fields)
let config ~base_path =
  let path = Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "config") "runtime.toml" in
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
  let transport = if http then ["endpoint",Option.value ~default:`Null endpoint]
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
let native_json ~binary args =
  match Process_eio.run_argv_with_status_split_or_refusal (binary::args) with
  | Ok (Unix.WEXITED 0,body,_) ->
    (try Ok (Yojson.Safe.from_string body) with Yojson.Json_error _ -> Error Unsupported_connection)
  | Ok _ | Error _ -> Error Unsupported_connection
let positive = function `Int n when n>0 -> Some n | _ -> None
let project_client_models ~source ~catalog json =
  let* root=match json with `Assoc fields -> Ok fields | _ -> Error Unsupported_connection in
  let* models=list (value "models" root) in
  let rec project seen = function
    | [] -> Ok []
    | (`Assoc row)::tail ->
      let* id=text (value "id" row) in
      let* ()=if List.mem id seen then Error Unsupported_connection else Ok () in
      let label=match value "label" row with `String label -> label | _ -> id in
      let context=value (if catalog then "max_context" else "context") row in
      let context=match positive context with Some n -> `Int n | None -> `Null in
      let* tail=project (id::seen) tail in
      Ok (`Assoc ["id",`String id;"label",`String label;"context",context;"tools",`Null]::tail)
    | _ -> Error Unsupported_connection in
  let* rows=project [] models in
  Ok (`Assoc ["source",`String source;"account_availability_verified",`Bool false;"models",`List rows])
let discover ~binary ~sw:_ ~net ~base_path request =
  Eio.Switch.run (fun sw ->
    let* config=config ~base_path in
    let pending=ref [] in
    let* template,id=source_template ~sw ~pending config request in
    match value "choice" template with
    | `String "codex" ->
      let* command=text (value "command" template) in
      let* json=native_json ~binary ["runtime-codex-models";"--cli-path";command] in
      project_client_models ~source:"codex_isolated_account_model_list" ~catalog:false json
    | `String "claude_code" ->
      let* json=native_json ~binary ["runtime-model-list";"claude-code"] in
      project_client_models ~source:"installed_claude_catalog_not_account_verification" ~catalog:true json
    | `String "antigravity" ->
      let* command=text (value "command" template) in
      let* credential=text (value "credential_file" template) in
      let* json=native_json ~binary ["runtime-antigravity-models";"--cli-path";command;"--credential-file";credential] in
      project_client_models ~source:"antigravity_selected_account_models" ~catalog:false json
    | _ ->
      let* connection=Runtime_model_discovery.connection_of_json (`Assoc (("provider_id",`String id)::template))
        |> Result.map_error (fun _ -> Unsupported_connection) in
      Runtime_model_discovery.discover ~sw ~net connection |> Result.map_error (fun error -> Discovery_failed error))
let context ~binary ~net ~base_path request =
  Eio.Switch.run (fun sw ->
    let* request=fields ["source";"model";"load"] ["source";"model";"load"] request in
    let* model=text (value "model" request) in
    let* load=match value "load" request with `Bool value -> Ok value | _ -> Error Invalid_request in
    let* config=config ~base_path in
    let pending=ref [] in
    let* template,id=source_template ~sw ~pending config (value "source" request) in
    let observed = match value "choice" template with
      | `String "antigravity" ->
        let* command=text (value "command" template) in
        let* credential=text (value "credential_file" template) in
        native_json ~binary ["runtime-antigravity-context";"--cli-path";command;"--credential-file";credential;"--model";model]
      | `String ("codex"|"claude_code") -> Error Unsupported_connection
      | _ ->
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
         let declared = match value "choice" template with
           | `String ("openai_compatible"|"messages") ->
             (match Llm_provider.Model_catalog.load_default () with
              | Error _ -> None
              | Ok catalog -> Runtime_model_context_metadata.find ~provider_id:id ~model
                  (Llm_provider.Model_catalog.model_entries catalog))
           | _ -> None in
         match declared with
         | Some context -> Ok (`Assoc ["model",`String model;"context",`Int context;
             "context_source",`String "installed_provider_catalog";"tools",`Null])
         | None -> observed))
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
