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

let has_png_structure ?(single_frame = false) bytes =
  let length = String.length bytes in
  let be32 offset =
    (Char.code bytes.[offset] lsl 24) lor (Char.code bytes.[offset+1] lsl 16)
    lor (Char.code bytes.[offset+2] lsl 8) lor Char.code bytes.[offset+3] in
  let rec chunks offset first has_data =
    if offset > length - 12 then false else
    let size=be32 offset in
    if size < 0 || size > length - offset - 12 then false else
    let kind=String.sub bytes (offset+4) 4 in
    let next=offset+12+size in
    if first then kind="IHDR" && size=13 && chunks next false false
    else match kind with
      | "IHDR" -> false
      | ("acTL" | "fcTL" | "fdAT") when single_frame -> false
      (* Colour-cell fitting uses the stored dimensions. Defer metadata that
         can alter their display orientation or pixel aspect to the original. *)
      | "eXIf" when single_frame -> false
      | ("tEXt" | "zTXt") when single_frame ->
          let exif_keyword = "Raw profile type exif\000" in
          not (size >= String.length exif_keyword
               && String.sub bytes (offset+8) (String.length exif_keyword) = exif_keyword)
          && chunks next false has_data
      | "pHYs" when single_frame ->
          size = 9 && be32 (offset+8) = be32 (offset+12) && chunks next false has_data
      | "IDAT" -> chunks next false (has_data || size > 0)
      | "IEND" -> size=0 && has_data && next=length
      | _ -> chunks next false has_data in
  String.starts_with ~prefix:"\137PNG\r\n\026\n" bytes
  && (match Masc.Keeper_image_dimensions.image_dimensions bytes with
      | Some (width,height) -> width > 0 && height > 0
      | None -> false)
  && chunks 8 true false

(* Exit statuses with a documented meaning. curl(1) "EXIT CODES"; sh(1):
   a command that is not found exits 127. *)
let curl_exit_could_not_resolve_host = 6
let curl_exit_could_not_connect = 7
let curl_exit_http_error_status = 22
let curl_exit_operation_timeout = 28
let sh_exit_command_not_found = 127

type runner_failure = { error : Unix.error; operation : string; argument : string }

let run_checked ~run command =
  try Ok (run command) with
  | Unix.Unix_error (error, operation, argument) -> Error { error; operation; argument }

let runner_failure_text { error; operation; argument } =
  let context = match operation, argument with
    | "", "" -> ""
    | operation, "" -> " (" ^ operation ^ ")"
    | "", argument -> " (" ^ argument ^ ")"
    | operation, argument -> " (" ^ operation ^ ": " ^ argument ^ ")" in
  Unix.error_message error ^ context

type fetch_failure =
  | Http_error_status
  | Operation_timeout
  | Could_not_resolve_host
  | Could_not_connect
  | Curl_missing
  | Curl_exit of { code : int }
  | Curl_signaled of { signal : int }
  | Curl_stopped of { signal : int }
  | Curl_runner_failed of runner_failure
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
  | Curl_runner_failed failure -> "could not run curl: " ^ runner_failure_text failure
  | No_body_written -> "curl wrote no body"

type download_error =
  | Fetch_failed of fetch_failure
  | Empty_body
  | Cache_unreadable of { detail : string }
  | Cached_body_too_large of { max_bytes : int }

let download_error_text = function
  | Fetch_failed failure -> "could not download the image: " ^ fetch_failure_text failure
  | Empty_body -> "the URL answered with an empty body"
  | Cache_unreadable { detail } -> "the cached image could not be read: " ^ detail
  | Cached_body_too_large { max_bytes } ->
      Printf.sprintf "the cached image exceeds the %d-byte preview limit" max_bytes

type decode_failure =
  | Decoder_missing
  | Decoder_exit of { code : int }
  | Decoder_signaled of { signal : int }
  | Decoder_stopped of { signal : int }
  | Decoder_runner_failed of runner_failure
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
  | Decoder_signaled { signal } ->
    if signal = Sys.sigkill
    then "decoder was killed (SIGKILL: out of time or memory)"
    else Printf.sprintf "decoder was killed by signal %d" signal
  | Decoder_stopped { signal } -> Printf.sprintf "decoder was stopped by signal %d" signal
  | Decoder_runner_failed failure -> "could not run decoder: " ^ runner_failure_text failure
  | No_frame_written -> "decoder wrote no frame"
  | Frame_unreadable { detail } -> "the decoded frame could not be read: " ^ detail

(* How often a bounded run looks at its child. A decoder that finishes is
   noticed within one interval; the interval is not a cost of its own, since
   the caller is a loader thread with nothing else to do. *)
let run_poll_interval_seconds = 0.02

let wait_bounded ?(cancelled = fun () -> false) ~deadline_seconds pid =
  let started_ns = Mtime_clock.elapsed_ns () in
  let rec reap () =
    match Unix.waitpid [] pid with
    | _, status -> status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap () in
  let rec wait () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
      if cancelled () || Int64.to_float (Int64.sub (Mtime_clock.elapsed_ns ()) started_ns) /. 1e9 >= deadline_seconds
      then begin
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error (Unix.ESRCH, _, _) -> ());
        reap ()
      end
      else begin
        Unix.sleepf run_poll_interval_seconds;
        wait ()
      end
    | _, status -> status
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait () in
  wait ()

(* A renderer's system thread can outlive its Eio observer. Serialize spawning
   with normal process shutdown so a late worker cannot leave a child behind. *)
let subprocess_mutex = Mutex.create ()
let subprocess_changed = Condition.create ()
let subprocess_stopping = ref false
let subprocesses : (int * bool Atomic.t) list ref = ref []

let stop_subprocesses () =
  Mutex.lock subprocess_mutex;
  subprocess_stopping := true;
  List.iter (fun (_,cancelled) -> Atomic.set cancelled true) !subprocesses;
  while !subprocesses <> [] do Condition.wait subprocess_changed subprocess_mutex done;
  Mutex.unlock subprocess_mutex

let () = at_exit stop_subprocesses

let bounded_command_environment () =
  Unix.environment () |> Array.to_list |> List.filter (fun entry ->
    match String.index_opt entry '=' with
    | None -> false
    | Some split ->
        let name = String.sub entry 0 split in
        let value = String.sub entry (split + 1) (String.length entry - split - 1) in
        not (List.mem name ["BASH_ENV"; "ENV"; "SHELLOPTS"; "BASHOPTS"; "POSIXLY_CORRECT"])
        && not (String.starts_with ~prefix:"BASH_FUNC_" name)
        && not (String.starts_with ~prefix:"() {" value)) |> Array.of_list

let run_bounded ?max_file_bytes ~deadline_seconds command =
  let command = match max_file_bytes with
    | None -> command
    | Some bytes ->
        (* Bash uses 1024-byte blocks outside POSIX mode on both supported
           platforms. Set the hard limit too, so descendants inherit it. *)
        if bytes <= 0 || bytes mod 1024 <> 0 then
          invalid_arg "max_file_bytes must be a positive multiple of 1024";
        let script = Printf.sprintf
          "builtin set +o posix || exit 1; \
           masc_limit_current=$(builtin ulimit -S -f) || exit 1; \
           case \"$masc_limit_current\" in \
           unlimited) masc_limit_blocks=%d ;; \
           ''|*[!0-9]*) exit 1 ;; \
           *) if [ \"$masc_limit_current\" -lt %d ]; then \
                masc_limit_blocks=$masc_limit_current; \
              else masc_limit_blocks=%d; fi ;; esac; \
           builtin ulimit -f \"$masc_limit_blocks\" && exec %s"
          (bytes / 1024) (bytes / 1024) (bytes / 1024) command in
        "/bin/bash -c " ^ Filename.quote script in
  (* Standard input, output and error are the null device: a decoder that
     reads a terminal would take the keys the operator is typing, and one that
     writes to it would draw over the screen. *)
  let null = Unix.openfile "/dev/null" [ Unix.O_RDWR ] 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close null)
    (fun () ->
       (* exec: the shell becomes the decoder, so the kill below reaches it. *)
       let child =
         Mutex.lock subprocess_mutex;
         Fun.protect ~finally:(fun () -> Mutex.unlock subprocess_mutex) (fun () ->
           if !subprocess_stopping then None else
           let args = [| "sh"; "-c"; "exec " ^ command |] in
           let pid = match max_file_bytes with
             | None -> Unix.create_process "/bin/sh" args null null null
             | Some _ -> Unix.create_process_env "/bin/sh" args
                 (bounded_command_environment ()) null null null in
           let cancelled = Atomic.make false in
           subprocesses := (pid,cancelled) :: !subprocesses;
           Some (pid,cancelled)) in
       match child with
       | None -> Unix.WSIGNALED Sys.sigkill
       | Some (pid,cancelled) ->
           Fun.protect ~finally:(fun () ->
             Mutex.lock subprocess_mutex;
             subprocesses := List.filter (fun (_,other) -> other != cancelled) !subprocesses;
             Condition.broadcast subprocess_changed;
             Mutex.unlock subprocess_mutex) (fun () ->
             try wait_bounded ~cancelled:(fun () -> Atomic.get cancelled) ~deadline_seconds pid
             with exn ->
               (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
               let rec reap () = match Unix.waitpid [] pid with
                 | _ -> ()
                 | exception Unix.Unix_error (Unix.EINTR,_,_) -> reap ()
                 | exception Unix.Unix_error (Unix.ECHILD,_,_) -> () in
               (try reap () with Unix.Unix_error _ -> ());
               raise exn))

let discard path = try Sys.remove path with Sys_error _ -> ()

type bounded_read_error = Read_too_large | Read_unavailable of string

let read_bounded_bytes ~max_bytes path =
  try
    let descriptor = Unix.openfile path [Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC] 0 in
    Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () ->
      if (Unix.fstat descriptor).Unix.st_kind <> Unix.S_REG then
        Error (Read_unavailable "not a regular file")
      else
        let buffer = Buffer.create (min max_bytes 65536) in
        let chunk = Bytes.create 65536 in
        let rec read () =
          let remaining = max_bytes + 1 - Buffer.length buffer in
          if remaining = 0 then Error Read_too_large
          else match Unix.read descriptor chunk 0 (min remaining (Bytes.length chunk)) with
            | 0 -> Ok (Buffer.contents buffer)
            | count -> Buffer.add_subbytes buffer chunk 0 count; read ()
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> read () in
        read ())
  with
  | Sys_error detail -> Error (Read_unavailable detail)
  | Unix.Unix_error (error,_,_) -> Error (Read_unavailable (Unix.error_message error))

let read_bytes ?max_bytes path =
  match max_bytes with
  | None ->
      (try Ok (In_channel.with_open_bin path In_channel.input_all)
       with Sys_error detail -> Error detail)
  | Some max_bytes ->
      Result.map_error (function
        | Read_too_large -> Printf.sprintf "image exceeds the %d-byte preview limit" max_bytes
        | Read_unavailable detail -> detail) (read_bounded_bytes ~max_bytes path)

let input_path ~cache_dir url =
  Filename.concat cache_dir ("img_" ^ Digest.to_hex (Digest.string url))

let png_path ~cache_dir input =
  Filename.concat cache_dir
    ("conv_" ^ Digest.to_hex (Digest.string (input ^ "_converted_png")) ^ ".png")

let downloaded_frame_path ~cache_dir url =
  png_path ~cache_dir (input_path ~cache_dir url) ^ ".bound"

let invalidate_download ~cache_dir url =
  let input = input_path ~cache_dir url in
  discard input;
  discard (png_path ~cache_dir input);
  discard (downloaded_frame_path ~cache_dir url)

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

(* The converter may still hold its output open after it reports success.
   Publish a new file so later writes through that handle cannot change the
   cached frame. This does not prove the converter had finished writing when
   its output was read. *)
let publish_snapshot ~cache_dir ~target parts =
  match Filename.open_temp_file ~mode:[Open_binary] ~temp_dir:cache_dir "conv_frame_" ".png" with
  | exception Sys_error detail -> Error detail
  | path, channel ->
    let moved = ref false in
    Fun.protect ~finally:(fun () ->
      close_out_noerr channel;
      if not !moved then discard path) (fun () ->
      try
        List.iter (Out_channel.output_string channel) parts;
        Out_channel.close channel;
        Sys.rename path target;
        moved := true;
        Ok target
      with Sys_error detail -> Error detail)

type download = Download of string

let download_bytes (Download bytes) = bytes

let with_download_snapshot ~cache_dir (Download bytes) f =
  match attempt_path ~cache_dir ~prefix:"download_input_" ~suffix:".img" with
  | Error detail -> Error detail
  | Ok path ->
    Fun.protect ~finally:(fun () -> discard path) (fun () ->
      let written =
        try Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc bytes); Ok ()
        with Sys_error detail -> Error detail in
      Result.map (fun () -> f path) written)

let download ?(force_fetch = false) ?max_bytes ~run ~cache_dir url =
  let target = input_path ~cache_dir url in
  let judge bytes = verdict_of_bytes bytes in
  let read_cached () =
    let reading = match max_bytes with
      | None -> Result.map_error (fun detail -> Cache_unreadable { detail }) (read_bytes target)
      | Some max_bytes -> Result.map_error (function
          | Read_too_large -> Cached_body_too_large { max_bytes }
          | Read_unavailable detail -> Cache_unreadable { detail })
          (read_bounded_bytes ~max_bytes target) in
    match reading with
    | Error error ->
        if Option.is_none max_bytes then discard target;
        Error error
    | Ok bytes ->
      match judge bytes with
      | Known_image _ | Unknown_signature -> Ok (Download bytes)
      | Empty ->
          if Option.is_none max_bytes then discard target;
          Error Empty_body
  in
  let fetch () =
    match attempt_path ~cache_dir ~prefix:"dl_" ~suffix:".part" with
    | Error detail -> Error (Cache_unreadable { detail })
    | Ok attempt ->
      let owns_attempt = ref true in
      Fun.protect ~finally:(fun () -> if !owns_attempt then discard attempt) (fun () ->
        let command = Printf.sprintf "curl -s -L --fail --max-time 5 -o %s %s"
            (Filename.quote attempt) (Filename.quote url) in
        match run_checked ~run command with
        | Error failure -> Error (Fetch_failed (Curl_runner_failed failure))
        | Ok status ->
          match fetch_failure_of_status status ~body_present:(Sys.file_exists attempt) with
          | Some failure -> Error (Fetch_failed failure)
          | None ->
            match read_bytes ?max_bytes attempt with
            | Error detail -> Error (Cache_unreadable { detail })
            | Ok bytes ->
              match judge bytes with
              | Empty -> Error Empty_body
              | Known_image _ | Unknown_signature ->
                if Option.is_some max_bytes then Ok (Download bytes)
                else begin
                  let result = publish ~attempt ~target in
                  owns_attempt := false;
                  match result with
                  | Ok _ -> Ok (Download bytes)
                  | Error detail -> Error (Cache_unreadable { detail })
                end)
  in
  if not force_fetch && Sys.file_exists target then
    match read_cached () with
    | Ok body -> Ok body
    | Error (Cached_body_too_large _ as error) -> Error error
    | Error (Fetch_failed _ | Empty_body | Cache_unreadable _) -> fetch ()
  else fetch ()

let collect_decoder_bytes ?max_bytes ~run ~output_path command =
  match run_checked ~run command with
  | Error failure -> Error (Decoder_runner_failed failure)
  | Ok status ->
    match decode_failure_of_status status ~output_present:(Sys.file_exists output_path) with
    | Some failure -> Error failure
    | None ->
      match read_bytes ?max_bytes output_path with
      | Error detail -> Error (Frame_unreadable { detail })
      | Ok "" -> Error No_frame_written
      | Ok bytes -> Ok bytes

let run_decoder_bytes ~run ~output_path command =
  discard output_path;
  match collect_decoder_bytes ~run ~output_path command with
  (* Public callers may share [output_path]. The caller must own the path to
     remove it after an exception or runner failure. *)
  | Error (Decoder_runner_failed _ as failure) -> Error failure
  | Error ((Decoder_missing | Decoder_exit _ | Decoder_signaled _
           | Decoder_stopped _ | No_frame_written | Frame_unreadable _) as failure) ->
    discard output_path; Error failure
  | Ok bytes -> Ok bytes

let run_decoder ~run ~output_path command =
  Result.map (fun _ -> output_path) (run_decoder_bytes ~run ~output_path command)

type converter = Sips | Image_magick | Ffmpeg
type conversion_failure = (converter * decode_failure) list

let converter_name = function
  | Sips -> "sips" | Image_magick -> "convert" | Ffmpeg -> "ffmpeg"

let conversion_failure_text failures =
  String.concat "; " (List.map (fun (converter, failure) ->
    converter_name converter ^ ": " ^ decode_failure_text failure) failures)

let convert_frame ~run ~cache_dir input =
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
          Printf.sprintf "ffmpeg -y -i %s -frames:v 1 %s >/dev/null 2>&1" source (Filename.quote out))
      ]
    in
    match attempt_path ~cache_dir ~prefix:"conv_attempt_" ~suffix:".png" with
    | Error detail -> Error [ Sips, Frame_unreadable { detail } ]
    | Ok attempt_file ->
      let rec attempt failures = function
        | [] -> discard attempt_file; Error (List.rev failures)
        | (converter, command) :: rest ->
          (* Publish only a nonempty frame captured from this attempt. *)
          match run_decoder_bytes ~run ~output_path:attempt_file (command attempt_file) with
          | Ok bytes ->
            Fun.protect ~finally:(fun () -> discard attempt_file) (fun () ->
              Ok (converter, failures, bytes))
          (* A signalled converter can leave a descendant writing to this
             pathname. Do not give that pathname to a fallback converter. *)
          | Error ((Decoder_runner_failed _ | Decoder_signaled _ | Decoder_stopped _) as failure) ->
            Error (List.rev ((converter, failure) :: failures))
          | Error ((Decoder_missing | Decoder_exit _ | No_frame_written | Frame_unreadable _) as failure) ->
            attempt ((converter, failure) :: failures) rest
      in
      attempt [] commands

let convert_and_publish ~run ~cache_dir ~target ~encode input =
  match convert_frame ~run ~cache_dir input with
  | Error failures -> Error failures
  | Ok (converter, failures, bytes) ->
    (* Keep the converter's file separate from the published snapshot. *)
    match publish_snapshot ~cache_dir ~target (encode bytes) with
    | Ok _ -> Ok bytes
    | Error detail ->
      Error (List.rev ((converter, Frame_unreadable {detail}) :: failures))

let convert_to_png ~run ~cache_dir input =
  let target = png_path ~cache_dir input in
  match read_bytes target with
  | Ok bytes when String.length bytes > 0 -> Ok target
  | Ok _ | Error _ ->
    Result.map (fun _ -> target)
      (convert_and_publish ~run ~cache_dir ~target ~encode:(fun bytes -> [bytes]) input)

let downloaded_frame_prefix bytes =
  "masc-tui-image-frame-v1:" ^ Agent_core_sha256.(digest_string bytes |> to_hex) ^ "\n"

let cached_downloaded_frame ~prefix path =
  try In_channel.with_open_bin path (fun channel ->
    if really_input_string channel (String.length prefix) <> prefix then None
    else match In_channel.input_line channel with
      | None -> None
      | Some size ->
        match int_of_string_opt size with
        | Some size when size > 0 ->
          let frame = In_channel.input_all channel in
          if String.length frame = size then Some frame else None
        | Some _ | None -> None)
  with Sys_error _ | End_of_file -> None

(* Admit one supported JPEG frame header and scan through EOI. A second SOF,
   including one after a progressive scan, must not give the decoder a larger
   frame than the dimensions already checked by the caller. *)
let has_bounded_jpeg_structure ~width ~height bytes =
  let length=String.length bytes in
  let byte offset=Char.code bytes.[offset] in
  let be16 offset=(byte offset lsl 8) lor byte (offset+1) in
  let valid=ref (String.starts_with ~prefix:"\xff\xd8" bytes) in
  let position=ref 2 and in_scan=ref false and seen_frame=ref false
  and seen_scan=ref false and finished=ref false in
  while !valid && not !finished do
    if !position >= length then valid := false
    else if !in_scan && byte !position <> 0xff then incr position
    else if byte !position <> 0xff then valid := false
    else begin
      while !position < length && byte !position = 0xff do incr position done;
      if !position >= length then valid := false
      else begin
        let marker=byte !position in
        incr position;
        if !in_scan && (marker = 0x00 || (marker >= 0xd0 && marker <= 0xd7)) then ()
        else if marker = 0xd9 then begin
          if !seen_frame && !seen_scan then finished := true else valid := false
        end
        else if marker = 0x00 || marker = 0xd8 || marker = 0x01
             || (marker >= 0xd0 && marker <= 0xd7) then valid := false
        else if !position > length - 2 then valid := false
        else begin
          let segment=be16 !position in
          if segment < 2 || segment > length - !position then valid := false
          else begin
            let is_frame = marker >= 0xc0 && marker <= 0xcf
              && marker <> 0xc4 && marker <> 0xc8 && marker <> 0xcc in
            if is_frame then begin
              if !seen_frame || (marker <> 0xc0 && marker <> 0xc1 && marker <> 0xc2)
                 || segment < 8 || byte (!position+2) <> 8
                 || be16 (!position+3) <> height || be16 (!position+5) <> width
                 || byte (!position+7) = 0 || byte (!position+7) > 4
                 || segment <> 8 + (3 * byte (!position+7))
              then valid := false
              else seen_frame := true
            end else if marker <> 0xc4 && marker <> 0xdb && marker <> 0xdd
              && marker <> 0xda && marker <> 0xfe && not (marker >= 0xe0 && marker <= 0xef)
            then valid := false;
            if marker = 0xe0 && segment >= 7
               && String.sub bytes (!position+2) 5 = "JFIF\000"
               && (segment < 16 || be16 (!position+10) <> be16 (!position+12))
            then valid := false;
            if marker = 0xda then begin
              if not !seen_frame || segment < 6 || byte (!position+2) = 0
                 || byte (!position+2) > 4
                 || segment <> 6 + (2 * byte (!position+2))
              then valid := false;
              (* A decoder recovering from a malformed scan header can
                 interpret an embedded marker before the declared end. *)
              for index = !position + 2 to !position + segment - 1 do
                if byte index = 0xff then valid := false
              done;
              seen_scan := true;
              in_scan := true
            end else in_scan := false;
            position := !position + segment
          end
        end
      end
    end
  done;
  !valid && !finished && !position = length

(* GIF89a image descriptors must fit the logical screen. Check every frame,
   not just the canvas dimensions, before the decoder sees the stream.
   https://giflib.sourceforge.net/gifstandard/GIF89a.html *)
let has_bounded_gif_structure ~width ~height bytes =
  let length = String.length bytes in
  let valid = ref (length >= 13 &&
    (String.starts_with ~prefix:"GIF87a" bytes || String.starts_with ~prefix:"GIF89a" bytes)
    && (Char.code bytes.[12] = 0 || Char.code bytes.[12] = 49)) in
  let position = ref 13 and found_image = ref false and finished = ref false in
  let byte offset = Char.code bytes.[offset] in
  let le16 offset = byte offset lor (byte (offset + 1) lsl 8) in
  let skip count =
    if count < 0 || !position > length - count then valid := false
    else position := !position + count in
  let skip_table packed =
    if packed land 0x80 <> 0 then skip (3 * (1 lsl ((packed land 7) + 1))) in
  let skip_subblocks () =
    let ended = ref false in
    while !valid && not !ended do
      if !position >= length then valid := false
      else begin
        let size = byte !position in
        incr position;
        if size = 0 then ended := true else skip size
      end
    done in
  if !valid then skip_table (byte 10);
  while !valid && not !finished do
    if !position >= length then valid := false
    else match byte !position with
    | 0x3b -> incr position; finished := true
    | 0x21 ->
        if !position > length - 2 then valid := false
        else begin
          let label = byte (!position + 1) in
          (* Plain-text and unknown extensions can contain their own graphics
             dimensions; do not guess how a decoder will allocate for them. *)
          if label <> 0xf9 && label <> 0xfe && label <> 0xff then valid := false
          else begin skip 2; if !valid then skip_subblocks () end
        end
    | 0x2c ->
        if !position > length - 10 then valid := false
        else begin
          let left=le16 (!position + 1) and top=le16 (!position + 3) in
          let frame_width=le16 (!position + 5) and frame_height=le16 (!position + 7) in
          let packed=byte (!position + 9) in
          if frame_width <= 0 || frame_height <= 0 || frame_width > width || frame_height > height
             || left > width - frame_width || top > height - frame_height then valid := false
          else begin
            found_image := true;
            skip 10;
            skip_table packed;
            skip 1;
            if !valid then skip_subblocks ()
          end
        end
    | _ -> valid := false
  done;
  !valid && !found_image && !finished && !position = length

(* Bound encoded input and declared pixels before invoking the colour-cell
   decoder. This does not bound every allocation the decoder makes. *)
let check_bounded_image ~max_bytes bytes =
  if String.length bytes > max_bytes then
    Error (Printf.sprintf "image exceeds the %d-byte preview limit" max_bytes)
  else match verdict_of_bytes bytes, Masc.Keeper_image_dimensions.image_dimensions bytes with
    | Known_image {media_type="image/png"}, Some (width,height)
        when has_png_structure ~single_frame:true bytes
          && width > 0 && height > 0 && width <= (max_bytes / 4) / height -> Ok ()
    | Known_image {media_type="image/jpeg"}, Some (width,height)
        when width > 0 && height > 0 && width <= (max_bytes / 4) / height
          && has_bounded_jpeg_structure ~width ~height bytes -> Ok ()
    | Known_image {media_type="image/gif"}, Some (width,height)
        when width > 0 && height > 0 && width <= (max_bytes / 4) / height
          && has_bounded_gif_structure ~width ~height bytes -> Ok ()
    | (Known_image _ | Unknown_signature | Empty), (Some _ | None) ->
        Error "bounded colour preview requires a supported image within the image limit"

let prepare_downloaded_png ~run ~cache_dir ~url body =
    let bytes = download_bytes body in
    match verdict_of_bytes bytes with
    | Known_image { media_type = "image/png" } -> Ok bytes
    | Known_image _ | Unknown_signature | Empty ->
      let target = downloaded_frame_path ~cache_dir url in
      let prefix = downloaded_frame_prefix bytes in
      let cached = cached_downloaded_frame ~prefix target in
      match cached with
      | Some frame -> Ok frame
      | None ->
        Result.bind (with_download_snapshot ~cache_dir body (fun input ->
          let encode frame = [prefix; string_of_int (String.length frame); "\n"; frame] in
          match convert_and_publish ~run ~cache_dir ~target ~encode input with
          | Ok frame -> Ok frame
          | Error failures -> Error (conversion_failure_text failures))) Fun.id

let prepare_png ~run ~cache_dir url =
  match download ~run ~cache_dir url with
  | Error error -> Error (download_error_text error)
  | Ok body -> prepare_downloaded_png ~run ~cache_dir ~url body

let prepare_captured_png ~run ~cache_dir bytes =
  match verdict_of_bytes bytes with
  | Empty -> Error "image payload is empty"
  | Known_image {media_type="image/png"} -> Ok bytes
  | Known_image _ | Unknown_signature ->
      Result.bind (with_download_snapshot ~cache_dir (Download bytes) (fun input ->
        convert_frame ~run ~cache_dir input
        |> Result.map (fun (_,_,frame) -> frame)
        |> Result.map_error conversion_failure_text)) Fun.id

let prepare_payload ~run ~cache_dir bytes =
  match verdict_of_bytes bytes with
  | Empty -> Error "image payload is empty"
  | Known_image { media_type = "image/png" } -> Ok bytes
  | Known_image _ | Unknown_signature ->
    let input = input_path ~cache_dir ("payload:" ^ bytes) in
    let saved =
      Result.bind (attempt_path ~cache_dir ~prefix:"payload_attempt_" ~suffix:".img")
        (fun attempt ->
          match Out_channel.with_open_bin attempt (fun oc -> Out_channel.output_string oc bytes) with
          | () -> publish ~attempt ~target:input
          | exception Sys_error detail -> discard attempt; Error detail)
    in
    Result.bind saved (fun input ->
      match convert_to_png ~run ~cache_dir input with
      | Ok path -> read_bytes path
      | Error failures -> Error (conversion_failure_text failures))

let prepare_file ~run ~cache_dir path =
  let source =
    try Ok (In_channel.with_open_bin path (fun channel ->
      really_input_string channel (in_channel_length channel)))
    with
    | Sys_error detail -> Error detail
    | End_of_file -> Error "the file ended sooner than its length said" in
  Result.bind source (prepare_payload ~run ~cache_dir)

type display = Pixel_graphics | Character_cells of { columns : int; rows : int }

type presentation =
  | Png of string
  | Rgba of { columns : int; pixel_rows : int; bytes : string }

type captured_copy = { path : string; openable : bool }

let captured_copy_mutex = Mutex.create ()
type pending_copy = { copy : captured_copy; mutable discarded : bool }
let pending_copies : pending_copy list ref = ref []
let captured_copy_stopping = ref false

let with_captured_copy_lock f =
  Mutex.lock captured_copy_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock captured_copy_mutex) f

(* This runs on the cleanup worker, not the terminal fiber. A failed unlink stays
   registered for another attempt during shutdown. *)
let cleanup_discarded_copies () =
  let copies = with_captured_copy_lock (fun () ->
    List.filter (fun entry -> entry.discarded) !pending_copies) in
  List.iter (fun entry ->
    let removed = try Unix.unlink entry.copy.path; true with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> true
      | Unix.Unix_error _ -> false in
    if removed then with_captured_copy_lock (fun () ->
      pending_copies := List.filter (fun current -> current != entry) !pending_copies)) copies

let save_captured_copy ~directory bytes =
  let suffix, openable = match verdict_of_bytes bytes with
    | Known_image {media_type="image/png"} -> ".png", true
    | Known_image {media_type="image/jpeg"} -> ".jpg", true
    | Known_image {media_type="image/gif"} -> ".gif", true
    | Known_image {media_type="image/webp"} -> ".webp", true
    | Known_image _ | Unknown_signature | Empty -> ".bin", false in
  if with_captured_copy_lock (fun () -> !captured_copy_stopping) then
    Error "image copy worker is stopping"
  else match Filename.open_temp_file ~mode:[Open_binary] ~perms:0o600
      ~temp_dir:directory "masc-image-" suffix with
    | exception Sys_error detail -> Error detail
    | path, channel ->
        let handed_off = ref false in
        Fun.protect ~finally:(fun () ->
          close_out_noerr channel;
          if not !handed_off then discard path) (fun () ->
          try
            Out_channel.output_string channel bytes;
            Out_channel.close channel;
            let copy = {path;openable} in
            let registered = with_captured_copy_lock (fun () ->
              if !captured_copy_stopping then false
              else begin
                pending_copies := {copy;discarded=false} :: !pending_copies;
                true
              end) in
            if registered then begin handed_off := true; Ok copy end
            else Error "image copy worker is stopping"
          with Sys_error detail -> Error detail)

let retain_captured_copy copy =
  with_captured_copy_lock (fun () ->
    match List.find_opt (fun pending -> pending.copy == copy && not pending.discarded) !pending_copies with
    | Some entry ->
        pending_copies := List.filter (fun pending -> pending != entry) !pending_copies;
        true
    | None -> false)

let discard_captured_copy copy =
  with_captured_copy_lock (fun () ->
    List.iter (fun pending -> if pending.copy == copy then pending.discarded <- true) !pending_copies)

let stop_captured_copies () =
  let pending = with_captured_copy_lock (fun () ->
    captured_copy_stopping := true;
    let pending = !pending_copies in
    pending_copies := [];
    pending) in
  List.iter (fun entry -> discard entry.copy.path) pending

let () = at_exit stop_captured_copies

let limit_cell_grid ~max_cells (columns, pixel_rows) =
  if columns <= 0 || pixel_rows <= 1 || columns <= max_cells / (pixel_rows / 2) then
    columns, pixel_rows
  else
    let scale = sqrt (float_of_int max_cells /.
      (float_of_int columns *. float_of_int (pixel_rows / 2))) in
    let columns = min max_cells (max 1 (int_of_float (float_of_int columns *. scale))) in
    let pixel_rows = max 2 (int_of_float (float_of_int pixel_rows *. scale) land lnot 1) in
    columns, 2 * min (pixel_rows / 2) (max_cells / columns)

(* FFmpeg's own pixel guard also applies when its decoder sees dimensions that
   differ from a preliminary header read. It does not bound total memory. *)
let ffmpeg_decode_limits = function
  | None -> ""
  | Some bytes ->
      Printf.sprintf "-max_pixels %d -threads 1 " (bytes / 4)

(* ffmpeg applies EXIF orientation when it decodes a JPEG. Measure the
   oriented frame, rather than the pre-orientation SOF, before fitting it to
   terminal cells. The original source has already passed the JPEG admission
   check, and both the private output and its dimensions are checked again. *)
let normalize_bounded_jpeg ~run ~cache_dir ~max_bytes source =
  let open Result.Syntax in
  Result.bind (with_download_snapshot ~cache_dir (Download source) (fun input ->
    let* output = attempt_path ~cache_dir ~prefix:"oriented_image_" ~suffix:".png" in
    Fun.protect ~finally:(fun () -> discard output) (fun () ->
      let command = Printf.sprintf
        "ffmpeg -v error -nostdin -y %s-i %s -frames:v 1 -f image2 -c:v png %s >/dev/null 2>&1"
        (ffmpeg_decode_limits (Some max_bytes)) (Filename.quote input) (Filename.quote output) in
      let* png = Result.map_error decode_failure_text
        (collect_decoder_bytes ~max_bytes ~run ~output_path:output command) in
      let* () = check_bounded_image ~max_bytes png in
      match verdict_of_bytes png with
      | Known_image {media_type="image/png"} -> Ok png
      | Known_image _ | Unknown_signature | Empty -> Error "image decoder did not return PNG"))) Fun.id

let prepare_presentation ?max_bytes ?max_cells ~run ~cache_dir display source =
  match display with
  | Pixel_graphics -> Ok (Png source)
  | Character_cells {columns;rows} ->
    let open Result.Syntax in
    let* () = match max_bytes with
      | None -> Ok ()
      | Some max_bytes -> check_bounded_image ~max_bytes source in
    let* source = match max_bytes, verdict_of_bytes source with
      | Some max_bytes, Known_image {media_type="image/jpeg"} ->
          normalize_bounded_jpeg ~run ~cache_dir ~max_bytes source
      | (Some _ | None), (Known_image _ | Unknown_signature | Empty) -> Ok source in
    let* width, height =
      match verdict_of_bytes source, Masc.Keeper_image_dimensions.image_dimensions source with
      | Known_image {media_type=("image/png" | "image/jpeg" | "image/gif")}, Some (width,height)
        when width > 0 && height > 0 -> Ok (width,height)
      | (Known_image _ | Unknown_signature | Empty), (Some _ | None) ->
        Error "character image preview requires a supported image with valid dimensions" in
    let columns, pixel_rows = Masc_tui_image_mosaic.fit_grid
      ~src_w:width ~src_h:height ~max_cols:columns ~max_rows:(rows * 2) in
    let columns, pixel_rows = match max_cells with
      | None -> columns, pixel_rows
      | Some limit when limit > 0 -> limit_cell_grid ~max_cells:limit (columns, pixel_rows)
      | Some _ -> 0, 0 in
    if columns <= 0 || pixel_rows <= 0 then Error "no room for the image preview"
    else if Option.exists (fun limit -> columns > (limit / 4) / pixel_rows) max_bytes then
      Error "terminal image dimensions exceed the colour preview limit"
    else
      let* input = attempt_path ~cache_dir ~prefix:"cell_image_" ~suffix:".img" in
      Fun.protect ~finally:(fun () -> discard input) (fun () ->
        let* output = attempt_path ~cache_dir ~prefix:"cell_frame_" ~suffix:".rgba" in
        Fun.protect ~finally:(fun () -> discard output) (fun () ->
          let* () =
            try Out_channel.with_open_bin input (fun oc -> Out_channel.output_string oc source); Ok ()
            with Sys_error detail -> Error detail in
          let command = Printf.sprintf
            "ffmpeg -v error -nostdin -y %s-i %s -vf scale=%d:%d -frames:v 1 -f rawvideo -pix_fmt rgba %s >/dev/null 2>&1"
            (ffmpeg_decode_limits max_bytes) (Filename.quote input) columns pixel_rows (Filename.quote output) in
          (* [output] is an exclusively reserved empty file. Keep the name
             occupied until this attempt finishes and read its bytes once. *)
          let* bytes = Result.map_error decode_failure_text
            (collect_decoder_bytes ?max_bytes ~run ~output_path:output command) in
          if String.length bytes <> columns * pixel_rows * 4 then
            Error "image decoder returned an incomplete or unexpected RGBA frame"
          else Ok (Rgba {columns;pixel_rows;bytes})))

type remote_image =
  | Remote_unfetched
  | Remote_png of string
  | Remote_native of { source : string; png : string }
  | Remote_bounded_source of string
  | Remote_cells of { source : string; cells : (presentation, string) result }
  | Remote_busy of string option
  | Remote_bounded_failure of string
  | Remote_native_failed of { source : string; detail : string }
  | Remote_copy_ready of { copy : captured_copy; reason : string; requested_save : bool }
  | Remote_copy_failed of { source : string; reason : string; detail : string; requested_save : bool }

type remote_action =
  | Fetch_remote
  | Prepare_remote_cells of string
  | Prepare_native_source of string
  | Draw_remote_png of string
  | Draw_remote_cells of { source : string; cells : presentation }
  | Open_remote_page of { reason : string; source : string option }
  | Open_remote_copy of { copy : captured_copy; reason : string; requested_save : bool }
  | Hold_remote_source of { source : string; reason : string; detail : string; requested_save : bool }

let native_source_action source =
  match verdict_of_bytes source with
  | Known_image {media_type="image/png"} -> Draw_remote_png source
  | Known_image _ | Unknown_signature | Empty -> Prepare_native_source source

let decide_remote ~graphics ~colour image =
  match graphics, colour, image with
  | (None | Some true | Some false), (true | false), Remote_copy_ready {copy;reason;requested_save} ->
      Open_remote_copy {copy;reason;requested_save}
  | (None | Some true | Some false), (true | false), Remote_copy_failed {source;reason;detail;requested_save} ->
      Hold_remote_source {source;reason;detail;requested_save}
  | (None | Some true), (true | false), Remote_unfetched -> Fetch_remote
  | (None | Some true), (true | false), Remote_bounded_failure _ -> Fetch_remote
  | (None | Some true), (true | false), Remote_png png -> Draw_remote_png png
  | (None | Some true), (true | false), Remote_native {png;_} -> Draw_remote_png png
  | (None | Some true), (true | false),
    (Remote_bounded_source source | Remote_cells {source;_} | Remote_busy (Some source)) ->
      native_source_action source
  | (None | Some true), (true | false), Remote_native_failed {source;detail} ->
      Open_remote_page {reason=detail;source=Some source}
  | (None | Some true), (true | false), Remote_busy None ->
      Open_remote_page {reason="another image is still preparing";source=None}
  | Some false, false, (Remote_png source | Remote_bounded_source source
      | Remote_cells {source;_} | Remote_busy (Some source) | Remote_native_failed {source;_}
      | Remote_native {source;_}) ->
      Open_remote_page {reason="terminal does not support pixel or colour-cell images";source=Some source}
  | Some false, false, (Remote_unfetched | Remote_busy None | Remote_bounded_failure _) ->
      Open_remote_page {reason="terminal does not support pixel or colour-cell images";source=None}
  | Some false, true, Remote_unfetched -> Fetch_remote
  | Some false, true, (Remote_png source | Remote_bounded_source source
      | Remote_native_failed {source;_} | Remote_native {source;_}) ->
      Prepare_remote_cells source
  | Some false, true, Remote_cells {source;cells=Ok (Rgba _ as cells)} -> Draw_remote_cells {source;cells}
  | Some false, true, Remote_cells {source;cells=Ok (Png _)} ->
      Open_remote_page {reason="colour-cell renderer did not return a character frame";source=Some source}
  | Some false, true, Remote_cells {source;cells=Error detail} ->
      Open_remote_page {reason=detail;source=Some source}
  | Some false, true, Remote_busy source ->
      Open_remote_page {reason="another image is still preparing";source}
  | Some false, true, Remote_bounded_failure detail -> Open_remote_page {reason=detail;source=None}
