(** Voice audio clip HTTP surface (RFC-0235 P1).

    Serves synthesized TTS clips to a connected dashboard browser by
    capability token, so the browser plays the utterance instead of relying
    on the server host's speakers ([Voice_bridge_core.run_local_playback]).

      GET /api/v1/voice/audio/<token>

    The token is the 128-bit [Random_id.hex] filename written by
    [Voice_bridge_transport.make_audio_file]. Token = filename = HTTP
    capability: no per-clip ACL table, no agent identity in the URL (the
    legacy [<ts>_<agent>.mp3] name was enumerable).

    Auth is [with_public_read] — the same gate as [artifacts/<sha256>]: the
    unguessable token is the capability, exactly as a sha256 is for blobs.

    Response (200): raw bytes, Content-Type audio/mpeg. NOT a JSON envelope:
    the dashboard fetches this URL directly from an [<audio>]/[Audio]
    element, which needs the media bytes, not a wrapped payload.

   Errors:
      400 — token malformed (not 32 hex chars)
      404 — clip not on disk (never synthesized, or reaped by the 1h TTL of
            [Voice_bridge.cleanup_old_audio_files])
      413 — generated media exceeds the configured serve cap
      503 — base path unresolvable *)

open Server_utils
open Server_auth

module Http = Http_server_eio

let token_hex_len = 32 (* Random_id.hex ~bytes:16 => 2*16 hex chars *)

let is_valid_token (s : string) : bool =
  String.length s = token_hex_len
  && String.for_all
       (fun c ->
         (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'f'))
       s

let generated_media_serve_max_bytes () =
  Env_config.KeeperVision.max_image_bytes ()

(* Clip path under the same audio dir [Voice_bridge_transport.make_audio_file]
   writes to. Reuses [Voice_bridge_core.masc_base_dir] so this route and the
   synthesis side cannot drift apart. *)
let clip_path ~token =
  Filename.concat (Voice_bridge_core.masc_base_dir ()) "audio"
  |> fun dir -> Filename.concat dir (token ^ ".mp3")

let serve_clip ~token request reqd =
  let path = clip_path ~token in
  if not (Sys.file_exists path) then
    (* Never synthesized, or reaped by the 1h TTL reaper. Text-only render
       remains the dashboard fallback, so 404 is not a hard failure. *)
    respond_public_read_json_value ~status:`Not_found request reqd
      (`Assoc [ ("error", `String "not found"); ("token", `String token) ])
  else (
    (* Raw bytes — the dashboard's <audio>/Audio element fetches this URL
       directly. [Fs_compat.load_file] returns the mp3 bytes as a string;
       mp3 has no OCaml-string encoding hazard. content-length is explicit
       to avoid chunked encoding, which some clients mishandle for media. *)
    let body = Fs_compat.load_file path in
    let headers =
      Httpun.Headers.of_list
        ( ("content-type", "audio/mpeg")
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
   missing token is a soft 404 (text-only render remains the dashboard fallback),
   mirroring [serve_clip]. *)
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

let add_routes router =
  router
  |> Http.Router.prefix_get "/api/v1/voice/audio/" (fun request reqd ->
       with_public_read
         (fun _state _req reqd ->
           let path = Http.Request.path request in
           match extract_path_param ~prefix:"/api/v1/voice/audio/" path with
           | None ->
               respond_public_read_json_value ~status:`Bad_request request reqd
                 (`Assoc [ ("error", `String "token path parameter required") ])
           | Some raw when not (is_valid_token raw) ->
               respond_public_read_json_value ~status:`Bad_request request reqd
                 (`Assoc
                    [ ("error", `String "invalid token")
                    ; ("reason", `String "expected 32-char hex (128-bit)")
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
                    ; ("reason", `String "expected 32-char hex (128-bit)")
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
