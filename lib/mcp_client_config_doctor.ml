type stage_status =
  | Stage_pass
  | Stage_warn
  | Stage_fail
  | Stage_skip

type stage = {
  name : string;
  status : stage_status;
  detail : string;
}

type t = {
  config_path : string option;
  file_present : bool;
  parse_error : string option;
  server_names : string list;
  server_present : bool;
  url : string option;
  bearer_token_env_var : string option;
  bearer_token_env_matches : bool option;
  authorization_header_present : bool option;
  accept_header : string option;
  accept_header_ok : bool option;
  x_masc_agent : string option;
  x_masc_agent_ok : bool option;
  stages : stage list;
}

let stage name status detail = { name; status; detail }

let config_file_stage = "mcp_client_config_file"
let config_parse_stage = "mcp_client_config_parse"
let server_config_stage = "mcp_client_server_config"
let auth_model_stage = "mcp_client_auth_model"
let http_headers_stage = "mcp_client_http_headers"
let agent_header_stage = "mcp_client_agent_header"
let login_stage = "mcp_client_login"

let login_probe_stage (spec : Local_mcp_client_catalog.spec) =
  stage
    login_stage
    (if spec.login_supported then Stage_warn else Stage_skip)
    (match spec.login_note with
     | Some note -> note
     | None -> "MASC MCP client auth uses bearer-token config")

let stage_status_to_string = function
  | Stage_pass -> "pass"
  | Stage_warn -> "warn"
  | Stage_fail -> "fail"
  | Stage_skip -> "skip"

let empty ?config_path ?parse_error ?(file_present = false) stages =
  {
    config_path;
    file_present;
    parse_error;
    server_names = [];
    server_present = false;
    url = None;
    bearer_token_env_var = None;
    bearer_token_env_matches = None;
    authorization_header_present = None;
    accept_header = None;
    accept_header_ok = None;
    x_masc_agent = None;
    x_masc_agent_ok = None;
    stages;
  }

let table_fields_opt = function
  | Otoml.TomlTable fields
  | Otoml.TomlInlineTable fields ->
      Some fields
  | _ -> None

let assoc_opt key fields = List.assoc_opt key fields

let assoc_ci_opt key fields =
  let expected = String.lowercase_ascii key in
  List.find_map
    (fun (field_key, value) ->
      if String.equal (String.lowercase_ascii field_key) expected then
        Some value
      else
        None)
    fields

let string_opt key fields =
  match assoc_opt key fields with
  | Some (Otoml.TomlString value) -> Some value
  | _ -> None

let string_ci_opt key fields =
  match assoc_ci_opt key fields with
  | Some (Otoml.TomlString value) -> Some value
  | _ -> None

let sorted_keys fields =
  fields |> List.map fst |> List.sort_uniq String.compare

let accept_header_ok raw =
  let media_types =
    raw |> String.split_on_char ','
    |> List.map (fun value -> value |> String.trim |> String.lowercase_ascii)
  in
  List.mem "application/json" media_types
  && List.mem "text/event-stream" media_types

let server_names_detail names =
  match names with
  | [] -> "(none)"
  | _ -> String.concat ", " names

let config_path_opt (sync : Local_mcp_client_catalog.config_sync) =
  match Sys.getenv_opt sync.config_path_env_var |> Env_config_core.trim_opt with
  | Some path -> Some path
  | None ->
      Option.map
        (fun home ->
          List.fold_left Filename.concat home sync.default_config_path_segments)
        (Env_config_core.home_dir_opt ())

let analyze_content ~(spec : Local_mcp_client_catalog.spec) ~config_path content =
  match Otoml.Parser.from_string_result content with
  | Error parse_error ->
      empty ~config_path ~file_present:true ~parse_error
        [
          stage config_file_stage Stage_pass
            (Printf.sprintf "read %s" config_path);
          stage config_parse_stage Stage_fail parse_error;
          stage server_config_stage Stage_skip
            "skipped because MCP client config did not parse as TOML";
          stage auth_model_stage Stage_skip
            "skipped because MCP client config did not parse as TOML";
          stage http_headers_stage Stage_skip
            "skipped because MCP client config did not parse as TOML";
          stage agent_header_stage Stage_skip
            "skipped because MCP client config did not parse as TOML";
          login_probe_stage spec;
        ]
  | Ok toml ->
      let root_fields = table_fields_opt toml |> Option.value ~default:[] in
      let mcp_servers_fields =
        match assoc_opt "mcp_servers" root_fields with
        | Some value -> table_fields_opt value |> Option.value ~default:[]
        | None -> []
      in
      let server_names = sorted_keys mcp_servers_fields in
      let masc_fields =
        match assoc_opt spec.server_name mcp_servers_fields with
        | Some value -> table_fields_opt value
        | None -> None
      in
      let server_present = Option.is_some masc_fields in
      let url = Option.bind masc_fields (fun fields -> string_opt "url" fields) in
      let bearer_token_env_var =
        Option.bind masc_fields (fun fields ->
            string_opt "bearer_token_env_var" fields)
      in
      let bearer_token_env_matches =
        Option.map
          (String.equal spec.token_env_var)
          bearer_token_env_var
      in
      let headers_fields =
        Option.bind masc_fields (fun fields ->
            match assoc_opt "http_headers" fields with
            | Some value -> table_fields_opt value
            | None -> None)
      in
      let authorization_header_present =
        if not server_present then
          None
        else
          Some
            (match headers_fields with
             | Some fields ->
                 Option.is_some (assoc_ci_opt "Authorization" fields)
             | None -> false)
      in
      let accept_header =
        Option.bind headers_fields (fun fields -> string_ci_opt "Accept" fields)
      in
      let accept_header_ok = Option.map accept_header_ok accept_header in
      let x_masc_agent =
        Option.bind headers_fields (fun fields ->
            string_ci_opt "X-MASC-Agent" fields)
      in
      let x_masc_agent_ok =
        Option.map (String.equal spec.agent_name) x_masc_agent
      in
      let config_stage =
        stage config_file_stage Stage_pass
          (Printf.sprintf "read %s" config_path)
      in
      let parse_stage =
        stage config_parse_stage Stage_pass "TOML parsed"
      in
      let server_stage =
        if server_present then
          stage server_config_stage Stage_pass
            (Printf.sprintf "[mcp_servers.%s] is present" spec.server_name)
        else
          stage server_config_stage Stage_fail
            (Printf.sprintf
               "[mcp_servers.%s] is missing; configured server names: %s"
               spec.server_name (server_names_detail server_names))
      in
      let auth_stage =
        match server_present, bearer_token_env_var, authorization_header_present with
        | false, _, _ ->
            stage auth_model_stage Stage_skip
              (Printf.sprintf "skipped because [mcp_servers.%s] is missing" spec.server_name)
        | true, Some env_var, Some false
          when String.equal env_var spec.token_env_var ->
            stage auth_model_stage Stage_pass
              (Printf.sprintf
                 "uses bearer_token_env_var=%s and no hardcoded Authorization header"
                 spec.token_env_var)
        | true, Some env_var, Some true
          when String.equal env_var spec.token_env_var ->
            stage auth_model_stage Stage_fail
              "bearer_token_env_var is correct, but http_headers still contains Authorization"
        | true, Some env_var, _ ->
            stage auth_model_stage Stage_fail
              (Printf.sprintf
                 "expected bearer_token_env_var=%s, found %s"
                 spec.token_env_var env_var)
        | true, None, Some true ->
            stage auth_model_stage Stage_fail
              "missing bearer_token_env_var and http_headers contains Authorization"
        | true, None, _ ->
            stage auth_model_stage Stage_fail
              (Printf.sprintf "missing bearer_token_env_var=%s" spec.token_env_var)
      in
      let headers_stage =
        match server_present, accept_header_ok with
        | false, _ ->
            stage http_headers_stage Stage_skip
              (Printf.sprintf "skipped because [mcp_servers.%s] is missing" spec.server_name)
        | true, Some true ->
            stage http_headers_stage Stage_pass
              "Accept covers application/json and text/event-stream"
        | true, Some false ->
            stage http_headers_stage Stage_fail
              "Accept must include application/json and text/event-stream"
        | true, None ->
            stage http_headers_stage Stage_fail
              "missing http_headers.Accept for Streamable HTTP MCP"
      in
      let agent_stage =
        match server_present, x_masc_agent_ok with
        | false, _ ->
            stage agent_header_stage Stage_skip
              (Printf.sprintf "skipped because [mcp_servers.%s] is missing" spec.server_name)
        | true, Some true ->
            stage agent_header_stage Stage_pass
              (Printf.sprintf "X-MASC-Agent identifies %s" spec.agent_name)
        | true, Some false ->
            stage agent_header_stage Stage_warn
              (Printf.sprintf "X-MASC-Agent is present but not %s" spec.agent_name)
        | true, None ->
            stage agent_header_stage Stage_warn
              (Printf.sprintf "missing X-MASC-Agent=%s header" spec.agent_name)
      in
      {
        config_path = Some config_path;
        file_present = true;
        parse_error = None;
        server_names;
        server_present;
        url;
        bearer_token_env_var;
        bearer_token_env_matches;
        authorization_header_present;
        accept_header;
        accept_header_ok;
        x_masc_agent;
        x_masc_agent_ok;
        stages =
          [
            config_stage;
            parse_stage;
            server_stage;
            auth_stage;
            headers_stage;
            agent_stage;
            login_probe_stage spec;
          ];
      }

let analyze_path ~(spec : Local_mcp_client_catalog.spec) config_path =
  if not (Sys.file_exists config_path) then
    empty ~config_path
      [
        stage config_file_stage Stage_fail
          (Printf.sprintf "MCP client config file does not exist: %s" config_path);
        stage config_parse_stage Stage_skip
          "skipped because MCP client config file is missing";
        stage server_config_stage Stage_skip
          "skipped because MCP client config file is missing";
        stage auth_model_stage Stage_skip
          "skipped because MCP client config file is missing";
        stage http_headers_stage Stage_skip
          "skipped because MCP client config file is missing";
        stage agent_header_stage Stage_skip
          "skipped because MCP client config file is missing";
        login_probe_stage spec;
      ]
  else
    try analyze_content ~spec ~config_path (Fs_compat.load_file config_path)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        empty ~config_path ~file_present:true
          ~parse_error:(Printexc.to_string exn)
          [
            stage config_file_stage Stage_fail
              (Printf.sprintf "failed to read %s: %s" config_path
                 (Printexc.to_string exn));
            stage config_parse_stage Stage_skip
              "skipped because MCP client config file could not be read";
            stage server_config_stage Stage_skip
              "skipped because MCP client config file could not be read";
            stage auth_model_stage Stage_skip
              "skipped because MCP client config file could not be read";
            stage http_headers_stage Stage_skip
              "skipped because MCP client config file could not be read";
            stage agent_header_stage Stage_skip
              "skipped because MCP client config file could not be read";
            login_probe_stage spec;
          ]

let analyze_default ~(spec : Local_mcp_client_catalog.spec)
    ~(config_sync : Local_mcp_client_catalog.config_sync) () =
  match config_path_opt config_sync with
  | None ->
      empty
        [
          stage config_file_stage Stage_fail
            (Printf.sprintf "HOME and %s are unset" config_sync.config_path_env_var);
          stage config_parse_stage Stage_skip
            "skipped because MCP client config path is unknown";
          stage server_config_stage Stage_skip
            "skipped because MCP client config path is unknown";
          stage auth_model_stage Stage_skip
            "skipped because MCP client config path is unknown";
          stage http_headers_stage Stage_skip
            "skipped because MCP client config path is unknown";
          stage agent_header_stage Stage_skip
            "skipped because MCP client config path is unknown";
          login_probe_stage spec;
        ]
  | Some path -> analyze_path ~spec path

let stage_to_yojson stage =
  `Assoc
    [
      ("name", `String stage.name);
      ("status", `String (stage_status_to_string stage.status));
      ("detail", `String stage.detail);
    ]

let option_field name = function
  | Some value -> (name, `String value)
  | None -> (name, `Null)

let option_bool_field name = function
  | Some value -> (name, `Bool value)
  | None -> (name, `Null)

let to_yojson report =
  `Assoc
    [
      option_field "config_path" report.config_path;
      ("file_present", `Bool report.file_present);
      option_field "parse_error" report.parse_error;
      ( "server_names",
        `List (List.map (fun value -> `String value) report.server_names) );
      ("server_present", `Bool report.server_present);
      option_field "url" report.url;
      option_field "bearer_token_env_var" report.bearer_token_env_var;
      option_bool_field "bearer_token_env_matches"
        report.bearer_token_env_matches;
      option_bool_field "authorization_header_present"
        report.authorization_header_present;
      option_field "accept_header" report.accept_header;
      option_bool_field "accept_header_ok" report.accept_header_ok;
      option_field "x_masc_agent" report.x_masc_agent;
      option_bool_field "x_masc_agent_ok" report.x_masc_agent_ok;
      ("stages", `List (List.map stage_to_yojson report.stages));
    ]

let warnings report =
  report.stages
  |> List.filter_map (fun stage ->
         match stage.status with
         | Stage_fail | Stage_warn ->
             Some
               (Printf.sprintf "MCP client config pipeline %s: %s" stage.name
                  stage.detail)
         | Stage_pass | Stage_skip -> None)

let next_actions ~(spec : Local_mcp_client_catalog.spec)
    ~(config_sync : Local_mcp_client_catalog.config_sync) report =
  let has_stage name =
    List.exists
      (fun stage ->
        String.equal stage.name name
        &&
        match stage.status with
        | Stage_fail | Stage_warn -> true
        | Stage_pass | Stage_skip -> false)
      report.stages
  in
  [
    (if has_stage config_file_stage then
       Some
         (Printf.sprintf
            "Set %s or HOME so doctor auth can inspect the MCP client config file."
            config_sync.config_path_env_var)
     else
       None);
    (if has_stage server_config_stage then
       Some
         (Printf.sprintf
            "Create a [mcp_servers.%s] entry in the MCP client config."
            spec.server_name)
     else
       None);
    (if has_stage auth_model_stage then
       Some
         (Printf.sprintf
            "Set [mcp_servers.%s].bearer_token_env_var=\"%s\" and remove hardcoded Authorization from http_headers."
            spec.server_name spec.token_env_var)
     else
       None);
    (if has_stage http_headers_stage then
       Some
         (Printf.sprintf
            "Set [mcp_servers.%s].http_headers.Accept to include application/json and text/event-stream."
            spec.server_name)
     else
       None);
    (if has_stage agent_header_stage then
       Some
         (Printf.sprintf
            "Set [mcp_servers.%s].http_headers.X-MASC-Agent=\"%s\" for config/runtime attribution."
            spec.server_name spec.agent_name)
     else
       None);
  ]
  |> List.filter_map Fun.id
