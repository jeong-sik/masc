[@@@warning "-32-69"]

(** TTS proxy — forwards text to ElevenLabs and returns audio/mpeg bytes.
    Reads ELEVENLABS_API_KEY from environment. *)
let trpg_tts_proxy ~body_str : (string, [> `Bad_request | `Internal_server_error] * string) result =
  try
    let json = Yojson.Safe.from_string body_str in
    let open Yojson.Safe.Util in
    let text =
      match json |> member "text" |> to_string_option with
      | Some t when String.length (String.trim t) > 0 -> String.trim t
      | _ -> raise (Yojson.Json_error "missing or empty 'text' field")
    in
    let voice_id =
      match json |> member "voice_id" |> to_string_option with
      | Some v when String.length v > 0 -> v
      | _ -> "21m00Tcm4TlvDq8ikWAM"  (* Rachel *)
    in
    let model_id =
      match json |> member "voice_model" |> to_string_option with
      | Some m when String.length m > 0 -> m
      | _ -> "eleven_multilingual_v2"
    in
    match Sys.getenv_opt "ELEVENLABS_API_KEY" with
    | None | Some "" ->
        Error (`Internal_server_error, "ELEVENLABS_API_KEY not configured")
    | Some api_key ->
        let url = Printf.sprintf
          "https://api.elevenlabs.io/v1/text-to-speech/%s" voice_id in
        let req_body = Yojson.Safe.to_string (`Assoc [
          ("text", `String text);
          ("model_id", `String model_id);
          ("voice_settings", `Assoc [
            ("stability", `Float 0.5);
            ("similarity_boost", `Float 0.75);
            ("style", `Float 0.0);
          ]);
        ]) in
        let headers = [
          ("xi-api-key", api_key);
          ("Content-Type", "application/json");
          ("Accept", "audio/mpeg");
        ] in
        let header_args = List.concat_map (fun (k, v) ->
          ["-H"; Printf.sprintf "%s: %s" k v]
        ) headers in
        let argv = ["curl"; "-s"; "--max-time"; "30";
                    "-X"; "POST"; url] @ header_args @ ["-d"; "@-"] in
        let (status, raw) = Process_eio.run_argv_with_stdin_and_status
          ~timeout_sec:35.0
          ~stdin_content:req_body
          argv in
        (match status with
         | Unix.WEXITED 0 ->
             if String.length raw < 100 then
               (* ElevenLabs returns JSON error bodies which are short *)
               (try
                 let err_json = Yojson.Safe.from_string raw in
                 let detail = err_json |> member "detail" |> member "message"
                   |> to_string_option |> Option.value ~default:raw in
                 Error (`Internal_server_error,
                   Printf.sprintf "ElevenLabs error: %s" detail)
               with _ -> Ok raw)
             else
               Ok raw
         | Unix.WEXITED 28 ->
             Error (`Internal_server_error, "ElevenLabs request timed out")
         | Unix.WEXITED code ->
             Error (`Internal_server_error,
               Printf.sprintf "curl exit %d calling ElevenLabs" code)
         | _ ->
             Error (`Internal_server_error, "ElevenLabs request failed"))
  with
  | Yojson.Json_error e ->
      Error (`Bad_request, Printf.sprintf "invalid json: %s" e)
  | exn ->
      Error (`Internal_server_error,
        Printf.sprintf "TTS proxy error: %s" (Printexc.to_string exn))
