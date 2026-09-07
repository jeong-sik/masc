type error =
  | Incomplete_stream of string
  | Capture_failed of string
  | Persistence_failed of string

let error_to_string = function
  | Incomplete_stream stream -> stream ^ " did not reach confirmed EOF"
  | Capture_failed message -> "output capture failed: " ^ message
  | Persistence_failed message -> "output publication failed: " ^ message

let error_code = function
  | Incomplete_stream _ -> "execute_output_capture_incomplete"
  | Capture_failed _ -> "execute_output_capture_failed"
  | Persistence_failed _ -> "execute_output_externalization_failed"

let capture_directory ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "execute_output"

type publication =
  { fields : (string * Yojson.Safe.t) list
  ; release_sources : unit -> unit
  }

let complete_path stream = function
  | Process_output_capture.Complete_file { path; byte_length } -> Ok (path, byte_length)
  | Process_output_capture.Incomplete_file _ -> Error (Incomplete_stream stream)
  | Process_output_capture.Capture_failed { message; path = _ } ->
    Error (Capture_failed message)

let ( let* ) = Result.bind

(* All file I/O and redaction below runs in the same blocking job. *)
let copy_chunks ?expected_bytes path emit =
  let fd = Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0 in
  let channel =
    match Unix.in_channel_of_descr fd with
    | channel -> channel
    | exception exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      (try Unix.close fd with Unix.Unix_error _ -> ());
      Printexc.raise_with_backtrace exception_ backtrace
  in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
    let before = Unix.fstat fd in
    if before.st_kind <> Unix.S_REG then raise (Sys_error "captured output is not a regular file");
    (match expected_bytes with
     | Some expected when expected <> before.st_size ->
       raise (Sys_error "captured output size differs from its EOF receipt")
     | Some _ | None -> ());
    let buffer = Bytes.create Sys.io_buffer_size in
    let rec loop total =
      match input channel buffer 0 (Bytes.length buffer) with
      | 0 -> total
      | count -> emit (Bytes.sub_string buffer 0 count); loop (total + count)
    in
    let count = loop 0 in
    let after = Unix.fstat fd in
    if count <> before.st_size || before.st_dev <> after.st_dev
       || before.st_ino <> after.st_ino || before.st_size <> after.st_size
       || before.st_mtime <> after.st_mtime || before.st_ctime <> after.st_ctime
    then raise (Sys_error "captured output changed while publishing");
    close_in channel)

let unlink_if_present path =
  try Unix.unlink path with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let publish ~base_path ~redaction (files : Process_output_capture.files) =
  let* stdout_path, stdout_bytes = complete_path "stdout" files.stdout in
  let* stderr_path, stderr_bytes = complete_path "stderr" files.stderr in
  Eio_guard.run_in_systhread ~label:"keeper-execute-publish-output" (fun () ->
    let temporary_files = ref [] in
    let temporary_file () =
      let path = Filename.temp_file ~temp_dir:(Filename.dirname stdout_path)
          "redacted-" ".output" in
      temporary_files := path :: !temporary_files;
      path
    in
    let cleanup paths =
      List.iter
        (fun path ->
          try unlink_if_present path with
          | Unix.Unix_error (error, operation, _) ->
            Log.Keeper.warn "execute output cleanup failed %s: %s (%s)"
              path (Unix.error_message error) operation)
        paths
    in
    (* fun-protect-finally-ok: synchronous file cleanup inside the blocking
       job, preserving an original publication/cancellation exception. *)
    Fun.protect ~finally:(fun () -> cleanup !temporary_files) (fun () ->
      try
        let redact_file path expected_bytes =
          let destination = temporary_file () in
          let state = Keeper_secret_redaction.create_stream_state redaction in
          Out_channel.with_open_bin destination (fun channel ->
            copy_chunks ~expected_bytes path (fun chunk ->
              output_string channel (Keeper_secret_redaction.redact_stream_chunk state chunk));
            output_string channel (Keeper_secret_redaction.redact_stream_finish state));
          destination
        in
        let stdout = redact_file stdout_path stdout_bytes in
        let stderr = redact_file stderr_path stderr_bytes in
        let combined = temporary_file () in
        Out_channel.with_open_bin combined (fun channel ->
          copy_chunks stdout (output_string channel);
          copy_chunks stderr (output_string channel));
        let total_bytes = (Unix.stat combined).st_size in
        let fields =
          if total_bytes <= Tool_bridge.default_externalize_threshold_bytes then
            [ "output", `String (In_channel.with_open_bin combined In_channel.input_all) ]
          else
            let store = Tool_blob_store.create ~base_path in
            let store_file path =
              Tool_blob_store.put_file_durable store ~path ~mime:"text/plain"
              |> Tool_output.normalized_artifact_ref_to_json
            in
            [ "output_artifact", store_file combined
            ; "stdout_artifact", store_file stdout
            ; "stderr_artifact", store_file stderr
            ]
        in
        Ok
          { fields = ("output_completeness", `String "complete") :: fields
          ; release_sources = (fun () ->
              Eio_guard.run_in_systhread ~label:"keeper-execute-release-output"
                (fun () -> cleanup [ stdout_path; stderr_path ]))
          }
      with
      | Sys_error message -> Error (Persistence_failed message)
      | Unix.Unix_error (error, operation, path) ->
        Error (Persistence_failed
          (Printf.sprintf "%s %s: %s" operation path (Unix.error_message error)))))
