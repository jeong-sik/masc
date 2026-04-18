(** HTTP routes for sidecar lifecycle.

    Provides [/api/v1/sidecar/{start,stop,status}] endpoints that shell
    out to [sidecars/<id>-bot/run.sh]. The wrapper is the single source
    of truth for how a sidecar is started, signalled, and inspected —
    this module only thin-wraps it for HTTP consumers (i.e. the
    dashboard's connectors surface).

    Design baseline: docs/SIDECAR-LIFECYCLE-API-RFC.md.

    Uses query-string [?name=<id>] (matching the existing channel_gate
    routes such as [/api/v1/gate/connector/bind?name=<connector>])
    rather than path params, so we don't introduce a second routing
    convention.

    @since v0.10.0 *)

open Server_auth

module Http = Http_server_eio

(** Whitelist of sidecars the backend will spawn or signal. Anything else
    short-circuits at the request boundary so [Sys.command] is never reached
    for an attacker-controlled id. *)
let known_ids = [ "discord"; "imessage"; "slack"; "telegram" ]

(** Pure whitelist check; exposed so unit tests can confirm shell-meta and
    path traversal in [name=] are rejected before any [Sys.command] /
    [Process_eio] is reached. *)
let validate_name = function
  | None -> Error "missing 'name' query parameter"
  | Some n when List.mem n known_ids -> Ok n
  | Some n -> Error (Printf.sprintf "unknown sidecar id: %s" n)

let parse_name request =
  validate_name (Server_utils.query_param request "name")

let starts_with ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.equal (String.sub value 0 prefix_len) prefix

let trim_opt = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let runtime_base_path ?base_path () =
  match trim_opt base_path with
  | Some path -> path
  | None -> (
      match Sys.getenv_opt "MASC_BASE_PATH" with
      | Some p when String.length (String.trim p) > 0 -> String.trim p
      | _ -> Sys.getcwd ())

let request_base_path state =
  state.Mcp_server.room_config.base_path

let dir_exists path =
  Sys.file_exists path && Sys.is_directory path

let dedupe_keep_order values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if Hashtbl.mem seen value then
        false
      else (
        Hashtbl.replace seen value ();
        true))
    values

let project_root_from_executable () =
  let raw_exe =
    try Sys.executable_name with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | _ -> ""
  in
  let exe =
    if raw_exe = "" then ""
    else
      try Unix.realpath raw_exe
      with Unix.Unix_error _ | Sys_error _ | Invalid_argument _ -> raw_exe
  in
  if exe = "" then None
  else
    let rec walk dir =
      let parent = Filename.dirname dir in
      if String.equal parent dir then None
      else if String.equal (Filename.basename dir) "_build" then Some parent
      else walk parent
    in
    walk (Filename.dirname exe)

let sidecar_root () =
  trim_opt (Sys.getenv_opt "MASC_SIDECAR_ROOT")

let sidecar_root_candidates ?sidecar_root ?project_root ~base_path () =
  [ sidecar_root; Some base_path; project_root ]
  |> List.filter_map (fun item -> item)
  |> dedupe_keep_order

let sidecar_dir_under root id =
  Filename.concat root (Printf.sprintf "sidecars/%s-bot" id)

let resolve_existing_sidecar_dir ?sidecar_root ?project_root ~base_path id =
  sidecar_root_candidates ?sidecar_root ?project_root ~base_path ()
  |> List.find_map (fun root ->
         let dir = sidecar_dir_under root id in
         if dir_exists dir then Some dir else None)

let missing_sidecar_dir_message ?sidecar_root ?project_root ~base_path id =
  let searched =
    sidecar_root_candidates ?sidecar_root ?project_root ~base_path ()
    |> List.map (fun root -> sidecar_dir_under root id)
  in
  let searched_text =
    match searched with
    | [] -> "no candidate roots"
    | paths -> String.concat ", " paths
  in
  Printf.sprintf
    "sidecar directory not found for %s; looked under %s. Set \
     MASC_SIDECAR_ROOT=/path/to/masc-mcp or start the server with \
     `start-masc-mcp.sh --sidecar-root /path/to/masc-mcp`."
    id searched_text

let today_yyyymmdd () =
  let tm = Unix.localtime (Unix.time ()) in
  Printf.sprintf "%04d%02d%02d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday

let legacy_status_rel id =
  Printf.sprintf ".masc/connectors/%s/status.json" id

type sidecar_status_config = {
  env_names : string list;
  toml_keys : string list;
}

let sidecar_status_config = function
  | "discord" ->
      {
        env_names = [ "DISCORD_STATUS_PATH"; "discord_status_path" ];
        toml_keys = [ "discord_status_path"; "status_path" ];
      }
  | "imessage" ->
      {
        env_names = [ "IMESSAGE_STATUS_PATH"; "status_path" ];
        toml_keys = [ "status_path" ];
      }
  | "slack" ->
      {
        env_names = [ "SLACK_STATUS_PATH"; "MASC_SLACK_STATUS_PATH"; "status_path" ];
        toml_keys = [ "status_path" ];
      }
  | "telegram" ->
      {
        env_names =
          [ "TELEGRAM_STATUS_PATH"; "MASC_TELEGRAM_STATUS_PATH"; "status_path" ];
        toml_keys = [ "status_path" ];
      }
  | id -> invalid_arg (Printf.sprintf "unknown sidecar id: %s" id)

let read_file path =
  In_channel.with_open_text path In_channel.input_all

let strip_matching_quotes value =
  let len = String.length value in
  if len >= 2 then
    let first = value.[0] in
    let last = value.[len - 1] in
    if (first = '"' && last = '"') || (first = '\'' && last = '\'') then
      String.sub value 1 (len - 2)
    else
      value
  else
    value

let parse_env_assignment line =
  let trimmed = String.trim line in
  if trimmed = "" || starts_with ~prefix:"#" trimmed then
    None
  else
    let body =
      if starts_with ~prefix:"export " trimmed then
        String.sub trimmed 7 (String.length trimmed - 7) |> String.trim
      else
        trimmed
    in
    match String.index_opt body '=' with
    | None -> None
    | Some idx ->
        let key = String.sub body 0 idx |> String.trim in
        let raw_value =
          String.sub body (idx + 1) (String.length body - idx - 1) |> String.trim
        in
        trim_opt (Some key)
        |> Option.map (fun normalized_key ->
               (normalized_key, strip_matching_quotes raw_value))

let env_file_lookup path names =
  if not (Sys.file_exists path) then
    None
  else
    let pairs =
      read_file path
      |> String.split_on_char '\n'
      |> List.filter_map parse_env_assignment
    in
    names |> List.find_map (fun name -> List.assoc_opt name pairs |> trim_opt)

let toml_lookup path keys =
  if not (Sys.file_exists path) then
    None
  else
    match Keeper_toml_loader.parse_toml (read_file path) with
    | Error _ -> None
    | Ok doc ->
        keys
        |> List.find_map (fun key ->
               match List.assoc_opt key doc with
               | Some (Keeper_toml_loader.Toml_string value) -> trim_opt (Some value)
               | _ -> None)

let resolve_relative_path ~roots raw_path =
  let path = String.trim raw_path in
  if path = "" then []
  else if Filename.is_relative path then
    roots |> List.map (fun root -> Filename.concat root path)
  else
    [ path ]

let first_existing_or_first = function
  | [] -> None
  | candidates -> (
      match List.find_opt Sys.file_exists candidates with
      | Some path -> Some path
      | None ->
          match candidates with
          | first :: _ -> Some first
          | [] -> None)

let runtime_toml_path ~base_path id =
  Filename.concat base_path (Printf.sprintf ".gate/runtime/%s/config.toml" id)

let status_file_candidates ?sidecar_root ?project_root ?sidecar_dir ~base_path id =
  let roots = sidecar_root_candidates ?sidecar_root ?project_root ~base_path () in
  let cfg = sidecar_status_config id in
  let env_paths =
    cfg.env_names
    |> List.find_map (fun name -> trim_opt (Sys.getenv_opt name))
    |> Option.map (resolve_relative_path ~roots)
    |> Option.value ~default:[]
  in
  let dotenv_paths =
    match sidecar_dir with
    | None -> []
    | Some dir ->
        env_file_lookup (Filename.concat dir ".env") cfg.env_names
        |> Option.map (resolve_relative_path ~roots)
        |> Option.value ~default:[]
  in
  let toml_paths =
    roots
    |> List.filter_map (fun root ->
           toml_lookup (runtime_toml_path ~base_path:root id) cfg.toml_keys
           |> Option.map (fun raw -> resolve_relative_path ~roots:[ root ] raw))
    |> List.concat
  in
  let default_paths =
    resolve_relative_path ~roots (Printf.sprintf ".gate/runtime/%s/status.json" id)
  in
  let legacy_paths = resolve_relative_path ~roots (legacy_status_rel id) in
  dedupe_keep_order (env_paths @ dotenv_paths @ toml_paths @ default_paths @ legacy_paths)

let status_file ?sidecar_root ?project_root ?sidecar_dir ~base_path id =
  status_file_candidates ?sidecar_root ?project_root ?sidecar_dir ~base_path id
  |> first_existing_or_first
  |> Option.value ~default:(Filename.concat base_path (legacy_status_rel id))

let log_file_candidates ?sidecar_root ?project_root ~base_path id =
  let roots = sidecar_root_candidates ?sidecar_root ?project_root ~base_path () in
  roots
  |> List.map (fun root ->
         Filename.concat root
           (Printf.sprintf ".masc/logs/%s-sidecar-%s.log" id (today_yyyymmdd ())))
  |> dedupe_keep_order

let today_log_file ?sidecar_root ?project_root ~base_path id =
  log_file_candidates ?sidecar_root ?project_root ~base_path id
  |> first_existing_or_first
  |> Option.value
       ~default:
         (Filename.concat base_path
            (Printf.sprintf ".masc/logs/%s-sidecar-%s.log" id (today_yyyymmdd ())))

let runtime_sidecar_dir_result ?base_path id =
  let runtime_base_path = runtime_base_path ?base_path () in
  let configured_sidecar_root = sidecar_root () in
  let project_root = project_root_from_executable () in
  match
    resolve_existing_sidecar_dir
      ?sidecar_root:configured_sidecar_root
      ?project_root
      ~base_path:runtime_base_path
      id
  with
  | Some dir -> Ok dir
  | None ->
      Error
        (missing_sidecar_dir_message
           ?sidecar_root:configured_sidecar_root
           ?project_root
           ~base_path:runtime_base_path
           id)

let runtime_sidecar_script_result ?base_path id =
  match runtime_sidecar_dir_result ?base_path id with
  | Error _ as error -> error
  | Ok dir ->
      let script = Filename.concat dir "run.sh" in
      if Sys.file_exists script then
        Ok script
      else
        Error
          (Printf.sprintf
             "sidecar run.sh not found for %s at %s. Set \
              MASC_SIDECAR_ROOT=/path/to/masc-mcp or start the server with \
              `start-masc-mcp.sh --sidecar-root /path/to/masc-mcp`."
             id script)

(** Clamp the [?lines=N] query param to [1, 1000]. Pure so unit tests
    can pin the upper bound without a request mock. *)
let clamp_lines = function
  | None -> 200
  | Some n -> max 1 (min 1000 n)

let respond_json request reqd ~status body =
  respond_json_with_cors ~status request reqd (Yojson.Safe.to_string body)

let bad_request request reqd msg =
  respond_json request reqd ~status:`Bad_request
    (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])

let read_status_json ~base_path id =
  let configured_sidecar_root = sidecar_root () in
  let project_root = project_root_from_executable () in
  let sidecar_dir =
    resolve_existing_sidecar_dir
      ?sidecar_root:configured_sidecar_root
      ?project_root
      ~base_path
      id
  in
  let path =
    status_file
      ?sidecar_root:configured_sidecar_root
      ?project_root
      ?sidecar_dir
      ~base_path
      id
  in
  if Sys.file_exists path then
    let body = read_file path in
    let parsed = try Some (Yojson.Safe.from_string body) with _ -> None in
    `Assoc [
      ("ok", `Bool true);
      ("available", `Bool true);
      ("status_path", `String path);
      ("status", Option.value parsed ~default:`Null);
    ]
  else
    `Assoc [
      ("ok", `Bool true);
      ("available", `Bool false);
      ("status_path", `String path);
    ]

let handle_status state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
      let base_path = request_base_path state in
      respond_json request reqd ~status:`OK (read_status_json ~base_path id)

let handle_stop state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
      let base_path = request_base_path state in
      (match runtime_sidecar_script_result ~base_path id with
       | Error msg ->
           respond_json request reqd ~status:`Service_unavailable
             (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
       | Ok script ->
           let (_status, stdout) =
             Process_eio.run_argv_with_status ~timeout_sec:5.0
               [ script; "stop" ]
           in
           let trimmed = String.trim stdout in
           let signaled_marker =
             Printf.sprintf "Sent SIGTERM to %s-bot processes." id
           in
           let signaled =
             let needle_len = String.length signaled_marker in
             let rec contains i =
               if i + needle_len > String.length trimmed then false
               else if String.equal (String.sub trimmed i needle_len) signaled_marker then true
               else contains (i + 1)
             in
             contains 0
           in
           respond_json request reqd ~status:`OK
             (`Assoc [
                ("ok", `Bool true);
                ("signaled", `Bool signaled);
                ("note", `String trimmed);
              ]))

let handle_logs state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
      let base_path = request_base_path state in
      let configured_sidecar_root = sidecar_root () in
      let project_root = project_root_from_executable () in
      let lines =
        clamp_lines (Server_utils.query_param request "lines"
                     |> Option.map int_of_string_opt
                     |> Option.join)
      in
      let path =
        today_log_file
          ?sidecar_root:configured_sidecar_root
          ?project_root
          ~base_path
          id
      in
      if not (Sys.file_exists path) then
        respond_json request reqd ~status:`OK
          (`Assoc [
             ("ok", `Bool true);
             ("log_path", `String path);
             ("available", `Bool false);
             ("lines", `List []);
           ])
      else
        let (_status, stdout) =
          Process_eio.run_argv_with_status ~timeout_sec:5.0
            [ "tail"; "-n"; string_of_int lines; path ]
        in
        let line_list =
          String.split_on_char '\n' stdout
          |> List.filter (fun l -> not (String.equal l ""))
          |> List.map (fun l -> `String l)
        in
        respond_json request reqd ~status:`OK
          (`Assoc [
             ("ok", `Bool true);
             ("log_path", `String path);
             ("available", `Bool true);
             ("lines", `List line_list);
           ])

(** Per-process schema cache. The Pydantic [BotConfig.model_json_schema]
    output only changes when sidecar source changes, which requires a
    backend restart in practice (we don't hot-reload Python). So a
    per-id cache keyed by id is safe for the lifetime of this process. *)
let schema_cache : (string, string) Hashtbl.t = Hashtbl.create 8

(** Reset the cache; only used by tests. *)
let reset_schema_cache () = Hashtbl.reset schema_cache

(** Pick a Python interpreter for a given sidecar id.

    Discord-bot uses [uv] (project has pyproject.toml + uv.lock). The
    other 3 ship a hand-managed [.venv/]. We prefer the venv path when
    it exists because it sidesteps a [uv] dependency on the host running
    the backend. *)
let python_argv_for sidecar_dir =
  let venv_python = Filename.concat sidecar_dir ".venv/bin/python" in
  if Sys.file_exists venv_python then
    [ venv_python; "-m"; "src.schema_dump" ]
  else
    [ "uv"; "run"; "--directory"; sidecar_dir; "python"; "-m"; "src.schema_dump" ]

let fetch_schema ?base_path id =
  match Hashtbl.find_opt schema_cache id with
  | Some cached -> Ok cached
  | None ->
      (match runtime_sidecar_dir_result ?base_path id with
       | Error _ as error -> error
       | Ok sidecar_dir ->
           let argv = python_argv_for sidecar_dir in
           let (status, stdout) =
             Process_eio.run_argv_with_status ~timeout_sec:10.0 ~cwd:sidecar_dir argv
           in
           (match status with
            | Unix.WEXITED 0 ->
                let trimmed = String.trim stdout in
                Hashtbl.replace schema_cache id trimmed;
                Ok trimmed
            | _ ->
                Error
                  "schema_dump failed; ensure the sidecar's Python deps are installed (run `./run.sh start` once or `uv sync`)"))

(** ---- Config write (PUT) ----

    The dashboard config form (ConnectorConfigForm) submits the editor
    state as JSON. We whitelist keys against the sidecar's own schema
    (so only BotConfig-known names reach disk), coerce each value to
    its schema-declared TOML type, and atomically rewrite the runtime
    TOML at [.gate/runtime/<id>/config.toml].

    The sidecar picks this file up on next start (Pydantic
    [TomlConfigSettingsSource] sits in the source priority list below
    env but above field defaults). We do not hot-reload a running
    sidecar — that is the operator's job. *)

type toml_value =
  | Tstring of string
  | Tint of int
  | Tfloat of float
  | Tbool of bool

(** Hard cap on any single value the dashboard can write, so a
    runaway client can't balloon the TOML. Typical fields (tokens,
    URLs, numeric knobs) are well under this. *)
let max_value_bytes = 8192

let escape_toml_string s =
  let buf = Buffer.create (String.length s + 4) in
  String.iter (fun c ->
    match c with
    | '\\' -> Buffer.add_string buf "\\\\"
    | '"' -> Buffer.add_string buf "\\\""
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c when Char.code c < 0x20 ->
        Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let render_value = function
  | Tstring s -> Printf.sprintf "\"%s\"" (escape_toml_string s)
  | Tint n -> string_of_int n
  | Tfloat f -> Printf.sprintf "%g" f
  | Tbool true -> "true"
  | Tbool false -> "false"

let render_toml (pairs : (string * toml_value) list) : string =
  let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) pairs in
  let lines = List.map (fun (k, v) -> Printf.sprintf "%s = %s" k (render_value v)) sorted in
  String.concat "\n" lines ^ "\n"

type declared_type = [ `String | `Integer | `Number | `Boolean ]

let parse_declared_type json : declared_type =
  match json with
  | `Assoc _ ->
      (match Yojson.Safe.Util.member "type" json with
       | `String "integer" -> `Integer
       | `String "number" -> `Number
       | `String "boolean" -> `Boolean
       | _ -> `String)
  | _ -> `String

let schema_field_types ?base_path id : (string * declared_type) list =
  match fetch_schema ?base_path id with
  | Error _ -> []
  | Ok json_str ->
      (match Yojson.Safe.from_string json_str with
       | j ->
           (match Yojson.Safe.Util.member "properties" j with
            | `Assoc assoc -> List.map (fun (k, v) -> (k, parse_declared_type v)) assoc
            | _ -> [])
       | exception _ -> [])

let coerce_value (typ : declared_type) (raw : string) : (toml_value, string) result =
  if String.length raw > max_value_bytes then
    Error (Printf.sprintf "value too long (>%d bytes)" max_value_bytes)
  else match typ with
    | `String -> Ok (Tstring raw)
    | `Integer ->
        (match int_of_string_opt (String.trim raw) with
         | Some n -> Ok (Tint n)
         | None -> Error (Printf.sprintf "expected integer, got %S" raw))
    | `Number ->
        (match float_of_string_opt (String.trim raw) with
         | Some n -> Ok (Tfloat n)
         | None -> Error (Printf.sprintf "expected number, got %S" raw))
    | `Boolean ->
        (match String.lowercase_ascii (String.trim raw) with
         | "true" | "1" -> Ok (Tbool true)
         | "false" | "0" -> Ok (Tbool false)
         | _ -> Error (Printf.sprintf "expected true/false, got %S" raw))

let config_toml_path ~base_path id =
  Filename.concat base_path
    (Printf.sprintf ".gate/runtime/%s/config.toml" id)

(** Atomic write: tmp file + rename. POSIX rename is atomic so a
    concurrent reader sees either the old file or the new one, never a
    half-written one. Inlined here rather than reaching into
    Keeper_toml_loader (which keeps it as a private helper). *)
let atomic_write_file ~(path : string) (content : string) : (unit, string) result =
  let tmp = path ^ ".tmp" in
  try
    let oc = open_out tmp in
    Fun.protect
      ~finally:(fun () -> try close_out oc with _ -> ())
      (fun () -> output_string oc content);
    Sys.rename tmp path;
    Ok ()
  with exn ->
    (try Sys.remove tmp with _ -> ());
    Error (Printf.sprintf "atomic write failed: %s" (Printexc.to_string exn))

(** Make sure [.gate/runtime/<id>/] exists before atomic_write_file
    tries to rename into it. *)
let ensure_parent_dir path =
  let dir = Filename.dirname path in
  let rec mk d =
    if Sys.file_exists d then ()
    else begin
      mk (Filename.dirname d);
      try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  mk dir

(** Parse a JSON body of the form [{"<KEY>": "<VALUE>", ...}] into a
    list of pairs. All values are expected as JSON strings (the
    dashboard form emits them that way) — richer JSON types are
    converted to their string form so type coercion runs downstream
    from the same path. *)
let parse_body_pairs body_str : ((string * string) list, string) result =
  match Yojson.Safe.from_string body_str with
  | `Assoc assoc ->
      let pairs = List.map (fun (k, v) ->
        let s = match v with
          | `String s -> s
          | `Int i -> string_of_int i
          | `Float f -> Printf.sprintf "%g" f
          | `Bool b -> if b then "true" else "false"
          | `Null -> ""
          | _ -> Yojson.Safe.to_string v
        in
        (k, s)
      ) assoc in
      Ok pairs
  | _ -> Error "body must be a JSON object"
  | exception _ -> Error "body is not valid JSON"

(** GET /api/v1/sidecar/config?name=<id>

    Reads the current runtime TOML and returns the values as a flat map
    so the dashboard form can prefill instead of showing only schema
    defaults. Empty file or missing file → [exists: false] envelope so
    the form falls back to defaults gracefully.

    All values are stringified for transport — the dashboard is the
    one rendering the form, and the form already knows the type from
    the schema response. Keeps the wire format simple. *)
let handle_get_config _state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
      let path = config_toml_path ~base_path:(request_base_path _state) id in
      if not (Sys.file_exists path) then
        respond_json request reqd ~status:`OK
          (`Assoc [
             ("ok", `Bool true);
             ("id", `String id);
             ("path", `String path);
             ("exists", `Bool false);
             ("values", `Assoc []);
           ])
      else
        let content =
          try In_channel.with_open_text path In_channel.input_all
          with _ -> ""
        in
        (match Keeper_toml_loader.parse_toml content with
         | Error msg ->
             respond_json request reqd ~status:`Internal_server_error
               (`Assoc [
                  ("ok", `Bool false);
                  ("error", `String (Printf.sprintf "TOML parse failed: %s" msg));
                ])
         | Ok doc ->
             let pairs = List.filter_map (fun (k, v) ->
               match v with
               | Keeper_toml_loader.Toml_string s -> Some (k, `String s)
               | Keeper_toml_loader.Toml_int n -> Some (k, `String (string_of_int n))
               | Keeper_toml_loader.Toml_float f -> Some (k, `String (Printf.sprintf "%g" f))
               | Keeper_toml_loader.Toml_bool b -> Some (k, `String (if b then "true" else "false"))
               | Keeper_toml_loader.Toml_string_array _ -> None
             ) doc in
             respond_json request reqd ~status:`OK
               (`Assoc [
                  ("ok", `Bool true);
                  ("id", `String id);
                  ("path", `String path);
                  ("exists", `Bool true);
                  ("values", `Assoc pairs);
                ]))

let handle_put_config _state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
      Http.Request.read_body_async reqd (fun body_str ->
        match parse_body_pairs body_str with
        | Error msg -> bad_request request reqd msg
        | Ok pairs ->
            let base_path = request_base_path _state in
            let types = schema_field_types ~base_path id in
            if types = [] then
              respond_json request reqd ~status:`Service_unavailable
                (`Assoc [
                   ("ok", `Bool false);
                   ("error", `String "schema unavailable; run `./run.sh start` once so the form knows which fields exist");
                 ])
            else
              let type_of k = List.assoc_opt k types in
              let rec collect acc rejected = function
                | [] -> Ok (List.rev acc, List.rev rejected)
                | (k, v) :: rest ->
                    (match type_of k with
                     | None -> collect acc (k :: rejected) rest
                     | Some typ ->
                         (match coerce_value typ v with
                          | Ok tv -> collect ((k, tv) :: acc) rejected rest
                          | Error msg ->
                              Error (Printf.sprintf "%s: %s" k msg)))
              in
              (match collect [] [] pairs with
               | Error msg -> bad_request request reqd msg
               | Ok (accepted, rejected) ->
                   let path = config_toml_path ~base_path id in
                   ensure_parent_dir path;
                   let toml_str = render_toml accepted in
                   (match atomic_write_file ~path toml_str with
                    | Error e ->
                        respond_json request reqd ~status:`Internal_server_error
                          (`Assoc [
                             ("ok", `Bool false);
                             ("error", `String e);
                           ])
                    | Ok () ->
                        respond_json request reqd ~status:`OK
                          (`Assoc [
                             ("ok", `Bool true);
                             ("id", `String id);
                             ("path", `String path);
                             ("written_fields", `Int (List.length accepted));
                             ("rejected_fields", `List (List.map (fun s -> `String s) rejected));
                           ])))
      )

let handle_schema _state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
      (match fetch_schema ~base_path:(request_base_path _state) id with
       | Error msg ->
           respond_json request reqd ~status:`Service_unavailable
             (`Assoc [
                ("ok", `Bool false);
                ("error", `String msg);
              ])
       | Ok json_str ->
           (match Yojson.Safe.from_string json_str with
            | parsed ->
                respond_json request reqd ~status:`OK
                  (`Assoc [
                     ("ok", `Bool true);
                     ("id", `String id);
                     ("schema", parsed);
                   ])
            | exception _ ->
                respond_json request reqd ~status:`Internal_server_error
                  (`Assoc [
                     ("ok", `Bool false);
                     ("error", `String "schema_dump returned invalid JSON");
                   ])))

let handle_start state request reqd =
  match parse_name request with
  | Error msg -> bad_request request reqd msg
  | Ok id ->
      let base_path = request_base_path state in
      (match runtime_sidecar_script_result ~base_path id with
       | Error msg ->
           respond_json request reqd ~status:`Service_unavailable
             (`Assoc [ ("ok", `Bool false); ("error", `String msg) ])
       | Ok script ->
           (* Detach: run via setsid + nohup so the sidecar survives backend
              restart. Only [script] is interpolated, and the path comes from
              a resolved directory + fixed filename, so [Filename.quote] gives
              a closed-shell injection surface. *)
           let cmd =
             Printf.sprintf
               "MASC_BASE_PATH=%s setsid nohup %s start </dev/null >/dev/null 2>&1 &"
               (Filename.quote base_path)
               (Filename.quote script)
           in
           let _ = Sys.command cmd in
           respond_json request reqd ~status:`Accepted
             (`Assoc [
                ("ok", `Bool true);
                ("id", `String id);
                ("note", `String "sidecar spawn requested; poll /api/v1/sidecar/status?name=...");
              ]))

(** Register sidecar lifecycle routes on the router. *)
let add_routes ~sw:_ ~clock:_ router =
  router
  |> Http.Router.get "/api/v1/sidecar/status" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         handle_status state request reqd
       ) request reqd)

  |> Http.Router.get "/api/v1/sidecar/logs" (fun request reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun state _req reqd ->
         handle_logs state request reqd
       ) request reqd)

  (* Schema is field-shape metadata, not values, so it's safe under
     public_read — the dashboard form needs it during cold-start
     onboarding (before any auth tokens are configured). *)
  |> Http.Router.get "/api/v1/sidecar/schema" (fun request reqd ->
       with_public_read (fun state _req reqd ->
         handle_schema state request reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/sidecar/start" (fun request reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun state _req reqd ->
         handle_start state request reqd
       ) request reqd)

  |> Http.Router.post "/api/v1/sidecar/stop" (fun request reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun state _req reqd ->
         handle_stop state request reqd
       ) request reqd)

  (* Writes user-supplied values (potentially containing tokens) to disk,
     so [tool_auth] not [public_read]. Whitelisting + type coercion runs
     inside the handler — the auth gate just keeps unauth'd writers out. *)
  |> Http.Router.post "/api/v1/sidecar/config" (fun request reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun state _req reqd ->
         handle_put_config state request reqd
       ) request reqd)

  (* Read current runtime TOML so the dashboard form prefills with what's
     actually on disk. Tokens may surface in the response, so [tool_auth]. *)
  |> Http.Router.get "/api/v1/sidecar/config" (fun request reqd ->
       with_tool_auth ~tool_name:"sidecar" (fun state _req reqd ->
         handle_get_config state request reqd
       ) request reqd)
