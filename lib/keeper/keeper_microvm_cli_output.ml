type unavailable_output =
  | Capture_directory_unavailable
  | Capture_incomplete
  | Capture_failed
  | Capture_limit_exceeded
  | Capture_unreadable
  | Capture_permissions_invalid
  | Capture_length_mismatch
  | Capture_cleanup_failed

type error = { reason : unavailable_output; status : Unix.process_status option }

let release_capture_directory directory =
  let remove () = Fs_compat.remove_tree directory in
  match
    (match Fs_compat.execution_context () with
     | Fs_compat.Non_eio -> remove ()
     | Fs_compat.Eio_fiber -> Eio.Cancel.protect remove)
  with
  | () -> Ok ()
  | exception (Sys_error _ | Unix.Unix_error _ | Eio.Io _) -> Error Capture_cleanup_failed
;;

let with_capture_directory ~status use =
  match Filename.temp_dir "masc-microvm-cli-" "" with
  | exception (Sys_error _ | Unix.Unix_error _) ->
    Error {reason = Capture_directory_unavailable; status = None}
  | directory ->
    let cleanup () = release_capture_directory directory in
    let reraise exn backtrace =
      (match cleanup () with
       | Ok () -> ()
       | Error _ -> Log.Keeper.warn "private microvm CLI capture cleanup failed");
      Printexc.raise_with_backtrace exn backtrace in
    match use directory with
    | result ->
      (match cleanup () with
       | Ok () -> result
       | Error reason -> Error {reason; status = !status})
    | exception (Eio.Cancel.Cancelled _ as exn) -> reraise exn (Printexc.get_raw_backtrace ())
    | exception exn -> reraise exn (Printexc.get_raw_backtrace ())
;;

let read_complete_stdout ~capture_dir = function
  | Process_output_capture.Incomplete_file _ -> Error Capture_incomplete
  | Process_output_capture.Capture_failed { limit_exceeded = true; _ } -> Error Capture_limit_exceeded
  | Process_output_capture.Capture_failed { limit_exceeded = false; _ } -> Error Capture_failed
  | Process_output_capture.Complete_file {path; byte_length} ->
    (match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.getuid ())
        ~ownership_root:capture_dir path with
     | Error _ | Ok None -> Error Capture_unreadable
     | Ok (Some file) ->
       if file.snapshot.permissions <> 0o600 then Error Capture_permissions_invalid
       else if String.length file.content <> byte_length then Error Capture_length_mismatch
       else Ok file.content)
;;

let read_with ?timeout_sec ?stdout_limit ?stderr_limit ?fallback_policy ?env ?cwd ~argv () =
  let status = ref None in
  with_capture_directory ~status (fun directory ->
    let capture_dir = Unix.realpath directory in
    let ((observed_status, _stdout_preview, stderr_preview), files) =
      Process_output_capture.with_capture ?stdout_limit ?stderr_limit ~capture_dir (fun output_capture ->
        let (observed_status, _, _) as result =
          Process_eio.run_argv_with_status_split_streaming ?timeout_sec ?env ?cwd ?fallback_policy ~output_capture
            ~on_stdout_chunk:ignore ~on_stderr_chunk:ignore argv in
        status := Some observed_status;
        result) in
    match read_complete_stdout ~capture_dir files.stdout with
    | Ok stdout -> Ok (observed_status, stdout, stderr_preview)
    | Error reason -> Error {reason; status = Some observed_status})
;;

let read ~timeout_sec ~argv =
  read_with ~timeout_sec ~argv ()
  |> Result.map (fun (status, stdout, _) -> status, stdout)
;;

let read_with_environment ?timeout_sec ~stdout_limit ~stderr_limit ~env ~cwd ~argv () =
  read_with ?timeout_sec ~stdout_limit ~stderr_limit ~fallback_policy:Process_eio.Eio_only ~env ~cwd ~argv ()
;;

let unavailable_message = function
  | Capture_directory_unavailable -> "private capture directory unavailable"
  | Capture_incomplete -> "stdout EOF was not established"
  | Capture_failed -> "complete stdout capture unavailable"
  | Capture_limit_exceeded -> "stdout exceeded the capture byte limit"
  | Capture_unreadable -> "owned capture could not be read"
  | Capture_permissions_invalid -> "capture permissions are not private"
  | Capture_length_mismatch -> "capture byte length changed"
  | Capture_cleanup_failed -> "private capture cleanup failed"
;;

let error_message error = "microvm CLI output unavailable: " ^ unavailable_message error.reason
