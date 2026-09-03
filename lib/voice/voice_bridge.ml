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
    Some (Masc_network_defaults.voice_audio_path token)
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

(* Issue #7690 replaced the byte-based [String.sub] in [Audit_log.preview] with
   a character-boundary cut but left this shape here. A 50-byte cut lands
   mid-character on Korean (3 bytes per syllable); the trailing partial byte
   rides the tool result into the codex app-server stdin, which decodes UTF-8
   and exits on the invalid sequence. *)
let message_preview_max_bytes = 50

let message_preview message =
  String_util.utf8_prefix ~max_bytes:message_preview_max_bytes message
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
            (* Resolved per endpoint, not once for the chain: a voice id is
               provider vocabulary, so carrying the first endpoint's id to the
               next asks for a voice that does not exist there (#24068). *)
            ~voice:(Voice_config.voice_for_agent_at_endpoint config endpoint agent_id)
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
  match Voice_config.load_detailed () with
  | Ok config -> Ok (Voice_config.public_json config)
  | Error error ->
    Error
      (Tool_args.error_assoc
         [ "message", `String (Voice_config.load_error_to_string error)
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
    HTTP Client with Timeout (Eio-native)
    ============================================ *)

(** The four ways a Voice MCP call can fail. The caller receives the exact
    typed observation from one endpoint attempt; this module does not infer a
    replay policy from the constructor or rendered message. *)
type mcp_call_error =
  | Timed_out of float
  | Connection_failed of string
  | Http_status of
      { code : int
      ; body : string
      }
  | Malformed_body of string

type effect_disposition =
  | Proven_pre_effect
  | Remote_effect_unresolved

let mcp_call_effect_disposition = function
  | Timed_out _ | Connection_failed _ | Http_status _ | Malformed_body _ ->
    Remote_effect_unresolved
;;

let mcp_call_error_to_string = function
  | Timed_out seconds -> Printf.sprintf "Request timeout after %.1fs" seconds
  | Connection_failed detail -> Printf.sprintf "Connection error: %s" detail
  | Http_status { code; body } -> Printf.sprintf "HTTP %d: %s" code body
  | Malformed_body detail ->
    Printf.sprintf "Voice MCP: invalid JSON body: %s" detail
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
       Error (Timed_out timeout_sec))
;;

let parse_json_response body =
  try Ok (Yojson.Safe.from_string body) with
  | Yojson.Json_error msg ->
    Error (Malformed_body msg)
;;

(** Make a single HTTP POST request to the Voice MCP server. *)
let single_voice_mcp_call ~net:_ ~uri ~headers_list ~body_str =
  match
    Masc_http_client.post_sync ~url:(Uri.to_string uri)
      ~headers:headers_list ~body:body_str ()
  with
  | Ok (code, body) when code >= 200 && code < 300 -> parse_json_response body
  | Ok (code, body) -> Error (Http_status { code; body })
  | Error e ->
    (* RFC-0106: re-raise Eio.Cancel.Cancelled when the surrounding fiber
       was cancelled. Masc_http_client.post_sync delegates to a piaf pool
       whose [Pool.do_request] catches all exceptions including Cancelled
       and reports them as an Error string. [call_voice_mcp_endpoint] runs a
       single attempt -- the retry loop this once named is gone -- so what a
       swallowed Cancelled now reaches is the caller's endpoint failover:
       [try_endpoints] would read it as this endpoint failing and speak
       through the next one instead of unwinding. *)
    Eio.Fiber.check ();
    Error (Connection_failed e)
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
  operation ()
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
                    ; "message_preview", `String (message_preview message)
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
                    ; "message_preview", `String (message_preview message)
                    ; "local_playback_status", `String "opened"
                    ; "local_playback_reason"
                      , `String
                          "blocking local players failed; handed audio file to macOS open"
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
                    ; "message_preview", `String (message_preview message)
                    ; "local_playback_status", `String "played"
                    ; "played_seconds", `Float played_seconds
                    ]
                    @ audio_payload_fields ~audio_file ~audio_device))
               endpoint))
     | Error error ->
       (try Sys.remove audio_file with
        | Sys_error _ -> ());
       Error (`Proven_pre_effect error))
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
      match
        call_voice_mcp_endpoint
          ~clock
          ~net
          ~endpoint
          ~tool_name:"agent_speak"
          ~arguments:args
      with
      | Error error ->
        (match mcp_call_effect_disposition error with
         | Proven_pre_effect ->
           Error (`Proven_pre_effect (mcp_call_error_to_string error))
         | Remote_effect_unresolved ->
           Error (`Outcome_unknown (mcp_call_error_to_string error)))
      | Ok json ->
        (match extract_mcp_result json with
         | Error error -> Error (`Outcome_unknown error)
         | Ok data ->
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
                 ]
                 @ audio_payload_fields ~audio_file ~audio_device
               in
               (match data with
                | `Assoc fields -> `Assoc (fields @ audio_fields)
                | other -> other)
             | None -> data
           in
           Ok (append_provider_metadata data endpoint)))
;;

(** Try HTTP TTS endpoints to synthesize a browser-playable MP3 clip.
    Used when the winning endpoint is [Voice_mcp] so the dashboard still
    has an audio clip even though the MCP server owns local playback.
    Returns [None] when no HTTP endpoint is configured or all fail. *)
let try_http_tts_for_browser_audio
      ~sw
      ~clock
      ~net
      ~config
      ~agent_id
      ~message
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
             (* Resolved per endpoint (#24068): see the dashboard chain. *)
           ~voice:(Voice_config.voice_for_agent_at_endpoint config endpoint agent_id)
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
           | Error (`Proven_pre_effect error) ->
             let attempt = Printf.sprintf "%s: %s" endpoint.id error in
             (if rest <> []
              then
                log_error
                  (Printf.sprintf
                     "TTS endpoint %s failed; trying next endpoint: %s"
                     endpoint.id
                     error));
             try_endpoints (attempt :: attempted) rest
           | Error (`Outcome_unknown error) ->
             Error
               (Printf.sprintf
                  "TTS endpoint %s outcome is unknown; failover stopped: %s"
                  endpoint.id
                  error))
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
               ~config
               ~agent_id
               ~message
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
  match Voice_config.load_detailed () with
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

(* Room level, measured rather than assumed.

   The recording threshold used to be the literal 1% that sox's silence filter
   takes as a fraction of full scale (about -40 dBFS). Measured on this
   workstation 2026-09-03, the noise floor sat at -37.2 dB on one pass and
   -26.3 dB on another minutes later, both above that constant: the filter saw
   sound continuously, so recording started immediately and the trailing-silence
   condition never came true. Every capture ran to the timeout and handed
   whisper a room.

   The floor moves by more than 10 dB between passes in one room, which is why
   this is read at each capture rather than configured once. *)

let calibration_seconds = 0.5

(* Speech sat 5.0 dB and 6.1 dB above the floor on the two measured passes --
   an ordinary sentence at a laptop's built-in microphone, not a quiet one. A
   margin near that separation swallows the utterance, so the trigger is set
   just clear of the room and the gate below decides whether anything was said. *)
let trigger_margin_db = 3.0

(* What a capture must exceed, over its whole length, to be worth transcribing.
   Below the trigger margin so that a capture which did fire but carries only
   room tone is still refused. *)
let speech_margin_db = 2.0

let rms_amplitude_of_file audio_file =
  match run_voice_status ~timeout_sec:10.0 [ "sox"; audio_file; "-n"; "stat" ] with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  (* sox reports a level whatever its exit code, and a non-zero exit on a
     truncated capture still carries the line we read. The parse decides, not
     the status. *)
  | _, output ->
    (* sox writes stat to stderr, which run_voice_status folds into output. The
       line is "RMS     amplitude:    0.013946". *)
    let line =
      String.split_on_char '\n' output
      |> List.find_opt (fun l ->
        String_util.string_contains_substring ~needle:"RMS" l
        && String_util.string_contains_substring ~needle:"amplitude" l)
    in
    Option.bind line (fun l ->
      match List.filter (fun t -> t <> "") (String.split_on_char ' ' l) with
      | _ :: _ :: value :: _ -> float_of_string_opt value
      | _ -> None)
;;

let db_of_amplitude v = if v > 0.0 then 20.0 *. log10 v else neg_infinity
let amplitude_of_db d = if d = neg_infinity then 0.0 else 10.0 ** (d /. 20.0)

(* sox's silence filter takes a percentage of full scale. *)
let percent_of_amplitude v = 100.0 *. v

(* One short capture with no silence filter, so it records the room as it is. *)
let measure_noise_floor ~agent_id =
  let probe =
    Filename.temp_file (Printf.sprintf "masc_nf_%s_" (safe_agent_id agent_id)) ".wav"
  in
  let cleanup () = try Sys.remove probe with Sys_error _ -> () in
  Eio_guard.protect ~finally:cleanup (fun () ->
       match
         run_voice_status
           ~timeout_sec:(calibration_seconds +. 5.0)
           [ "rec"; "-q"; "-t"; "wav"; probe
           ; "rate"; "16k"; "channels"; "1"
           ; "trim"; "0"; Printf.sprintf "%.2f" calibration_seconds ]
       with
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | Unix.WEXITED 0, _ -> rms_amplitude_of_file probe
       | _ -> None)
;;

let record_and_transcribe ~agent_id ?(timeout_sec = 15.0) ?language_code () =
  let audio_file =
    Filename.temp_file (Printf.sprintf "masc_stt_%s_" (safe_agent_id agent_id)) ".wav"
  in
  (* [None] when the probe could not run: the capture then uses the constant
     this replaced rather than a threshold derived from nothing. *)
  let noise_floor = measure_noise_floor ~agent_id in
  let trigger_percent =
    match noise_floor with
    | Some floor when floor > 0.0 ->
      percent_of_amplitude
        (amplitude_of_db (db_of_amplitude floor +. trigger_margin_db))
    | Some _ | None -> 1.0
  in
  let threshold = Printf.sprintf "%.2f%%" trigger_percent in
  Log.Transport.debug
    "voice capture: noise floor %s, trigger %s"
    (match noise_floor with
     | Some f -> Printf.sprintf "%.1f dB" (db_of_amplitude f)
     | None -> "unmeasured")
    threshold;
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
    ; threshold
    ; "1"
    ; "2.0"
    ; threshold
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
    (* Whisper answers silence with a sentence. Measured 2026-09-03 against the
       local whisper.cpp endpoint, three captures of an empty room returned
       "감사합니다.", "감사합니다." and "네" -- fluent text for an operator who
       said nothing. Byte size cannot tell those apart from speech: a capture
       that ran to its timeout on room tone is large.

       So the level decides, and a capture that never rose above the room is
       not sent. This is the only place that refusal can happen; once the audio
       reaches the endpoint chain, a hallucinated transcript is indistinguishable
       from a real one. *)
    let silent =
      match noise_floor, if file_exists then rms_amplitude_of_file audio_file else None with
      | Some floor, Some captured when floor > 0.0 ->
        db_of_amplitude captured < db_of_amplitude floor +. speech_margin_db
      | _ -> false
    in
    if (not file_exists) || silent
    then
      Ok
        (`Assoc
            [ "status", `String "no_audio"
            ; "text", `String ""
            ; ( "message"
              , `String
                  (if file_exists
                   then "nothing was said above the room level"
                   else "no speech detected or recording too short") )
            ])
    else transcribe_audio ~audio_file ?language_code ())
;;
