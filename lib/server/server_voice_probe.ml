let audio_suffix_of_content_type header =
  let media_type =
    match header with
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

let report attempts =
  `Assoc [ ("endpoints", `List (List.map Voice_bridge.probe_attempt_json attempts)) ]

let message_of_body body =
  match Yojson.Safe.from_string body with
  (* Narrowed to what the parser throws: a wildcard here would swallow
     Eio.Cancel.Cancelled and leave a cancelled fiber reporting a parse
     failure. *)
  | exception Yojson.Json_error _ -> Error "the request body is not JSON"
  | `Assoc fields ->
    (match List.assoc_opt "message" fields with
     | Some (`String text) when String.trim text <> "" -> Ok text
     | Some _ | None ->
       Error "a probe needs a non-empty \"message\" for the endpoints to synthesize")
  | _ ->
    Error "a probe needs a non-empty \"message\" for the endpoints to synthesize"

let tts_report ~body =
  match message_of_body body with
  | Error reason -> Error reason
  | Ok message ->
    (match Voice_bridge.probe_tts ~message () with
     | Ok attempts -> Ok (report attempts)
     | Error reason -> Error reason)

let stt_report ~content_type ~body =
  if String.length body = 0 then Error "empty audio body"
  else
    Eio.Switch.run (fun sw ->
      let tmp =
        Filename.temp_file
          "masc_voice_probe_"
          (audio_suffix_of_content_type content_type)
      in
      Eio.Switch.on_release sw (fun () ->
        try Sys.remove tmp with
        | Sys_error _ -> ());
      Fs_compat.save_file tmp body;
      match Voice_bridge.probe_stt ~audio_file:tmp () with
      | Ok attempts -> Ok (report attempts)
      | Error reason -> Error reason)
