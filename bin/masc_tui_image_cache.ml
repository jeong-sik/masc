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

let has_png_structure bytes =
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

let download_error_text = function
  | Fetch_failed failure -> "could not download the image: " ^ fetch_failure_text failure
  | Empty_body -> "the URL answered with an empty body"
  | Cache_unreadable { detail } -> "the cached image could not be read: " ^ detail

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

let run_bounded ~deadline_seconds command =
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
           let pid = Unix.create_process "/bin/sh" [| "sh"; "-c"; "exec " ^ command |] null null null in
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

let read_bytes path =
  try Ok (In_channel.with_open_bin path In_channel.input_all)
  with Sys_error detail -> Error detail

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

let download ?(force_fetch = false) ~run ~cache_dir url =
  let target = input_path ~cache_dir url in
  let judge bytes = verdict_of_bytes bytes in
  let read_cached () =
    match read_bytes target with
    | Error detail -> discard target; Error (Cache_unreadable { detail })
    | Ok bytes ->
      match judge bytes with
      | Known_image _ | Unknown_signature -> Ok (Download bytes)
      | Empty -> discard target; Error Empty_body
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
            match read_bytes attempt with
            | Error detail -> Error (Cache_unreadable { detail })
            | Ok bytes ->
              match judge bytes with
              | Empty -> Error Empty_body
              | Known_image _ | Unknown_signature ->
                let result = publish ~attempt ~target in
                owns_attempt := false;
                match result with
                | Ok _ -> Ok (Download bytes)
                | Error detail -> Error (Cache_unreadable { detail }))
  in
  if not force_fetch && Sys.file_exists target then
    match read_cached () with Ok body -> Ok body | Error _ -> fetch ()
  else fetch ()

let collect_decoder_bytes ~run ~output_path command =
  match run_checked ~run command with
  | Error failure -> Error (Decoder_runner_failed failure)
  | Ok status ->
    match decode_failure_of_status status ~output_present:(Sys.file_exists output_path) with
    | Some failure -> Error failure
    | None ->
      match read_bytes output_path with
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

let prepare_png ~run ~cache_dir url =
  match download ~run ~cache_dir url with
  | Error error -> Error (download_error_text error)
  | Ok body ->
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

let prepare_presentation ~run ~cache_dir display png =
  match display with
  | Pixel_graphics -> Ok (Png png)
  | Character_cells {columns;rows} ->
    let open Result.Syntax in
    let* width, height =
      match verdict_of_bytes png, Masc.Keeper_image_dimensions.image_dimensions png with
      | Known_image {media_type="image/png"}, Some (width,height)
        when width > 0 && height > 0 -> Ok (width,height)
      | (Known_image _ | Unknown_signature | Empty), (Some _ | None) ->
        Error "character image preview requires a PNG with valid dimensions" in
    let columns, pixel_rows = Masc_tui_image_mosaic.fit_grid
      ~src_w:width ~src_h:height ~max_cols:columns ~max_rows:(rows * 2) in
    if columns <= 0 || pixel_rows <= 0 then Error "no room for the image preview"
    else
      let* input = attempt_path ~cache_dir ~prefix:"cell_image_" ~suffix:".png" in
      Fun.protect ~finally:(fun () -> discard input) (fun () ->
        let* output = attempt_path ~cache_dir ~prefix:"cell_frame_" ~suffix:".rgba" in
        Fun.protect ~finally:(fun () -> discard output) (fun () ->
          let* () =
            try Out_channel.with_open_bin input (fun oc -> Out_channel.output_string oc png); Ok ()
            with Sys_error detail -> Error detail in
          let command = Printf.sprintf
            "ffmpeg -v error -nostdin -y -i %s -vf scale=%d:%d -frames:v 1 -f rawvideo -pix_fmt rgba %s >/dev/null 2>&1"
            (Filename.quote input) columns pixel_rows (Filename.quote output) in
          (* [output] is an exclusively reserved empty file. Keep the name
             occupied until this attempt finishes and read its bytes once. *)
          let* bytes = Result.map_error decode_failure_text
            (collect_decoder_bytes ~run ~output_path:output command) in
          if String.length bytes <> columns * pixel_rows * 4 then
            Error "image decoder returned an incomplete or unexpected RGBA frame"
          else Ok (Rgba {columns;pixel_rows;bytes})))

type remote_image =
  | Remote_unfetched
  | Remote_png of string
  | Remote_cells of { png : string; cells : (presentation, string) result }
  | Remote_busy of string option

type remote_action =
  | Fetch_remote
  | Prepare_remote_cells of string
  | Draw_remote_png of string
  | Draw_remote_cells of { png : string; cells : presentation }
  | Open_remote_page of string

let decide_remote ~graphics ~colour image =
  match graphics, colour, image with
  | (None | Some true), (true | false), Remote_unfetched -> Fetch_remote
  | (None | Some true), (true | false), (Remote_png png | Remote_cells {png;_}) ->
      Draw_remote_png png
  | (None | Some true), (true | false), Remote_busy (Some png) -> Draw_remote_png png
  | (None | Some true), (true | false), Remote_busy None ->
      Open_remote_page "another image is still preparing"
  | Some false, false, (Remote_unfetched | Remote_png _ | Remote_cells _ | Remote_busy _) ->
      Open_remote_page "terminal does not support pixel or colour-cell images"
  | Some false, true, Remote_unfetched -> Fetch_remote
  | Some false, true, Remote_png png -> Prepare_remote_cells png
  | Some false, true, Remote_cells {png;cells=Ok (Rgba _ as cells)} -> Draw_remote_cells {png;cells}
  | Some false, true, Remote_cells {cells=Ok (Png _);_} ->
      Open_remote_page "colour-cell renderer did not return a character frame"
  | Some false, true, Remote_cells {cells=Error detail;_} -> Open_remote_page detail
  | Some false, true, Remote_busy _ -> Open_remote_page "another image is still preparing"
