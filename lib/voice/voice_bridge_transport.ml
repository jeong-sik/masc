(** Transport helpers for {!Voice_bridge}. *)

open Result.Syntax

let safe_agent_id value =
  String.map
    (fun c ->
       if
         (c >= 'a' && c <= 'z')
         || (c >= 'A' && c <= 'Z')
         || (c >= '0' && c <= '9')
         || c = '-'
         || c = '_'
       then c
       else '_')
    value
;;

let make_audio_file ~agent_id =
  Voice_bridge_core.ensure_audio_dir ();
  let timestamp = int_of_float (Time_compat.now ()) in
  Filename.concat
    (Filename.concat (Voice_bridge_core.masc_base_dir ()) "audio")
    (Printf.sprintf "%d_%s.mp3" timestamp (safe_agent_id agent_id))
;;

let write_text path content = Fs_compat.save_file path content
let read_file path = Fs_compat.load_file path

let resolve_api_key endpoint =
  let adapter = Voice_runtime_overlay.adapter_for_endpoint endpoint in
  match Voice_runtime_overlay.endpoint_auth_env_name endpoint with
  | Some env_name ->
    (match Sys.getenv_opt env_name with
     | Some value ->
       let trimmed = String.trim value in
       if trimmed <> ""
       then Ok trimmed
       else
         Error
           (Printf.sprintf
              "voice provider %s (endpoint %s) expects %s to be set to a non-empty value"
              adapter.canonical_name
              endpoint.id
              env_name)
     | None ->
       Error
         (Printf.sprintf
            "voice provider %s (endpoint %s) expects %s to be set to a non-empty value"
            adapter.canonical_name
            endpoint.id
            env_name))
  | None -> Ok ""
;;

let exec_gate_raw_source argv = String.concat " " (List.map Filename.quote argv)

let run_voice_status ?(timeout_sec = 35.0) ?(stdin_content = "") argv =
  Masc_exec.Exec_gate.run_argv_with_stdin_and_status
    ~actor:(Masc_exec.Agent_id.of_string "voice/bridge")
    ~raw_source:(exec_gate_raw_source argv)
    ~summary:"voice bridge exec"
    ~timeout_sec
    ~stdin_content
    argv
;;

let run_audio_http_request_to_file ~url ~headers ~body_json ~output_file =
  let body_file = Filename.temp_file "masc_voice_request" ".json" in
  Eio_guard.protect
    ~finally:(fun () ->
      try Sys.remove body_file with
      | Sys_error _ -> ())
    (fun () ->
       write_text body_file (Yojson.Safe.to_string body_json);
       let header_args =
         List.concat_map
           (fun (key, value) -> [ "-H"; Printf.sprintf "%s: %s" key value ])
           headers
       in
       let argv =
         [ "curl"; "-sS"; "--max-time"; "30"; "-X"; "POST"; url ]
         @ header_args
         @ [ "--data-binary"; "@" ^ body_file; "-o"; output_file; "-w"; "%{http_code}" ]
       in
       let status, http_code_str =
         run_voice_status
           ~timeout_sec:Env_config_runtime.Voice.http_request_timeout_sec
           argv
       in
       match status with
       | Unix.WEXITED 0 ->
         let http_code =
           Option.value ~default:0 (int_of_string_opt (String.trim http_code_str))
         in
         if http_code >= 200 && http_code < 300
         then (
           let file_size =
             try (Unix.stat output_file).st_size with
             | Unix.Unix_error _ -> 0
           in
           if file_size > 100
           then Ok file_size
           else (
             let detail =
               try read_file output_file with
               | Sys_error _ -> "response too small"
             in
             Error
               (Printf.sprintf
                  "HTTP %d returned small audio payload (%d bytes): %s"
                  http_code
                  file_size
                  detail)))
         else (
           let detail =
             try read_file output_file with
             | Sys_error _ -> "request failed"
           in
           Error (Printf.sprintf "HTTP %d: %s" http_code detail))
       | Unix.WEXITED 28 -> Error "request timed out"
       | Unix.WEXITED code -> Error (Printf.sprintf "curl exit %d" code)
       | _ -> Error "curl process failed")
;;

let speak_via_http_tts_to_file endpoint ~agent_id ~message ~voice ~model ~output_file =
  let* api_key = resolve_api_key endpoint in
  let tuning = Voice_bridge_core.tuning_for_agent agent_id in
  let* request =
    Voice_runtime_overlay.http_request_for_tts
      endpoint
      ~api_key
      ~message
      ~voice
      ~model
      ~tuning
  in
  run_audio_http_request_to_file
    ~url:request.url
    ~headers:request.headers
    ~body_json:request.body_json
    ~output_file
;;

let run_stt_multipart_request (req : Voice_runtime_overlay.stt_request) =
  let header_args =
    List.concat_map
      (fun (key, value) -> [ "-H"; Printf.sprintf "%s: %s" key value ])
      req.headers
  in
  let form_args =
    List.concat_map
      (fun (key, value) -> [ "-F"; Printf.sprintf "%s=%s" key value ])
      req.form_fields
  in
  let field_name, file_path = req.file_field in
  let file_arg = [ "-F"; Printf.sprintf "%s=@%s" field_name file_path ] in
  let argv =
    [ "curl"; "-sS"; "--fail-with-body"; "--max-time"; "30"; "-X"; "POST"; req.url ]
    @ header_args
    @ form_args
    @ file_arg
  in
  let status, body =
    run_voice_status ~timeout_sec:Env_config_runtime.Voice.http_request_timeout_sec argv
  in
  match status with
  | Unix.WEXITED 0 ->
    (match Yojson.Safe.from_string body with
     | json -> Ok json
     | exception Yojson.Json_error msg ->
       Error (Printf.sprintf "STT response parse error: %s" msg))
  | Unix.WEXITED 22 ->
    Error
      (Printf.sprintf
         "STT HTTP error: %s"
         (if String.length body > 200 then String.sub body 0 200 else body))
  | Unix.WEXITED 28 -> Error "STT request timed out"
  | Unix.WEXITED code -> Error (Printf.sprintf "STT curl exit %d" code)
  | _ -> Error "STT curl process failed"
;;

let transcribe_via_http_stt endpoint ~audio_file ~model =
  let* api_key = resolve_api_key endpoint in
  let* request =
    Voice_runtime_overlay.stt_request_for_endpoint endpoint ~api_key ~audio_file ~model
  in
  run_stt_multipart_request request
;;
