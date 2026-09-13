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

(* A voice command run with a refusal kept apart from an exit.

   The tuple runner above answers a program that never started with exit 127,
   and it answers every other failure before the process -- a permission
   denied, a working directory that would not open -- with the same 127.
   Reading 127 as "not installed" gave those the wrong cause. Measured
   2026-09-13: a whisper command pointed at a file with no execute bit was
   reported as "... is not installed", which reinstalling does not change.

   [Ok] carries the output exactly as the tuple runner renders it, so a
   transcript read from stdout on success is the same bytes as before. *)
let run_voice_command ~timeout_sec argv =
  match Process_eio.run_argv_with_status_split_or_refusal ~timeout_sec argv with
  | Ok (status, stdout, stderr) ->
    Ok (status, Process_eio_stderr.output_for_status ~status ~stdout ~stderr)
  | Error refusal -> Error refusal
;;

let command_name = function
  | command :: _ -> command
  | [] -> "the command"
;;

(* Only a program that is not there is called not installed. Every other
   refusal keeps the runner's own sentence: naming an install for a
   permission error sends the operator to fetch what they already have. *)
let command_refusal_reason ~command (refusal : Process_eio.spawn_refusal) =
  match refusal with
  | Process_eio.Executable_not_found _ -> Printf.sprintf "%s is not installed" command
  | ( Process_eio.Empty_argv
    | Process_eio.Spawn_failed _
    | Process_eio.Child_setup_failed _
    | Process_eio.Cwd_unavailable _ ) as refusal ->
    Printf.sprintf "%s could not start: %s" command
      (Process_eio.spawn_refusal_to_string refusal)
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

let run_audio_command_to_file (req : Voice_runtime_overlay.command_request) ~output_file =
  let command = command_name req.Voice_runtime_overlay.argv in
  match
    run_voice_command
      ~timeout_sec:Env_config_runtime.Voice.http_request_timeout_sec
      req.Voice_runtime_overlay.argv
  with
  | Error refusal -> Error (command_refusal_reason ~command refusal)
  | Ok (status, output) ->
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
        (Printf.sprintf "%s exited cleanly and wrote %d bytes of audio" command file_size)
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
  run_audio_command_to_file request ~output_file
;;

(* Up to [count] bytes from the start of a file; fewer when the file is
   shorter. *)
let leading_bytes ~count path =
  let read channel =
    let buffer = Bytes.create count in
    let rec fill filled =
      if filled = count
      then filled
      else (
        match input channel buffer filled (count - filled) with
        | 0 -> filled
        | read -> fill (filled + read))
    in
    Bytes.sub_string buffer 0 (fill 0)
  in
  match open_in_bin path with
  | exception Sys_error message -> Error message
  | channel ->
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
        match read channel with
        | bytes -> Ok bytes
        | exception Sys_error message -> Error message)
;;

(* Transcribing by running a command. The transcript is the command's own
   output, so what comes back is text rather than the JSON an HTTP endpoint
   answers with; the caller shapes it.

   The audio's container is checked before the command runs, because the
   command cannot be asked afterwards: whisper-cli answers a container it does
   not decode with exit 0 and an empty transcript, the same answer silence
   gets. See {!Voice_runtime_overlay.whisper_cli_input}. *)
let transcribe_via_command endpoint ~audio_file ~model =
  let* request =
    Voice_runtime_overlay.stt_command_for_endpoint endpoint ~audio_file ~model
  in
  let command = command_name request.Voice_runtime_overlay.argv in
  let* () =
    match
      leading_bytes ~count:Voice_runtime_overlay.audio_container_probe_bytes audio_file
    with
    | Error message -> Error (Printf.sprintf "the audio could not be read: %s" message)
    | Ok bytes ->
      let container = Voice_runtime_overlay.audio_container_of_leading_bytes bytes in
      (match Voice_runtime_overlay.whisper_cli_input container with
       | Voice_runtime_overlay.Reads | Voice_runtime_overlay.Not_measured -> Ok ()
       | Voice_runtime_overlay.Does_not_read ->
         Error
           (Printf.sprintf
              "%s reads WAV, FLAC or MP3, and this audio is %s"
              command
              (Voice_runtime_overlay.audio_container_name container)))
  in
  match
    run_voice_command
      ~timeout_sec:Env_config_runtime.Voice.http_request_timeout_sec
      request.Voice_runtime_overlay.argv
  with
  | Error refusal -> Error (command_refusal_reason ~command refusal)
  | Ok (status, output) ->
  match status with
  | Unix.WEXITED 0 -> Ok (String.trim output)
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
  let command = command_name request.Voice_runtime_overlay.argv in
  match
    run_voice_command
      ~timeout_sec:Env_config_runtime.Voice.http_request_timeout_sec
      request.Voice_runtime_overlay.argv
  with
  | Error refusal -> Error (command_refusal_reason ~command refusal)
  | Ok (status, output) ->
  match status with
  | Unix.WEXITED 0 -> Ok output
  | Unix.WEXITED code ->
    Error
      (Printf.sprintf "%s exit %d: %s" command code
         (command_failure_reason output))
  | Unix.WSIGNALED sig_num ->
    Error (Printf.sprintf "%s killed by signal %d" command sig_num)
  | Unix.WSTOPPED sig_num ->
    Error (Printf.sprintf "%s stopped by signal %d" command sig_num)
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
  (* See sibling TTS dispatch above (line ~121) for rationale: closed-sum
     named arms over [Unix.process_status] expose the signal number
     that the previous wildcard discarded. *)
  | Unix.WSIGNALED sig_num ->
    Error (Printf.sprintf "STT curl killed by signal %d" sig_num)
  | Unix.WSTOPPED sig_num ->
    Error (Printf.sprintf "STT curl stopped by signal %d" sig_num)
;;

(* Catalogue credentials go through stdin so process arguments do not expose
   them. Curl and the process runner use the same configured HTTP deadline. *)
let run_voice_listing_request ~timeout_sec (req : Voice_runtime_overlay.voice_listing_request) =
  let stdin_content =
    String.concat ""
      (List.map
         (fun (key, value) -> Printf.sprintf "%s: %s\n" key value)
         req.listing_headers)
  in
  let argv =
    [ "curl"; "-sS"; "--fail-with-body"; "--max-time"; string_of_float timeout_sec
    ; "--header"; "@-"; req.listing_url
    ]
  in
  let status, body =
    run_voice_status ~timeout_sec ~stdin_content argv
  in
  match status with
  | Unix.WEXITED 0 ->
    (match Yojson.Safe.from_string body with
     | json -> Ok json
     | exception Yojson.Json_error msg ->
       Error (Printf.sprintf "voice listing parse error: %s" msg))
  | Unix.WEXITED 22 ->
    Error
      (Printf.sprintf
         "voice listing HTTP error: %s"
         (if String.length body > 200 then String.sub body 0 200 else body))
  | Unix.WEXITED 28 -> Error "voice listing request timed out"
  | Unix.WEXITED code -> Error (Printf.sprintf "voice listing curl exit %d" code)
  (* Named for the same reason the two dispatches above are: a wildcard here
     discards which signal ended it. *)
  | Unix.WSIGNALED sig_num ->
    Error (Printf.sprintf "voice listing curl killed by signal %d" sig_num)
  | Unix.WSTOPPED sig_num ->
    Error (Printf.sprintf "voice listing curl stopped by signal %d" sig_num)
;;

type catalogue_continuation = Complete | Next_page of string

type catalogue_page =
  { voices : Yojson.Safe.t list
  ; continuation : catalogue_continuation
  }

(* ElevenLabs GET /v2/voices, verified against its official contract 2026-09-13:
   https://elevenlabs.io/docs/api-reference/voices/search
   total_count is a changing snapshot, not a pagination boundary. *)
let catalogue_page_of_json = function
  | `Assoc fields ->
    let field name = List.filter_map (fun (key, value) ->
      if String.equal key name then Some value else None) fields in
    let* voices =
      match field "voices" with
      | [ `List voices ] -> Ok voices
      | _ -> Error "voice catalogue page needs one voices list"
    in
    let* has_more =
      match field "has_more" with
      | [ `Bool value ] -> Ok value
      | _ -> Error "voice catalogue page needs one boolean has_more"
    in
    let* next_page =
      match field "next_page_token" with
      | [] | [ `Null ] -> Ok None
      | [ `String token ] when String.trim token <> "" -> Ok (Some token)
      | _ -> Error "voice catalogue page has an invalid next_page_token"
    in
    let* continuation =
      match has_more, next_page with
      | false, _ -> Ok Complete
      | true, Some token -> Ok (Next_page token)
      | true, None -> Error "voice catalogue has_more requires a next_page_token"
    in
    Ok { voices; continuation }
  | _ -> Error "voice catalogue page is not an object"
;;

module Catalogue_cursors = Set.Make (String)

let collect_voice_catalogue ~remaining_seconds ~fetch_page
    (request : Voice_runtime_overlay.voice_listing_request) =
  let rec collect visited reversed page_request =
    let timeout_sec = remaining_seconds () in
    if timeout_sec <= 0. then Error "voice catalogue scan timed out"
    else
      let* json = fetch_page ~timeout_sec page_request in
      let* page = catalogue_page_of_json json in
      if remaining_seconds () <= 0. then Error "voice catalogue scan timed out"
      else
        let reversed = List.rev_append page.voices reversed in
        match page.continuation with
        | Complete -> Ok (`Assoc [ "voices", `List (List.rev reversed) ])
        | Next_page token ->
          if Catalogue_cursors.mem token visited then
            Error "voice catalogue repeated a pagination cursor"
          else
            let uri = Uri.of_string request.listing_url in
            let listing_url =
              Uri.to_string (Uri.add_query_param' uri ("next_page_token", token))
            in
            collect (Catalogue_cursors.add token visited) reversed
              { request with listing_url }
  in
  collect Catalogue_cursors.empty [] request
;;

let list_voices_via_http endpoint =
  let deadline =
    Monotonic_deadline.after ~seconds:Env_config_runtime.Voice.http_request_timeout_sec
  in
  let* api_key = resolve_api_key endpoint in
  let* request = Voice_runtime_overlay.voice_listing_request_for_endpoint endpoint ~api_key in
  collect_voice_catalogue
    ~remaining_seconds:(fun () -> Monotonic_deadline.remaining_seconds deadline)
    ~fetch_page:run_voice_listing_request request
;;

let transcribe_via_http_stt endpoint ~audio_file ~model =
  let* api_key = resolve_api_key endpoint in
  let* request =
    Voice_runtime_overlay.stt_request_for_endpoint endpoint ~api_key ~audio_file ~model
  in
  run_stt_multipart_request request
;;
