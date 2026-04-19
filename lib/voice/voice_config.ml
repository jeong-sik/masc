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

let trim_opt = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

let dedupe_keep_order values =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | value :: rest ->
        if List.mem value seen then loop seen acc rest
        else loop (value :: seen) (value :: acc) rest
  in
  loop [] [] values

let voice_config_file_in root =
  let masc_dir =
    Coord_utils.masc_root_dir_from
      ~base_path:root
      ~cluster_name:(Env_config_core.cluster_name ())
  in
  Filename.concat masc_dir "voice_config.json"

let base_path_voice_config_path_opt () =
  Env_config_core.base_path_opt ()
  |> Option.map voice_config_file_in

let repo_voice_config_path_opt () =
  let root =
    match Env_config_core.base_path_opt () with
    | Some bp -> bp
    | None ->
      let cwd = Sys.getcwd () in
      (match Coord_utils_backend_setup.find_git_root cwd with
       | Some path -> path
       | None -> cwd)
  in
  Some (voice_config_file_in root)

let fallback_voice_config_path () =
  let root =
    match Env_config_core.base_path_opt () with
    | Some bp -> bp
    | None -> Sys.getcwd ()
  in
  voice_config_file_in root

let config_path_candidates () =
  [
    base_path_voice_config_path_opt ();
    repo_voice_config_path_opt ();
    Some (fallback_voice_config_path ());
  ]
  |> List.filter_map Fun.id
  |> dedupe_keep_order

let config_path () =
  let candidates = config_path_candidates () in
  match List.find_opt Sys.file_exists candidates, candidates with
  | Some path, _ -> path
  | None, path :: _ -> path
  | None, [] -> fallback_voice_config_path ()

let trim_nonempty = function
  | `String value ->
      let trimmed = String.trim value in
      if trimmed = "" then None else Some trimmed
  | _ -> None

let string_list_opt = function
  | `List items ->
      let rec loop acc = function
        | [] -> Some (List.rev acc)
        | item :: rest -> (
            match trim_nonempty item with
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
  match Yojson.Safe.Util.member field json |> trim_nonempty with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s.%s is required" ctx field)

let require_object ~ctx ~field json =
  match Yojson.Safe.Util.member field json with
  | `Assoc _ as obj -> Ok obj
  | _ -> Error (Printf.sprintf "%s.%s must be object" ctx field)

let require_list ~ctx ~field json =
  match Yojson.Safe.Util.member field json with
  | `List items -> Ok items
  | _ -> Error (Printf.sprintf "%s.%s must be array" ctx field)

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
  let base_url = Yojson.Safe.Util.member "base_url" json |> trim_nonempty in
  let mcp_url = Yojson.Safe.Util.member "mcp_url" json |> trim_nonempty in
  let health_url = Yojson.Safe.Util.member "health_url" json |> trim_nonempty in
  let api_key_env = Yojson.Safe.Util.member "api_key_env" json |> trim_nonempty in
  let enabled =
    Yojson.Safe.Util.member "enabled" json |> bool_or_default true
  in
  let timeout_seconds =
    Yojson.Safe.Util.member "timeout_seconds" json |> float_opt
  in
  let max_retries = Yojson.Safe.Util.member "max_retries" json |> int_opt in
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
  match Yojson.Safe.Util.member "agent_voices" json with
  | `Assoc pairs ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | (agent_id, value) :: rest -> (
            match trim_nonempty value with
            | Some voice ->
                loop ((String.trim agent_id, voice) :: acc) rest
            | None ->
                Error
                  (Printf.sprintf
                     "tts.agent_voices.%s must be a non-empty string" agent_id) )
      in
      loop [] pairs
  | `Null -> Ok []
  | _ -> Error "tts.agent_voices must be an object"

let parse_voice_tuning ~ctx json =
  match json with
  | `Assoc _ ->
      Ok
        {
          stability =
            Yojson.Safe.Util.member "stability" json |> float_or_default 0.5;
          similarity_boost =
            Yojson.Safe.Util.member "similarity_boost" json
            |> float_or_default 0.75;
          style = Yojson.Safe.Util.member "style" json |> float_or_default 0.0;
        }
  | `Null ->
      Ok { stability = 0.5; similarity_boost = 0.75; style = 0.0 }
  | _ -> Error (Printf.sprintf "%s must be an object" ctx)

let parse_agent_voice_settings json =
  match Yojson.Safe.Util.member "agent_voice_settings" json with
  | `Assoc pairs ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | (agent_id, tuning_json) :: rest -> (
            match parse_voice_tuning ~ctx:("tts.agent_voice_settings." ^ agent_id) tuning_json with
            | Ok tuning -> loop ((String.trim agent_id, tuning) :: acc) rest
            | Error _ as err -> err)
      in
      loop [] pairs
  | `Null -> Ok []
  | _ -> Error "tts.agent_voice_settings must be an object"

let parse_tts json =
  let open Result in
  let* tts_json = require_object ~ctx:"root" ~field:"tts" json in
  let* default_model = require_string ~ctx:"tts" ~field:"default_model" tts_json in
  let* default_voice = require_string ~ctx:"tts" ~field:"default_voice" tts_json in
  let* default_voice_settings =
    parse_voice_tuning ~ctx:"tts.default_voice_settings"
      (Yojson.Safe.Util.member "default_voice_settings" tts_json)
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
  match Yojson.Safe.Util.member "local_playback" json with
  | `Assoc local_json ->
      let local_json = `Assoc local_json in
      let enabled =
        Yojson.Safe.Util.member "enabled" local_json |> bool_or_default false
      in
      let agents =
        match Yojson.Safe.Util.member "agents" local_json with
        | `List values -> List.filter_map trim_nonempty values
        | _ -> []
      in
      Ok { enabled; agents }
  | `Null -> Ok { enabled = false; agents = [] }
  | _ -> Error "root.local_playback must be an object"

let load () =
  let path = config_path () in
  if not (Sys.file_exists path) then
    Error (Printf.sprintf "voice config missing at %s" path)
  else
    try
      let json = Safe_ops.read_json_eio path in
      let open Result in
      let* tts = parse_tts json in
      let* stt = parse_stt json in
      let* session = parse_session json in
      let* local_playback = parse_local_playback json in
      Ok { tts; stt; session; local_playback }
    with
    | Yojson.Json_error error ->
        Error (Printf.sprintf "invalid voice config json: %s" error)
    | Sys_error error ->
        Error (Printf.sprintf "voice config read failed: %s" error)
    | Eio.Io _ as exn ->
        Error (Printf.sprintf "voice config Eio read failed: %s" (Printexc.to_string exn))

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
  `Assoc
    [
      ("status", `String "ok");
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
