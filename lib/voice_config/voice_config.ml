type endpoint_kind =
  | Openai_compat
  | Elevenlabs_direct
  | Voice_mcp

type endpoint = {
  id : string;
  kind : endpoint_kind;
  base_url : string option;
  mcp_url : string option;
  health_url : string option;
  api_key_env : string option;
  enabled : bool;
  timeout_seconds : float option;
  max_retries : int option;
}

type voice_tuning = {
  stability : float;
  similarity_boost : float;
  style : float;
}

type tts_config = {
  default_model : string;
  default_voice : string;
  default_voice_settings : voice_tuning;
  agent_voices : (string * string) list;
  agent_voice_settings : (string * voice_tuning) list;
  endpoints : endpoint list;
}

type stt_config = {
  default_model : string;
  endpoints : endpoint list;
}

type session_config = { endpoints : endpoint list }

type local_playback_config = {
  enabled : bool;
  agents : string list;
}

type t = {
  tts : tts_config;
  stt : stt_config;
  session : session_config;
  local_playback : local_playback_config;
}

open Result.Syntax

let default_elevenlabs_base_url = "https://api.elevenlabs.io/v1"

let trim_opt = Env_config_core.trim_opt

let voice_config_file_in root =
  let masc_dir =
    Workspace_utils.masc_root_dir_from
      ~base_path:root
      ~cluster_name:(Env_config_core.cluster_name ())
  in
  Filename.concat masc_dir "voice_config.json"

let base_path_voice_config_path_opt () =
  (Host_config.from_env ()).base_path
  |> Option.map voice_config_file_in

let repo_voice_config_path_opt () =
  let root =
    match (Host_config.from_env ()).base_path with
    | Some bp -> bp
    | None ->
      let cwd = Config_dir_resolver.current_working_dir () in
      (match Workspace_utils_backend_setup.find_git_root cwd with
       | Some path -> path
       | None -> cwd)
  in
  Some (voice_config_file_in root)

let fallback_voice_config_path () =
  let root =
    match (Host_config.from_env ()).base_path with
    | Some bp -> bp
    | None -> Config_dir_resolver.base_path_or_cwd ()
  in
  voice_config_file_in root

let config_path_candidates () =
  [
    base_path_voice_config_path_opt ();
    repo_voice_config_path_opt ();
    Some (fallback_voice_config_path ());
  ]
  |> List.filter_map Fun.id
  |> Json_util.dedupe_keep_order

let config_path () =
  let candidates = config_path_candidates () in
  match List.find_opt Sys.file_exists candidates, candidates with
  | Some path, _ -> path
  | None, path :: _ -> path
  | None, [] -> fallback_voice_config_path ()

let trim_nonempty_json = function
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let string_list_opt = function
  | `List items ->
      let rec loop acc = function
        | [] -> Some (List.rev acc)
        | item :: rest -> (
            match trim_nonempty_json item with
            | Some value -> loop (value :: acc) rest
            | None -> None)
      in
      loop [] items
  | `Null -> Some []
  | _ -> None

let bool_or_default default = function
  | `Bool value -> value
  | _ -> default

let int_opt = function
  | `Int value -> Some value
  | _ -> None

let float_opt = function
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | _ -> None

let float_or_default default = function
  | `Float value -> value
  | `Int value -> float_of_int value
  | _ -> default

let require_string ~ctx ~field json =
  match Json_util.get_string_nonempty json field with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s.%s is required" ctx field)

let require_object ~ctx ~field json =
  match Json_util.get_object json field with
  | Some obj -> Ok obj
  | None ->
      let raw = Option.value ~default:`Null (Json_util.assoc_member_opt field json) in
      Error
        (Printf.sprintf "%s.%s must be object, got %s: %s" ctx field
           (Json_util.kind_name raw) (Json_util.excerpt raw))

let require_list ~ctx ~field json =
  match Json_util.get_array json field with
  | Some (`List items) -> Ok items
  | _ ->
      let raw = Option.value ~default:`Null (Json_util.assoc_member_opt field json) in
      Error
        (Printf.sprintf "%s.%s must be array, got %s: %s" ctx field
           (Json_util.kind_name raw) (Json_util.excerpt raw))

let endpoint_kind_of_string = function
  | "openai_compat" -> Ok Openai_compat
  | "elevenlabs_direct" -> Ok Elevenlabs_direct
  | "voice_mcp" -> Ok Voice_mcp
  | value ->
      Error
        (Printf.sprintf
           "endpoint.kind must be one of openai_compat|elevenlabs_direct|voice_mcp (got %s)"
           value)

let string_of_endpoint_kind = function
  | Openai_compat -> "openai_compat"
  | Elevenlabs_direct -> "elevenlabs_direct"
  | Voice_mcp -> "voice_mcp"

let parse_endpoint ~ctx json =
  let open Result in
  let* id = require_string ~ctx ~field:"id" json in
  let* kind_raw = require_string ~ctx ~field:"kind" json in
  let* kind = endpoint_kind_of_string kind_raw in
  let base_url = Json_util.get_string_nonempty json "base_url" in
  let mcp_url = Json_util.get_string_nonempty json "mcp_url" in
  let health_url = Json_util.get_string_nonempty json "health_url" in
  let api_key_env = Json_util.get_string_nonempty json "api_key_env" in
  let enabled =
    Option.value ~default:true (Json_util.get_bool json "enabled")
  in
  let timeout_seconds = Json_util.get_float json "timeout_seconds" in
  let max_retries = Json_util.get_int json "max_retries" in
  let base_url =
    match kind, base_url with
    | Elevenlabs_direct, None -> Some default_elevenlabs_base_url
    | _ -> base_url
  in
  let* () =
    match kind with
    | Openai_compat ->
        if Option.is_some base_url then Ok ()
        else Error (Printf.sprintf "%s.base_url is required for openai_compat" ctx)
    | Elevenlabs_direct -> Ok ()
    | Voice_mcp -> Ok ()
  in
  Ok
    {
      id;
      kind;
      base_url;
      mcp_url;
      health_url;
      api_key_env;
      enabled;
      timeout_seconds;
      max_retries;
    }

let rec parse_endpoints ~ctx acc = function
  | [] ->
      let endpoints = List.rev acc in
      if endpoints = [] then Error (Printf.sprintf "%s must not be empty" ctx)
      else Ok endpoints
  | item :: rest ->
      let next_ctx = Printf.sprintf "%s[%d]" ctx (List.length acc) in
      (match parse_endpoint ~ctx:next_ctx item with
      | Ok endpoint -> parse_endpoints ~ctx (endpoint :: acc) rest
      | Error _ as error -> error)

let parse_agent_voices json =
  match Json_util.assoc_member_opt "agent_voices" json with
  | Some (`Assoc pairs) ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | (agent_id, value) :: rest -> (
            match trim_nonempty_json value with
            | Some voice ->
                loop ((String.trim agent_id, voice) :: acc) rest
            | None ->
                Error
                  (Printf.sprintf
                     "tts.agent_voices.%s must be a non-empty string" agent_id) )
      in
      loop [] pairs
  | None | Some `Null -> Ok []
  | Some other ->
      Error
        (Printf.sprintf "tts.agent_voices must be an object, got %s: %s"
           (Json_util.kind_name other) (Json_util.excerpt other))

let parse_voice_tuning ~ctx json =
  match json with
  | `Assoc _ ->
      Ok
        {
          stability =
            Option.value ~default:0.5 (Json_util.get_float json "stability");
          similarity_boost =
            Option.value ~default:0.75 (Json_util.get_float json "similarity_boost");
          style = Option.value ~default:0.0 (Json_util.get_float json "style");
        }
  | `Null ->
      Ok { stability = 0.5; similarity_boost = 0.75; style = 0.0 }
  | other ->
      Error
        (Printf.sprintf "%s must be an object, got %s: %s" ctx
           (Json_util.kind_name other) (Json_util.excerpt other))

let parse_agent_voice_settings json =
  match Json_util.assoc_member_opt "agent_voice_settings" json with
  | Some (`Assoc pairs) ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | (agent_id, tuning_json) :: rest -> (
            match parse_voice_tuning ~ctx:("tts.agent_voice_settings." ^ agent_id) tuning_json with
            | Ok tuning -> loop ((String.trim agent_id, tuning) :: acc) rest
            | Error _ as err -> err)
      in
      loop [] pairs
  | None | Some `Null -> Ok []
  | Some other ->
      Error
        (Printf.sprintf "tts.agent_voice_settings must be an object, got %s: %s"
           (Json_util.kind_name other) (Json_util.excerpt other))

let parse_tts json =
  let open Result in
  let* tts_json = require_object ~ctx:"root" ~field:"tts" json in
  let* default_model = require_string ~ctx:"tts" ~field:"default_model" tts_json in
  let* default_voice = require_string ~ctx:"tts" ~field:"default_voice" tts_json in
  let* default_voice_settings =
    parse_voice_tuning ~ctx:"tts.default_voice_settings"
      (Option.value ~default:`Null (Json_util.assoc_member_opt "default_voice_settings" tts_json))
  in
  let* agent_voices = parse_agent_voices tts_json in
  let* agent_voice_settings =
    parse_agent_voice_settings tts_json
  in
  let* endpoints_json = require_list ~ctx:"tts" ~field:"endpoints" tts_json in
  let* endpoints = parse_endpoints ~ctx:"tts.endpoints" [] endpoints_json in
  Ok
    {
      default_model;
      default_voice;
      default_voice_settings;
      agent_voices;
      agent_voice_settings;
      endpoints;
    }

let parse_stt json =
  let open Result in
  let* stt_json = require_object ~ctx:"root" ~field:"stt" json in
  let* default_model = require_string ~ctx:"stt" ~field:"default_model" stt_json in
  let* endpoints_json = require_list ~ctx:"stt" ~field:"endpoints" stt_json in
  let* endpoints = parse_endpoints ~ctx:"stt.endpoints" [] endpoints_json in
  Ok { default_model; endpoints }

let parse_session json =
  let open Result in
  let* session_json = require_object ~ctx:"root" ~field:"session" json in
  let* endpoints_json =
    require_list ~ctx:"session" ~field:"endpoints" session_json
  in
  match endpoints_json with
  | [] -> Ok { endpoints = [] }
  | items ->
    let* endpoints = parse_endpoints ~ctx:"session.endpoints" [] items in
    Ok { endpoints }

let parse_local_playback json =
  match Json_util.assoc_member_opt "local_playback" json with
  | Some (`Assoc _ as local_json) ->
      let enabled =
        Option.value ~default:false (Json_util.get_bool local_json "enabled")
      in
      let agents =
        match Json_util.assoc_member_opt "agents" local_json with
        | Some (`List values) -> List.filter_map trim_nonempty_json values
        | _ -> []
      in
      Ok { enabled; agents }
  | None | Some `Null -> Ok { enabled = false; agents = [] }
  | Some other ->
      Error
        (Printf.sprintf "root.local_playback must be an object, got %s: %s"
           (Json_util.kind_name other) (Json_util.excerpt other))

let parse_json json =
  let open Result in
  let* tts = parse_tts json in
  let* stt = parse_stt json in
  let* session = parse_session json in
  let* local_playback = parse_local_playback json in
  Ok { tts; stt; session; local_playback }

(** ── runtime.toml [voice] section loading ─────────────────────
    Otoml → Yojson bridge so {!parse_json} can consume a TOML
    [\[voice\]] section without a dedicated TOML parser.
    The bridge handles only the types that appear in voice_config:
    integers, floats, strings, booleans, tables (objects), and arrays.
    TOML arrays-of-tables ([[\[voice.tts.endpoints\]]]) become JSON
    arrays of objects — matching what [parse_json] expects. *)

let rec toml_to_json = function
  | Otoml.TomlInteger i -> `Int i
  | Otoml.TomlFloat f -> `Float f
  | Otoml.TomlString s -> `String s
  | Otoml.TomlBoolean b -> `Bool b
  | Otoml.TomlOffsetDateTime d
  | Otoml.TomlLocalDateTime d
  | Otoml.TomlLocalDate d
  | Otoml.TomlLocalTime d -> `String d
  | Otoml.TomlTable pairs
  | Otoml.TomlInlineTable pairs ->
      `Assoc (List.map (fun (k, v) -> (k, toml_to_json v)) pairs)
  | Otoml.TomlArray elems -> `List (List.map toml_to_json elems)
  | Otoml.TomlTableArray elems -> `List (List.map toml_to_json elems)

(** Resolve the runtime.toml path from the config root.
    Uses {!Config_dir_resolver} (SSOT) so the path stays in sync
    with the rest of the config loading pipeline. *)
let runtime_toml_path () : string option =
  let resolution = Config_dir_resolver.resolve () in
  if resolution.config_root.exists then
    let path =
      Filename.concat resolution.config_root.path
        Config_dir_resolver.runtime_toml_filename
    in
    if Sys.file_exists path then Some path else None
  else None

(** Try loading voice config from the [\[voice\]] section of
    runtime.toml.  Returns [Ok config] when the section exists
    and parses cleanly.  Returns [Error _] when:
    - no runtime.toml in config root (expected — fall back to JSON)
    - no [\[voice\]] section (expected — fall back to JSON)
    - TOML parse error in [\[voice\]] (unexpected — surfaced, NOT
      silently swallowed, so the operator knows the TOML is broken) *)
let load_from_runtime_toml () =
  match runtime_toml_path () with
  | None -> Error "no runtime.toml in config root"
  | Some path ->
    try
      let toml = Otoml.Parser.from_file path in
      (match Otoml.find_opt toml Fun.id [ "voice" ] with
       | None -> Error "no [voice] section in runtime.toml"
       | Some _ ->
         (* Fun.id returns the raw Otoml.t value; toml_to_json
            pattern-matches on its constructors. *)
         let voice_value =
           match Otoml.find_opt toml Fun.id [ "voice" ] with
           | Some v -> v
           | None -> Otoml.TomlTable []
         in
         let json = toml_to_json voice_value in
         parse_json json)
    with
    | Otoml.Parse_error (_, msg) ->
        Error (Printf.sprintf "runtime.toml parse error: %s" msg)
    | Sys_error msg ->
        Error (Printf.sprintf "runtime.toml read failed: %s" msg)

let load () =
  (* Prefer runtime.toml [voice] section over standalone JSON.
     Only fall back when the file or section is absent — TOML
     parse errors are surfaced to the operator. *)
  match load_from_runtime_toml () with
  | Ok config -> Ok config
  | Error msg ->
    Log.Runtime.info
      "voice_config: falling back to JSON (%s)" msg;
    let path = config_path () in
    if not (Sys.file_exists path) then
      Error (Printf.sprintf "voice config missing at %s" path)
    else
      try
        let json = Safe_ops.read_json_eio path in
        parse_json json
      with
      | Yojson.Json_error error ->
          Error (Printf.sprintf "invalid voice config json: %s" error)
      | Sys_error error ->
          Error (Printf.sprintf "voice config read failed: %s" error)
      | Eio.Io _ as exn ->
          Error (Printf.sprintf "voice config Eio read failed: %s"
                   (Printexc.to_string exn))

let enabled_endpoints (endpoints : endpoint list) =
  List.filter (fun (endpoint : endpoint) -> endpoint.enabled) endpoints

let select_endpoint ?endpoint_id (endpoints : endpoint list) =
  let endpoints = enabled_endpoints endpoints in
  match endpoint_id with
  | Some id when String.trim id <> "" -> (
      let id = String.trim id in
      List.find_opt
        (fun (endpoint : endpoint) ->
          endpoint.id = id || string_of_endpoint_kind endpoint.kind = id)
        endpoints )
  | _ -> (
      match endpoints with
      | first :: _ -> Some first
      | [] -> None)

let voice_for_agent config agent_id =
  match List.assoc_opt agent_id config.tts.agent_voices with
  | Some voice -> voice
  | None -> config.tts.default_voice

let tuning_for_agent config agent_id =
  match List.assoc_opt agent_id config.tts.agent_voice_settings with
  | Some tuning -> tuning
  | None -> config.tts.default_voice_settings

let local_playback_enabled_for_agent config agent_id =
  config.local_playback.enabled
  &&
  match config.local_playback.agents with
  | [] -> true
  | agents -> List.mem agent_id agents

let unique_strings values =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | value :: rest ->
        if List.mem value seen then loop seen acc rest
        else loop (value :: seen) (value :: acc) rest
  in
  loop [] [] values

let available_voices config =
  config.tts.default_voice
  :: List.map snd config.tts.agent_voices
  |> unique_strings

let endpoint_public_json (endpoints : endpoint list) =
  let active : endpoint option = select_endpoint endpoints in
  let fallback_configured =
    List.fold_left
      (fun acc (endpoint : endpoint) -> if endpoint.enabled then acc + 1 else acc)
      0 endpoints
    > 1
  in
  `Assoc
    [
      ("configured", `Bool (endpoints <> []));
      ( "enabled",
        `Bool
          (match active with
          | Some (endpoint : endpoint) -> endpoint.enabled
          | None -> false) );
      ("fallback_configured", `Bool fallback_configured);
    ]

let active_endpoint_json endpoints =
  endpoint_public_json endpoints

let agent_voices_json config =
  `List
    (List.map
       (fun (agent_id, voice) ->
         `Assoc [ ("agent_id", `String agent_id); ("voice", `String voice) ])
       config.tts.agent_voices)

let public_json config =
  Tool_args.ok_assoc
    [
      ( "tts",
        `Assoc
          [
            ("default_model", `String config.tts.default_model);
            ("default_voice", `String config.tts.default_voice);
            ("available_voices", `List (List.map (fun voice -> `String voice) (available_voices config)));
            ("available_models", `List [ `String config.tts.default_model ]);
            ("active_endpoint", active_endpoint_json config.tts.endpoints);
          ] );
      ( "stt",
        `Assoc
          [
            ("default_model", `String config.stt.default_model);
            ("active_endpoint", active_endpoint_json config.stt.endpoints);
          ] );
      ( "session",
        `Assoc [ ("active_endpoint", active_endpoint_json config.session.endpoints) ] );
      ( "local_playback",
        `Assoc
          [
            ("enabled", `Bool config.local_playback.enabled);
            ( "agents",
              `List
                (List.map (fun agent_id -> `String agent_id) config.local_playback.agents) );
          ] );
    ]
