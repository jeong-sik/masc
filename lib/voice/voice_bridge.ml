(** Voice_bridge — TTS synthesis, speech-to-text, local playback. *)

include Voice_bridge_core

open Result.Syntax

let safe_agent_id = Voice_bridge_transport.safe_agent_id
let make_audio_file = Voice_bridge_transport.make_audio_file
let run_voice_status = Voice_bridge_transport.run_voice_status
let speak_via_http_tts_to_file = Voice_bridge_transport.speak_via_http_tts_to_file
let transcribe_via_http_stt = Voice_bridge_transport.transcribe_via_http_stt

let audio_url_of_file audio_file =
  match Filename.chop_suffix_opt ~suffix:".mp3" (Filename.basename audio_file) with
  | Some token when token <> "" ->
    Some (Printf.sprintf "/api/v1/voice/audio/%s" token)
  | _ -> None
;;

let audio_payload_fields ~audio_file ~audio_device =
  (match audio_url_of_file audio_file with
   | Some url -> [ "audio_url", `String url ]
   | None -> [])
  @
  match audio_device with
  | Some id when id <> "" -> [ "audio_device", `String id ]
  | _ -> []
;;

let available_stt_endpoints (config : Voice_config.t) =
  config.stt.endpoints |> List.filter (fun (ep : Voice_config.endpoint) -> ep.enabled)
;;

let transcribe_audio ~audio_file ?language_code () =
  match Voice_config.load_detailed () with
  | Error (Voice_config.Invalid msg) ->
    (* An explicit voice config exists but is broken: surface the
       load failure instead of substituting a hardcoded model. *)
    Error (Printf.sprintf "voice config load failed: %s" msg)
  | Error Voice_config.Not_configured ->
    (* Voice is not set up in this environment: STT is explicitly
       disabled, which is not an error of the config itself. *)
    Error "no enabled STT endpoints configured"
  | Ok config ->
    let model = config.stt.default_model in
    let endpoints = available_stt_endpoints config in
    let rec try_endpoints attempted = function
      | [] ->
        Error
          (Printf.sprintf
             "all enabled STT endpoints failed: %s"
             (String.concat " | " (List.rev attempted)))
      | endpoint :: rest ->
        (match transcribe_via_http_stt endpoint ~audio_file ~model with
         | Ok json ->
           let text =
             Option.value
               (Json_util.get_string json "text")
               ~default:(Yojson.Safe.to_string json)
           in
           let lang =
             match language_code with
             | Some lc -> lc
             | None ->
               (match Json_util.get_string json "language_code" with
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
         | Error error ->
           let attempt = Printf.sprintf "%s: %s" endpoint.id error in
           (if rest <> []
            then
              log_error
                (Printf.sprintf
                   "STT endpoint %s failed; trying next endpoint: %s"
                   endpoint.id
                   error));
           try_endpoints (attempt :: attempted) rest)
    in
    if endpoints = []
    then Error "no enabled STT endpoints configured"
    else try_endpoints [] endpoints
;;

let available_tts_endpoints ?provider (config : Voice_config.t) =
  Voice_runtime_overlay.select_endpoints ?provider config.tts.endpoints
;;

(** Synthesize a dashboard-playable MP3 via any HTTP TTS endpoint.
    This is used as a parallel fallback when the active transport is
    [Voice_mcp], which produces audio through a local/MCP path but does not
    write a browser-fetchable file. *)
let try_http_tts_for_dashboard ~config ~agent_id ~message ~voice ~model ~audio_device () =
  let endpoints = available_tts_endpoints config in
  let rec try_endpoint = function
    | [] -> None
    | endpoint :: rest ->
      let adapter = Voice_runtime_overlay.adapter_for_endpoint endpoint in
      if Voice_runtime_overlay.transport_supports_http_tts adapter
      then (
        let audio_file = make_audio_file () in
        match
          speak_via_http_tts_to_file
            endpoint
            ~agent_id
            ~message
            ~voice
            ~model
            ~output_file:audio_file
        with
        | Ok file_size -> Some (audio_file, file_size)
        | Error _ ->
          (try Sys.remove audio_file with
           | Sys_error _ -> ());
          try_endpoint rest)
      else try_endpoint rest
  in
  try_endpoint endpoints
;;

let public_config_json () =
  match load_voice_config () with
  | Ok config -> Ok (Voice_config.public_json config)
  | Error message ->
    Error
      (Tool_args.error_assoc
         [ "message", `String message
         ; "config_path", `String (Voice_config.config_path ())
         ])
;;

(** Clean up old audio files (>24 hours) and enforce a size cap.
    Call from heartbeat. Older files are removed first; if the total
    size still exceeds the cap, the oldest files are removed until the
    cap is satisfied. *)
let cleanup_old_audio_files () =
  let dir = Filename.concat (masc_base_dir ()) "audio" in
  if Sys.file_exists dir && Sys.is_directory dir
  then (
    let now = Time_compat.now () in
    let cutoff = now -. Masc_time_constants.day in
    let entries = Sys.readdir dir in
    let with_stats =
      Array.to_list entries
      |> List.filter_map (fun entry ->
           let path = Filename.concat dir entry in
           try
             let stat = Unix.stat path in
             Some (path, stat.st_mtime, stat.st_size)
           with
           | Unix.Unix_error _ | Sys_error _ -> None)
    in
    let by_age = List.sort (fun (_, m1, _) (_, m2, _) -> Float.compare m1 m2) with_stats in
    let removed = ref 0 in
    let remove path =
      try
        Sys.remove path;
        incr removed
      with
      | Unix.Unix_error _ | Sys_error _ -> ()
    in
    (* First pass: remove files older than 24h. *)
    let remaining =
      List.filter
        (fun (path, mtime, _size) ->
           if mtime < cutoff
           then (
             remove path;
             false)
           else true)
        by_age
    in
    (* Second pass: enforce size cap by removing oldest files first. *)
    let max_size_bytes = 500 * 1024 * 1024 in
    let total_size = List.fold_left (fun acc (_, _, size) -> acc + size) 0 remaining in
    if total_size > max_size_bytes
    then
      ignore
        (List.fold_left
           (fun acc (path, _mtime, size) ->
              if acc <= max_size_bytes
              then acc
              else (
                remove path;
                acc - size))
           total_size
           remaining);
    if !removed > 0
    then log_info (Printf.sprintf "Cleaned up %d old audio files" !removed))
;;

(** ============================================
    Types
    ============================================ *)

type agent_speak_completion =
  | Spoken
  | Dedup_skipped

type agent_speak_result =
  { completion : agent_speak_completion
  ; payload : Yojson.Safe.t
  }

(** ============================================
    HTTP Client with Timeout and Retry (Eio-native)
    ============================================ *)

(** Check if an error is retryable (transient)
    Retryable errors: connection failures, timeouts, HTTP 5xx *)
let is_retryable_error error =
  if String.length error = 0
  then false
  else (
    let s = String.lowercase_ascii error in
    String.starts_with ~prefix:"connection" s
    || String.starts_with ~prefix:"timeout" s
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

let parse_json_response body =
  try Ok (Yojson.Safe.from_string body) with
  | Yojson.Json_error msg ->
    Error (Printf.sprintf "Voice MCP: invalid JSON body: %s" msg)
;;

(** Make a single HTTP POST request to the Voice MCP server. *)
let single_voice_mcp_call ~net:_ ~uri ~headers_list ~body_str =
  match
    Masc_http_client.post_sync ~url:(Uri.to_string uri)
      ~headers:headers_list ~body:body_str ()
  with
  | Ok (code, body) when code >= 200 && code < 300 -> parse_json_response body
  | Ok (code, body) -> Error (Printf.sprintf "HTTP %d: %s" code body)
  | Error e ->
    (* RFC-0106: re-raise Eio.Cancel.Cancelled when the surrounding fiber
       was cancelled. Masc_http_client.post_sync delegates to a piaf pool
       whose [Pool.do_request] catches all exceptions including Cancelled
       and reports them as an Error string; without this check the retry
       loop in [call_voice_mcp_endpoint] would sleep and re-attempt
       instead of unwinding cancellation immediately. *)
    Eio.Fiber.check ();
    Error (Printf.sprintf "Connection error: %s" e)
;;

(** Extract result from MCP response *)
let extract_mcp_result json =
  try
    let result = json |> Json_util.assoc_member_opt "result" in
    if result = None
    then (
      let error =
        match Json_util.assoc_member_opt "error" json with
        | Some err ->
          (match Json_util.assoc_member_opt "message" err with
           | Some (`String s) -> Some s
           | _ -> None)
        | None -> None
      in
      Error (Option.value error ~default:"Unknown error"))
    else (
      (* Get content from result *)
      let content =
        match Option.bind result (fun r -> Json_util.assoc_member_opt "content" r) with
        | Some (`List l) -> l
        | _ -> []
      in
      match content with
      | [] -> Ok (`Assoc [])
      | first :: _ ->
        let text = Json_util.get_string first "text" in
        (match text with
         | Some t ->
           (try Ok (Yojson.Safe.from_string t) with
            | Yojson.Json_error _ -> Ok (`String t))
         | None -> Ok (Option.value ~default:`Null result)))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> Error (Printf.sprintf "Parse error: %s" (Printexc.to_string e))
;;

let call_voice_mcp_endpoint ~clock ~net ~endpoint ~tool_name ~arguments =
  let uri =
    match Voice_runtime_overlay.session_mcp_url_of_endpoint endpoint with
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
  let headers_list =
    [ "Content-Type", "application/json"; "Accept", "application/json" ]
  in
  let operation () =
    let timeout =
      Option.value endpoint.timeout_seconds ~default:(request_timeout_seconds ())
    in
    with_timeout ~clock ~timeout (fun () ->
      single_voice_mcp_call ~net ~uri ~headers_list ~body_str)
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
      ~config
      ?audio_device
      endpoint
  =
  let adapter = Voice_runtime_overlay.adapter_for_endpoint endpoint in
  match adapter.transport with
  | Voice_runtime_overlay.Openai_compat | Voice_runtime_overlay.Elevenlabs_direct ->
    let audio_file = make_audio_file () in
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
        | (`Failed reason | `Skipped reason) as playback_status ->
          let local_playback_status =
            match playback_status with
            | `Failed _ -> "failed"
            | `Skipped _ -> "skipped"
          in
          Ok
            (append_provider_metadata
               (`Assoc
                   ([ "status", `String "spoken"
                    ; "agent_id", `String agent_id
                    ; "voice", `String voice
                    ; "audio_file", `String audio_file
                    ; "audio_size", `Int file_size
                    ; ( "message_preview"
                      , `String
                          (String.sub message 0 (min 50 (String.length message))) )
                    ; "local_playback_status", `String local_playback_status
                    ; "local_playback_reason", `String reason
                    ]
                    @ audio_payload_fields ~audio_file ~audio_device))
               endpoint)
        | `Opened handoff_seconds ->
          Ok
            (append_provider_metadata
               (`Assoc
                   ([ "status", `String "spoken"
                    ; "agent_id", `String agent_id
                    ; "voice", `String voice
                    ; "audio_file", `String audio_file
                    ; "audio_size", `Int file_size
                    ; ( "message_preview"
                      , `String
                          (String.sub message 0 (min 50 (String.length message))) )
                    ; "local_playback_status", `String "opened"
                    ; "local_playback_reason"
                      , `String
                          "blocking local players failed; handed audio file to macOS open"
                    ; "open_handoff_seconds", `Float handoff_seconds
                    ]
                    @ audio_payload_fields ~audio_file ~audio_device))
               endpoint)
        | `Played played_seconds ->
          Ok
            (append_provider_metadata
               (`Assoc
                   ([ "status", `String "spoken"
                    ; "agent_id", `String agent_id
                    ; "voice", `String voice
                    ; "audio_file", `String audio_file
                    ; "audio_size", `Int file_size
                    ; ( "message_preview"
                      , `String
                          (String.sub message 0 (min 50 (String.length message))) )
                    ; "local_playback_status", `String "played"
                    ; "played_seconds", `Float played_seconds
                    ]
                    @ audio_payload_fields ~audio_file ~audio_device))
               endpoint))
     | Error error ->
       (try Sys.remove audio_file with
        | Sys_error _ -> ());
       Error error)
  | Voice_runtime_overlay.Voice_mcp ->
    let args =
      `Assoc
        [ "agent_id", `String agent_id
        ; "message", `String message
        ; "voice", `String voice
        ; "priority", `Int priority
        ]
    in
    with_voice_output_turn ~agent_id (fun () ->
      let* json =
        call_voice_mcp_endpoint
          ~clock
          ~net
          ~endpoint
          ~tool_name:"agent_speak"
          ~arguments:args
      in
      let* data = extract_mcp_result json in
      (* Voice_mcp plays audio locally but does not expose a file for the
         dashboard. Try to synthesize a parallel HTTP TTS clip so the
         browser can also play it. *)
      let data =
        match
          try_http_tts_for_dashboard
            ~config
            ~agent_id
            ~message
            ~voice
            ~model
            ~audio_device
            ()
        with
        | Some (audio_file, file_size) ->
          let audio_fields =
            [ "audio_file", `String audio_file
            ; "audio_size", `Int file_size
            ]
            @ audio_payload_fields ~audio_file ~audio_device
          in
          (match data with
           | `Assoc fields -> `Assoc (fields @ audio_fields)
           | other -> other)
        | None -> data
      in
      Ok (append_provider_metadata data endpoint))
;;

(** Try HTTP TTS endpoints to synthesize a browser-playable MP3 clip.
    Used when the winning endpoint is [Voice_mcp] so the dashboard still
    has an audio clip even though the MCP server owns local playback.
    Returns [None] when no HTTP endpoint is configured or all fail. *)
let try_http_tts_for_browser_audio
      ~sw
      ~clock
      ~net
      ~agent_id
      ~message
      ~voice
      ~model
      ~priority
      ?audio_device
      endpoints
  =
  let http_endpoints =
    List.filter Voice_runtime_overlay.endpoint_supports_http_tts endpoints
  in
  let rec try_endpoints = function
    | [] -> None
    | endpoint :: rest ->
      let audio_file = make_audio_file () in
      (match
         speak_via_http_tts_to_file
           endpoint
           ~message
           ~voice
           ~model
           ~agent_id
           ~output_file:audio_file
       with
       | Ok file_size -> Some (audio_file, file_size)
       | Error _ ->
         (try Sys.remove audio_file with
          | Sys_error _ -> ());
         try_endpoints rest)
  in
  try_endpoints http_endpoints
;;

let result_has_audio_file = function
  | `Assoc fields -> List.assoc_opt "audio_file" fields <> None
  | _ -> false
;;

let merge_browser_audio_fields ~audio_file ~file_size ?audio_device json =
  match json with
  | `Assoc fields ->
    `Assoc
      (fields
       @ [ ("audio_file", `String audio_file); ("audio_size", `Int file_size) ]
       @ audio_payload_fields ~audio_file ~audio_device)
  | other -> other
;;

(** Request speaking turn.
    Ordered endpoint chain from voice_config.json. Fails explicitly when no
    real backend accepts the request.

    RFC-0235 P3: when the winning endpoint is [Voice_mcp] and a separate
    HTTP TTS endpoint is also configured, synthesize a parallel browser
    clip so the dashboard can play the utterance. The MCP server still
    owns local playback; the HTTP clip is dashboard-only. *)
let agent_speak_json
      ~sw
      ~clock
      ~net
      ~agent_id
      ~message
      ?provider
      ?(priority = 1)
      ?audio_device
      ()
  =
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
    match Voice_config.load_detailed () with
    | Error (Voice_config.Invalid msg) ->
      (* An explicit voice config exists but is broken: surface the
         load failure instead of substituting a hardcoded model. *)
      Error (Printf.sprintf "voice config load failed: %s" msg)
    | Error Voice_config.Not_configured ->
      (* Voice is not set up in this environment: TTS is explicitly
         disabled, which is not an error of the config itself. *)
      Error "no configured TTS endpoint"
    | Ok config ->
      let endpoints = available_tts_endpoints ?provider config in
      let model = config.tts.default_model in
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
               ~config
               ?audio_device
               endpoint
           with
           | Ok _ as ok -> ok
           | Error error ->
             let attempt = Printf.sprintf "%s: %s" endpoint.id error in
             (if rest <> []
              then
                log_error
                  (Printf.sprintf
                     "TTS endpoint %s failed; trying next endpoint: %s"
                     endpoint.id
                     error));
             try_endpoints (attempt :: attempted) rest)
      in
      if endpoints = []
      then Error "no configured TTS endpoint"
      else
        match try_endpoints [] endpoints with
        | Ok result when not (result_has_audio_file result) ->
          (* The winning endpoint was [Voice_mcp]. Try a dashboard-playable
             HTTP TTS clip in parallel so the dashboard has audio playback.
             If no HTTP endpoint is available or all fail, the MCP result
             still stands and the dashboard simply shows no audio player. *)
          (match
             try_http_tts_for_browser_audio
               ~sw
               ~clock
               ~net
               ~agent_id
               ~message
               ~voice
               ~model
               ~priority
               ?audio_device
               endpoints
           with
           | Some (audio_file, file_size) ->
             log_info
               (Printf.sprintf
                  "Voice MCP: synthesized parallel browser audio clip for agent=%s file=%s"
                  agent_id
                  audio_file);
             Ok (merge_browser_audio_fields ~audio_file ~file_size ?audio_device result)
           | None ->
             log_info
               (Printf.sprintf
                  "Voice MCP path used for agent=%s; no browser audio clip available (no HTTP TTS endpoint)."
                  agent_id);
             Ok result)
        | other -> other)
;;

let decode_agent_speak_result payload =
  match Json_util.get_string payload "status" with
  | Some "spoken" -> Ok { completion = Spoken; payload }
  | Some "dedup_skipped" -> Ok { completion = Dedup_skipped; payload }
  | Some status ->
    Error (Printf.sprintf "voice speak returned unsupported status=%S" status)
  | None -> Error "voice speak result is missing required status"
;;

let agent_speak
      ~sw
      ~clock
      ~net
      ~agent_id
      ~message
      ?provider
      ?priority
      ?audio_device
      ()
  =
  match
    agent_speak_json
      ~sw
      ~clock
      ~net
      ~agent_id
      ~message
      ?provider
      ?priority
      ?audio_device
      ()
  with
  | Error _ as error -> error
  | Ok payload -> decode_agent_speak_result payload
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

(** {1 Microphone record + transcribe} *)

let play_tone freq =
  try
    ignore
      (run_voice_status
         ~timeout_sec:Env_config_runtime.Voice.audio_test_tone_timeout_sec
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
  Eio_guard.protect ~finally:cleanup (fun () ->
    play_tone 880.0;
    let* () =
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
