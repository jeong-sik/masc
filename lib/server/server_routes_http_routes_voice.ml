(** Voice audio clip HTTP surface (RFC-0235 P1).

    Serves synthesized TTS clips to a connected dashboard browser by
    capability token, so the browser plays the utterance instead of relying
    on the server host's speakers ([Voice_bridge_core.run_local_playback]).

      GET /api/v1/voice/audio/<token>

    The token is the 128-bit [Random_id.hex] filename written by
    [Voice_bridge_transport.make_audio_file]. Token = filename = HTTP
    capability: no per-clip ACL table, no agent identity in the URL (the
    legacy [<ts>_<agent>.mp3] name was enumerable).

    Auth is [with_public_read]. The unguessable token is a capability, so this
    route remains on the strict-auth public-read allowlist. Artifact digests
    are content identifiers, not authorization capabilities.

    Response (200): raw bytes, Content-Type audio/mpeg or audio/wav. NOT a JSON envelope:
    the dashboard fetches this URL directly from an [<audio>]/[Audio]
    element, which needs the media bytes, not a wrapped payload.

   Errors:
      400 — token malformed (not 32 hex chars)
      404 — clip not on disk (never synthesized, or reaped by the 24h TTL of
            [Voice_bridge.cleanup_old_audio_files])
      503 — base path unresolvable *)

open Server_utils
open Server_auth

module Http = Http_server_eio

let is_valid_token token = Option.is_some (Voice_bridge_core.audio_file_of_token token)

let generated_media_serve_max_bytes () =
  Env_config.KeeperGeneratedMedia.max_bytes ()

(* Clip path under the same audio dir [Voice_bridge_transport.make_audio_file]
   writes to. Reuses [Voice_bridge_core.masc_base_dir] so this route and the
   synthesis side cannot drift apart. *)
let serve_clip ~token request reqd =
  match Voice_bridge_core.audio_file_of_token token with
  | None ->
    respond_public_read_json_value ~status:`Bad_request request reqd
      (`Assoc [ "error", `String "invalid audio token" ])
  | Some (filename, format) ->
  let path =
    Filename.concat (Filename.concat (Voice_bridge_core.masc_base_dir ()) "audio") filename
  in
  if not (Sys.file_exists path) then
    (* Never synthesized, or reaped by the 24h TTL reaper. Text-only render
       remains the dashboard fallback, so 404 is not a hard failure. *)
    respond_public_read_json_value ~status:`Not_found request reqd
      (`Assoc [ ("error", `String "not found"); ("token", `String token) ])
  else (
    (* The capability carries the format written by synthesis. *)
    let body = Fs_compat.load_file path in
    let headers =
      Httpun.Headers.of_list
        ( ("content-type", Voice_bridge_core.audio_content_type format)
        :: ("content-length", string_of_int (String.length body))
        :: public_read_cors_headers request )
    in
    let response = Httpun.Response.create ~headers (`OK :> Httpun.Status.t) in
    Httpun.Reqd.respond_with_string reqd response body)

(* RFC-0301: serve a model-generated media file by deterministic store token.
   Unlike voice clips, this token is a content-derived locator, not a bearer
   capability, so the route is [CanReadState]-gated below. The file is resolved
   under the SAME workspace base_path the bridge persisted it with, so the write
   and read paths agree; content-type is derived from the stored extension. A
   missing token is a soft 404 (text-only render remains the dashboard fallback);
   an oversized stored file returns 413 before it is loaded into memory. *)
let serve_media ~base_path ~token request reqd =
  match Keeper_chat_media_store.file_path_of_token ~base_dir:base_path ~token with
  | None ->
    respond_json_value_with_cors ~status:`Not_found request reqd
      (`Assoc [ ("error", `String "not found"); ("token", `String token) ])
  | Some path ->
    let max_bytes = generated_media_serve_max_bytes () in
    match Fs_compat.file_size path with
    | None ->
        respond_json_value_with_cors ~status:`Not_found request reqd
          (`Assoc [ ("error", `String "not found"); ("token", `String token) ])
    | Some size when size > max_bytes ->
        respond_json_value_with_cors ~status:`Payload_too_large request reqd
          (`Assoc
             [ ("error", `String "media too large")
             ; ("token", `String token)
             ; ("max_bytes", `Int max_bytes)
             ; ("size_bytes", `Int size)
             ])
    | Some _ -> (
        match Fs_compat.load_file_opt path with
        | None ->
            respond_json_value_with_cors ~status:`Not_found request reqd
              (`Assoc [ ("error", `String "not found"); ("token", `String token) ])
        | Some body ->
            let headers =
              Httpun.Headers.of_list
                (("content-type", Keeper_chat_media_store.content_type_of_path path)
                 :: ("content-length", string_of_int (String.length body))
                 :: cors_headers (get_origin request))
            in
            let response = Httpun.Response.create ~headers (`OK :> Httpun.Status.t) in
            Httpun.Reqd.respond_with_string reqd response body)

(* Owner-route JSON respond helper. Unlike [respond_public_read_json_value],
   this adds no public-read capability headers: the transcribe route is
   owner-bearer-gated, not token-capability-gated (RFC-0236 §2.2/§3.4). *)
let respond_json ?(status = `OK) ~request reqd json =
  Http.Response.json_value ~status ~compress:true ~request json reqd

let audio_temp_suffix request =
  let media_type =
    match Http.Request.header request "content-type" with
    | None -> ""
    | Some raw ->
      let raw = String.lowercase_ascii (String.trim raw) in
      (match String.index_opt raw ';' with
       | None -> raw
       | Some idx -> String.trim (String.sub raw 0 idx))
  in
  match media_type with
  | "audio/mp4" | "audio/x-m4a" -> ".mp4"
  | "audio/mpeg" | "audio/mp3" -> ".mp3"
  | "audio/ogg" -> ".ogg"
  | "audio/wav" | "audio/wave" | "audio/x-wav" -> ".wav"
  | "audio/webm" | _ -> ".webm"

(** RFC-0236 P1 — transcribe browser-captured speech.

    Raw audio bytes in the request body (audio/webm, audio/mp4, ...), Scribe
    v2 via [Voice_bridge.transcribe_audio], and the whole transcribe record
    ([{status; text; language_code; endpoint_id}]) is returned so the dashboard
    can show the detected language. The dashboard renders only [text].

    Transcription spends an ElevenLabs API call per request, so this is
    admin/owner-gated with [CanAdmin]. [CanBroadcast] is intentionally too
    broad here: worker tokens have it for normal chat/broadcast writes, but
    they must not spend the operator's STT quota. This is the auth asymmetry
    with the GET audio route — that route is [with_public_read] because the
    token is an unguessable capability; transcribe has no capability, only the
    dashboard bearer.

    Input audio is a transient temp file registered with the Eio switch for
    cleanup on every exit path; nothing is persisted (unlike RFC-0235 output
    clips, which are SSOT chat records). *)
let handle_transcribe _state request reqd body =
  if String.length body = 0 then
    respond_json ~status:`Bad_request ~request reqd
      (`Assoc [ ("error", `String "empty audio body") ])
  else
    Eio.Switch.run (fun sw ->
      let tmp = Filename.temp_file "masc_voice_transcribe_" (audio_temp_suffix request) in
      Eio.Switch.on_release sw (fun () ->
        try Sys.remove tmp with
        | Sys_error _ -> ());
      Fs_compat.save_file tmp body;
      match Voice_bridge.transcribe_audio ~audio_file:tmp () with
      | Ok json -> respond_json ~request reqd json
      | Error err ->
        respond_json ~status:`Bad_request ~request reqd
          (`Assoc [ ("error", `String err) ]))


(* A voice setup failure carries its own sentence; the status says what kind of
   failure it was. A revision that moved under the caller is a conflict, not a
   bad request: the caller did nothing wrong, it just read before someone else
   wrote. *)
let respond_voice_setup_error request reqd error =
  let status =
    match error with
    | Server_voice_setup_actions.Invalid_request _ -> `Bad_request
    | Server_voice_setup_actions.Setup_failed Voice_setup.Configuration_changed ->
      `Conflict
    | Server_voice_setup_actions.Setup_failed
        (Voice_setup.Configuration_unavailable _) -> `Internal_server_error
    | Server_voice_setup_actions.Setup_failed
        ( Voice_setup.Voice_section_invalid _
        | Voice_setup.Endpoint_path_unusable _
        | Voice_setup.Configuration_rejected _ ) -> `Bad_request
  in
  respond_json_value_with_cors ~status request reqd
    (`Assoc
      [ "error", `String (Server_voice_setup_actions.error_message error) ])

let handle_voice_setup ~base_path ~act request reqd body =
  match Yojson.Safe.from_string body with
  (* Narrowed to what the parser throws: a wildcard here would swallow
     Eio.Cancel.Cancelled and answer a cancelled fiber with a parse error. *)
  | exception Yojson.Json_error _ ->
    respond_json_value_with_cors ~status:`Bad_request request reqd
      (`Assoc [ "error", `String "the request body is not JSON" ])
  | json ->
    (match act ~base_path json with
     | Ok result -> respond_json_value_with_cors ~status:`OK request reqd result
     | Error error -> respond_voice_setup_error request reqd error)

(* Probing every endpoint, rather than serving from the first that answers.

   The fallback chain behind agent_speak stops at the first endpoint that
   works, which is right for a turn and wrong for "is this configuration
   working": a chain that succeeds says nothing about the endpoints behind
   the one that answered, so a dead fallback looks exactly like a healthy one
   until the endpoint in front of it goes away. [Voice_bridge.probe_tts] and
   [probe_stt] ask all of them and report each separately; these routes are
   how a dashboard or a wizard asks for that report. *)
let probe_report_json attempts =
  `Assoc [ "endpoints", `List (List.map Voice_bridge.probe_attempt_json attempts) ]

let probe_failed request reqd reason =
  respond_json ~status:`Bad_request ~request reqd (`Assoc [ "error", `String reason ])

let handle_probe_tts request reqd body =
  match Yojson.Safe.from_string body with
  (* Narrowed to what the parser throws: a wildcard here would swallow
     Eio.Cancel.Cancelled and leave a cancelled fiber reporting a parse
     failure. *)
  | exception Yojson.Json_error _ ->
    probe_failed request reqd "the request body is not JSON"
  | json ->
    let message =
      match json with
      | `Assoc fields ->
        (match List.assoc_opt "message" fields with
         | Some (`String text) when String.trim text <> "" -> Some text
         | Some _ | None -> None)
      | _ -> None
    in
    (match message with
     | None ->
       probe_failed request reqd
         "a probe needs a non-empty \"message\" for the endpoints to synthesize"
     | Some message ->
       (match Voice_bridge.probe_tts ~message () with
        | Ok attempts -> respond_json ~request reqd (probe_report_json attempts)
        | Error reason -> probe_failed request reqd reason))

(* The audio arrives in the raw body, the way /voice/transcribe takes it. *)
let handle_probe_stt request reqd body =
  if String.length body = 0
  then probe_failed request reqd "empty audio body"
  else
    Eio.Switch.run (fun sw ->
      let tmp = Filename.temp_file "masc_voice_probe_" (audio_temp_suffix request) in
      Eio.Switch.on_release sw (fun () ->
        try Sys.remove tmp with
        | Sys_error _ -> ());
      Fs_compat.save_file tmp body;
      match Voice_bridge.probe_stt ~audio_file:tmp () with
      | Ok attempts -> respond_json ~request reqd (probe_report_json attempts)
      | Error reason -> probe_failed request reqd reason)

(* Which voices an endpoint has, asked before the endpoint is written.

   A voice id is provider vocabulary and the two kinds that publish a
   catalogue publish it differently -- ElevenLabs answers a URL, say answers a
   command -- so the kind decides which is asked rather than one being tried
   and the other used when it fails. Asked before the endpoint is saved so a
   wizard does not have to write a guess first and correct it after. *)
let catalogue_failed request reqd reason =
  respond_json ~status:`Bad_request ~request reqd (`Assoc [ "error", `String reason ])

let handle_voice_catalogue request reqd body =
  match Yojson.Safe.from_string body with
  (* Narrowed to what the parser throws, for the reason the probes are. *)
  | exception Yojson.Json_error _ ->
    catalogue_failed request reqd "the request body is not JSON"
  | json ->
    (match Server_voice_setup_actions.catalogue_endpoint_of_json json with
     | Error error ->
       catalogue_failed request reqd (Server_voice_setup_actions.error_message error)
     | Ok endpoint ->
       (match Voice_bridge.list_voices endpoint with
        | Error reason -> catalogue_failed request reqd reason
        | Ok voices ->
          respond_json ~request reqd
            (`Assoc
              [ "voices", `List (List.map Voice_bridge.catalogue_voice_json voices) ])))

let add_routes router =
  router
  |> Http.Router.prefix_get Masc_network_defaults.voice_audio_path_prefix
       (fun request reqd ->
       with_public_read
         (fun _state _req reqd ->
           let path = Http.Request.path request in
           match
             extract_path_param
               ~prefix:Masc_network_defaults.voice_audio_path_prefix path
           with
           | None ->
               respond_public_read_json_value ~status:`Bad_request request reqd
                 (`Assoc [ ("error", `String "token path parameter required") ])
           | Some raw when not (is_valid_token raw) ->
               respond_public_read_json_value ~status:`Bad_request request reqd
                 (`Assoc
                    [ ("error", `String "invalid token")
                    ; ("reason", `String "expected 32-char hex (128-bit), optionally followed by .wav")
                    ])
           | Some token -> serve_clip ~token request reqd)
         request reqd)
  |> Http.Router.prefix_get "/api/v1/media/" (fun request reqd ->
       (* RFC-0301: model-generated media (image/audio/document) fetched by an
          authenticated content locator. Content hashes are not capabilities. *)
       with_permission_auth ~permission:Masc_domain.CanReadState
         (fun state _req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           let path = Http.Request.path request in
           match extract_path_param ~prefix:"/api/v1/media/" path with
           | None ->
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (`Assoc [ ("error", `String "token path parameter required") ])
           | Some raw when not (Keeper_chat_media_store.valid_token raw) ->
               respond_json_value_with_cors ~status:`Bad_request request reqd
                 (`Assoc
                    [ ("error", `String "invalid token")
                    ; ("reason", `String "expected 64-char lowercase hex (SHA-256)")
                    ])
           | Some token -> serve_media ~base_path ~token request reqd)
         request reqd)
  |> Http.Router.post "/api/v1/voice/transcribe" (fun request reqd ->
       (* RFC-0236 P1: browser-captured speech -> text. Admin/owner-only
          ([CanAdmin]) — each call spends an ElevenLabs STT credit, so unlike
          the GET audio route this carries no public capability. *)
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name _req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             handle_transcribe state request reqd body))
         request reqd)
  (* Probing a TTS endpoint spends a credit on a metered provider, the same
     reason /voice/transcribe is admin-gated rather than carrying a public
     capability. *)
  |> Http.Router.post "/api/v1/voice/probe/tts" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state _agent_name _req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             handle_probe_tts request reqd body))
         request reqd)
  |> Http.Router.post "/api/v1/voice/probe/stt" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state _agent_name _req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             handle_probe_stt request reqd body))
         request reqd)
  (* Asking a provider for its catalogue spends nothing but reaches out with
     the operator's credential, so it is gated like the rest of setup. *)
  |> Http.Router.post "/api/v1/voice/voices" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun _state _agent_name _req reqd ->
           Http.Request.read_body_async reqd (fun body ->
             handle_voice_catalogue request reqd body))
         request reqd)
  (* Voice setup: read what is configured, see what a change would do, commit
     it. All three are CanAdmin -- they read and rewrite the workspace's
     runtime.toml, which GET /api/v1/voice/config deliberately does not expose
     (it answers three booleans and no endpoint identity, because it is a public
     read). *)
  |> Http.Router.get "/api/v1/voice/setup" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name _req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           match Server_voice_setup_actions.observe ~base_path with
           | Ok json -> respond_json_value_with_cors ~status:`OK request reqd json
           | Error error -> respond_voice_setup_error request reqd error)
         request reqd)
  |> Http.Router.post "/api/v1/voice/setup/preview" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name _req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           Http.Request.read_body_async reqd (fun body ->
             handle_voice_setup ~base_path
               ~act:Server_voice_setup_actions.preview request reqd body))
         request reqd)
  |> Http.Router.post "/api/v1/voice/setup" (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name _req reqd ->
           let base_path = (Mcp_server.workspace_config state).base_path in
           Http.Request.read_body_async reqd (fun body ->
             handle_voice_setup ~base_path ~act:Server_voice_setup_actions.apply request
               reqd body))
         request reqd)
