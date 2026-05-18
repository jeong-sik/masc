module Cascade_decl = Cascade_declarative_types

let option_int_json = function
  | Some value -> `Int value
  | None -> `Null

let option_string_json = function
  | Some value -> `String value
  | None -> `Null

let provider_log_surface = "/api/v1/dashboard/provider-logs"
let provider_log_tail_surface = "/api/v1/dashboard/provider-logs/tail"
let provider_log_default_lines = 200
let provider_log_max_lines = 3000
let provider_log_default_max_bytes = 1_048_576
let provider_log_hard_max_bytes = 4_194_304

let clamp_int ~min_value ~max_value value = max min_value (min max_value value)

let string_starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix

let expand_provider_log_path raw =
  let path = String.trim raw in
  match Sys.getenv_opt "HOME" with
  | Some home when string_starts_with ~prefix:"~/" path ->
      home ^ String.sub path 1 (String.length path - 1)
  | Some home when string_starts_with ~prefix:"$HOME/" path ->
      home ^ String.sub path 5 (String.length path - 5)
  | _ -> path

let provider_log_parse_errors_json errors =
  errors
  |> List.map (fun (err : Cascade_declarative_parser.parse_error) ->
         Printf.sprintf "%s: %s" err.path err.message)
  |> String.concat "; "

let provider_log_error_json ~surface message =
  `Assoc
    [
      ("generated_at_iso", `String (Masc_domain.now_iso ()));
      ("dashboard_surface", `String surface);
      ("source", `String "cascade_provider_log");
      ("ok", `Bool false);
      ("error", `String message);
    ]

let load_provider_log_config () =
  match Cascade_runtime.cascade_config_path () with
  | None -> Error "cascade config path unavailable"
  | Some path -> (
      match Cascade_declarative_parser.parse_file path with
      | Ok cfg -> Ok (path, cfg)
      | Error errors -> Error (provider_log_parse_errors_json errors))

let provider_log_metadata_json
    ~(config_path : string)
    (provider : Cascade_decl.cascade_provider)
    (log : Cascade_decl.cascade_provider_log) =
  let resolved_path =
    match log.path with
    | Some path -> `String (expand_provider_log_path path)
    | None -> `Null
  in
  `Assoc
    [
      ("id", `String provider.id);
      ("display_name", `String provider.display_name);
      ("protocol", `String provider.protocol);
      ("enabled", `Bool log.enabled);
      ("path", option_string_json log.path);
      ("resolved_path", resolved_path);
      ("default_lines", option_int_json log.default_lines);
      ("max_bytes", option_int_json log.max_bytes);
      ("cascade_config_path", `String config_path);
    ]

let dashboard_provider_logs_json () =
  match load_provider_log_config () with
  | Error message ->
      `Assoc
        [
          ("generated_at_iso", `String (Masc_domain.now_iso ()));
          ("dashboard_surface", `String provider_log_surface);
          ("source", `String "cascade_provider_log");
          ("ok", `Bool false);
          ("error", `String message);
          ("providers", `List []);
        ]
  | Ok (config_path, cfg) ->
      let providers =
        cfg.providers
        |> List.filter_map (fun (provider : Cascade_decl.cascade_provider) ->
               match provider.log with
               | None -> None
               | Some log -> Some (provider_log_metadata_json ~config_path provider log))
      in
      `Assoc
        [
          ("generated_at_iso", `String (Masc_domain.now_iso ()));
          ("dashboard_surface", `String provider_log_surface);
          ("source", `String "cascade_provider_log");
          ("ok", `Bool true);
          ("providers", `List providers);
        ]

let configured_provider_log provider_id cfg =
  match
    List.find_opt
      (fun (provider : Cascade_decl.cascade_provider) ->
        String.equal provider.id provider_id)
      cfg.Cascade_decl.providers
  with
  | None -> None
  | Some provider -> (
    match provider.Cascade_decl.log with
    | Some log -> Some (provider, log)
    | None -> None)

let strip_trailing_cr line =
  let len = String.length line in
  if len > 0 && Char.equal line.[len - 1] '\r' then
    String.sub line 0 (len - 1)
  else
    line

let drop_first = function
  | [] -> []
  | _ :: rest -> rest

let drop_trailing_empty lines =
  match List.rev lines with
  | "" :: rest -> List.rev rest
  | _ -> lines

let rec drop_n n lines =
  if n <= 0 then
    lines
  else
    match lines with
    | [] -> []
    | _ :: rest -> drop_n (n - 1) rest

let tail_list ~limit lines =
  let length = List.length lines in
  drop_n (length - min length limit) lines

let read_provider_log_tail ~path ~lines ~max_bytes =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let file_len = in_channel_length ic in
      let start = max 0 (file_len - max_bytes) in
      let read_len = file_len - start in
      seek_in ic start;
      let raw = really_input_string ic read_len in
      let parsed =
        raw
        |> String.split_on_char '\n'
        |> (fun parts -> if start > 0 then drop_first parts else parts)
        |> drop_trailing_empty
        |> List.map strip_trailing_cr
        |> tail_list ~limit:lines
      in
      List.mapi
        (fun index text -> `Assoc [ ("line", `Int (index + 1)); ("text", `String text) ])
        parsed)

let provider_log_int_or_default opt fallback =
  match opt with
  | Some value -> value
  | None -> fallback

let dashboard_provider_log_tail_json request =
  let error status message =
    (status, provider_log_error_json ~surface:provider_log_tail_surface message)
  in
  let provider_id =
    match Server_utils.query_param request "provider" with
    | Some raw -> String.trim raw
    | None -> ""
  in
  if String.equal provider_id "" then
    error `Bad_request "provider query parameter is required"
  else
    match load_provider_log_config () with
    | Error message -> error `Internal_server_error message
    | Ok (config_path, cfg) -> (
      match configured_provider_log provider_id cfg with
      | None ->
          error `Not_found
            (Printf.sprintf "provider %S has no configured log" provider_id)
      | Some (_provider, log) when not log.enabled ->
          error `Forbidden
            (Printf.sprintf "provider %S log tail is disabled" provider_id)
      | Some (_provider, { path = None; _ }) ->
          error `Bad_request
            (Printf.sprintf "provider %S log path is not configured" provider_id)
      | Some (provider, ({ path = Some raw_path; _ } as log)) ->
          let path = expand_provider_log_path raw_path in
          if String.equal path "" || Filename.is_relative path then
            error `Bad_request
              "provider log path must be absolute after ~/ or $HOME expansion"
          else
            let default_lines =
              provider_log_int_or_default log.default_lines provider_log_default_lines
              |> clamp_int ~min_value:1 ~max_value:provider_log_max_lines
            in
            let requested_lines =
              Server_utils.int_query_param request "lines" ~default:default_lines
              |> clamp_int ~min_value:1 ~max_value:provider_log_max_lines
            in
            let max_bytes =
              provider_log_int_or_default log.max_bytes provider_log_default_max_bytes
              |> clamp_int ~min_value:1 ~max_value:provider_log_hard_max_bytes
            in
            try
              let entries =
                read_provider_log_tail ~path ~lines:requested_lines ~max_bytes
              in
              ( `OK,
                `Assoc
                  [
                    ("generated_at_iso", `String (Masc_domain.now_iso ()));
                    ("dashboard_surface", `String provider_log_tail_surface);
                    ("source", `String "cascade_provider_log_file");
                    ("ok", `Bool true);
                    ( "provider",
                      `Assoc
                        [
                          ("id", `String provider.id);
                          ("display_name", `String provider.display_name);
                          ("protocol", `String provider.protocol);
                        ] );
                    ("log", provider_log_metadata_json ~config_path provider log);
                    ( "query",
                      `Assoc
                        [
                          ("lines", `Int requested_lines);
                          ("max_bytes", `Int max_bytes);
                        ] );
                    ("returned", `Int (List.length entries));
                    ("entries", `List entries);
                  ] )
            with
            | Sys_error message -> error `Internal_server_error message
            | exn -> error `Internal_server_error (Printexc.to_string exn))
