type verdict =
  | Known_image of { media_type : string }
  | Unknown_signature
  | Empty

let verdict_of_bytes bytes =
  if String.length bytes = 0 then Empty
  else
    match Masc.Keeper_vision_tool.sniff_image_media_type bytes with
    | Ok media_type -> Known_image { media_type }
    | Error _ -> Unknown_signature

(* Exit statuses with a documented meaning. curl(1) "EXIT CODES"; sh(1):
   a command that is not found exits 127. *)
let curl_exit_could_not_resolve_host = 6
let curl_exit_could_not_connect = 7
let curl_exit_http_error_status = 22
let curl_exit_operation_timeout = 28
let sh_exit_command_not_found = 127

type fetch_failure =
  | Http_error_status
  | Operation_timeout
  | Could_not_resolve_host
  | Could_not_connect
  | Curl_missing
  | Curl_exit of { code : int }
  | Curl_signaled of { signal : int }
  | Curl_stopped of { signal : int }
  | No_body_written

let fetch_failure_of_status status ~body_present =
  match status with
  | Unix.WEXITED 0 -> if body_present then None else Some No_body_written
  | Unix.WEXITED code ->
      Some
        (if code = curl_exit_http_error_status then Http_error_status
         else if code = curl_exit_operation_timeout then Operation_timeout
         else if code = curl_exit_could_not_resolve_host then Could_not_resolve_host
         else if code = curl_exit_could_not_connect then Could_not_connect
         else if code = sh_exit_command_not_found then Curl_missing
         else Curl_exit { code })
  | Unix.WSIGNALED signal -> Some (Curl_signaled { signal })
  | Unix.WSTOPPED signal -> Some (Curl_stopped { signal })

let fetch_failure_text = function
  | Http_error_status -> "the server answered with an HTTP error status"
  | Operation_timeout -> "the download timed out"
  | Could_not_resolve_host -> "the host could not be resolved"
  | Could_not_connect -> "the host could not be reached"
  | Curl_missing -> "curl is not installed"
  | Curl_exit { code } -> Printf.sprintf "curl exited %d" code
  | Curl_signaled { signal } -> Printf.sprintf "curl was killed by signal %d" signal
  | Curl_stopped { signal } -> Printf.sprintf "curl was stopped by signal %d" signal
  | No_body_written -> "curl wrote no body"

type download_error =
  | Fetch_failed of fetch_failure
  | Empty_body
  | Cache_unreadable of { detail : string }

let download_error_text = function
  | Fetch_failed failure -> "could not download the image: " ^ fetch_failure_text failure
  | Empty_body -> "the URL answered with an empty body"
  | Cache_unreadable { detail } -> "the cached image could not be read: " ^ detail

type decode_failure =
  | Decoder_missing
  | Decoder_rejected of { code : int }
  | Decoder_signaled of { signal : int }
  | Decoder_stopped of { signal : int }
  | No_frame_written
  | Frame_unreadable of { detail : string }

let decode_failure_of_status status ~output_present =
  match status with
  | Unix.WEXITED 0 -> if output_present then None else Some No_frame_written
  | Unix.WEXITED code ->
      Some
        (if code = sh_exit_command_not_found then Decoder_missing
         else Decoder_rejected { code })
  | Unix.WSIGNALED signal -> Some (Decoder_signaled { signal })
  | Unix.WSTOPPED signal -> Some (Decoder_stopped { signal })

let decode_failure_discards_body = function
  | Decoder_rejected _ -> true
  | Decoder_missing | Decoder_signaled _ | Decoder_stopped _ | No_frame_written
  | Frame_unreadable _ ->
      false

let decode_failure_text = function
  | Decoder_missing -> "ffmpeg is not installed"
  | Decoder_rejected { code } -> Printf.sprintf "ffmpeg rejected the body (exit %d)" code
  | Decoder_signaled { signal } -> Printf.sprintf "ffmpeg was killed by signal %d" signal
  | Decoder_stopped { signal } -> Printf.sprintf "ffmpeg was stopped by signal %d" signal
  | No_frame_written -> "ffmpeg wrote no frame"
  | Frame_unreadable { detail } -> "the decoded frame could not be read: " ^ detail
