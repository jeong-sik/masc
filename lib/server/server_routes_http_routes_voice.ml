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
