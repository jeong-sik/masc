(** MASC Voice Bridge - Eio-native Implementation

    Enables multi-agent voice collaboration via turn-based speaking.
    Core constraint: "병렬 수집 → 순차 출력" (parallel collection → sequential output)

    TTS Strategy (priority order):
    1. ElevenLabs API direct (ELEVENLABS_API_KEY)
    2. Railway proxy (ELEVENLABS_PROXY_URL)
    3. Voice MCP Server (port 8936, legacy)
    4. text_fallback (silent)

    Eio Migration Notes:
    - Direct style (no monads)
    - Cohttp_eio.Client for HTTP
    - Eio.Time.sleep for delays
    - Eio.Fiber.first for timeouts
*)

(** ============================================
    Configuration (JSON SSOT)
    ============================================ *)

let default_timeout_seconds = 5.0
let default_max_retries = 3
let default_initial_backoff_seconds = 1.0
let default_backoff_multiplier = 2.0
let ( let* ) = Result.bind

let default_agent_voices =
  [
    ("claude", "Sarah");
    ("gemini", "Roger");
    ("codex", "George");
    ("llama", "Laura");
  ]

let load_voice_config () = Voice_config.load ()

let request_timeout_seconds () = default_timeout_seconds
let max_retries () = default_max_retries
let initial_backoff_seconds () = default_initial_backoff_seconds
let backoff_multiplier () = default_backoff_multiplier

let agent_voices () =
  match load_voice_config () with
  | Ok config -> config.tts.agent_voices
  | Error _ -> default_agent_voices

let tuning_for_agent agent_id =
  match load_voice_config () with
  | Ok config -> Voice_config.tuning_for_agent config agent_id
  | Error _ ->
      { Voice_config.stability = 0.5; similarity_boost = 0.75; style = 0.0 }

let local_playback_enabled_for_agent agent_id =
  match load_voice_config () with
  | Ok config -> Voice_config.local_playback_enabled_for_agent config agent_id
  | Error _ -> false

let ends_with ~suffix s =
  let slen = String.length s in
  let plen = String.length suffix in
  slen >= plen && String.sub s (slen - plen) plen = suffix

let compose_endpoint_from_base ~base_url ~path =
  let base_uri = Uri.of_string base_url in
  let base_path = Uri.path base_uri in
  let base_path =
    if base_path = "" then "/"
    else if ends_with ~suffix:"/" base_path && String.length base_path > 1 then
      String.sub base_path 0 (String.length base_path - 1)
    else base_path
  in
  let final_path =
    if path = "/mcp" then
      if ends_with ~suffix:"/mcp" base_path then base_path
      else if base_path = "/" then "/mcp"
      else base_path ^ "/mcp"
    else if path = "/health" then
      if ends_with ~suffix:"/health" base_path then base_path
      else if ends_with ~suffix:"/mcp" base_path then
        String.sub base_path 0 (String.length base_path - 4) ^ "/health"
      else if base_path = "/" then "/health"
      else base_path ^ "/health"
    else if base_path = "/" then path
    else base_path ^ path
  in
  Uri.with_path base_uri final_path

let active_session_endpoint () =
  match load_voice_config () with
  | Ok config -> Voice_config.select_endpoint config.session.endpoints
  | Error _ -> None

let session_mcp_uri endpoint =
  match endpoint.Voice_config.mcp_url with
  | Some url -> Uri.of_string url
  | None -> (
      match endpoint.base_url with
      | Some base_url -> compose_endpoint_from_base ~base_url ~path:"/mcp"
      | None -> Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:8936 ~path:"/mcp" ())

let session_health_uri endpoint =
  match endpoint.Voice_config.health_url with
  | Some url -> Uri.of_string url
  | None -> (
      match endpoint.base_url with
      | Some base_url -> compose_endpoint_from_base ~base_url ~path:"/health"
      | None ->
          Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:8936 ~path:"/health" ())

let voice_mcp_uri () =
  match active_session_endpoint () with
  | Some endpoint -> session_mcp_uri endpoint
  | None -> Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:8936 ~path:"/mcp" ()

let voice_health_uri () =
  match active_session_endpoint () with
  | Some endpoint -> session_health_uri endpoint
  | None ->
      Uri.make ~scheme:"http" ~host:"127.0.0.1" ~port:8936 ~path:"/health" ()

let voice_mcp_host () =
  match Uri.host (voice_mcp_uri ()) with Some host -> host | None -> "127.0.0.1"

let voice_mcp_port () =
  match Uri.port (voice_mcp_uri ()) with Some port -> port | None -> 8936

let client_for_uri ~net uri =
  if Uri.scheme uri = Some "https" then
    Cohttp_eio.Client.make ~https:(Some (Eio_context.get_https_connector ())) net
  else
    Cohttp_eio.Client.make ~https:None net

(** ============================================
    Structured Logging
    ============================================ *)

let log_prefix = "[VoiceBridge]"

let log_info msg =
  Log.info "%s %s" log_prefix msg

let log_error msg =
  Log.error "%s %s" log_prefix msg

let log_debug msg =
  Log.debug "%s %s" log_prefix msg

let local_playback_enabled config ~agent_id =
  config.Voice_config.local_playback.enabled
  &&
  (match config.local_playback.agents with
  | [] -> true
  | agents -> List.mem agent_id agents)

let split_path_env value =
  String.split_on_char ':' value
  |> List.filter (fun entry -> String.trim entry <> "")

let find_executable_in_path ?path_value executable =
  let path_value =
    match path_value with
    | Some value -> value
    | None -> Option.value (Sys.getenv_opt "PATH") ~default:""
  in
  let candidates =
    split_path_env path_value
    |> List.map (fun dir -> Filename.concat dir executable)
  in
  List.find_opt (fun path -> Sys.file_exists path && not (Sys.is_directory path)) candidates

let local_playback_argv ?path_value ~audio_file () =
  let commands =
    [
      ("ffplay", [ "-nodisp"; "-autoexit"; "-loglevel"; "error" ]);
      ("mpg123", [ "-q" ]);
      ("play", [ "-q" ]);
      ("open", []);
    ]
  in
  let rec pick = function
    | [] -> None
    | (executable, args) :: rest -> (
        match find_executable_in_path ?path_value executable with
        | Some path -> Some (path :: args @ [ audio_file ])
        | None -> pick rest)
  in
  pick commands

let start_local_playback ~sw ~agent_id ~audio_file =
  match load_voice_config () with
  | Error _ -> ()
  | Ok config ->
      if not (local_playback_enabled config ~agent_id) then
        ()
      else
        match local_playback_argv ~audio_file () with
        | None ->
            log_error
              "local voice playback unavailable: no ffplay/mpg123/play/open executable found"
        | Some argv ->
          Eio.Fiber.fork ~sw (fun () ->
              match Process_eio.run_argv_with_status ~timeout_sec:180.0 argv with
              | Unix.WEXITED 0, _ ->
                  log_info
                    (Printf.sprintf "local voice playback finished: agent=%s file=%s via=%s"
                       agent_id audio_file (List.hd argv))
              | Unix.WEXITED code, output ->
                  log_error
                    (Printf.sprintf
                       "local voice playback failed (exit=%d): %s%s"
                       code (String.concat " " argv)
                       (if String.trim output = "" then "" else " :: " ^ String.trim output))
              | Unix.WSTOPPED signal, output ->
                  log_error
                    (Printf.sprintf
                       "local voice playback stopped (sig=%d): %s%s"
                       signal (String.concat " " argv)
                       (if String.trim output = "" then "" else " :: " ^ String.trim output))
              | Unix.WSIGNALED signal, output ->
                  log_error
                    (Printf.sprintf
                       "local voice playback signaled (sig=%d): %s%s"
                       signal (String.concat " " argv)
                       (if String.trim output = "" then "" else " :: " ^ String.trim output)))

(** Get voice for agent, defaults to "Sarah" if config is unavailable *)
let get_voice_for_agent agent_id =
  let voices = agent_voices () in
  match List.assoc_opt agent_id voices with
  | Some voice -> voice
  | None -> "Sarah"

(** ============================================
    TTS Adapters
    ============================================ *)

let elevenlabs_voice_ids = [
  ("Sarah",  "EXAVITQu4vr4xnSDxMaL");
  ("Roger",  "CwhRBWXzGAHq8TQ4Fs17");
  ("George", "JBFqnCBsd6RMkjVDRZzb");
  ("Laura",  "FGY2WhTYpPnrIDTdsKH5");
]

let voice_name_to_id name =
  match List.assoc_opt name elevenlabs_voice_ids with
  | Some id -> id
  | None ->
      let trimmed = String.trim name in
      if trimmed = "" then "21m00Tcm4TlvDq8ikWAM" else trimmed

(** Ensure .masc/audio/ directory exists *)
let masc_base_dir () =
  match Sys.getenv_opt "ME_ROOT" with
  | Some root when String.trim root <> "" -> Filename.concat root ".masc"
  | _ -> ".masc"

let ensure_audio_dir () =
  let dir = Filename.concat (masc_base_dir ()) "audio" in
  if not (Sys.file_exists dir) then
    Sys.mkdir dir 0o755
  else if not (Sys.is_directory dir) then
    log_error "voice audio path exists but is not a directory"

let normalize_base_url value =
  let trimmed = String.trim value in
  if ends_with ~suffix:"/" trimmed && String.length trimmed > 1 then
    String.sub trimmed 0 (String.length trimmed - 1)
  else
    trimmed

let endpoint_url endpoint =
  match endpoint.Voice_config.kind with
  | Voice_config.Openai_compat | Voice_config.Elevenlabs_direct ->
      endpoint.base_url
  | Voice_config.Voice_mcp -> (
      match endpoint.mcp_url with
      | Some _ as url -> url
      | None -> endpoint.base_url)

let endpoint_url_json endpoint =
  match endpoint_url endpoint with
  | Some value -> `String value
  | None -> `Null

let append_provider_metadata json endpoint =
  let adapter = Provider_adapter.voice_adapter_for_endpoint endpoint in
  match json with
  | `Assoc fields ->
      `Assoc
        (fields
        @ [
            ("provider_name", `String adapter.canonical_name);
            ( "provider_kind",
              `String (Provider_adapter.string_of_voice_transport adapter.transport) );
            ( "provider_family",
              `String (Provider_adapter.string_of_provider_family adapter.provider_family) );
            ("provider_auth", `String (Provider_adapter.string_of_auth_mode adapter.auth_mode));
            ("endpoint_id", `String endpoint.id);
            ("endpoint_url", endpoint_url_json endpoint);
          ])
  | other -> other

let safe_agent_id value =
  String.map
    (fun c ->
      if
        (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c = '-'
        || c = '_'
      then c
      else '_')
    value

let make_audio_file ~agent_id =
  ensure_audio_dir ();
  let timestamp = int_of_float (Time_compat.now ()) in
  Filename.concat
    (Filename.concat (masc_base_dir ()) "audio")
    (Printf.sprintf "%d_%s.mp3" timestamp (safe_agent_id agent_id))

let write_text path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

let show_process_status = function
  | Unix.WEXITED code -> Printf.sprintf "exit %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal

let playback_success_json ~attempted ~succeeded ~method_name ?detail () =
  `Assoc
    [
      ("enabled", `Bool attempted);
      ("attempted", `Bool attempted);
      ("succeeded", `Bool succeeded);
      ("method", `String method_name);
      ("detail", match detail with Some value -> `String value | None -> `Null);
    ]

let playback_skipped_json reason =
  `Assoc
    [
      ("enabled", `Bool false);
      ("attempted", `Bool false);
      ("succeeded", `Bool false);
      ("method", `Null);
      ("detail", `String reason);
    ]

let play_audio_locally ~agent_id ~audio_file =
  if not (local_playback_enabled_for_agent agent_id) then
    Ok (playback_skipped_json "local playback disabled")
  else
    let run argv =
      Process_eio.run_argv_with_status ~timeout_sec:120.0 argv
    in
    let run_afplay path =
      let argv =
        if Sys.file_exists "/usr/bin/afplay" then [ "/usr/bin/afplay"; path ]
        else [ "afplay"; path ]
      in
      run argv
    in
    match run_afplay audio_file with
    | Unix.WEXITED 0, _ ->
        Ok (playback_success_json ~attempted:true ~succeeded:true ~method_name:"afplay" ())
    | status, output ->
        let wav_file = Filename.temp_file "masc_voice_playback" ".wav" in
        Fun.protect
          ~finally:(fun () -> try Sys.remove wav_file with Sys_error _ -> ())
          (fun () ->
            let ffmpeg_argv =
              [ "ffmpeg"; "-y"; "-loglevel"; "error"; "-i"; audio_file; wav_file ]
            in
            match run ffmpeg_argv with
            | Unix.WEXITED 0, _ -> (
                match run_afplay wav_file with
                | Unix.WEXITED 0, _ ->
                    Ok
                      (playback_success_json ~attempted:true ~succeeded:true
                         ~method_name:"ffmpeg+afplay"
                         ~detail:"converted to wav for playback" ())
                | status2, output2 ->
                    Error
                      (Printf.sprintf
                         "local playback failed after wav conversion: afplay=%s output=%s"
                         (show_process_status status2)
                         (String.trim output2)) )
            | status_ffmpeg, output_ffmpeg ->
                Error
                  (Printf.sprintf
                     "local playback failed: afplay=%s output=%s; ffmpeg=%s output=%s"
                     (show_process_status status)
                     (String.trim output)
                     (show_process_status status_ffmpeg)
                     (String.trim output_ffmpeg)) )

let resolve_api_key endpoint =
  let adapter = Provider_adapter.voice_adapter_for_endpoint endpoint in
  match
    Provider_adapter.voice_auth_env_name
      ?endpoint_api_key_env:endpoint.Voice_config.api_key_env
      adapter
  with
  | Some env_name -> (
      match Sys.getenv_opt env_name with
      | Some value when String.trim value <> "" -> Ok (String.trim value)
      | _ ->
          Error
            (Printf.sprintf
               "voice provider %s (endpoint %s) expects %s to be set"
               adapter.canonical_name endpoint.id env_name) )
  | None -> Ok ""

let run_audio_http_request_to_file ~url ~headers ~body_json ~output_file =
  let body_file = Filename.temp_file "masc_voice_request" ".json" in
  Fun.protect
    ~finally:(fun () -> (try Sys.remove body_file with Sys_error _ -> ()))
    (fun () ->
      write_text body_file (Yojson.Safe.to_string body_json);
      let header_args =
        List.concat_map
          (fun (key, value) -> [ "-H"; Printf.sprintf "%s: %s" key value ])
          headers
      in
      let argv =
        [
          "curl";
          "-sS";
          "--max-time";
          "30";
          "-X";
          "POST";
          url;
        ]
        @ header_args
        @ [ "--data-binary"; "@" ^ body_file; "-o"; output_file; "-w"; "%{http_code}" ]
      in
      let status, http_code_str =
        Process_eio.run_argv_with_stdin_and_status ~timeout_sec:35.0
          ~stdin_content:"" argv
      in
      match status with
      | Unix.WEXITED 0 ->
          let http_code =
            try int_of_string (String.trim http_code_str) with Failure _ -> 0
          in
          if http_code >= 200 && http_code < 300 then
            let file_size =
              try (Unix.stat output_file).st_size with Unix.Unix_error _ -> 0
            in
            if file_size > 100 then Ok file_size
            else
              let detail =
                try read_file output_file with Sys_error _ -> "response too small"
              in
              Error
                (Printf.sprintf "HTTP %d returned small audio payload (%d bytes): %s"
                   http_code file_size detail)
          else
            let detail =
              try read_file output_file with Sys_error _ -> "request failed"
            in
            Error (Printf.sprintf "HTTP %d: %s" http_code detail)
      | Unix.WEXITED 28 -> Error "request timed out"
      | Unix.WEXITED code -> Error (Printf.sprintf "curl exit %d" code)
      | _ -> Error "curl process failed")

let speak_via_openai_compat_to_file endpoint ~agent_id ~message ~voice ~model ~output_file =
  let open Result in
  let* api_key = resolve_api_key endpoint in
  let base_url =
    match endpoint.base_url with
    | Some value -> Ok (normalize_base_url value)
    | None ->
        Error
          (Printf.sprintf "voice config endpoint %s missing base_url" endpoint.id)
  in
  let* base_url = base_url in
  let headers =
    [ ("Content-Type", "application/json"); ("Accept", "audio/mpeg") ]
    @
    if api_key = "" then [] else [ ("Authorization", "Bearer " ^ api_key) ]
  in
  let tuning = tuning_for_agent agent_id in
  let body_json =
    `Assoc
      [
        ("input", `String message);
        ("voice", `String voice);
        ("model", `String model);
        ("response_format", `String "mp3");
        ( "voice_settings",
          `Assoc
            [
              ("stability", `Float tuning.stability);
              ("similarity_boost", `Float tuning.similarity_boost);
              ("style", `Float tuning.style);
            ] );
      ]
  in
  run_audio_http_request_to_file
    ~url:(base_url ^ "/audio/speech")
    ~headers ~body_json ~output_file

let speak_via_elevenlabs_to_file endpoint ~agent_id ~message ~voice ~model ~output_file =
  let open Result in
  let* api_key = resolve_api_key endpoint in
  let base_url =
    match endpoint.base_url with
    | Some value -> Ok (normalize_base_url value)
    | None ->
        Error
          (Printf.sprintf "voice config endpoint %s missing base_url" endpoint.id)
  in
  let* base_url = base_url in
  let voice_id = voice_name_to_id voice in
  let headers =
    [
      ("xi-api-key", api_key);
      ("Content-Type", "application/json");
      ("Accept", "audio/mpeg");
    ]
  in
  let tuning = tuning_for_agent agent_id in
  let body_json =
    `Assoc
      [
        ("text", `String message);
        ("model_id", `String model);
        ( "voice_settings",
          `Assoc
            [
              ("stability", `Float tuning.stability);
              ("similarity_boost", `Float tuning.similarity_boost);
              ("style", `Float tuning.style);
            ] );
      ]
  in
  run_audio_http_request_to_file
    ~url:(Printf.sprintf "%s/text-to-speech/%s" base_url voice_id)
    ~headers ~body_json ~output_file

let available_tts_endpoints ?provider () =
  let normalize value = String.lowercase_ascii (String.trim value) in
  let endpoint_matches_provider label endpoint =
    let adapter = Provider_adapter.voice_adapter_for_endpoint endpoint in
    let labels =
      endpoint.id
      :: Voice_config.string_of_endpoint_kind endpoint.kind
      :: Provider_adapter.string_of_voice_transport adapter.transport
      :: adapter.canonical_name
      :: adapter.aliases
    in
    let target = normalize label in
    List.exists (fun candidate -> String.equal (normalize candidate) target) labels
  in
  match load_voice_config () with
  | Error _ -> []
  | Ok config ->
      let endpoints = Voice_config.enabled_endpoints config.tts.endpoints in
      (match provider with
      | Some label when String.trim label <> "" ->
          List.filter (endpoint_matches_provider label) endpoints
      | _ -> endpoints)

let provider_error_json endpoint message =
  append_provider_metadata
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])
    endpoint

let public_config_json () =
  match load_voice_config () with
  | Ok config -> Ok (Voice_config.public_json config)
  | Error message ->
      Error
        (`Assoc
          [ ("status", `String "error");
            ("message", `String message);
            ("config_path", `String (Voice_config.config_path ())) ])

let tts_preview_bytes_from_request_json json =
  let open Yojson.Safe.Util in
  let text =
    match json |> member "text" |> to_string_option with
    | Some value when String.trim value <> "" -> String.trim value
    | _ -> (
        match json |> member "input" |> to_string_option with
        | Some value when String.trim value <> "" -> String.trim value
        | _ -> raise (Yojson.Json_error "missing or empty text/input field"))
  in
  let voice =
    match json |> member "voice" |> to_string_option with
    | Some value when String.trim value <> "" -> String.trim value
    | _ -> (
        match json |> member "voice_id" |> to_string_option with
        | Some value when String.trim value <> "" -> String.trim value
        | _ -> (
            match load_voice_config () with
            | Ok config -> config.tts.default_voice
            | Error _ -> "Sarah"))
  in
  let model =
    match json |> member "model" |> to_string_option with
    | Some value when String.trim value <> "" -> String.trim value
    | _ -> (
        match json |> member "voice_model" |> to_string_option with
        | Some value when String.trim value <> "" -> String.trim value
        | _ -> (
            match load_voice_config () with
            | Ok config -> config.tts.default_model
            | Error _ -> "eleven_multilingual_v2"))
  in
  let provider =
    json |> member "provider" |> to_string_option
    |> Option.map String.trim
    |> (function Some value when value <> "" -> Some value | _ -> None)
  in
  let endpoints = available_tts_endpoints ?provider () in
  let rec try_endpoints attempted = function
    | [] ->
        let detail =
          if attempted = [] then "no configured TTS endpoint"
          else String.concat "; " (List.rev attempted)
        in
        Error detail
    | endpoint :: rest -> (
        match endpoint.Voice_config.kind with
        | Voice_config.Voice_mcp ->
            let note =
              Printf.sprintf "%s: preview unsupported for voice_mcp" endpoint.id
            in
            try_endpoints (note :: attempted) rest
        | Voice_config.Openai_compat | Voice_config.Elevenlabs_direct ->
            let output_file = Filename.temp_file "masc_voice_preview" ".mp3" in
            let result =
              match endpoint.Voice_config.kind with
              | Voice_config.Openai_compat ->
                  speak_via_openai_compat_to_file endpoint ~agent_id:"preview"
                    ~message:text ~voice ~model
                    ~output_file
              | Voice_config.Elevenlabs_direct ->
                  speak_via_elevenlabs_to_file endpoint ~agent_id:"preview"
                    ~message:text ~voice ~model
                    ~output_file
              | Voice_config.Voice_mcp -> assert false
            in
            Fun.protect
              ~finally:(fun () -> (try Sys.remove output_file with Sys_error _ -> ()))
              (fun () ->
                match result with
                | Ok _ -> Ok (read_file output_file)
                | Error error ->
                    let note = Printf.sprintf "%s: %s" endpoint.id error in
                    try_endpoints (note :: attempted) rest))
  in
  try_endpoints [] endpoints

(** Clean up old audio files (>1 hour). Call from heartbeat. *)
let cleanup_old_audio_files () =
  let dir = Filename.concat (masc_base_dir ()) "audio" in
  if Sys.file_exists dir && Sys.is_directory dir then begin
    let now = Time_compat.now () in
    let cutoff = now -. 3600.0 in
    let entries = Sys.readdir dir in
    let removed = ref 0 in
    Array.iter (fun entry ->
      let path = Filename.concat dir entry in
      (try
        let stat = Unix.stat path in
        if stat.st_mtime < cutoff then begin
          Sys.remove path;
          incr removed
        end
      with Unix.Unix_error _ | Sys_error _ -> ())
    ) entries;
    if !removed > 0 then
      log_info (Printf.sprintf "Cleaned up %d old audio files" !removed)
  end

(** ============================================
    Types
    ============================================ *)

(** Voice session status *)
type voice_session_status = {
  session_id: string;
  agent_id: string;
  voice: string;
  is_active: bool;
  turn_count: int;
  duration_seconds: float option;
}

(** Conference status *)
type conference_status = {
  conference_id: string;
  state: string;  (* idle, active, paused, ended *)
  participants: string list;
  current_speaker: string option;
  queue_size: int;
  turn_count: int;
}

(** Turn request result *)
type turn_request_result = {
  status: string;
  agent_id: string;
  message_preview: string;
  voice: string;
  queue_position: int;
}

(** ============================================
    HTTP Client with Timeout and Retry (Eio-native)
    ============================================ *)

(** Timeout exception for Eio.Fiber.first pattern *)
exception Timeout of string

(** Safe string prefix check *)
let starts_with ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

(** Check if an error is retryable (transient)
    Retryable errors: connection failures, timeouts, HTTP 5xx *)
let is_retryable_error error =
  if String.length error = 0 then false
  else
    let s = String.lowercase_ascii error in
    starts_with ~prefix:"connection" s ||
    starts_with ~prefix:"timeout" s ||
    (try
      Scanf.sscanf s "http %d" (fun code -> code >= 500 && code < 600)
    with Scanf.Scan_failure _ | Failure _ | End_of_file -> false)

(** Timeout helper using Eio.Fiber.first - returns Error after specified seconds *)
let with_timeout ~clock ?timeout operation =
  let timeout_sec = match timeout with Some t -> t | None -> request_timeout_seconds () in
  Eio.Fiber.first
    (fun () -> operation ())
    (fun () ->
      Eio.Time.sleep clock timeout_sec;
      Error (Printf.sprintf "Request timeout after %.1fs" timeout_sec))

(** Retry with exponential backoff - Eio version *)
let rec retry_with_backoff ~clock ~attempt ~max_attempts ~backoff_sec operation =
  let result = operation () in
  match result with
  | Ok _ as success -> success
  | Error e when attempt < max_attempts && is_retryable_error e ->
    log_info (Printf.sprintf "Retry %d/%d after %.1fs (error: %s)"
      attempt max_attempts backoff_sec e);
    Eio.Time.sleep clock backoff_sec;
    retry_with_backoff ~clock
      ~attempt:(attempt + 1)
      ~max_attempts
      ~backoff_sec:(backoff_sec *. backoff_multiplier ())
      operation
  | Error _ as failure ->
    log_error (Printf.sprintf "All %d retries exhausted" max_attempts);
    failure

(** Make single HTTP POST request to Voice MCP server - Eio version *)
let single_voice_mcp_call ~sw ~client ~uri ~headers ~body_str =
  try
    let body = Cohttp_eio.Body.of_string body_str in
    let resp, resp_body = Cohttp_eio.Client.post ~sw ~body ~headers client uri in
    let status = Cohttp.Response.status resp in
    (* Read body using Eio.Buf_read *)
    let body_str = Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:max_int in
    if Cohttp.Code.is_success (Cohttp.Code.code_of_status status) then
      Ok (Yojson.Safe.from_string body_str)
    else
      Error (Printf.sprintf "HTTP %d: %s"
        (Cohttp.Code.code_of_status status) body_str)
  with exn ->
    Error (Printf.sprintf "Connection error: %s" (Printexc.to_string exn))

(** Make HTTP POST request to Voice MCP server with timeout and retry - Eio version *)
let call_voice_mcp ~sw ~clock ~net ~tool_name ~arguments =
  log_debug (Printf.sprintf "Calling tool: %s" tool_name);
  let uri = voice_mcp_uri () in
  let request_body = `Assoc [
    ("jsonrpc", `String "2.0");
    ("method", `String "tools/call");
    ("id", `Int 1);
    ("params", `Assoc [
      ("name", `String tool_name);
      ("arguments", arguments);
    ]);
  ] in
  let body_str = Yojson.Safe.to_string request_body in
  let headers = Cohttp.Header.of_list [
    ("Content-Type", "application/json");
    ("Accept", "application/json");
  ] in
  let client = client_for_uri ~net uri in
  let operation () =
    with_timeout ~clock (fun () ->
      single_voice_mcp_call ~sw ~client ~uri ~headers ~body_str)
  in
  let result = retry_with_backoff ~clock
    ~attempt:1
    ~max_attempts:(max_retries ())
    ~backoff_sec:(initial_backoff_seconds ())
    operation
  in
  (match result with
  | Ok _ -> log_debug (Printf.sprintf "Tool %s succeeded" tool_name)
  | Error e -> log_error (Printf.sprintf "Tool %s failed: %s" tool_name e));
  result

(** Extract result from MCP response *)
let extract_mcp_result json =
  let open Yojson.Safe.Util in
  try
    let result = json |> member "result" in
    if result = `Null then
      let error = json |> member "error" |> member "message" |> to_string_option in
      Error (Option.value error ~default:"Unknown error")
    else
      (* Get content from result *)
      let content = result |> member "content" |> to_list in
      match content with
      | [] -> Ok (`Assoc [])
      | first :: _ ->
        let text = first |> member "text" |> to_string_option in
        (match text with
        | Some t ->
          (try Ok (Yojson.Safe.from_string t)
           with Yojson.Json_error _ -> Ok (`String t))
        | None -> Ok result)
  with e ->
    Error (Printf.sprintf "Parse error: %s" (Printexc.to_string e))

let call_voice_mcp_endpoint ~sw ~clock ~net ~endpoint ~tool_name ~arguments =
  let uri = session_mcp_uri endpoint in
  let request_body =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("method", `String "tools/call");
        ("id", `Int 1);
        ("params", `Assoc [ ("name", `String tool_name); ("arguments", arguments) ]);
      ]
  in
  let body_str = Yojson.Safe.to_string request_body in
  let headers =
    Cohttp.Header.of_list
      [ ("Content-Type", "application/json"); ("Accept", "application/json") ]
  in
  let client = client_for_uri ~net uri in
  let operation () =
    let timeout =
      Option.value endpoint.timeout_seconds ~default:(request_timeout_seconds ())
    in
    with_timeout ~clock ~timeout (fun () ->
        single_voice_mcp_call ~sw ~client ~uri ~headers ~body_str)
  in
  retry_with_backoff ~clock ~attempt:1
    ~max_attempts:(Option.value endpoint.max_retries ~default:(max_retries ()))
    ~backoff_sec:(initial_backoff_seconds ()) operation

let attempt_tts_endpoint ~sw ~clock ~net ~agent_id ~message ~voice ~model
    ~priority endpoint =
  match endpoint.Voice_config.kind with
  | Voice_config.Openai_compat ->
      let audio_file = make_audio_file ~agent_id in
      (match
         speak_via_openai_compat_to_file endpoint ~message ~voice ~model
           ~agent_id ~output_file:audio_file
       with
      | Ok file_size ->
          start_local_playback ~sw ~agent_id ~audio_file;
          Ok
            (append_provider_metadata
               (`Assoc
                 [
                   ("status", `String "spoken");
                   ("agent_id", `String agent_id);
                   ("voice", `String voice);
                   ("audio_file", `String audio_file);
                   ("audio_size", `Int file_size);
                   ( "message_preview",
                     `String
                       (String.sub message 0 (min 50 (String.length message))) );
                 ])
               endpoint)
      | Error error ->
          (try Sys.remove audio_file with Sys_error _ -> ());
          Error error)
  | Voice_config.Elevenlabs_direct ->
      let audio_file = make_audio_file ~agent_id in
      (match
         speak_via_elevenlabs_to_file endpoint ~message ~voice ~model
           ~agent_id ~output_file:audio_file
       with
      | Ok file_size ->
          start_local_playback ~sw ~agent_id ~audio_file;
          Ok
            (append_provider_metadata
               (`Assoc
                 [
                   ("status", `String "spoken");
                   ("agent_id", `String agent_id);
                   ("voice", `String voice);
                   ("audio_file", `String audio_file);
                   ("audio_size", `Int file_size);
                   ( "message_preview",
                     `String
                       (String.sub message 0 (min 50 (String.length message))) );
                 ])
               endpoint)
      | Error error ->
          (try Sys.remove audio_file with Sys_error _ -> ());
          Error error)
  | Voice_config.Voice_mcp ->
      let args =
        `Assoc
          [
            ("agent_id", `String agent_id);
            ("message", `String message);
            ("voice", `String voice);
            ("priority", `Int priority);
          ]
      in
      (match
         call_voice_mcp_endpoint ~sw ~clock ~net ~endpoint ~tool_name:"agent_speak"
           ~arguments:args
       with
      | Ok json -> (
          match extract_mcp_result json with
          | Ok data -> Ok (append_provider_metadata data endpoint)
          | Error error -> Error error)
      | Error error -> Error error)

(** ============================================
    Fallback Strategies
    ============================================ *)

(** Check if Voice MCP server is available (non-blocking, cached)
    Circuit Breaker pattern - shorter cache on failure for faster recovery *)
let voice_server_available = ref None
let voice_server_check_time = ref 0.0
let voice_server_health_target = ref None

(** Cache duration: 30s on success, 5s on failure (Circuit Breaker) *)
let cache_duration () =
  match !voice_server_available with
  | Some true -> 30.0   (* Success: cache longer *)
  | Some false -> 5.0   (* Failure: retry sooner *)
  | None -> 0.0         (* No cache: check immediately *)

let session_endpoint_result () =
  match load_voice_config () with
  | Error message -> Error message
  | Ok config -> (
      match Voice_config.select_endpoint config.session.endpoints with
      | Some endpoint -> (
          match endpoint.Voice_config.kind with
          | Voice_config.Voice_mcp -> Ok endpoint
          | _ ->
              Error
                (Printf.sprintf
                   "session endpoint %s must use kind=voice_mcp" endpoint.id) )
      | None -> Error "no configured session endpoint")

let is_voice_server_available ~sw ~clock ~net =
  match session_endpoint_result () with
  | Error _ ->
      voice_server_available := Some false;
      false
  | Ok endpoint ->
      let health_target = Uri.to_string (session_health_uri endpoint) in
      if !voice_server_health_target <> Some health_target then (
        voice_server_health_target := Some health_target;
        voice_server_available := None;
        voice_server_check_time := 0.0);
      let now = Time_compat.now () in
      if now -. !voice_server_check_time < cache_duration () then
        Option.value !voice_server_available ~default:false
      else begin
        voice_server_check_time := now;
        let check () =
          try
            let uri = session_health_uri endpoint in
            let client = client_for_uri ~net uri in
            let resp, _ = Cohttp_eio.Client.get ~sw client uri in
            let status = Cohttp.Response.status resp in
            let available =
              Cohttp.Code.is_success (Cohttp.Code.code_of_status status)
            in
            voice_server_available := Some available;
            Ok available
          with exn ->
            Eio.traceln "[WARN] voice server check failed: %s"
              (Printexc.to_string exn);
            voice_server_available := Some false;
            Ok false
        in
        with_timeout ~clock ~timeout:2.0 check |> function
        | Ok available -> available
        | Error _ ->
            voice_server_available := Some false;
            false
      end

(** Text-only fallback for when voice is unavailable *)
let text_fallback ?reason ?(attempted_endpoints = []) ~agent_id ~message () =
  let voice = get_voice_for_agent agent_id in
  log_info (Printf.sprintf "[Text fallback] %s (%s): %s"
    agent_id voice
    (String.sub message 0 (min 50 (String.length message))));
  let fields =
    [
      ("status", `String "text_fallback");
      ("agent_id", `String agent_id);
      ("voice", `String voice);
      ( "message_preview",
        `String (String.sub message 0 (min 50 (String.length message))) );
    ]
    @
    (match reason with Some value -> [ ("reason", `String value) ] | None -> [])
    @
    if attempted_endpoints = [] then []
    else
      [
        ( "attempted_endpoints",
          `List (List.map (fun value -> `String value) attempted_endpoints) );
      ]
  in
  Ok (`Assoc fields)

let call_session_tool ~sw ~clock ~net ~tool_name ~arguments =
  match session_endpoint_result () with
  | Error message -> Error message
  | Ok endpoint -> (
      match
        call_voice_mcp_endpoint ~sw ~clock ~net ~endpoint ~tool_name ~arguments
      with
      | Ok json -> (
          match extract_mcp_result json with
          | Ok data -> Ok (append_provider_metadata data endpoint)
          | Error error -> Error error)
      | Error error -> Error error)

(** ============================================
    Voice Session Management (Eio-native)
    ============================================ *)

(** Start a voice session for an agent *)
let start_voice_session ~sw ~clock ~net ~agent_id ?session_name () =
  let voice = get_voice_for_agent agent_id in
  let args =
    `Assoc
      [
        ("agent_id", `String agent_id);
        ("voice", `String voice);
        ("session_name", match session_name with Some n -> `String n | None -> `Null);
      ]
  in
  match call_session_tool ~sw ~clock ~net ~tool_name:"voice_session_start" ~arguments:args with
  | Ok (`Assoc fields as data) ->
      let open Yojson.Safe.Util in
      let session_id =
        data |> member "session_id" |> to_string_option
        |> Option.value ~default:"unknown"
      in
      Ok
        (`Assoc
          ([
             ("session_id", `String session_id);
             ("agent_id", `String agent_id);
             ("voice", `String voice);
             ("is_active", `Bool true);
             ("turn_count", `Int 0);
             ("duration_seconds", `Null);
           ]
          @ List.filter
              (fun (key, _) ->
                key = "provider_kind" || key = "endpoint_id" || key = "endpoint_url")
              fields))
  | Ok data -> Ok data
  | Error error -> Error error

(** End a voice session *)
let end_voice_session ~sw ~clock ~net ~agent_id =
  if not (is_voice_server_available ~sw ~clock ~net) then
    Error "Voice server unavailable"
  else
    let args = `Assoc [ ("agent_id", `String agent_id) ] in
    call_session_tool ~sw ~clock ~net ~tool_name:"voice_session_end" ~arguments:args

(** Request speaking turn.
    Ordered endpoint chain from voice_config.json. Fails explicitly when no
    real backend accepts the request. *)
let agent_speak ~sw ~clock ~net ~agent_id ~message ?provider ?(priority=1) () =
  let voice = get_voice_for_agent agent_id in
  let provider =
    provider |> Option.map String.trim
    |> (function Some value when value <> "" -> Some value | _ -> None)
  in
  cleanup_old_audio_files ();
  let endpoints = available_tts_endpoints ?provider () in
  let model =
    match load_voice_config () with
    | Ok config -> config.tts.default_model
    | Error _ -> "eleven_multilingual_v2"
  in
  let rec try_endpoints attempted = function
    | [] ->
        Error
          (Printf.sprintf "all configured TTS endpoints failed: %s"
             (String.concat " | " (List.rev attempted)))
    | endpoint :: rest -> (
        match
          attempt_tts_endpoint ~sw ~clock ~net ~agent_id ~message ~voice ~model
            ~priority endpoint
        with
        | Ok result -> Ok result
        | Error error ->
            let attempt = Printf.sprintf "%s: %s" endpoint.id error in
            try_endpoints (attempt :: attempted) rest)
  in
  if endpoints = [] then
    Error "no configured TTS endpoint"
  else
    try_endpoints [] endpoints

(** List active voice sessions *)
let list_voice_sessions ~sw ~clock ~net =
  if not (is_voice_server_available ~sw ~clock ~net) then
    Error "Voice server unavailable"
  else
    let args = `Assoc [] in
    call_session_tool ~sw ~clock ~net ~tool_name:"voice_session_list" ~arguments:args

(** Get voice configuration for an agent *)
let get_agent_voice ~agent_id =
  match load_voice_config () with
  | Ok config ->
      let voice = Voice_config.voice_for_agent config agent_id in
      Ok
        (`Assoc
          [
            ("agent_id", `String agent_id);
            ("voice", `String voice);
            ( "available_voices",
              `List
                (List.map
                   (fun value -> `String value)
                (Voice_config.available_voices config)) );
          ])
  | Error _ ->
      let voice = get_voice_for_agent agent_id in
      Ok
        (`Assoc
          [
            ("agent_id", `String agent_id);
            ("voice", `String voice);
            ("available_voices", `List (List.map (fun (_, v) -> `String v) (agent_voices ())));
          ])

(** ============================================
    Conference Management (Eio-native)
    ============================================ *)

(** Start a multi-agent voice conference *)
let start_conference ~sw ~clock ~net ~agent_ids ?conference_name () =
  let agent_voices_list =
    List.map
      (fun id ->
        `Assoc [ ("agent_id", `String id); ("voice", `String (get_voice_for_agent id)) ])
      agent_ids
  in
  let args =
    `Assoc
      [
        ("agent_ids", `List (List.map (fun id -> `String id) agent_ids));
        ("agent_voices", `List agent_voices_list);
        ("conference_name", match conference_name with Some n -> `String n | None -> `Null);
      ]
  in
  match call_session_tool ~sw ~clock ~net ~tool_name:"conference_start" ~arguments:args with
  | Ok (`Assoc fields as data) ->
      let open Yojson.Safe.Util in
      let conference_id =
        data |> member "conference_id" |> to_string_option
        |> Option.value ~default:"unknown"
      in
      Ok
        (`Assoc
          ([
             ("conference_id", `String conference_id);
             ("state", `String "active");
             ("participants", `List (List.map (fun id -> `String id) agent_ids));
             ("current_speaker", `Null);
             ("queue_size", `Int 0);
             ("turn_count", `Int 0);
           ]
          @ List.filter
              (fun (key, _) ->
                key = "provider_kind" || key = "endpoint_id" || key = "endpoint_url")
              fields))
  | Ok data -> Ok data
  | Error error -> Error error

(** End a multi-agent voice conference *)
let end_conference ~sw ~clock ~net ~agent_ids () =
  if not (is_voice_server_available ~sw ~clock ~net) then
    Error "Voice server unavailable - cannot end conference"
  else
  let classify_result = function
    | Ok (`Assoc fields) -> (
        match List.assoc_opt "status" fields with
        | Some (`String "ended") -> `Ended
        | Some (`String _) | Some _ -> `Failed
        | None -> `Failed)
    | Ok _ -> `Failed
    | Error _ -> `Failed
  in
  let ended, skipped, failed =
    List.fold_left
      (fun (ended, skipped, failed) agent_id ->
        match classify_result (end_voice_session ~sw ~clock ~net ~agent_id) with
        | `Ended -> (ended + 1, skipped, failed)
        | `Failed -> (ended, skipped, failed + 1))
      (0, 0, 0) agent_ids
  in
  Ok (`Assoc [
    ("ended", `Int ended);
    ("skipped", `Int skipped);
    ("failed", `Int failed);
    ("total", `Int (List.length agent_ids));
  ])

(** Get transcript of voice conversation *)
let get_transcript ~sw ~clock ~net () =
  if not (is_voice_server_available ~sw ~clock ~net) then
    Error "Voice server unavailable"
  else
    let args = `Assoc [] in
    match
      call_session_tool ~sw ~clock ~net ~tool_name:"get_transcript"
        ~arguments:args
    with
    | Ok data -> Ok data
    | Error error -> Error error

(** ============================================
    Health Check (Eio-native)
    ============================================ *)

(** Health check for Voice MCP server *)
let health_check ~sw ~clock:_ ~net () =
  match session_endpoint_result () with
  | Error error -> Error error
  | Ok endpoint ->
      let uri = session_health_uri endpoint in
      try
        let client = client_for_uri ~net uri in
        let resp, body = Cohttp_eio.Client.get ~sw client uri in
        let status = Cohttp.Response.status resp in
        let body_str = Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int in
        if Cohttp.Code.is_success (Cohttp.Code.code_of_status status) then
          Ok
            (append_provider_metadata
               (`Assoc
                 [
                   ("status", `String "healthy");
                   ("server", `String (Uri.to_string uri));
                   ( "response",
                     try Yojson.Safe.from_string body_str
                     with Yojson.Json_error _ -> `String body_str );
                 ])
               endpoint)
        else
          Error
            (Printf.sprintf "Unhealthy: HTTP %d"
               (Cohttp.Code.code_of_status status))
      with exn ->
        Error (Printf.sprintf "Not reachable: %s" (Printexc.to_string exn))
