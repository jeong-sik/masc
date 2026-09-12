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

let make_audio_file ~format =
  Voice_bridge_core.ensure_audio_dir ();
  (* The token is both the filename and the HTTP capability for
     /api/v1/voice/audio/:token (RFC-0235 P1). agent_id is deliberately
     absent from the filename: a logged-in operator viewing one keeper
     must not be able to enumerate another keeper's clips by guessing
     <ts>_<agent>. 16 bytes = 128-bit unguessable. *)
  let token = Random_id.hex ~bytes:16 in
  (* The extension is the format the caller is about to write, not a fixed
     one: a writer handed a name it cannot encode fails without saying so
     (see [Voice_bridge_core.clip_format]). *)
  Filename.concat
    (Voice_bridge_core.audio_dir ())
    (token ^ Voice_bridge_core.clip_extension format)
;;

(* The tail of a failed command's output, because that is where the reason
   is. Measured 2026-09-13: whisper-cli printed 9 lines of backend loading
   before "failed to open <model>", so a head-first cut reported which Metal
   library loaded and never the missing file. *)
let command_failure_reason_bytes = 400

let command_failure_reason output =
  let length = String.length output in
  if length <= command_failure_reason_bytes
  then output
  else
    "..."
    ^ String.sub
        output
        (length - command_failure_reason_bytes)
        command_failure_reason_bytes
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

let run_voice_status ?(timeout_sec = 35.0) ?(stdin_content = "") argv =
  Process_eio.run_argv_with_stdin_and_status
    ~timeout_sec
    ~stdin_content
    argv
;;

(* The endpoint's own timeout when it names one. [timeout_seconds] has been in
   the voice configuration, its writer, the HTTP routes and the wizard from the
   start and nothing read it: an operator who set it got the workspace-wide
   value anyway. voice_config refuses a field it would silently drop for
   exactly this reason -- "a setting that is silently dropped reads as a
   setting that took" -- and this one was dropped.

   A value at or below zero is not a shorter wait but a wait that cannot
   happen. The configuration reader does not refuse one yet (#35641), so it is
   not obeyed here either. *)
let endpoint_timeout_sec (endpoint : Voice_config.endpoint) =
  match endpoint.Voice_config.timeout_seconds with
  | Some seconds when seconds > 0. -> seconds
  | Some _ | None -> Env_config_runtime.Voice.http_request_timeout_sec
;;

(* curl carries the same deadline as the wait around it. Left at a constant,
   curl ended the request at 30 seconds whatever the endpoint or the workspace
   asked for, so the longer of the two settings could never take effect. *)
let max_time_arg timeout_sec = [ "--max-time"; Printf.sprintf "%g" timeout_sec ]

let run_audio_http_request_to_file ~timeout_sec ~url ~headers ~body_json ~output_file =
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
         [ "curl"; "-sS" ] @ max_time_arg timeout_sec @ [ "-X"; "POST"; url ]
         @ header_args
         @ [ "--data-binary"; "@" ^ body_file; "-o"; output_file; "-w"; "%{http_code}" ]
       in
       let status, http_code_str = run_voice_status ~timeout_sec argv in
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
       (* [Unix.process_status] is a closed sum of WEXITED / WSIGNALED
          / WSTOPPED — the previous [| _ -> "curl process failed"]
          discarded both the variant and the signal number, leaving
          operators unable to distinguish OOM-kill (SIGKILL=9) /
          deadline-kill (SIGTERM=15) / Ctrl-C (SIGINT=2) / pipe break
          (SIGPIPE=13).  Naming both arms makes the dispatch typed
          exhaustive and surfaces [sig_num] so [kill -l <n>] decodes
          it.  Mirrors sibling pattern in
          [lib/tool_local_runtime_http.ml:79-82]. *)
       | Unix.WSIGNALED sig_num ->
         Error (Printf.sprintf "TTS curl killed by signal %d" sig_num)
       | Unix.WSTOPPED sig_num ->
         Error (Printf.sprintf "TTS curl stopped by signal %d" sig_num))
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
    ~timeout_sec:(endpoint_timeout_sec endpoint)
    ~url:request.url
    ~headers:request.headers
    ~body_json:request.body_json
    ~output_file
;;

(* Running a command that writes the audio, for the kinds that are a command
   rather than an address. The file it produces is judged the same way the HTTP
   path judges its download: a command can exit 0 and write nothing, and a
   caller told "spoke" about an empty file has been told the wrong thing. *)
let smallest_believable_audio_bytes = 100

let run_audio_command_to_file ~timeout_sec (req : Voice_runtime_overlay.command_request) ~output_file =
  let status, output = run_voice_status ~timeout_sec req.Voice_runtime_overlay.argv in
  match status with
  | Unix.WEXITED 0 ->
    let file_size =
      try (Unix.stat output_file).st_size with
      | Unix.Unix_error _ -> 0
    in
    if file_size > smallest_believable_audio_bytes
    then Ok file_size
    else
      Error
        (Printf.sprintf
           "%s exited cleanly and wrote %d bytes of audio"
           (match req.Voice_runtime_overlay.argv with
            | command :: _ -> command
            | [] -> "the command")
           file_size)
  | Unix.WEXITED 127 ->
    Error
      (Printf.sprintf
         "%s is not installed"
         (match req.Voice_runtime_overlay.argv with
          | command :: _ -> command
          | [] -> "the command"))
  | Unix.WEXITED code ->
    Error
      (Printf.sprintf "voice command exit %d: %s" code
         (command_failure_reason output))
  (* Named rather than wildcarded, for the reason the dispatches above are:
     a wildcard discards which signal ended it. *)
  | Unix.WSIGNALED sig_num ->
    Error (Printf.sprintf "voice command killed by signal %d" sig_num)
  | Unix.WSTOPPED sig_num ->
    Error (Printf.sprintf "voice command stopped by signal %d" sig_num)
;;

let speak_via_command_to_file endpoint ~message ~voice ~output_file =
  let* request =
    Voice_runtime_overlay.tts_command_for_endpoint endpoint ~voice ~message ~output_file
  in
  run_audio_command_to_file ~timeout_sec:(endpoint_timeout_sec endpoint) request ~output_file
;;

(* Transcribing by running a command. The transcript is the command's own
   output, so what comes back is text rather than the JSON an HTTP endpoint
   answers with; the caller shapes it. *)
let transcribe_via_command endpoint ~audio_file ~model =
  let* request =
    Voice_runtime_overlay.stt_command_for_endpoint endpoint ~audio_file ~model
  in
  let status, output =
    run_voice_status
      ~timeout_sec:(endpoint_timeout_sec endpoint)
      request.Voice_runtime_overlay.argv
  in
  let command =
    match request.Voice_runtime_overlay.argv with
    | command :: _ -> command
    | [] -> "the command"
  in
  match status with
  | Unix.WEXITED 0 -> Ok (String.trim output)
  | Unix.WEXITED 127 -> Error (Printf.sprintf "%s is not installed" command)
  | Unix.WEXITED code ->
    Error
      (Printf.sprintf "%s exit %d: %s" command code
         (command_failure_reason output))
  | Unix.WSIGNALED sig_num ->
    Error (Printf.sprintf "%s killed by signal %d" command sig_num)
  | Unix.WSTOPPED sig_num ->
    Error (Printf.sprintf "%s stopped by signal %d" command sig_num)
;;

(* Asking a command which voices it has. The answer is its stdout, so what
   comes back is text; parsing it belongs to the caller. *)
let list_voices_via_command endpoint =
  let* request = Voice_runtime_overlay.voice_listing_command_for_endpoint endpoint in
  let command =
    match request.Voice_runtime_overlay.argv with
    | command :: _ -> command
    | [] -> "the command"
  in
  let status, output =
    run_voice_status
      ~timeout_sec:(endpoint_timeout_sec endpoint)
      request.Voice_runtime_overlay.argv
  in
  match status with
  | Unix.WEXITED 0 -> Ok output
  | Unix.WEXITED 127 -> Error (Printf.sprintf "%s is not installed" command)
  | Unix.WEXITED code ->
    Error
      (Printf.sprintf "%s exit %d: %s" command code
         (command_failure_reason output))
  | Unix.WSIGNALED sig_num ->
    Error (Printf.sprintf "%s killed by signal %d" command sig_num)
  | Unix.WSTOPPED sig_num ->
    Error (Printf.sprintf "%s stopped by signal %d" command sig_num)
;;

let run_stt_multipart_request ~timeout_sec (req : Voice_runtime_overlay.stt_request) =
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
    [ "curl"; "-sS"; "--fail-with-body" ]
    @ max_time_arg timeout_sec
    @ [ "-X"; "POST"; req.url ]
    @ header_args
    @ form_args
    @ file_arg
  in
  let status, body = run_voice_status ~timeout_sec argv in
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
  (* See sibling TTS dispatch above (line ~121) for rationale: closed-sum
     named arms over [Unix.process_status] expose the signal number
     that the previous wildcard discarded. *)
  | Unix.WSIGNALED sig_num ->
    Error (Printf.sprintf "STT curl killed by signal %d" sig_num)
  | Unix.WSTOPPED sig_num ->
    Error (Printf.sprintf "STT curl stopped by signal %d" sig_num)
;;

let transcribe_via_http_stt endpoint ~audio_file ~model =
  let* api_key = resolve_api_key endpoint in
  let* request =
    Voice_runtime_overlay.stt_request_for_endpoint endpoint ~api_key ~audio_file ~model
  in
  run_stt_multipart_request ~timeout_sec:(endpoint_timeout_sec endpoint) request
;;
