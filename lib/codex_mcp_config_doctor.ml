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

let config_client = Local_mcp_clients.generated_config_client
let expected_server_name = Local_mcp_clients.generated_config_server_name
let expected_token_env_var = config_client.token_env_var
let expected_x_masc_agent = config_client.agent_name
let config_path_env_key = Local_mcp_clients.generated_config_path_env_key
let client_name = config_client.client_name
let client_display_name = String.capitalize_ascii client_name
let client_mcp_label = client_display_name ^ " MCP"
let cli_login_command = Printf.sprintf "`%s mcp login`" client_name
let stage_name suffix = client_name ^ "_" ^ suffix
let stage_config_file = stage_name "config_file"
let stage_config_parse = stage_name "config_parse"
let stage_server_config = stage_name "server_config"
let stage_auth_model = stage_name "auth_model"
let stage_http_headers = stage_name "http_headers"
let stage_agent_header = stage_name "agent_header"
let stage_oauth_login = stage_name "oauth_login"

let stage name status detail = { name; status; detail }

let oauth_login_stage () =
  stage stage_oauth_login Stage_skip
    (Printf.sprintf
       "%s is not part of the MASC bearer-token path"
       cli_login_command)

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

let config_path_opt () =
  match Sys.getenv_opt config_path_env_key |> Env_config_core.trim_opt with
  | Some path -> Some path
  | None ->
      Option.map
        (fun home ->
           Filename.concat home Local_mcp_clients.generated_config_relative_path)
        (Env_config_core.home_dir_opt ())

let analyze_content ~config_path content =
  match Otoml.Parser.from_string_result content with
  | Error parse_error ->
      empty ~config_path ~file_present:true ~parse_error
        [
          stage stage_config_file Stage_pass
            (Printf.sprintf "read %s" config_path);
          stage stage_config_parse Stage_fail parse_error;
          stage stage_server_config Stage_skip
            (Printf.sprintf
               "skipped because %s config did not parse as TOML"
               client_display_name);
          stage stage_auth_model Stage_skip
            (Printf.sprintf
               "skipped because %s config did not parse as TOML"
               client_display_name);
          stage stage_http_headers Stage_skip
            (Printf.sprintf
               "skipped because %s config did not parse as TOML"
               client_display_name);
          stage stage_agent_header Stage_skip
            (Printf.sprintf
               "skipped because %s config did not parse as TOML"
               client_display_name);
          oauth_login_stage ();
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
        match assoc_opt expected_server_name mcp_servers_fields with
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
          (String.equal expected_token_env_var)
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
        Option.map (String.equal expected_x_masc_agent) x_masc_agent
      in
      let config_stage =
        stage stage_config_file Stage_pass
          (Printf.sprintf "read %s" config_path)
      in
      let parse_stage =
        stage stage_config_parse Stage_pass "TOML parsed"
      in
      let server_stage =
        if server_present then
          stage stage_server_config Stage_pass
            (Printf.sprintf "[mcp_servers.%s] is present" expected_server_name)
        else
          stage stage_server_config Stage_fail
            (Printf.sprintf
               "[mcp_servers.%s] is missing; configured server names: %s"
               expected_server_name (server_names_detail server_names))
      in
      let auth_stage =
        match server_present, bearer_token_env_var, authorization_header_present with
        | false, _, _ ->
            stage stage_auth_model Stage_skip
              (Printf.sprintf
                 "skipped because [mcp_servers.%s] is missing"
                 expected_server_name)
        | true, Some env_var, Some false
          when String.equal env_var expected_token_env_var ->
            stage stage_auth_model Stage_pass
              (Printf.sprintf
                 "uses bearer_token_env_var=%s and no hardcoded Authorization header"
                 expected_token_env_var)
        | true, Some env_var, Some true
          when String.equal env_var expected_token_env_var ->
            stage stage_auth_model Stage_fail
              "bearer_token_env_var is correct, but http_headers still contains Authorization"
        | true, Some env_var, _ ->
            stage stage_auth_model Stage_fail
              (Printf.sprintf
                 "expected bearer_token_env_var=%s, found %s"
                 expected_token_env_var env_var)
        | true, None, Some true ->
            stage stage_auth_model Stage_fail
              "missing bearer_token_env_var and http_headers contains Authorization"
        | true, None, _ ->
            stage stage_auth_model Stage_fail
              (Printf.sprintf
                 "missing bearer_token_env_var=%s"
                 expected_token_env_var)
      in
      let headers_stage =
        match server_present, accept_header_ok with
        | false, _ ->
            stage stage_http_headers Stage_skip
              (Printf.sprintf
                 "skipped because [mcp_servers.%s] is missing"
                 expected_server_name)
        | true, Some true ->
            stage stage_http_headers Stage_pass
              "Accept covers application/json and text/event-stream"
        | true, Some false ->
            stage stage_http_headers Stage_fail
              "Accept must include application/json and text/event-stream"
        | true, None ->
            stage stage_http_headers Stage_fail
              "missing http_headers.Accept for Streamable HTTP MCP"
      in
      let agent_stage =
        match server_present, x_masc_agent_ok with
        | false, _ ->
            stage stage_agent_header Stage_skip
              (Printf.sprintf
                 "skipped because [mcp_servers.%s] is missing"
                 expected_server_name)
        | true, Some true ->
            stage stage_agent_header Stage_pass
              (Printf.sprintf "X-MASC-Agent identifies %s" expected_x_masc_agent)
        | true, Some false ->
            stage stage_agent_header Stage_warn
              (Printf.sprintf
                 "X-MASC-Agent is present but not %s"
                 expected_x_masc_agent)
        | true, None ->
            stage stage_agent_header Stage_warn
              (Printf.sprintf
                 "missing X-MASC-Agent=%s header"
                 expected_x_masc_agent)
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
            oauth_login_stage ();
          ];
      }

let analyze_path config_path =
  if not (Sys.file_exists config_path) then
    empty ~config_path
      [
        stage stage_config_file Stage_fail
          (Printf.sprintf
             "%s config file does not exist: %s"
             client_display_name config_path);
        stage stage_config_parse Stage_skip
          (Printf.sprintf
             "skipped because %s config file is missing"
             client_display_name);
        stage stage_server_config Stage_skip
          (Printf.sprintf
             "skipped because %s config file is missing"
             client_display_name);
        stage stage_auth_model Stage_skip
          (Printf.sprintf
             "skipped because %s config file is missing"
             client_display_name);
        stage stage_http_headers Stage_skip
          (Printf.sprintf
             "skipped because %s config file is missing"
             client_display_name);
        stage stage_agent_header Stage_skip
          (Printf.sprintf
             "skipped because %s config file is missing"
             client_display_name);
        oauth_login_stage ();
      ]
  else
    try analyze_content ~config_path (Fs_compat.load_file config_path)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        empty ~config_path ~file_present:true
          ~parse_error:(Printexc.to_string exn)
          [
            stage stage_config_file Stage_fail
              (Printf.sprintf "failed to read %s: %s" config_path
                 (Printexc.to_string exn));
            stage stage_config_parse Stage_skip
              (Printf.sprintf
                 "skipped because %s config file could not be read"
                 client_display_name);
            stage stage_server_config Stage_skip
              (Printf.sprintf
                 "skipped because %s config file could not be read"
                 client_display_name);
            stage stage_auth_model Stage_skip
              (Printf.sprintf
                 "skipped because %s config file could not be read"
                 client_display_name);
            stage stage_http_headers Stage_skip
              (Printf.sprintf
                 "skipped because %s config file could not be read"
                 client_display_name);
            stage stage_agent_header Stage_skip
              (Printf.sprintf
                 "skipped because %s config file could not be read"
                 client_display_name);
            oauth_login_stage ();
          ]

let analyze_default () =
  match config_path_opt () with
  | None ->
      empty
        [
          stage stage_config_file Stage_fail
            (Printf.sprintf
               "HOME and %s are unset"
               config_path_env_key);
          stage stage_config_parse Stage_skip
            (Printf.sprintf
               "skipped because %s config path is unknown"
               client_display_name);
          stage stage_server_config Stage_skip
            (Printf.sprintf
               "skipped because %s config path is unknown"
               client_display_name);
          stage stage_auth_model Stage_skip
            (Printf.sprintf
               "skipped because %s config path is unknown"
               client_display_name);
          stage stage_http_headers Stage_skip
            (Printf.sprintf
               "skipped because %s config path is unknown"
               client_display_name);
          stage stage_agent_header Stage_skip
            (Printf.sprintf
               "skipped because %s config path is unknown"
               client_display_name);
          oauth_login_stage ();
        ]
  | Some path -> analyze_path path

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
               (Printf.sprintf
                  "%s pipeline %s: %s"
                  client_mcp_label stage.name stage.detail)
         | Stage_pass | Stage_skip -> None)

let next_actions report =
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
    (if has_stage stage_config_file then
       Some
         (Printf.sprintf
            "Set %s or HOME so doctor auth can inspect the %s config file."
            config_path_env_key client_mcp_label)
     else
       None);
    (if has_stage stage_server_config then
       Some
         (Printf.sprintf
            "Create a [mcp_servers.%s] entry in %s config; MASC does not use %s OAuth."
            expected_server_name client_display_name cli_login_command)
     else
       None);
    (if has_stage stage_auth_model then
       Some
         (Printf.sprintf
            "Set [mcp_servers.%s].bearer_token_env_var=\"%s\" and remove hardcoded Authorization from http_headers."
            expected_server_name expected_token_env_var)
     else
       None);
    (if has_stage stage_http_headers then
       Some
         (Printf.sprintf
            "Set [mcp_servers.%s].http_headers.Accept to include application/json and text/event-stream."
            expected_server_name)
     else
       None);
    (if has_stage stage_agent_header then
       Some
         (Printf.sprintf
            "Set [mcp_servers.%s].http_headers.X-MASC-Agent=\"%s\" for config/runtime attribution."
            expected_server_name expected_x_masc_agent)
     else
       None);
  ]
  |> List.filter_map Fun.id
