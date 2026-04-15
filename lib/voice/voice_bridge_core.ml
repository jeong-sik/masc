(** Voice_bridge core — config, helpers, audio path utils, local playback. *)

(** MASC Voice Bridge - Eio-native Implementation

    Enables multi-agent voice collaboration via turn-based speaking.
    Core constraint: "병렬 수집 → 순차 출력" (parallel collection → sequential output)

    TTS Strategy (priority order):
    1. ElevenLabs API direct (ELEVENLABS_API_KEY)
    2. Railway proxy (ELEVENLABS_PROXY_URL)
    3. Voice MCP session endpoint (HTTP /mcp, legacy VOICE_MCP_* fallback)
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

let playback_mu = Eio.Mutex.create ()
let playback_dedup_window_sec = 30.0

type last_playback = { agent_id : string; message_hash : int; finished_at : float }
let last_playback_ref : last_playback option Atomic.t = Atomic.make None

let is_dedup_hit ~agent_id ~message =
  let h = Hashtbl.hash message in
  match Atomic.get last_playback_ref with
  | Some prev ->
    prev.agent_id = agent_id
    && prev.message_hash = h
    && Unix.gettimeofday () -. prev.finished_at < playback_dedup_window_sec
  | None -> false

let record_playback ~agent_id ~message =
  Atomic.set last_playback_ref
    (Some { agent_id; message_hash = Hashtbl.hash message; finished_at = Unix.gettimeofday () })

(** Default agent voices from Provider_adapter registry (SSOT).
    Hardcoded list removed — voices defined in Provider_adapter.direct_adapters. *)
let default_agent_voices () = Provider_adapter.all_agent_voices ()

let load_voice_config () = Voice_config.load ()

let request_timeout_seconds () = default_timeout_seconds
let max_retries () = default_max_retries
let initial_backoff_seconds () = default_initial_backoff_seconds
let backoff_multiplier () = default_backoff_multiplier

let agent_voices () =
  match load_voice_config () with
  | Ok config -> config.tts.agent_voices
  | Error _ -> default_agent_voices ()

let tuning_for_agent agent_id =
  match load_voice_config () with
  | Ok config -> Voice_config.tuning_for_agent config agent_id
  | Error _ ->
      { Voice_config.stability = 0.5; similarity_boost = 0.75; style = 0.0 }

let local_playback_enabled_for_agent agent_id =
  match load_voice_config () with
  | Ok config -> Voice_config.local_playback_enabled_for_agent config agent_id
  | Error _ -> false

let default_voice_uri path =
  Uri.of_string (Provider_adapter.default_voice_session_url ~path)

let voice_mcp_uri () =
  match load_voice_config () with
  | Ok config -> (
      match Provider_adapter.voice_session_endpoint_result config with
      | Ok endpoint -> (
          match Provider_adapter.voice_session_mcp_url_of_endpoint endpoint with
          | Ok url -> Uri.of_string url
          | Error _ -> default_voice_uri "/mcp" )
      | Error _ -> default_voice_uri "/mcp")
  | Error _ -> default_voice_uri "/mcp"

let voice_health_uri () =
  match load_voice_config () with
  | Ok config -> (
      match Provider_adapter.voice_session_endpoint_result config with
      | Ok endpoint -> (
          match Provider_adapter.voice_session_health_url_of_endpoint endpoint with
          | Ok url -> Uri.of_string url
          | Error _ -> default_voice_uri "/health" )
      | Error _ -> default_voice_uri "/health")
  | Error _ -> default_voice_uri "/health"

let voice_mcp_host () =
  match Uri.host (voice_mcp_uri ()) with
  | Some host -> host
  | None -> Env_config_runtime.Voice.default_host

let voice_mcp_port () =
  match Uri.port (voice_mcp_uri ()) with
  | Some port -> port
  | None -> Env_config_runtime.Voice.default_port

let client_for_uri ~sw ~net uri =
  match
    if Uri.scheme uri <> Some "https" then Ok None
    else
      match Eio_context.get_https_connector_result () with
      | Ok connector -> Ok (Some connector)
      | Error message -> Error message
  with
  | Ok https -> Ok (Masc_http_client.make_closing_client ~sw ~net ~https)
  | Error message -> Error message

let client_for_uri_result ~sw ~net uri =
  try client_for_uri ~sw ~net uri with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Error
        (Printf.sprintf "HTTPS client init error: %s"
           (Printexc.to_string exn))

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

(** Runs local playback with mutex-protected dedup check.
    Returns:
    - [`Dedup_hit] if another fiber already played this same message recently
      (check happens INSIDE the mutex to close the check-then-act race where two
      fibers both pass the outer [is_dedup_hit] before either records).
    - [`Played None] if playback was disabled, unavailable, or failed.
    - [`Played (Some dur)] if playback succeeded with the given duration.

    When [message] is [None] the dedup re-check is skipped (legacy callers that
    do not propagate the message string). *)
let run_local_playback ~sw:_ ~agent_id ?message ~audio_file () =
  match load_voice_config () with
  | Error e ->
    Log.Misc.warn "voice config load failed, skipping playback for %s: %s" agent_id e;
    `Played None
  | Ok config ->
    if not (Voice_config.local_playback_enabled_for_agent config agent_id) then
      `Played None
    else
      match local_playback_argv ~audio_file () with
      | None ->
        log_error
          "local voice playback unavailable: no ffplay/mpg123/play/open executable found";
        `Played None
      | Some argv ->
        Eio.Mutex.use_rw ~protect:true playback_mu (fun () ->
          let dedup_hit =
            match message with
            | Some m -> is_dedup_hit ~agent_id ~message:m
            | None -> false
          in
          if dedup_hit then begin
            log_info (Printf.sprintf
              "voice dedup skip inside mutex: agent=%s (same message within %.0fs window)"
              agent_id playback_dedup_window_sec);
            `Dedup_hit
          end
          else begin
            (* Record BEFORE playing so concurrent callers waiting on this mutex
               will observe the in-flight playback when they acquire it. *)
            (match message with
             | Some m -> record_playback ~agent_id ~message:m
             | None -> ());
            let t0 = Unix.gettimeofday () in
            try
              match Process_eio.run_argv_with_status ~timeout_sec:60.0 argv with
              | Unix.WEXITED 0, _ ->
                let dur = Unix.gettimeofday () -. t0 in
                log_info
                  (Printf.sprintf
                     "local voice playback finished: agent=%s file=%s via=%s duration=%.1fs"
                     agent_id audio_file
                     (match argv with h :: _ -> h | [] -> "unknown")
                     dur);
                `Played (Some dur)
              | Unix.WEXITED code, output ->
                log_error
                  (Printf.sprintf
                     "local voice playback failed (exit=%d): %s%s"
                     code (String.concat " " argv)
                     (if String.trim output = "" then "" else " :: " ^ String.trim output));
                `Played None
              | Unix.WSTOPPED signal, output ->
                log_error
                  (Printf.sprintf
                     "local voice playback stopped (sig=%d): %s%s"
                     signal (String.concat " " argv)
                     (if String.trim output = "" then "" else " :: " ^ String.trim output));
                `Played None
              | Unix.WSIGNALED signal, output ->
                log_error
                  (Printf.sprintf
                     "local voice playback signaled (sig=%d): %s%s"
                     signal (String.concat " " argv)
                     (if String.trim output = "" then "" else " :: " ^ String.trim output));
                `Played None
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              log_error (Printf.sprintf "voice playback exception: %s"
                (Printexc.to_string exn));
              `Played None
          end)

let start_local_playback ~sw ~agent_id ~audio_file =
  ignore (run_local_playback ~sw ~agent_id ~audio_file () : [`Dedup_hit | `Played of float option])

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

let trim_opt = function
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed
  | None -> None

(** Ensure .masc/audio/ directory exists *)
let resolved_base_path_opt () =
  match Env_config_core.base_path_opt () with
  | Some path -> Some path
  | None -> Coord_utils_backend_setup.find_git_root (Sys.getcwd ())

let masc_base_dir () =
  match resolved_base_path_opt () with
  | Some base_path -> Filename.concat base_path ".masc"
  | None -> ".masc"

let ensure_audio_dir () =
  let dir = Filename.concat (masc_base_dir ()) "audio" in
  if not (Sys.file_exists dir) then
    Sys.mkdir dir 0o755
  else if not (Sys.is_directory dir) then
    log_error "voice audio path exists but is not a directory"

let provider_metadata_keys =
  [ "provider_name"; "provider_kind"; "provider_family"; "provider_auth"; "endpoint_id"; "endpoint_url" ]

let strip_provider_metadata = function
  | `Assoc fields ->
      `Assoc
        (fields
        |> List.filter (fun (key, _) -> not (List.mem key provider_metadata_keys)))
  | other -> other

let append_provider_metadata json _endpoint =
  (* Public voice APIs stay vendor-neutral. Keep provider details in internal
     config and logs, but do not expose them through tool/API payloads. *)
  strip_provider_metadata json
