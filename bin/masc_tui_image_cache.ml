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
  | Decoder_exit of { code : int }
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
         else Decoder_exit { code })
  | Unix.WSIGNALED signal -> Some (Decoder_signaled { signal })
  | Unix.WSTOPPED signal -> Some (Decoder_stopped { signal })

let decode_failure_text = function
  | Decoder_missing -> "decoder executable was not found"
  | Decoder_exit { code } -> Printf.sprintf "decoder exited %d" code
  | Decoder_signaled { signal } -> Printf.sprintf "decoder was killed by signal %d" signal
  | Decoder_stopped { signal } -> Printf.sprintf "decoder was stopped by signal %d" signal
  | No_frame_written -> "decoder wrote no frame"
  | Frame_unreadable { detail } -> "the decoded frame could not be read: " ^ detail

let discard path = try Sys.remove path with Sys_error _ -> ()

let read_bytes path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error detail -> Error detail

let input_path ~cache_dir url =
  Filename.concat cache_dir ("img_" ^ Digest.to_hex (Digest.string url))

let png_path ~cache_dir input =
  Filename.concat cache_dir
    ("conv_" ^ Digest.to_hex (Digest.string (input ^ "_converted_png")) ^ ".png")

let invalidate_download ~cache_dir url =
  let input = input_path ~cache_dir url in
  discard input;
  discard (png_path ~cache_dir input)

(* A cache path is derived from the URL, so every worker on one URL names the
   same file. Writing it in place makes two workers visible to each other in the
   worst way: a retry invalidating the entry can delete the file a visual render
   is mid-download on, and two downloads curl into one path and each read the
   other's half. So an attempt writes a file of its own and renames it over the
   target, which is atomic within a directory -- a reader sees the whole old file
   or the whole new one, never a partial write, and a delete underneath an
   attempt costs that attempt nothing. *)
let attempt_path ~cache_dir ~prefix ~suffix =
  try Ok (Filename.temp_file ~temp_dir:cache_dir prefix suffix) with
  | Sys_error detail -> Error detail

(* Published only after the bytes are judged, so a refused download never sits
   in the cache waiting to be discarded by whoever reads it next. *)
let publish ~attempt ~target =
  try Sys.rename attempt target; Ok target with
  | Sys_error detail -> discard attempt; Error detail

let download ~run ~cache_dir url =
  let target = input_path ~cache_dir url in
  let judge bytes = verdict_of_bytes bytes in
  let read_cached () =
    match read_bytes target with
    | Error detail -> discard target; Error (Cache_unreadable { detail })
    | Ok bytes ->
      match judge bytes with
      | Known_image _ | Unknown_signature -> Ok target
      | Empty -> discard target; Error Empty_body
  in
  let fetch () =
    match attempt_path ~cache_dir ~prefix:"dl_" ~suffix:".part" with
    | Error detail -> Error (Cache_unreadable { detail })
    | Ok attempt ->
      let status = run (Printf.sprintf "curl -s -L --fail --max-time 5 -o %s %s"
        (Filename.quote attempt) (Filename.quote url)) in
      (match fetch_failure_of_status status ~body_present:(Sys.file_exists attempt) with
       | Some failure -> discard attempt; Error (Fetch_failed failure)
       | None ->
         match read_bytes attempt with
         | Error detail -> discard attempt; Error (Cache_unreadable { detail })
         | Ok bytes ->
           match judge bytes with
           | Empty -> discard attempt; Error Empty_body
           | Known_image _ | Unknown_signature ->
             (match publish ~attempt ~target with
              | Ok path -> Ok path
              | Error detail -> Error (Cache_unreadable { detail })))
  in
  if Sys.file_exists target then
    match read_cached () with Ok path -> Ok path | Error _ -> fetch ()
  else fetch ()

let run_decoder ~run ~output_path command =
  discard output_path;
  let status = run command in
  match decode_failure_of_status status ~output_present:(Sys.file_exists output_path) with
  | Some failure -> discard output_path; Error failure
  | None ->
    match read_bytes output_path with
    | Error detail -> discard output_path; Error (Frame_unreadable { detail })
    | Ok "" -> discard output_path; Error No_frame_written
    | Ok _ -> Ok output_path

type converter = Sips | Image_magick | Ffmpeg
type conversion_failure = (converter * decode_failure) list

let converter_name = function
  | Sips -> "sips" | Image_magick -> "convert" | Ffmpeg -> "ffmpeg"

let conversion_failure_text failures =
  String.concat "; " (List.map (fun (converter, failure) ->
    converter_name converter ^ ": " ^ decode_failure_text failure) failures)

let convert_to_png ~run ~cache_dir input =
  let target = png_path ~cache_dir input in
  match read_bytes target with
  | Ok bytes when String.length bytes > 0 -> Ok target
  | Ok _ | Error _ ->
    let source = Filename.quote input in
    let commands =
      [ Sips,
        (fun out ->
          Printf.sprintf "sips -s format png %s --out %s >/dev/null 2>&1" source
            (Filename.quote out))
      ; Image_magick,
        (fun out ->
          Printf.sprintf "convert %s %s >/dev/null 2>&1" source (Filename.quote out))
      ; Ffmpeg,
        (fun out ->
          Printf.sprintf "ffmpeg -y -i %s %s >/dev/null 2>&1" source (Filename.quote out))
      ]
    in
    match attempt_path ~cache_dir ~prefix:"conv_attempt_" ~suffix:".png" with
    | Error detail -> Error [ Sips, Frame_unreadable { detail } ]
    | Ok attempt_file ->
      let rec attempt failures = function
        | [] -> discard attempt_file; Error (List.rev failures)
        | (converter, command) :: rest ->
          (* The decoder writes into this attempt's own file; only a frame
             that was actually written is renamed over the shared path. *)
          match run_decoder ~run ~output_path:attempt_file (command attempt_file) with
          | Ok _ ->
            (* Published once, after a converter actually wrote a frame. *)
            (match publish ~attempt:attempt_file ~target with
             | Ok path -> Ok path
             | Error detail ->
               Error (List.rev ((converter, Frame_unreadable { detail }) :: failures)))
          | Error failure -> attempt ((converter, failure) :: failures) rest
      in
      attempt [] commands

let prepare_png ~run ~cache_dir url =
  match download ~run ~cache_dir url with
  | Error error -> Error (download_error_text error)
  | Ok input ->
    match read_bytes input with
    | Error detail -> Error detail
    | Ok bytes ->
      match verdict_of_bytes bytes with
      | Known_image { media_type = "image/png" } -> Ok bytes
      | Known_image _ | Unknown_signature | Empty ->
        match convert_to_png ~run ~cache_dir input with
        | Ok path -> read_bytes path
        | Error failures -> Error (conversion_failure_text failures)
