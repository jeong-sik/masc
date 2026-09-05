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

let available_stt_endpoints (stt : Voice_config.stt_config) =
  stt.Voice_config.endpoints |> List.filter (fun (ep : Voice_config.endpoint) -> ep.enabled)
;;

(* The [status] field of every capture result this module returns. One closed
   set, spelled here and read back by {!capture_outcome_of_json}, so a reader
   cannot fall through a string it does not know into "nothing was heard". *)
type capture_status =
  | Transcribed
  | No_audio
  | Discarded

let capture_status_to_string = function
  | Transcribed -> "transcribed"
  | No_audio -> "no_audio"
  | Discarded -> "discarded"
;;

let capture_status_of_string = function
  | "transcribed" -> Some Transcribed
  | "no_audio" -> Some No_audio
  | "discarded" -> Some Discarded
  | _ -> None
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
  | Ok { Voice_config.stt = None; _ } ->
    (* The config loaded and has no [stt] section. Typed absence: there is no
       model to send, so nothing is sent. *)
    Error "voice config has no [stt] section, so STT is not set up"
  | Ok { Voice_config.stt = Some stt; _ } ->
    let model = stt.Voice_config.default_model in
    let endpoints = available_stt_endpoints stt in
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
                 [ "status", `String (capture_status_to_string Transcribed)
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

let available_tts_endpoints ?provider (tts : Voice_config.tts_config) =
  Voice_runtime_overlay.select_endpoints ?provider tts.Voice_config.endpoints
;;

(** Synthesize a dashboard-playable MP3 via any HTTP TTS endpoint.
    This is used as a parallel fallback when the active transport is
    [Voice_mcp], which produces audio through a local/MCP path but does not
    write a browser-fetchable file. *)
let try_http_tts_for_dashboard ~tts ~agent_id ~message ~voice ~model ~audio_device () =
  let endpoints = available_tts_endpoints tts in
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
            ~voice:(Voice_config.voice_for_agent_at_endpoint tts endpoint agent_id)
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
      ~tts
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
                 ~tts
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
      ~tts
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
           ~voice:(Voice_config.voice_for_agent_at_endpoint tts endpoint agent_id)
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
  (* The config is read before the dedup check: a config that does not load
     refuses every message, including one that played a moment ago under a
     config that did. *)
  match Voice_config.load_detailed () with
  | Error (Voice_config.Invalid msg) ->
    (* An explicit voice config exists but is broken: surface the
       load failure instead of substituting a hardcoded model. *)
    Error (Printf.sprintf "voice config load failed: %s" msg)
  | Error Voice_config.Not_configured ->
    (* Voice is not set up in this environment: TTS is explicitly
       disabled, which is not an error of the config itself. *)
    Error "no configured TTS endpoint"
  | Ok { Voice_config.tts = None; _ } ->
    (* The config loaded and has no [tts] section. Refused here, before any
       endpoint is asked: there is no model to send, and an empty string in
       its place would reach providers as model_id "". *)
    Error "voice config has no [tts] section, so TTS is not set up"
  | Ok { Voice_config.tts = Some tts; _ } ->
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
      let endpoints = available_tts_endpoints ?provider tts in
      let model = tts.Voice_config.default_model in
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
               ~tts
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
               ~tts
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
  | Ok { Voice_config.tts = Some tts; _ } ->
    let voice = Voice_config.voice_for_agent tts agent_id in
    Ok
      (`Assoc
          [ "agent_id", `String agent_id
          ; "voice", `String voice
          ; ( "available_voices"
            , `List
                (List.map
                   (fun value -> `String value)
                   (Voice_config.available_voices tts)) )
          ])
  | Ok { Voice_config.tts = None; _ } | Error _ ->
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

   The recording threshold used to be a fixed 1% of full scale, about -40
   dBFS. Measured on this workstation 2026-09-03, the noise floor sat at -37.2
   dB on one pass and -26.3 dB on another minutes later, both above that
   constant: every capture began at once, never fell quiet again, ran to its
   timeout and handed whisper a room.

   The floor moves by more than 10 dB between passes in one room, which is why
   this is read at each capture rather than configured once. *)

(* Read per capture rather than cached: runtime.toml is hot-reloaded, and an
   operator turning a knob because captures are not starting wants the next
   press to use it, not the next restart.

   No config at all is the measured defaults: that is not an error of the
   config. A config that exists and does not parse is refused with its
   reason, before a microphone is opened. Running it on the defaults instead
   would put the capture under a knob the operator set and mistyped, with
   the dial connected to nothing. *)
let capture_config () =
  match Voice_config.load_detailed () with
  | Ok config -> Ok config.Voice_config.capture
  | Error Voice_config.Not_configured -> Ok Voice_config.default_capture
  | Error (Voice_config.Invalid reason) ->
    Error (Printf.sprintf "voice config is invalid, so no capture was started: %s" reason)
;;

(* How long past its own deadline a recorder's arm waits before giving up on
   it. The watcher, or the probe's trim, is what ends a recording; this only
   keeps one that somehow never ends from holding the microphone. *)
let recorder_arm_grace_seconds = 5.0

(* The opening of a capture the room profile is taken from. sox drops leading
   silence, so what survives at the start is this room during this capture. *)
let noise_profile_seconds = 0.25

(* How much of that profile sox's noisered subtracts, on its 0 to 1 scale.
   Measured on one sample at this setting: the floor went entirely and 81% of
   the speech stayed. *)
let noise_reduction_amount = 0.21

(* A bound on each sox pass over a finished capture, which is a file
   operation and not a recording. *)
let sox_pass_timeout_seconds = 15.0

(* How long a capture may run before it ends on its own, when the caller does
   not say. The keeper listen tool passes nothing when the model names no
   timeout, and its schema advertises this number. *)
let default_capture_timeout_seconds = 15.0

(* Every level in the capture path is an RMS amplitude on this scale, and dB
   here is dBFS. Measured 2026-09-04 on one workstation, an idle room read
   1.18% and an ordinary sentence 11.9% — 20 dB apart, which is the whole
   separation the thresholds have to work with. *)
let db_of_amplitude v = if v > 0.0 then 20.0 *. log10 v else neg_infinity
let amplitude_of_db d = if d = neg_infinity then 0.0 else 10.0 ** (d /. 20.0)

(* One short capture, recording the room as it is, for as long as a capture
   would spend calibrating. *)
let measure_noise_floor ~agent_id () =
  match capture_config () with
  | Error reason ->
    (* The capture that follows refuses with this same reason; a probe that
       ran anyway would measure a room for a capture that is not going to
       happen. *)
    Log.Transport.debug "voice noise floor not measured: %s" reason;
    None
  | Ok capture ->
    let calibration_seconds = capture.Voice_config.calibration_seconds in
    let probe =
      Filename.temp_file (Printf.sprintf "masc_nf_%s_" (safe_agent_id agent_id)) ".wav"
    in
    let cleanup () = try Sys.remove probe with Sys_error _ -> () in
    Eio_guard.protect ~finally:cleanup (fun () ->
         match
           run_voice_status
             ~timeout_sec:(calibration_seconds +. recorder_arm_grace_seconds)
             [ "rec"; "-q"; "-t"; "wav"; "-b"; "16"; "-e"; "signed-integer"; probe
             ; "rate"; string_of_int Voice_pcm.sample_rate; "channels"; "1"
             ; "trim"; "0"; Printf.sprintf "%.2f" calibration_seconds ]
         with
         | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
         | Unix.WEXITED 0, _ -> (
           (* RMS, and the whole probe rather than its tail: the capture that
              uses this floor compares RMS against it. A peak floor under an
              RMS level sits roughly a decade too high on room tone. *)
           match
             Voice_pcm.tail_rms ~window_seconds:calibration_seconds probe
           with
           | Ok amplitude -> Some amplitude
           | Error _ -> None)
         | _ -> None)
;;

(* Run [f] on a copy with the room subtracted; when either sox step fails,
   [f] runs on what the caller already had rather than on nothing.

   The profile comes from the capture's own leading moment, not a separate
   recording: sox drops leading silence, so what survives at the start is this
   room during this capture. A profile taken seconds earlier describes a room
   that may have changed, and subtracting the wrong profile removes speech. *)
let with_noise_reduced_audio ~audio_file ~f =
  (* The copy belongs to this scope, not its caller: both temporaries are
     removed when [f] returns, whatever it returns. The old shape handed the
     reduced file to its caller and nobody removed it — every noise-reduced
     capture left a masc_nr_*.wav behind forever. *)
  let profile = Filename.temp_file "masc_nr_" ".prof" in
  let reduced = Filename.temp_file "masc_nr_" ".wav" in
  let cleanup () =
    List.iter (fun p -> try Sys.remove p with Sys_error _ -> ()) [ profile; reduced ]
  in
  Eio_guard.protect ~finally:cleanup (fun () ->
    match
      run_voice_status
        ~timeout_sec:sox_pass_timeout_seconds
        [ "sox"; audio_file; "-n"; "trim"; "0"; Printf.sprintf "%.2f" noise_profile_seconds
        ; "noiseprof"; profile ]
    with
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | Unix.WEXITED 0, _ -> (
      match
        run_voice_status
          ~timeout_sec:sox_pass_timeout_seconds
          [ "sox"; audio_file; reduced; "noisered"; profile
          ; Printf.sprintf "%.2f" noise_reduction_amount ]
      with
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | Unix.WEXITED 0, _ -> f reduced
      | _ -> f audio_file)
    | _ -> f audio_file)
;;

(* How often the level is re-read while recording. Each read is a seek and a
   few thousand multiplications rather than a subprocess, so this can be far
   faster than the half-second the meter used to manage. *)
let level_poll_seconds = 0.1

(* The span each level is measured over. Shorter reads chatter on the gaps
   between consonants inside a single word; longer ones smear the end of an
   utterance into the silence after it and delay the stop by their own width. *)
let level_window_seconds = 0.3

(* Which of the three ways a recording can end. Only the first is speech; the
   other two carry no transcript and must not reach the endpoint, because
   whisper answers silence with a sentence. *)
(* Where the watcher is in the recording. A variant rather than a pair of
   flags: "calibrating" and "speaking" carry different fields, and no state
   outside these three exists. *)
type level_phase =
  | Calibrating of { until : float; floor : float option }
  | Listening of { floor : float }
  | Speaking of { floor : float; quiet_since : float option }

(* What the operator asked for when they ended a recording early. Two ways to
   end it, and a single variant rather than two flags: "stop" and "discard"
   cannot both be true, and a pair of booleans would let them be. *)
type stop_request =
  | Keep_what_was_heard
  | Discard

(* Why a recording is over. What is done with it turns on two things: whether
   speech was heard, and whether the operator said they do not want it. A
   capture stopped mid-sentence by the stop key carries a sentence; one
   abandoned mid-sentence by the discard key carried one and threw it away,
   and must say so -- reporting it as nothing heard tells an operator who
   just said something that their microphone is dead. *)
type capture_end =
  | Ended_after_speech
  (* These carry the room the capture measured, when it got that far. An
     operator whose draft came back empty cannot tell a microphone that heard
     nothing from a transcriber that failed, and the two levels are the
     difference: "you were at -38, speech had to clear -32" is a thing to act
     on, where "nothing was heard" is not. [None] when the recorder never
     produced a sample to measure. *)
  | Ended_without_speech of float option
  | Stopped_before_speech of float option
  (* The floor is always known here: speech was heard, so calibration had
     finished. *)
  | Discarded_after_speech of float

(* Watches the recording as it is written and decides when it is over.

   sox's own [silence] filter used to make this decision. It could not be
   observed while it was making it: with that filter the output file stays at
   zero bytes until the trigger fires, so a meter reading the file reported
   nothing for exactly as long as the operator needed to see something. The
   decision and the display now read the same number, once per poll. *)
(* What one reading does to the watcher, with no clock and no file in it. The
   loop below supplies the time and the level; every choice the capture makes
   is here, where it can be checked against a table of levels rather than a
   microphone. *)
type level_step =
  | Continue of level_phase
  | Finish of capture_end

let advance_phase ~(capture : Voice_config.capture_config) ~now ~level phase =
  let trigger_at floor =
    db_of_amplitude floor +. capture.Voice_config.trigger_margin_db
  in
  let quiet_below floor =
    db_of_amplitude floor +. capture.Voice_config.speech_margin_db
  in
  match level, phase with
  (* No audio to measure yet. The recorder creates the file before it writes
     to it, so this is the state every capture starts in. *)
  | None, phase -> Continue phase
  (* The room is read from the capture's own opening rather than a probe
     before it: whatever the recorder hears before speech starts is this room
     during this recording, and it costs no extra second. The smallest reading
     wins, so a door closing during calibration does not raise the threshold
     for the rest of the capture. *)
  | Some amplitude, Calibrating { until; floor } ->
    let floor =
      match floor with
      | Some previous -> Some (Float.min previous amplitude)
      | None -> Some amplitude
    in
    (match floor with
     | Some floor when now >= until -> Continue (Listening { floor })
     | Some _ | None -> Continue (Calibrating { until; floor }))
  | Some amplitude, Listening { floor } ->
    if db_of_amplitude amplitude > trigger_at floor
    then Continue (Speaking { floor; quiet_since = None })
    else Continue (Listening { floor })
  | Some amplitude, Speaking { floor; quiet_since } ->
    if db_of_amplitude amplitude < quiet_below floor
    then (
      match quiet_since with
      | Some since when now -. since >= capture.Voice_config.trailing_silence_seconds
        -> Finish Ended_after_speech
      | Some _ -> Continue (Speaking { floor; quiet_since })
      | None -> Continue (Speaking { floor; quiet_since = Some now }))
    else
      (* Speech resumed. The pause was inside the sentence. *)
      Continue (Speaking { floor; quiet_since = None })
;;

(* What a deadline means depends on where the watcher got to. A capture cut
   off mid-sentence still carries speech and is worth transcribing; one that
   never heard any is a recording of a room, and whisper answers those with a
   sentence. *)
let end_at_deadline = function
  | Speaking _ -> Ended_after_speech
  | Calibrating { floor; _ } -> Ended_without_speech floor
  | Listening { floor } -> Ended_without_speech (Some floor)
;;

(* The same question, asked of the other way a recording ends. The key says
   "stop", and the reason to press it is usually that the speaker has finished
   and does not want to sit out the trailing-silence wait; discarding then
   costs them the sentence again, while transcribing something unwanted costs
   one deletion in a draft that has not been sent.

   Before any speech it is an abort, and yields nothing -- which is also what
   keeps a room away from a transcriber that answers silence with a sentence. *)
let end_at_operator_stop request phase =
  match request, phase with
  (* An explicit discard is the operator saying they do not want it, which no
     amount of speech overrides. Nothing else in the capture path can say
     that: every other ending is inferred from levels. It is its own ending
     because what was thrown away was a sentence, and the operator is told
     that rather than that nothing was heard. *)
  | Discard, Speaking { floor; _ } -> Discarded_after_speech floor
  | Discard, Calibrating { floor; _ } -> Stopped_before_speech floor
  | Discard, Listening { floor } -> Stopped_before_speech (Some floor)
  | Keep_what_was_heard, Speaking _ -> Ended_after_speech
  | Keep_what_was_heard, Calibrating { floor; _ } -> Stopped_before_speech floor
  | Keep_what_was_heard, Listening { floor } -> Stopped_before_speech (Some floor)
;;

let watch_capture_level
      ~clock
      ~audio_file
      ~(capture : Voice_config.capture_config)
      ~noise_floor
      ~on_level
      ~should_stop
      ~deadline
  =
  (* Nothing but the clock, the file, and the operator's key is decided here.
     [advance_phase] holds every threshold. *)
  let rec step phase =
    Eio.Time.sleep clock level_poll_seconds;
    let now = Eio.Time.now clock in
    match should_stop () with
    | Some request -> end_at_operator_stop request phase
    | None ->
    if now >= deadline
    then end_at_deadline phase
    else (
      let level =
        match Voice_pcm.tail_rms ~window_seconds:level_window_seconds audio_file with
        | Ok amplitude -> Some amplitude
        | Error _ -> None
      in
      on_level
        (match level with
         | Some amplitude -> db_of_amplitude amplitude
         | None -> Float.neg_infinity);
      match advance_phase ~capture ~now ~level phase with
      | Finish ending -> ending
      | Continue next ->
        (* Said once, when the room stops being a guess. *)
        (match phase, next with
         | Calibrating _, Listening { floor } ->
           Log.Transport.debug
             "voice capture: room %.1f dB, speech above %.1f dB"
             (db_of_amplitude floor)
             (db_of_amplitude floor +. capture.Voice_config.trigger_margin_db)
         | _ -> ());
        step next)
  in
  let start = Eio.Time.now clock in
  let floor = Option.map (fun f -> f) noise_floor in
  match floor with
  (* A caller that has just captured for the same agent already knows the
     room, and re-measuring it would delay this capture by the calibration
     window for an answer it has. *)
  | Some floor -> step (Listening { floor })
  | None ->
    step
      (Calibrating
          { until = start +. capture.Voice_config.calibration_seconds; floor = None })
;;

(* What a capture that carries no speech says for itself.

   The levels are in it because without them the answer is not actionable: an
   empty draft looks the same whether the microphone heard nothing, the room
   rose over the threshold, or the transcriber failed. With them it is a
   number and a target, and an operator who reads "-38.2 dB, speech had to
   clear -32.2 dB" knows both that the capture ran and what to change. *)
let no_audio ~reason ~floor (capture : Voice_config.capture_config) =
  let detail =
    match floor with
    | Some floor ->
      Printf.sprintf
        "%s — room %.1f dB, speech had to clear %.1f dB"
        reason
        (db_of_amplitude floor)
        (db_of_amplitude floor +. capture.Voice_config.trigger_margin_db)
    (* The recorder produced nothing to measure, which is its own answer and a
       different one: not a room too loud but a microphone that delivered no
       samples at all. *)
    | None -> reason ^ " — the recorder produced no audio to measure"
  in
  `Assoc
    [ "status", `String (capture_status_to_string No_audio)
    ; "text", `String ""
    ; "message", `String detail
    ]
;;

(* What a discarded capture says for itself. It heard speech -- that is what
   separates it from {!no_audio} -- so the levels that explain a silence are
   not the point; that a sentence was thrown away on purpose is. *)
let discarded_json =
  `Assoc
    [ "status", `String (capture_status_to_string Discarded)
    ; "text", `String ""
    ; "message", `String "recording discarded — speech was heard and not transcribed"
    ]
;;

(* The capture result read back as one of the things it can be. This is the
   reader for the JSON {!record_and_transcribe} returns, kept next to the
   writers so the two cannot drift: a status neither knows is reported as
   such, and a result with no status at all is its own answer; neither is
   folded into "nothing was heard". *)
type capture_outcome =
  | Transcript of
      { text : string
      ; endpoint_id : string option
      }
  | Transcriber_returned_nothing of { endpoint_id : string option }
  | Nothing_heard of { message : string }
  | Discarded_recording of { message : string }
  | Unrecognized_status of string
  | Status_absent

let capture_outcome_of_json json =
  let field name = Json_util.get_string json name in
  let nonempty name = Json_util.get_string_nonempty json name in
  let message ~fallback = Option.value (nonempty "message") ~default:fallback in
  match field "status" with
  | None -> Status_absent
  | Some raw ->
    (match capture_status_of_string raw with
     | None -> Unrecognized_status raw
     | Some Transcribed ->
       (match nonempty "text" with
        | Some text -> Transcript { text = String.trim text; endpoint_id = nonempty "endpoint_id" }
        | None -> Transcriber_returned_nothing { endpoint_id = nonempty "endpoint_id" })
     | Some No_audio -> Nothing_heard { message = message ~fallback:"nothing was heard" }
     | Some Discarded ->
       Discarded_recording { message = message ~fallback:"recording discarded" })
;;

let record_and_transcribe
      ~agent_id
      ?(timeout_sec = default_capture_timeout_seconds)
      ?language_code
      ?noise_floor
      ?(on_level = fun (_ : float) -> ())
      ?(should_stop = fun () -> None)
      ()
  =
  (* Refused here, before a tone is played or a microphone opened: a config
     that exists and does not parse names its reason. *)
  let* capture = capture_config () in
  let audio_file =
    Filename.temp_file (Printf.sprintf "masc_stt_%s_" (safe_agent_id agent_id)) ".wav"
  in
  (* Pinned rather than left to sox, which chooses 32-bit when it is not told.
     The reader that measures this file decodes 16-bit, and a mismatch is not
     an error either side reports: it reads as noise. Measured 2026-09-04, a
     32-bit capture read 0.41 where sox said 0.011. *)
  let rec_argv =
    [ "rec"
    ; "-q"
    ; "-t"
    ; "wav"
    ; "-b"
    ; "16"
    ; "-e"
    ; "signed-integer"
    ; audio_file
    ; "rate"
    ; string_of_int Voice_pcm.sample_rate
    ; "channels"
    ; "1"
    ]
  in
  let cleanup () =
    try Sys.remove audio_file with
    | Sys_error _ -> ()
  in
  Eio_guard.protect ~finally:cleanup (fun () ->
    match Process_eio.get_clock () with
    | Error message -> Error (Printf.sprintf "voice capture has no clock: %s" message)
    | Ok clock ->
      play_tone 880.0;
      (* The recorder has no end of its own, so the watcher is what stops it:
         when the watcher returns, [Fiber.first] cancels the recording. The
         cancelled spawn sends sox SIGTERM and then waits, up to
         [Process_eio.child_exit_grace_seconds], for sox to close its pipes
         -- which it does on exit, after it has written the length into the
         WAV header. SIGKILL follows only if the grace runs out.

         The wait is what keeps the tail: sox flushes about one stdio buffer
         on SIGTERM, and a SIGKILL in the same instant loses it -- a quarter
         second of a two-second recording, measured 2026-09-04. A discard
         pays the same wait although the file is removed right after:
         [Process_eio] stops a cancelled spawn one way, and a kill that skips
         the grace is not a path it offers.

         The recorder's own arm carries the same deadline so that a watcher
         that somehow never returns cannot leave a microphone open. *)
      let outcome =
        Eio.Fiber.first
          (fun () ->
             match
               run_voice_status ~timeout_sec:(timeout_sec +. recorder_arm_grace_seconds) rec_argv
             with
             | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
             | exception exn ->
               Error (Printf.sprintf "rec exception: %s" (Printexc.to_string exn))
             (* The recorder has no end of its own, so reaching one means it
                stopped on its own arm without the watcher having decided
                anything. No floor was settled. *)
             | Unix.WEXITED 0, _ -> Ok (Ended_without_speech None)
             | Unix.WEXITED code, _ -> Error (Printf.sprintf "rec exit %d" code)
             | _ -> Error "rec process failed")
          (fun () ->
             Ok
               (watch_capture_level
                  ~clock
                  ~audio_file
                  ~capture
                  ~noise_floor
                  ~on_level
                  ~should_stop
                  ~deadline:(Eio.Time.now clock +. timeout_sec)))
      in
      play_tone 440.0;
      on_level Float.neg_infinity;
      (match outcome with
       | Error message -> Error message
       | Ok (Stopped_before_speech floor) ->
         (* Stopped before anything was said. Distinct from the message below
            because nothing waited for speech here -- saying the room was too
            quiet would blame a microphone that was never given a chance. *)
         Ok (no_audio ~reason:"stopped before anything was said" ~floor capture)
       | Ok (Discarded_after_speech _) ->
         (* The operator abandoned a recording that had speech in it. Not a
            silence: the microphone worked, and saying otherwise would send
            them looking for a fault that is not there. *)
         Ok discarded_json
       | Ok (Ended_without_speech floor) ->
         (* The gate that keeps a room away from the transcriber. It used to
            re-read the finished file and compare its average against its own
            opening; now the watcher has already compared every tenth of a
            second against the room and knows no reading cleared it. *)
         Ok (no_audio ~reason:"nothing rose above the room" ~floor capture)
       | Ok Ended_after_speech ->
         if capture.Voice_config.noise_reduction
         then
           with_noise_reduced_audio ~audio_file ~f:(fun audio_file ->
               transcribe_audio ~audio_file ?language_code ())
         else transcribe_audio ~audio_file ?language_code ()))
;;
