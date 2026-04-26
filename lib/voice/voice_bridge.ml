(** Voice_bridge — TTS synthesis, MCP voice sessions, conferences. *)

include Voice_bridge_core
open Result.Syntax

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
;;

let make_audio_file ~agent_id =
  ensure_audio_dir ();
  let timestamp = int_of_float (Time_compat.now ()) in
  Filename.concat
    (Filename.concat (masc_base_dir ()) "audio")
    (Printf.sprintf "%d_%s.mp3" timestamp (safe_agent_id agent_id))
;;

let write_text path content = Fs_compat.save_file path content
let read_file path = Fs_compat.load_file path

let resolve_api_key endpoint =
  let adapter = Provider_adapter.voice_adapter_for_endpoint endpoint in
  match Provider_adapter.voice_endpoint_auth_env_name endpoint with
  | Some env_name ->
    (match Sys.getenv_opt env_name with
     | Some value when String.trim value <> "" -> Ok (String.trim value)
     | _ ->
       Error
         (Printf.sprintf
            "voice provider %s (endpoint %s) expects %s to be set"
            adapter.canonical_name
            endpoint.id
            env_name))
  | None -> Ok ""
;;

let exec_gate_raw_source argv = String.concat " " (List.map Filename.quote argv)

let run_voice_status ?(timeout_sec = 35.0) ?(stdin_content = "") argv =
  Masc_exec.Exec_gate.run_argv_with_stdin_and_status
    ~actor:"voice/bridge"
    ~raw_source:(exec_gate_raw_source argv)
    ~summary:"voice bridge exec"
    ~timeout_sec
    ~stdin_content
    argv
;;

let run_audio_http_request_to_file ~url ~headers ~body_json ~output_file =
  let body_file = Filename.temp_file "masc_voice_request" ".json" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove body_file with
      | Sys_error _ -> ())
    (fun () ->
       write_text body_file (Yojson.Safe.to_string body_json);
       let header_args =
         List.concat_map
           (fun (key, value) -> [ "-H"; Printf.sprintf "%s: %s" key value ])
           headers
       in
       let argv =
         [ "curl"; "-sS"; "--max-time"; "30"; "-X"; "POST"; url ]
         @ header_args
         @ [ "--data-binary"; "@" ^ body_file; "-o"; output_file; "-w"; "%{http_code}" ]
       in
       let status, http_code_str = run_voice_status ~timeout_sec:35.0 argv in
       match status with
       | Unix.WEXITED 0 ->
         let http_code =
           Option.value ~default:0 (int_of_string_opt (String.trim http_code_str))
         in
         if http_code >= 200 && http_code < 300
         then (
           let file_size =
             try (Unix.stat output_file).st_size with
             | Unix.Unix_error _ -> 0
           in
           if file_size > 100
           then Ok file_size
           else (
             let detail =
               try read_file output_file with
               | Sys_error _ -> "response too small"
             in
             Error
               (Printf.sprintf
                  "HTTP %d returned small audio payload (%d bytes): %s"
                  http_code
                  file_size
                  detail)))
         else (
           let detail =
             try read_file output_file with
             | Sys_error _ -> "request failed"
           in
           Error (Printf.sprintf "HTTP %d: %s" http_code detail))
       | Unix.WEXITED 28 -> Error "request timed out"
       | Unix.WEXITED code -> Error (Printf.sprintf "curl exit %d" code)
       | _ -> Error "curl process failed")
;;

let speak_via_http_tts_to_file endpoint ~agent_id ~message ~voice ~model ~output_file =
  let* api_key = resolve_api_key endpoint in
  let tuning = tuning_for_agent agent_id in
  let* request =
    Provider_adapter.voice_http_request_for_tts
      endpoint
      ~api_key
      ~message
      ~voice
      ~model
      ~tuning
  in
  run_audio_http_request_to_file
    ~url:request.url
    ~headers:request.headers
    ~body_json:request.body_json
    ~output_file
;;

let run_stt_multipart_request (req : Provider_adapter.voice_stt_request) =
  let header_args =
    List.concat_map
      (fun (key, value) -> [ "-H"; Printf.sprintf "%s: %s" key value ])
      req.headers
  in
  let form_args =
    List.concat_map
      (fun (key, value) -> [ "-F"; Printf.sprintf "%s=%s" key value ])
      req.form_fields
  in
  let field_name, file_path = req.file_field in
  let file_arg = [ "-F"; Printf.sprintf "%s=@%s" field_name file_path ] in
  let argv =
    [ "curl"; "-sS"; "--fail-with-body"; "--max-time"; "30"; "-X"; "POST"; req.url ]
    @ header_args
    @ form_args
    @ file_arg
  in
  let status, body = run_voice_status ~timeout_sec:35.0 argv in
  match status with
  | Unix.WEXITED 0 ->
    (match Yojson.Safe.from_string body with
     | json -> Ok json
     | exception Yojson.Json_error msg ->
       Error (Printf.sprintf "STT response parse error: %s" msg))
  | Unix.WEXITED 22 ->
    Error
      (Printf.sprintf
         "STT HTTP error: %s"
         (if String.length body > 200 then String.sub body 0 200 else body))
  | Unix.WEXITED 28 -> Error "STT request timed out"
  | Unix.WEXITED code -> Error (Printf.sprintf "STT curl exit %d" code)
  | _ -> Error "STT curl process failed"
;;

let transcribe_via_http_stt endpoint ~audio_file ~model =
  let* api_key = resolve_api_key endpoint in
  let* request =
    Provider_adapter.voice_stt_request_for_endpoint endpoint ~api_key ~audio_file ~model
  in
  run_stt_multipart_request request
;;

let available_stt_endpoints () =
  match load_voice_config () with
  | Error _ -> []
  | Ok config ->
    config.stt.endpoints |> List.filter (fun (ep : Voice_config.endpoint) -> ep.enabled)
;;

let transcribe_audio ~audio_file ?language_code () =
  let model =
    match load_voice_config () with
    | Ok config -> config.stt.default_model
    | Error _ -> "scribe_v2"
  in
  let endpoints = available_stt_endpoints () in
  let rec try_endpoints = function
    | [] -> Error "no enabled STT endpoints configured"
    | endpoint :: rest ->
      (match transcribe_via_http_stt endpoint ~audio_file ~model with
       | Ok json ->
         let open Yojson.Safe.Util in
         let text =
           match json |> member "text" |> to_string_option with
           | Some t -> t
           | None -> Yojson.Safe.to_string json
         in
         let lang =
           match language_code with
           | Some lc -> lc
           | None ->
             (match json |> member "language_code" |> to_string_option with
              | Some lc -> lc
              | None -> "unknown")
         in
         Ok
           (`Assoc
               [ "status", `String "transcribed"
               ; "text", `String text
               ; "language_code", `String lang
               ; "endpoint_id", `String endpoint.id
               ])
       | Error _ when rest <> [] -> try_endpoints rest
       | Error err -> Error err)
  in
  try_endpoints endpoints
;;

let available_tts_endpoints ?provider () =
  match load_voice_config () with
  | Error _ -> []
  | Ok config -> Provider_adapter.select_voice_endpoints ?provider config.tts.endpoints
;;

let public_config_json () =
  match load_voice_config () with
  | Ok config -> Ok (Voice_config.public_json config)
  | Error message ->
    Error
      (`Assoc
          [ "status", `String "error"
          ; "message", `String message
          ; "config_path", `String (Voice_config.config_path ())
          ])
;;

let tts_preview_bytes_from_request_json json =
  let open Yojson.Safe.Util in
  let text =
    match json |> member "text" |> to_string_option with
    | Some value when String.trim value <> "" -> String.trim value
    | _ ->
      (match json |> member "input" |> to_string_option with
       | Some value when String.trim value <> "" -> String.trim value
       | _ -> raise (Yojson.Json_error "missing or empty text/input field"))
  in
  let voice =
    match json |> member "voice" |> to_string_option with
    | Some value when String.trim value <> "" -> String.trim value
    | _ ->
      (match json |> member "voice_id" |> to_string_option with
       | Some value when String.trim value <> "" -> String.trim value
       | _ ->
         (match load_voice_config () with
          | Ok config -> config.tts.default_voice
          | Error _ -> "Sarah"))
  in
  let model =
    match json |> member "model" |> to_string_option with
    | Some value when String.trim value <> "" -> String.trim value
    | _ ->
      (match json |> member "voice_model" |> to_string_option with
       | Some value when String.trim value <> "" -> String.trim value
       | _ ->
         (match load_voice_config () with
          | Ok config -> config.tts.default_model
          | Error _ -> "eleven_multilingual_v2"))
  in
  let provider =
    json
    |> member "provider"
    |> to_string_option
    |> Option.map String.trim
    |> function
    | Some value when value <> "" -> Some value
    | _ -> None
  in
  let endpoints = available_tts_endpoints ?provider () in
  let rec try_endpoints attempted = function
    | [] ->
      let detail =
        if attempted = []
        then "no configured TTS endpoint"
        else String.concat "; " (List.rev attempted)
      in
      Error detail
    | endpoint :: rest ->
      let adapter = Provider_adapter.voice_adapter_for_endpoint endpoint in
      if not (Provider_adapter.voice_transport_supports_http_tts adapter)
      then (
        let note = Printf.sprintf "%s: preview unsupported for voice_mcp" endpoint.id in
        try_endpoints (note :: attempted) rest)
      else (
        let output_file = Filename.temp_file "masc_voice_preview" ".mp3" in
        let result =
          speak_via_http_tts_to_file
            endpoint
            ~agent_id:"preview"
            ~message:text
            ~voice
            ~model
            ~output_file
        in
        Fun.protect
          ~finally:(fun () ->
            try Sys.remove output_file with
            | Sys_error _ -> ())
          (fun () ->
             match result with
             | Ok _ -> Ok (read_file output_file)
             | Error error ->
               let note = Printf.sprintf "%s: %s" endpoint.id error in
               try_endpoints (note :: attempted) rest))
  in
  try_endpoints [] endpoints
;;

(** Clean up old audio files (>1 hour). Call from heartbeat. *)
let cleanup_old_audio_files () =
  let dir = Filename.concat (masc_base_dir ()) "audio" in
  if Sys.file_exists dir && Sys.is_directory dir
  then (
    let now = Time_compat.now () in
    let cutoff = now -. 3600.0 in
    let entries = Sys.readdir dir in
    let removed = ref 0 in
    Array.iter
      (fun entry ->
         let path = Filename.concat dir entry in
         try
           let stat = Unix.stat path in
           if stat.st_mtime < cutoff
           then (
             Sys.remove path;
             incr removed)
         with
         | Unix.Unix_error _ | Sys_error _ -> ())
      entries;
    if !removed > 0
    then log_info (Printf.sprintf "Cleaned up %d old audio files" !removed))
;;

(** ============================================
    Types
    ============================================ *)

(** Voice session status *)
type voice_session_status =
  { session_id : string
  ; agent_id : string
  ; voice : string
  ; is_active : bool
  ; turn_count : int
  ; duration_seconds : float option
  }

(** Conference status *)
type conference_status =
  { conference_id : string
  ; state : string (* idle, active, paused, ended *)
  ; participants : string list
  ; current_speaker : string option
  ; queue_size : int
  ; turn_count : int
  }

(** Turn request result *)
type turn_request_result =
  { status : string
  ; agent_id : string
  ; message_preview : string
  ; voice : string
  ; queue_position : int
  }

(** ============================================
    HTTP Client with Timeout and Retry (Eio-native)
    ============================================ *)

(** Timeout exception for Eio.Fiber.first pattern *)
exception Timeout of string

(** Safe string prefix check *)
let starts_with ~prefix s = String.starts_with ~prefix s

(** Check if an error is retryable (transient)
    Retryable errors: connection failures, timeouts, HTTP 5xx *)
let is_retryable_error error =
  if String.length error = 0
  then false
  else (
    let s = String.lowercase_ascii error in
    starts_with ~prefix:"connection" s
    || starts_with ~prefix:"timeout" s
    ||
    try Scanf.sscanf s "http %d" (fun code -> code >= 500 && code < 600) with
    | Scanf.Scan_failure _ | Failure _ | End_of_file -> false)
;;

(** Timeout helper using Eio.Fiber.first - returns Error after specified seconds *)
let with_timeout ~clock ?timeout operation =
  let timeout_sec =
    match timeout with
    | Some t -> t
    | None -> request_timeout_seconds ()
  in
  Eio.Fiber.first
    (fun () -> operation ())
    (fun () ->
       Eio.Time.sleep clock timeout_sec;
       Error (Printf.sprintf "Request timeout after %.1fs" timeout_sec))
;;

(** Retry with exponential backoff - Eio version *)
let rec retry_with_backoff ~clock ~attempt ~max_attempts ~backoff_sec operation =
  let result = operation () in
  match result with
  | Ok _ as success -> success
  | Error e when attempt < max_attempts && is_retryable_error e ->
    log_info
      (Printf.sprintf
         "Retry %d/%d after %.1fs (error: %s)"
         attempt
         max_attempts
         backoff_sec
         e);
    Eio.Time.sleep clock backoff_sec;
    retry_with_backoff
      ~clock
      ~attempt:(attempt + 1)
      ~max_attempts
      ~backoff_sec:(backoff_sec *. backoff_multiplier ())
      operation
  | Error _ as failure ->
    log_error (Printf.sprintf "All %d retries exhausted" max_attempts);
    failure
;;

(** Make single HTTP POST request to Voice MCP server - Eio version *)
let single_voice_mcp_call ~sw ~client ~uri ~headers ~body_str =
  try
    let body = Cohttp_eio.Body.of_string body_str in
    let resp, resp_body = Cohttp_eio.Client.post ~sw ~body ~headers client uri in
    let status = Cohttp.Response.status resp in
    (* Read body using Eio.Buf_read *)
    let body_str = Eio.Buf_read.(parse_exn take_all) resp_body ~max_size:max_int in
    if Cohttp.Code.is_success (Cohttp.Code.code_of_status status)
    then Ok (Yojson.Safe.from_string body_str)
    else Error (Printf.sprintf "HTTP %d: %s" (Cohttp.Code.code_of_status status) body_str)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Error (Printf.sprintf "Connection error: %s" (Printexc.to_string exn))
;;

(** Extract result from MCP response *)
let extract_mcp_result json =
  let open Yojson.Safe.Util in
  try
    let result = json |> member "result" in
    if result = `Null
    then (
      let error = json |> member "error" |> member "message" |> to_string_option in
      Error (Option.value error ~default:"Unknown error"))
    else (
      (* Get content from result *)
      let content = result |> member "content" |> to_list in
      match content with
      | [] -> Ok (`Assoc [])
      | first :: _ ->
        let text = first |> member "text" |> to_string_option in
        (match text with
         | Some t ->
           (try Ok (Yojson.Safe.from_string t) with
            | Yojson.Json_error _ -> Ok (`String t))
         | None -> Ok result))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printf.sprintf "Parse error: %s" (Printexc.to_string e))
;;

let call_voice_mcp_endpoint ~sw ~clock ~net ~endpoint ~tool_name ~arguments =
  let uri =
    match Provider_adapter.voice_session_mcp_url_of_endpoint endpoint with
    | Ok url -> Uri.of_string url
    | Error _ -> voice_mcp_uri ()
  in
  let request_body =
    `Assoc
      [ "jsonrpc", `String "2.0"
      ; "method", `String "tools/call"
      ; "id", `Int 1
      ; "params", `Assoc [ "name", `String tool_name; "arguments", arguments ]
      ]
  in
  let body_str = Yojson.Safe.to_string request_body in
  let headers =
    Cohttp.Header.of_list
      [ "Content-Type", "application/json"; "Accept", "application/json" ]
  in
  match client_for_uri_result ~sw ~net uri with
  | Error error -> Error error
  | Ok client ->
    let operation () =
      let timeout =
        Option.value endpoint.timeout_seconds ~default:(request_timeout_seconds ())
      in
      with_timeout ~clock ~timeout (fun () ->
        single_voice_mcp_call ~sw ~client ~uri ~headers ~body_str)
    in
    retry_with_backoff
      ~clock
      ~attempt:1
      ~max_attempts:(Option.value endpoint.max_retries ~default:(max_retries ()))
      ~backoff_sec:(initial_backoff_seconds ())
      operation
;;

let attempt_tts_endpoint
      ~sw
      ~clock
      ~net
      ~agent_id
      ~message
      ~voice
      ~model
      ~priority
      endpoint
  =
  let adapter = Provider_adapter.voice_adapter_for_endpoint endpoint in
  match adapter.transport with
  | Provider_adapter.Voice_openai_compat | Provider_adapter.Voice_elevenlabs_direct ->
    let audio_file = make_audio_file ~agent_id in
    (match
       speak_via_http_tts_to_file
         endpoint
         ~message
         ~voice
         ~model
         ~agent_id
         ~output_file:audio_file
     with
     | Ok file_size ->
       (* run_local_playback now owns the dedup record inside its mutex to
             close the check-then-act race with [is_dedup_hit]. *)
       let playback_result = run_local_playback ~sw ~agent_id ~message ~audio_file () in
       (match playback_result with
        | `Dedup_hit ->
          (try Sys.remove audio_file with
           | Sys_error _ -> ());
          Ok
            (`Assoc
                [ "status", `String "dedup_skipped"
                ; "agent_id", `String agent_id
                ; "reason", `String "identical message was played recently (mutex)"
                ])
        | `Played played_seconds ->
          Ok
            (append_provider_metadata
               (`Assoc
                   (List.concat
                      [ [ "status", `String "spoken"
                        ; "agent_id", `String agent_id
                        ; "voice", `String voice
                        ; "audio_file", `String audio_file
                        ; "audio_size", `Int file_size
                        ; ( "message_preview"
                          , `String
                              (String.sub message 0 (min 50 (String.length message))) )
                        ]
                      ; (match played_seconds with
                         | Some s -> [ "played_seconds", `Float s ]
                         | None -> [])
                      ]))
               endpoint))
     | Error error ->
       (try Sys.remove audio_file with
        | Sys_error _ -> ());
       Error error)
  | Provider_adapter.Voice_mcp ->
    let args =
      `Assoc
        [ "agent_id", `String agent_id
        ; "message", `String message
        ; "voice", `String voice
        ; "priority", `Int priority
        ]
    in
    (match
       call_voice_mcp_endpoint
         ~sw
         ~clock
         ~net
         ~endpoint
         ~tool_name:"agent_speak"
         ~arguments:args
     with
     | Ok json ->
       (match extract_mcp_result json with
        | Ok data -> Ok (append_provider_metadata data endpoint)
        | Error error -> Error error)
     | Error error -> Error error)
;;

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
  | Some true -> 30.0 (* Success: cache longer *)
  | Some false -> 5.0 (* Failure: retry sooner *)
  | None -> 0.0 (* No cache: check immediately *)
;;

let session_endpoint_result () =
  match load_voice_config () with
  | Error message -> Error message
  | Ok config -> Provider_adapter.voice_session_endpoint_result config
;;

let is_voice_server_available ~sw:_ ~clock ~net =
  match session_endpoint_result () with
  | Error _ ->
    voice_server_available := Some false;
    false
  | Ok endpoint ->
    let health_target =
      match Provider_adapter.voice_session_health_url_of_endpoint endpoint with
      | Ok url -> url
      | Error _ -> Uri.to_string (voice_health_uri ())
    in
    if !voice_server_health_target <> Some health_target
    then (
      voice_server_health_target := Some health_target;
      voice_server_available := None;
      voice_server_check_time := 0.0);
    let now = Time_compat.now () in
    if now -. !voice_server_check_time < cache_duration ()
    then Option.value !voice_server_available ~default:false
    else (
      voice_server_check_time := now;
      let check () =
        try
          Eio.Switch.run
          @@ fun inner_sw ->
          let uri =
            match Provider_adapter.voice_session_health_url_of_endpoint endpoint with
            | Ok url -> Uri.of_string url
            | Error _ -> voice_health_uri ()
          in
          match client_for_uri_result ~sw:inner_sw ~net uri with
          | Error error -> Error error
          | Ok client ->
            let resp, _ = Cohttp_eio.Client.get ~sw:inner_sw client uri in
            let status = Cohttp.Response.status resp in
            let available = Cohttp.Code.is_success (Cohttp.Code.code_of_status status) in
            voice_server_available := Some available;
            Ok available
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Transport.warn "voice server check failed: %s" (Printexc.to_string exn);
          voice_server_available := Some false;
          Ok false
      in
      with_timeout ~clock ~timeout:2.0 check
      |> function
      | Ok available -> available
      | Error _ ->
        voice_server_available := Some false;
        false)
;;

let call_session_tool ~sw ~clock ~net ~tool_name ~arguments =
  match session_endpoint_result () with
  | Error message -> Error message
  | Ok endpoint ->
    (match call_voice_mcp_endpoint ~sw ~clock ~net ~endpoint ~tool_name ~arguments with
     | Ok json ->
       (match extract_mcp_result json with
        | Ok data -> Ok (append_provider_metadata data endpoint)
        | Error error -> Error error)
     | Error error -> Error error)
;;

(** ============================================
    Voice Session Management (Eio-native)
    ============================================ *)

(** Start a voice session for an agent *)
let start_voice_session ~sw ~clock ~net ~agent_id ?session_name () =
  let voice = get_voice_for_agent agent_id in
  let args =
    `Assoc
      [ "agent_id", `String agent_id
      ; "voice", `String voice
      ; "session_name", Json_util.string_opt_to_json session_name
      ]
  in
  match
    call_session_tool ~sw ~clock ~net ~tool_name:"voice_session_start" ~arguments:args
  with
  | Ok (`Assoc fields as data) ->
    let open Yojson.Safe.Util in
    let session_id =
      data |> member "session_id" |> to_string_option |> Option.value ~default:"unknown"
    in
    Ok
      (`Assoc
          ([ "session_id", `String session_id
           ; "agent_id", `String agent_id
           ; "voice", `String voice
           ; "is_active", `Bool true
           ; "turn_count", `Int 0
           ; "duration_seconds", `Null
           ]
           @ List.filter
               (fun (key, _) ->
                  key = "provider_kind" || key = "endpoint_id" || key = "endpoint_url")
               fields))
  | Ok data -> Ok data
  | Error error -> Error error
;;

(** End a voice session *)
let end_voice_session ~sw ~clock ~net ~agent_id =
  if not (is_voice_server_available ~sw ~clock ~net)
  then Error "Voice server unavailable"
  else (
    let args = `Assoc [ "agent_id", `String agent_id ] in
    call_session_tool ~sw ~clock ~net ~tool_name:"voice_session_end" ~arguments:args)
;;

(** Request speaking turn.
    Ordered endpoint chain from voice_config.json. Fails explicitly when no
    real backend accepts the request. *)
let agent_speak ~sw ~clock ~net ~agent_id ~message ?provider ?(priority = 1) () =
  if is_dedup_hit ~agent_id ~message
  then (
    log_info
      (Printf.sprintf
         "voice dedup skip: agent=%s (same message within %.0fs window)"
         agent_id
         playback_dedup_window_sec);
    Ok
      (`Assoc
          [ "status", `String "dedup_skipped"
          ; "agent_id", `String agent_id
          ; "reason", `String "identical message was played recently"
          ]))
  else (
    let voice = get_voice_for_agent agent_id in
    let provider =
      provider
      |> Option.map String.trim
      |> function
      | Some value when value <> "" -> Some value
      | _ -> None
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
          (Printf.sprintf
             "all configured TTS endpoints failed: %s"
             (String.concat " | " (List.rev attempted)))
      | endpoint :: rest ->
        (match
           attempt_tts_endpoint
             ~sw
             ~clock
             ~net
             ~agent_id
             ~message
             ~voice
             ~model
             ~priority
             endpoint
         with
         | Ok result -> Ok result
         | Error error ->
           let attempt = Printf.sprintf "%s: %s" endpoint.id error in
           try_endpoints (attempt :: attempted) rest)
    in
    if endpoints = []
    then Error "no configured TTS endpoint"
    else try_endpoints [] endpoints)
;;

(** List active voice sessions *)
let list_voice_sessions ~sw ~clock ~net =
  if not (is_voice_server_available ~sw ~clock ~net)
  then Error "Voice server unavailable"
  else (
    let args = `Assoc [] in
    call_session_tool ~sw ~clock ~net ~tool_name:"voice_session_list" ~arguments:args)
;;

(** Get voice configuration for an agent *)
let get_agent_voice ~agent_id =
  match load_voice_config () with
  | Ok config ->
    let voice = Voice_config.voice_for_agent config agent_id in
    Ok
      (`Assoc
          [ "agent_id", `String agent_id
          ; "voice", `String voice
          ; ( "available_voices"
            , `List
                (List.map
                   (fun value -> `String value)
                   (Voice_config.available_voices config)) )
          ])
  | Error _ ->
    let voice = get_voice_for_agent agent_id in
    Ok
      (`Assoc
          [ "agent_id", `String agent_id
          ; "voice", `String voice
          ; ( "available_voices"
            , `List (List.map (fun (_, v) -> `String v) (agent_voices ())) )
          ])
;;

(** ============================================
    Conference Management (Eio-native)
    ============================================ *)

(** Start a multi-agent voice conference *)
let start_conference ~sw ~clock ~net ~agent_ids ?conference_name () =
  let agent_voices_list =
    List.map
      (fun id ->
         `Assoc [ "agent_id", `String id; "voice", `String (get_voice_for_agent id) ])
      agent_ids
  in
  let args =
    `Assoc
      [ "agent_ids", `List (List.map (fun id -> `String id) agent_ids)
      ; "agent_voices", `List agent_voices_list
      ; "conference_name", Json_util.string_opt_to_json conference_name
      ]
  in
  match
    call_session_tool ~sw ~clock ~net ~tool_name:"conference_start" ~arguments:args
  with
  | Ok (`Assoc fields as data) ->
    let open Yojson.Safe.Util in
    let conference_id =
      data
      |> member "conference_id"
      |> to_string_option
      |> Option.value ~default:"unknown"
    in
    Ok
      (`Assoc
          ([ "conference_id", `String conference_id
           ; "state", `String "active"
           ; "participants", `List (List.map (fun id -> `String id) agent_ids)
           ; "current_speaker", `Null
           ; "queue_size", `Int 0
           ; "turn_count", `Int 0
           ]
           @ List.filter
               (fun (key, _) ->
                  key = "provider_kind" || key = "endpoint_id" || key = "endpoint_url")
               fields))
  | Ok data -> Ok data
  | Error error -> Error error
;;

(** End a multi-agent voice conference *)
let end_conference ~sw ~clock ~net ~agent_ids () =
  if not (is_voice_server_available ~sw ~clock ~net)
  then Error "Voice server unavailable - cannot end conference"
  else (
    let classify_result = function
      | Ok (`Assoc fields) ->
        (match List.assoc_opt "status" fields with
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
           | `Ended -> ended + 1, skipped, failed
           | `Failed -> ended, skipped, failed + 1)
        (0, 0, 0)
        agent_ids
    in
    Ok
      (`Assoc
          [ "ended", `Int ended
          ; "skipped", `Int skipped
          ; "failed", `Int failed
          ; "total", `Int (List.length agent_ids)
          ]))
;;

(** Get transcript of voice conversation *)
let get_transcript ~sw ~clock ~net () =
  if not (is_voice_server_available ~sw ~clock ~net)
  then Error "Voice server unavailable"
  else (
    let args = `Assoc [] in
    match
      call_session_tool ~sw ~clock ~net ~tool_name:"get_transcript" ~arguments:args
    with
    | Ok data -> Ok data
    | Error error -> Error error)
;;

(** ============================================
    Health Check (Eio-native)
    ============================================ *)

(** Health check for Voice MCP server *)
let health_check ~sw:_ ~clock:_ ~net () =
  match session_endpoint_result () with
  | Error error -> Error error
  | Ok endpoint ->
    let uri =
      match Provider_adapter.voice_session_health_url_of_endpoint endpoint with
      | Ok url -> Uri.of_string url
      | Error _ -> voice_health_uri ()
    in
    (try
       Eio.Switch.run
       @@ fun inner_sw ->
       match client_for_uri_result ~sw:inner_sw ~net uri with
       | Error error -> Error error
       | Ok client ->
         let resp, body = Cohttp_eio.Client.get ~sw:inner_sw client uri in
         let status = Cohttp.Response.status resp in
         let body_str = Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int in
         if Cohttp.Code.is_success (Cohttp.Code.code_of_status status)
         then
           Ok
             (append_provider_metadata
                (`Assoc
                    [ "status", `String "healthy"
                    ; "server", `String (Uri.to_string uri)
                    ; ( "response"
                      , try Yojson.Safe.from_string body_str with
                        | Yojson.Json_error _ -> `String body_str )
                    ])
                endpoint)
         else
           Error (Printf.sprintf "Unhealthy: HTTP %d" (Cohttp.Code.code_of_status status))
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn -> Error (Printf.sprintf "Not reachable: %s" (Printexc.to_string exn)))
;;

(** {1 Microphone record + transcribe} *)

let play_tone freq =
  try
    ignore
      (run_voice_status
         ~timeout_sec:2.0
         [ "play"; "-qn"; "synth"; "0.15"; "sine"; Printf.sprintf "%.0f" freq ])
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> Log.Transport.debug "play_tone failed: %s" (Printexc.to_string exn)
;;

let record_and_transcribe ~agent_id ?(timeout_sec = 15.0) ?language_code () =
  let audio_file =
    Filename.temp_file (Printf.sprintf "masc_stt_%s_" (safe_agent_id agent_id)) ".wav"
  in
  let rec_argv =
    [ "rec"
    ; "-q"
    ; "-t"
    ; "wav"
    ; audio_file
    ; "rate"
    ; "16k"
    ; "channels"
    ; "1"
    ; "silence"
    ; "1"
    ; "0.5"
    ; "1%"
    ; "1"
    ; "2.0"
    ; "1%"
    ]
  in
  let cleanup () =
    try Sys.remove audio_file with
    | Sys_error _ -> ()
  in
  Fun.protect ~finally:cleanup (fun () ->
    play_tone 880.0;
    let record_result =
      try
        let status, _output =
          run_voice_status ~timeout_sec:(timeout_sec +. 5.0) rec_argv
        in
        match status with
        | Unix.WEXITED 0 -> Ok ()
        | Unix.WEXITED code -> Error (Printf.sprintf "rec exit %d" code)
        | _ -> Error "rec process failed"
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printf.sprintf "rec exception: %s" (Printexc.to_string exn))
    in
    play_tone 440.0;
    match record_result with
    | Error err -> Error err
    | Ok () ->
      let file_exists =
        try (Unix.stat audio_file).st_size > 100 with
        | Unix.Unix_error _ -> false
      in
      if not file_exists
      then
        Ok
          (`Assoc
              [ "status", `String "no_audio"
              ; "text", `String ""
              ; "message", `String "no speech detected or recording too short"
              ])
      else transcribe_audio ~audio_file ?language_code ())
;;
