[@@@warning "-32-33-69"]

(** TTS proxy — forwards text to ElevenLabs and returns audio/mpeg bytes.
    Reads ELEVENLABS_API_KEY from environment. *)
let trpg_tts_proxy ~body_str : (string, [> `Bad_request | `Internal_server_error] * string) result =
  try
    let json = Yojson.Safe.from_string body_str in
    (match Voice_bridge.tts_preview_bytes_from_request_json json with
    | Ok bytes -> Ok bytes
    | Error message -> Error (`Internal_server_error, message))
  with
  | Yojson.Json_error e ->
      Error (`Bad_request, Printf.sprintf "invalid json: %s" e)
  | exn ->
      Error (`Internal_server_error,
        Printf.sprintf "TTS proxy error: %s" (Printexc.to_string exn))

let voice_config_payload () =
  match Voice_bridge.public_config_json () with
  | Ok json -> (`OK, json)
  | Error json -> (`Error, json)

