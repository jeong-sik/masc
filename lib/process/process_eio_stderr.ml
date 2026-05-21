(** stderr-capture + process-output formatting helpers for the Eio
    process runtime.

    Pure helpers — [output_for_status], [process_error_output], and
    [reason_of_exn_for_output] are total Printf builders.
    [create_stderr_tempfile] / [remove_temp_file_quietly] /
    [read_stderr_capture] / [captured_stderr_or_empty] are the
    private-tempfile cycle used by the Unix-fallback status helpers
    in [Process_eio] when the Eio path needs to surface a child
    process's stderr without leaking descriptors.

    Verbatim extract from [Process_eio]; all callers are internal
    to the parent (verified via grep across lib/ + test/; not in
    .mli). *)

let output_for_status ~(status : Unix.process_status) ~(stdout : string)
    ~(stderr : string) : string =
  let succeeded =
    match status with
    | Unix.WEXITED 0 -> true
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false
  in
  if succeeded then stdout
  else
    match stdout, stderr with
    | "", err -> err
    | out, "" -> out
    | out, err -> out ^ "\n" ^ err

let process_error_output ?(stderr = "") ~label:_ ~reason () =
  let stderr = String.trim stderr in
  if stderr = "" then
    Printf.sprintf "process_eio_error: %s" reason
  else
    Printf.sprintf "process_eio_error: %s\nstderr:\n%s" reason stderr

let reason_of_exn_for_output = function
  | Unix.Unix_error (err, fn, _) ->
      Printf.sprintf "%s: %s" fn (Unix.error_message err)
  | exn -> Printexc.to_string exn

(** Create a private stderr capture file for Unix fallback status helpers.
    Uses [Filename.temp_file] for atomic creation, then opens the file with
    private permissions and marks the descriptor close-on-exec to avoid
    descriptor leaks into unrelated child processes. *)
let create_stderr_tempfile () =
  let path = Filename.temp_file "masc_process_eio_stderr" ".tmp" in
  let fd =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC; Unix.O_CLOEXEC ] 0o600
  in
  (path, fd)

let remove_temp_file_quietly path =
  try Sys.remove path with
  | Sys_error _ -> ()

let read_stderr_capture path =
  try In_channel.with_open_bin path In_channel.input_all with
  | Sys_error msg ->
      Printf.sprintf
        "(stderr capture error) %s: %s"
        (Filename.basename path) msg

let captured_stderr_or_empty path_opt =
  match path_opt with
  | Some path -> read_stderr_capture path
  | None -> ""
