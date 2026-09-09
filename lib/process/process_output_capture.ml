type source =
  | Complete_file of { path : string; byte_length : int }
  | Incomplete_file of { path : string; byte_length : int }
  | Capture_failed of { path : string option; message : string }

type files = { stdout : source; stderr : source }
type stream = Stdout | Stderr

type open_file = {
  path : string;
  channel : out_channel;
  mutable byte_length : int;
  pending : bytes;
  mutable pending_length : int;
}

type state = Open of open_file | Closed of source
type t = { stdout : state ref; stderr : state ref }

let blocking f =
  Eio_guard.run_in_systhread ~label:"process-output-capture" f

let io_message = function
  | Sys_error message -> message
  | Unix.Unix_error (error, operation, _) ->
    operation ^ ": " ^ Unix.error_message error
  | exn -> Printexc.to_string exn

let failed ?path exn =
  Closed (Capture_failed { path; message = io_message exn })

let open_stream ~capture_dir prefix =
  match
    Filename.open_temp_file ~temp_dir:capture_dir ~mode:[ Open_binary ]
      ~perms:0o600 prefix ".raw"
  with
  | path, channel ->
    (try
       Unix.set_close_on_exec (Unix.descr_of_out_channel channel);
       Open
         { path; channel; byte_length = 0
         ; pending = Bytes.create Sys.io_buffer_size; pending_length = 0
         }
     with
     | (Sys_error _ | Unix.Unix_error _) as exn ->
       close_out_noerr channel;
       failed ~path exn)
  | exception ((Sys_error _ | Unix.Unix_error _) as exn) -> failed exn

let create ~capture_dir =
  blocking (fun () ->
    match
      Fs_compat.mkdir_p (Filename.dirname capture_dir);
      (try Unix.mkdir capture_dir 0o700 with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    with
    | () ->
      { stdout = ref (open_stream ~capture_dir "stdout-")
      ; stderr = ref (open_stream ~capture_dir "stderr-")
      }
    | exception ((Sys_error _ | Unix.Unix_error _) as exn) ->
      { stdout = ref (failed exn); stderr = ref (failed exn) })

let select t = function Stdout -> t.stdout | Stderr -> t.stderr

let flush_pending file =
  output file.channel file.pending 0 file.pending_length;
  file.byte_length <- file.byte_length + file.pending_length;
  file.pending_length <- 0

let append t ~stream chunk =
  let state = select t stream in
  let rec copy offset =
    match !state with
    | Closed _ -> ()
    | Open file ->
      let count = min (String.length chunk - offset)
          (Bytes.length file.pending - file.pending_length) in
      Bytes.blit_string chunk offset file.pending file.pending_length count;
      file.pending_length <- file.pending_length + count;
      (* Keep the pipe's chunk cadence for previews and live callbacks, but
         offload file I/O in standard-library-sized blocks rather than paying
         a system-thread transition for every small pipe read. *)
      if file.pending_length = Bytes.length file.pending then
        blocking (fun () ->
          try flush_pending file with
          | (Sys_error _ | Unix.Unix_error _) as exn ->
            close_out_noerr file.channel;
            state := failed ~path:file.path exn);
      if offset + count < String.length chunk then copy (offset + count)
  in
  copy 0

let close_state ~complete state =
  match !state with
  | Closed _ -> ()
  | Open file ->
    (try
       flush_pending file;
       close_out file.channel;
       state :=
         Closed
           (if complete
            then Complete_file { path = file.path; byte_length = file.byte_length }
            else Incomplete_file { path = file.path; byte_length = file.byte_length })
     with
     | (Sys_error _ | Unix.Unix_error _) as exn ->
       close_out_noerr file.channel;
       state := failed ~path:file.path exn)

let end_of_stream t ~stream =
  blocking (fun () -> close_state ~complete:true (select t stream))

let unavailable t ~message =
  blocking (fun () ->
    let invalidate state =
      close_state ~complete:false state;
      match !state with
      | Closed (Capture_failed _) -> ()
      | Closed (Complete_file { path; _ } | Incomplete_file { path; _ }) ->
        state := Closed (Capture_failed { path = Some path; message })
      | Open _ -> assert false
    in
    invalidate t.stdout;
    invalidate t.stderr)

let close t =
  blocking (fun () ->
    close_state ~complete:false t.stdout;
    close_state ~complete:false t.stderr)

let files t : files =
  let source state =
    match !state with
    | Closed source -> source
    | Open file ->
      Incomplete_file { path = file.path; byte_length = file.byte_length }
  in
  { stdout = source t.stdout; stderr = source t.stderr }

let with_capture ~capture_dir f =
  let owned = ref None in
  let result, capture =
    Eio_guard.protect
      ~finally:(fun () -> Option.iter close !owned)
      (fun () ->
        let capture = create ~capture_dir in
        owned := Some capture;
        f capture, capture)
  in
  result, files capture
