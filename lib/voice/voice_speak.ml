(* Voice_speak — the TTS synthesis pipeline: endpoint selection, the MCP/HTTP
   speak attempts, browser-audio fields and the agent_speak result contract.
   Extracted from Voice_bridge (E09 Phase 2c, task-2526). Callers keep the old
   names through Voice_bridge's re-exports.

   Design: reports/e09-voice-addon-boundary-design-20261023.md *)

include Voice_bridge_core

open Result.Syntax

let safe_agent_id = Voice_bridge_transport.safe_agent_id
let make_audio_file = Voice_bridge_transport.make_audio_file
let speak_via_http_tts_to_file = Voice_bridge_transport.speak_via_http_tts_to_file
let cleanup_old_audio_files = Voice_player.cleanup_old_audio_files

let clip_format_for_kind (kind : Voice_config.endpoint_kind) =
  match kind with
  | Voice_config.Macos_say | Voice_config.Espeak_ng -> Voice_bridge_core.Wav
  | Voice_config.Openai_compat
  | Voice_config.Elevenlabs_direct
  | Voice_config.Voice_mcp
  | Voice_config.Whisper_cli -> Voice_bridge_core.Mp3
;;

let audio_url_of_file audio_file =
  match Voice_bridge_core.clip_of_path audio_file with
  | Some (token, _format) -> Some (Masc_network_defaults.voice_audio_path token)
  | None -> None
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


let available_tts_endpoints ?provider (tts : Voice_config.tts_config) =
  Voice_runtime_overlay.select_endpoints ?provider tts.Voice_config.endpoints
;;

(** Synthesize a dashboard-playable MP3 via any HTTP TTS endpoint.
    This is used as a parallel fallback when the active transport is
    [Voice_mcp], which produces audio through a local/MCP path but does not
    write a browser-fetchable file. *)
let try_http_tts_for_dashboard ~(tts : Voice_config.tts_config) ~agent_id ~message ~voice
      ~audio_device () =
  (* The dashboard's own attempt, which only knows the HTTP endpoints. Each is
     asked for its own model; one that has none is passed over rather than
     asked with a blank name. *)
  let endpoints = available_tts_endpoints tts in
  let rec try_endpoint = function
    | [] -> None
    | endpoint :: rest ->
      let adapter = Voice_runtime_overlay.adapter_for_endpoint endpoint in
      if Voice_runtime_overlay.speaker_of_transport adapter.transport
         = Voice_runtime_overlay.Over_http
      then (
        match
          Voice_config.model_at_endpoint ~default_model:tts.Voice_config.default_model endpoint
        with
        | None -> try_endpoint rest
        | Some model ->
        let audio_file =
          make_audio_file ~format:(clip_format_for_kind endpoint.Voice_config.kind)
        in
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



(** ============================================
    Types
    ============================================ *)

type agent_speak_completion =
  | Spoken
  | Synthesized
  | Dedup_skipped
[@@deriving enumerate]

(* The [status] a speak result carries, and the reading of it back. One pair so
   the value written for a local endpoint and the value decoded from a Voice
   MCP server's answer are the same three words. *)
let agent_speak_completion_to_string = function
  | Spoken -> "spoken"
  | Synthesized -> "synthesized"
  | Dedup_skipped -> "dedup_skipped"

let agent_speak_completion_of_string s = List.find_opt (fun v -> String.equal (agent_speak_completion_to_string v) s) all_of_agent_speak_completion

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

let mcp_call_error_to_string = function
  | Timed_out seconds -> Printf.sprintf "Request timeout after %.1fs" seconds
  | Connection_failed detail -> Printf.sprintf "Connection error: %s" detail
  | Http_status { code; body } -> Printf.sprintf "HTTP %d: %s" code body
  | Malformed_body detail ->
    Printf.sprintf "Voice MCP: invalid JSON body: %s" detail
;;

(* One Voice MCP call under its window. An answer that arrived as the window
   closed is the answer -- a sentence the server spoke is not reported as
   [Timed_out] for its caller to speak again; [Timed_out] is the outcome only
   when no answer had arrived. *)
let with_timeout ~clock ?timeout operation =
  let timeout_sec =
    match timeout with
    | Some t -> t
    | None -> request_timeout_seconds ()
  in
  Watched_work.run
    ~watcher:(fun () ->
      Eio.Time.sleep clock timeout_sec;
      Error (Timed_out timeout_sec))
    operation
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

(* What a voice_mcp endpoint answered, said the way the other answers are:
   the voice that was asked for. The tool plays the sentence where that server
   plays audio and hands back no file, so there is no byte count to report. *)
let mcp_spoke_detail ~voice =
  Printf.sprintf
    "agent_speak answered in %s"
    (if String.trim voice = "" then "the system voice" else "\"" ^ voice ^ "\"")
;;


(** Try HTTP TTS endpoints to synthesize a browser-playable MP3 clip.
    Used when the winning endpoint is [Voice_mcp] so the dashboard still
    has an audio clip even though the MCP server owns local playback.
    Returns [None] when no HTTP endpoint is configured or all fail. *)
let try_http_tts_for_browser_audio
      ~sw
      ~clock
      ~net
      ~(tts : Voice_config.tts_config)
      ~agent_id
      ~message
      ~priority
      ?audio_device
      endpoints
  =
  let http_endpoints =
    List.filter
      (fun endpoint ->
        Voice_runtime_overlay.speaker_of_endpoint endpoint
        = Voice_runtime_overlay.Over_http)
      endpoints
  in
  let rec try_endpoints = function
    | [] -> None
    | endpoint :: rest ->
      (* Same as the dashboard chain above: each HTTP endpoint is asked for its
         own model, and one that has none is passed over. *)
      match
        Voice_config.model_at_endpoint ~default_model:tts.Voice_config.default_model endpoint
      with
      | None -> try_endpoints rest
      | Some model ->
      let audio_file =
        make_audio_file ~format:(clip_format_for_kind endpoint.Voice_config.kind)
      in
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

let remove_quietly path = try Sys.remove path with Sys_error _ -> ()
let spoke_detail = Voice_catalogue.spoke_detail
let check_command_voice = Voice_probe.check_command_voice

type probe_outcome = Voice_probe.probe_outcome =
  | Answered of string
  | Refused of string
  | Skipped of string

type probe_attempt = Voice_probe.probe_attempt = {
  endpoint_id : string;
  kind : Voice_config.endpoint_kind;
  outcome : probe_outcome;
}

let probe_tts ?(agent_id = "probe") ~message () =
  match Voice_config.load_detailed () with
  | Error error -> Error (Voice_config.load_error_to_string error)
  | Ok config ->
    (match config.Voice_config.tts with
     | None -> Error "no [voice.tts] section is configured, so nothing speaks"
     | Some tts ->
       Ok
         (List.map
            (fun (endpoint : Voice_config.endpoint) ->
              let outcome =
                (* The voice is resolved per endpoint: an id is provider
                   vocabulary, so the one that suits this endpoint is the one
                   to ask it for (#24068). *)
                let voice () =
                  Voice_config.voice_for_agent_at_endpoint tts endpoint agent_id
                in
                (* The voice that was asked for, not only the bytes that came
                   back. A say voice that is not installed was refused before
                   the clip, so an answer here is in the voice it names. A
                   blank one is the system voice, said as such rather than
                   as "". *)
                let answer = function
                  | Ok detail -> Answered detail
                  | Error reason -> Refused reason
                in
                (* The probe produces the audio the same ways the speak path
                   does, so that what it reports is what a turn would get
                   rather than a second opinion. *)
                let clip speak =
                  let voice = voice () in
                  let output_file =
                    make_audio_file ~format:(clip_format_for_kind endpoint.Voice_config.kind)
                  in
                  let spoken = speak ~voice ~output_file in
                  remove_quietly output_file;
                  answer (Result.map (fun size -> spoke_detail ~bytes:size ~voice) spoken)
                in
                if not endpoint.Voice_config.enabled
                then Skipped "disabled in the configuration"
                else
                  match Voice_runtime_overlay.speaker_of_endpoint endpoint with
                  | Voice_runtime_overlay.Does_not_speak ->
                    Skipped "this endpoint kind does not synthesize"
                  | Voice_runtime_overlay.By_command ->
                    (* Checked here and not before every speak: listing
                       took 0.56-0.59s per call on the mac that measured
                       it, which a keeper's every sentence would wait for.
                       This probe is where a mapping is confirmed. *)
                    (match check_command_voice endpoint ~voice:(voice ()) with
                     | Error reason -> Refused reason
                     | Ok () ->
                       clip (fun ~voice ~output_file ->
                         Voice_bridge_transport.speak_via_command_to_file
                           endpoint ~message ~voice ~output_file))
                  | Voice_runtime_overlay.Over_http ->
                    clip (fun ~voice ~output_file ->
                      match
                        Voice_config.model_at_endpoint
                          ~default_model:tts.Voice_config.default_model endpoint
                      with
                      | None ->
                        Error
                          "this endpoint is asked for a model by name and neither it \
                           nor [voice.tts] names one"
                      | Some model ->
                        speak_via_http_tts_to_file
                          endpoint ~agent_id ~message ~voice ~model ~output_file)
                  (* Through agent_speak, the tool a turn calls. Skipping it
                     reported a configuration whose only speaker is an MCP
                     tool as nothing answering, and voice-verify exited 1 for
                     a voice that worked. The call is bounded by the event
                     loop's clock, as the speak path's is. *)
                  | Voice_runtime_overlay.By_mcp_tool ->
                    let voice = voice () in
                    answer
                      (match Eio_context.get_clock_opt (), Eio_context.get_net_opt () with
                       | Some clock, Some net ->
                         with_voice_output_turn ~agent_id (fun () ->
                           match
                             call_voice_mcp_endpoint
                               ~clock
                               ~net
                               ~endpoint
                               ~tool_name:"agent_speak"
                               ~arguments:
                                 (`Assoc
                                   [ "agent_id", `String agent_id
                                   ; "message", `String message
                                   ; "voice", `String voice
                                   ; "priority", `Int 1
                                   ])
                           with
                           | Error error -> Error (mcp_call_error_to_string error)
                           | Ok json ->
                             Result.map (fun _ -> mcp_spoke_detail ~voice)
                               (extract_mcp_result json))
                       | None, _ | _, None ->
                         Error
                           "no event loop is running in this process to bound the MCP \
                            call with")
              in
              { endpoint_id = endpoint.Voice_config.id
              ; kind = endpoint.Voice_config.kind
              ; outcome
              })
            tts.Voice_config.endpoints))

(** Get voice configuration for an agent *)
let attempt_tts_endpoint
      ~sw
      ~clock
      ~net
      ~agent_id
      ~message
      ~voice
      ~priority
      ~(tts : Voice_config.tts_config)
      ?audio_device
      endpoint
  =
  let adapter = Voice_runtime_overlay.adapter_for_endpoint endpoint in
  let model =
    Voice_config.model_at_endpoint ~default_model:tts.Voice_config.default_model endpoint
  in
  match adapter.transport with
  (* One branch for every way of producing the audio, because everything after
     it -- playing the file, the dedup record, what gets reported -- is the
     same. Which of the two ways is used is the endpoint's kind, not a guess. *)
  | Voice_runtime_overlay.Openai_compat
  | Voice_runtime_overlay.Elevenlabs_direct
  | Voice_runtime_overlay.Macos_say
  | Voice_runtime_overlay.Espeak_ng ->
    let audio_file = make_audio_file ~format:(clip_format_for_kind endpoint.Voice_config.kind) in
    (match
       (match adapter.transport with
        | Voice_runtime_overlay.Macos_say
        | Voice_runtime_overlay.Espeak_ng ->
          Voice_bridge_transport.speak_via_command_to_file
            endpoint
            ~message
            ~voice
            ~output_file:audio_file
        | Voice_runtime_overlay.Openai_compat
        | Voice_runtime_overlay.Elevenlabs_direct
        | Voice_runtime_overlay.Voice_mcp
        | Voice_runtime_overlay.Whisper_cli ->
          (* These are asked for a model by name, the endpoint's own or the
             section's. The loader refuses a section that leaves one without,
             so [None] here is said rather than sent as [model_id ""]. *)
          (match model with
           | None ->
             Error
               (Printf.sprintf
                  "voice config endpoint %s is asked for a model by name and \
                   neither it nor [voice.tts] names one"
                  endpoint.Voice_config.id)
           | Some model ->
             speak_via_http_tts_to_file
               endpoint
               ~message
               ~voice
               ~model
               ~agent_id
               ~output_file:audio_file))
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
                [ "status", `String (agent_speak_completion_to_string Dedup_skipped)
                ; "agent_id", `String agent_id
                ; "reason", `String "identical message was played recently (mutex)"
                ])
        | (`Failed reason | `Skipped reason) as playback_status ->
          let local_playback_status =
            match playback_status with
            | `Failed _ -> "failed"
            | `Skipped _ -> "skipped"
          in
          (* The clip exists and nothing on this host played it. A keeper reads
             [status] to tell the operator what happened, so this is not
             [Spoken]. *)
          Ok
            (append_provider_metadata
               (`Assoc
                   ([ "status", `String (agent_speak_completion_to_string Synthesized)
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
                   ([ "status", `String (agent_speak_completion_to_string Spoken)
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
                   ([ "status", `String (agent_speak_completion_to_string Spoken)
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
  (* An endpoint that transcribes is not a fallback for one that speaks: a
     chain that quietly used it would report success for a turn nobody heard. *)
  | Voice_runtime_overlay.Whisper_cli ->
    Error
      (`Proven_pre_effect
        (Printf.sprintf
           "voice config endpoint %s transcribes and does not speak"
           endpoint.Voice_config.id))
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
        (* A failed voice MCP call does not prove the remote side did not
           play: a timeout or a dropped connection can come after playback
           started. So no MCP failure authorizes endpoint failover. *)
        Error (`Outcome_unknown (mcp_call_error_to_string error))
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
            [ "status", `String (agent_speak_completion_to_string Dedup_skipped)
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
        | (Ok _ | Error _) as other -> other)
;;

let decode_agent_speak_result payload =
  match Json_util.get_string payload "status" with
  | Some status ->
    (match agent_speak_completion_of_string status with
     | Some completion -> Ok { completion; payload }
     | None -> Error (Printf.sprintf "voice speak returned unsupported status=%S" status))
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
