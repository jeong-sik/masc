(* See [fd_append_whole.mli] for the contract. *)

type target =
  | Regular_file of Unix.file_descr
  | Stream of Unix.file_descr

let descriptor = function
  | Regular_file fd | Stream fd -> fd
;;

let append_flags access = [ access; Unix.O_APPEND; Unix.O_CREAT; Unix.O_CLOEXEC ]

let is_regular = function
  | Unix.S_REG -> true
  | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> false
;;

(* Whether the path names a regular file, or nothing yet (the open then
   creates one). *)
let regular_file_expected path =
  match Unix.stat path with
  | stats -> is_regular stats.Unix.st_kind
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
;;

let rec open_target path =
  let expected = regular_file_expected path in
  let access = if expected then Unix.O_RDWR else Unix.O_WRONLY in
  let fd = Unix.openfile path (append_flags access) 0o644 in
  match expected, is_regular (Unix.fstat fd).Unix.st_kind with
  | exception (Unix.Unix_error _ as error) ->
    Unix.close fd;
    raise error
  | true, true -> Regular_file fd
  | false, false -> Stream fd
  | true, false | false, true ->
    (* The path came to name another kind of file between the two calls.
       The access mode was chosen for the first kind: a regular file
       opened for writing only cannot be read, and a FIFO opened for
       reading too did not wait for its reader. Start again. *)
    Unix.close fd;
    open_target path
;;

type io =
  { write : Unix.file_descr -> string -> int -> int -> int
  ; end_offset : Unix.file_descr -> int
  ; last_byte : Unix.file_descr -> size:int -> char option
  ; truncate : Unix.file_descr -> int -> unit
  }

(* The offset these calls leave behind does not matter to the write: the
   descriptor is [O_APPEND], so every write lands at the end of the file. *)
let unix_last_byte fd ~size =
  let (_ : int) = Unix.lseek fd (size - 1) Unix.SEEK_SET in
  let byte = Bytes.create 1 in
  match Unix.read fd byte 0 1 with
  | 1 -> Some (Bytes.get byte 0)
  | _ -> None
;;

(* [Unix.single_write_substring], not [Unix.write_substring]: the latter
   loops over [write(2)] itself and, when a later round fails, raises
   without the count of the bytes the earlier rounds wrote (OCaml 5.5.2
   [otherlibs/unix/write_unix.c]). The rollback needs that count. *)
let unix_io =
  { write = Unix.single_write_substring
  ; end_offset = (fun fd -> Unix.lseek fd 0 Unix.SEEK_END)
  ; last_byte = unix_last_byte
  ; truncate = Unix.ftruncate
  }
;;

type start =
  | Anywhere
  | At_line_start

type not_rolled_back =
  | Not_a_regular_file
  | Changed_by_another_writer of
      { expected_size : int
      ; size : int
      }
  | Rollback_error of
      { error : Unix.error
      ; function_name : string
      ; argument : string
      }

type rollback =
  | Nothing_written
  | Rolled_back of { bytes : int }
  | Not_rolled_back of
      { bytes : int
      ; reason : not_rolled_back
      }

type failure =
  | End_unreadable of
      { error : Unix.error
      ; function_name : string
      ; argument : string
      }
  | Last_byte_missing of { size : int }
  | Write_failed of
      { write_failure : Fd_write_all.failure
      ; rollback : rollback
      }

let bytes_written = function
  | Fd_write_all.No_progress { bytes_written }
  | Fd_write_all.Unix_error { bytes_written; _ }
  | Fd_write_all.Operation_failed { bytes_written; _ } -> bytes_written
;;

let rec retrying_eintr f =
  match f () with
  | value -> Ok value
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> retrying_eintr f
  | exception Unix.Unix_error (error, function_name, argument) ->
    Error (error, function_name, argument)
;;

let write_all ~io fd bytes =
  Fd_write_all.run
    ~length:(String.length bytes)
    ~write:(fun ~offset ~length -> io.write fd bytes offset length)
;;

(* What a regular file looked like before the call wrote to it. *)
type before =
  { size : int
  ; ends_mid_line : bool
  }

(* What one look at the end of a regular file found. *)
type look =
  | Seen of before
  | No_byte_before of int

let look_once ~io ~start fd =
  let size = io.end_offset fd in
  match start with
  | Anywhere -> Seen { size; ends_mid_line = false }
  | At_line_start ->
    if size = 0
    then Seen { size; ends_mid_line = false }
    else (
      match io.last_byte fd ~size with
      | Some byte -> Seen { size; ends_mid_line = not (Char.equal byte '\n') }
      | None -> No_byte_before size)
;;

(* The file can become shorter between the two calls of a look, when
   another process takes back its own failed append. The length read
   first is then stale, so the file is looked at again. Every further
   look has to find a shorter file, which ends the looks: a file that
   did not shrink and still has no byte before its end is reported. *)
let observe ~io ~start fd =
  let rec look ~shorter_than =
    match retrying_eintr (fun () -> look_once ~io ~start fd) with
    | Ok (Seen before) -> Ok before
    | Ok (No_byte_before size) ->
      (match shorter_than with
       | Some previous when size >= previous -> Error (Last_byte_missing { size })
       | Some _ | None -> look ~shorter_than:(Some size))
    | Error (error, function_name, argument) ->
      Error (End_unreadable { error; function_name; argument })
  in
  look ~shorter_than:None
;;

(* The call's bytes are removed only when the file is exactly [size_before +
   bytes] long. When every other writer of the file only appends, that
   length means nothing was added since [size_before] was read except this
   call's bytes, and they are everything after [size_before]. A shorter
   file is never grown back to [size_before]. *)
let roll_back ~io ~fd ~size_before ~bytes =
  if bytes = 0
  then Nothing_written
  else (
    let expected_size = size_before + bytes in
    let left reason = Not_rolled_back { bytes; reason } in
    (* [truncate_interrupted]: a [truncate] of this call raised [EINTR].
       Whether it had cut the file by then is read from the file's length:
       a file that is [size_before] long has lost this call's bytes. *)
    let rec attempt ~truncate_interrupted =
      match io.end_offset fd with
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> attempt ~truncate_interrupted
      | exception Unix.Unix_error (error, function_name, argument) ->
        left (Rollback_error { error; function_name; argument })
      | size when size = expected_size ->
        (match io.truncate fd size_before with
         | () -> Rolled_back { bytes }
         | exception Unix.Unix_error (Unix.EINTR, _, _) ->
           attempt ~truncate_interrupted:true
         | exception Unix.Unix_error (error, function_name, argument) ->
           left (Rollback_error { error; function_name; argument }))
      | size when truncate_interrupted && size = size_before -> Rolled_back { bytes }
      | size -> left (Changed_by_another_writer { expected_size; size })
    in
    attempt ~truncate_interrupted:false)
;;

let append_to_regular_file ~io ~start fd content =
  match observe ~io ~start fd with
  | Error failure -> Error failure
  | Ok before ->
    let bytes = if before.ends_mid_line then "\n" ^ content else content in
    (match write_all ~io fd bytes with
     | Ok () -> Ok ()
     | Error write_failure ->
       let rollback =
         roll_back ~io ~fd ~size_before:before.size ~bytes:(bytes_written write_failure)
       in
       Error (Write_failed { write_failure; rollback }))
;;

let append_to_stream ~io fd content =
  match write_all ~io fd content with
  | Ok () -> Ok ()
  | Error write_failure ->
    let rollback =
      match bytes_written write_failure with
      | 0 -> Nothing_written
      | bytes -> Not_rolled_back { bytes; reason = Not_a_regular_file }
    in
    Error (Write_failed { write_failure; rollback })
;;

let run ~io ~start target content =
  if String.equal content ""
  then Ok ()
  else (
    match target with
    | Regular_file fd -> append_to_regular_file ~io ~start fd content
    | Stream fd -> append_to_stream ~io fd content)
;;

let write_failure_to_string = function
  | Fd_write_all.No_progress { bytes_written } ->
    Printf.sprintf "write accepted no bytes after %d" bytes_written
  | Fd_write_all.Unix_error { bytes_written; error; function_name; argument = _ } ->
    Printf.sprintf
      "%s failed after %d bytes: %s"
      function_name
      bytes_written
      (Unix.error_message error)
  | Fd_write_all.Operation_failed { bytes_written; exception_; backtrace = _ } ->
    Printf.sprintf
      "write failed after %d bytes: %s"
      bytes_written
      (Printexc.to_string exception_)
;;

let not_rolled_back_to_string = function
  | Not_a_regular_file -> "not a regular file"
  | Changed_by_another_writer { expected_size; size } ->
    Printf.sprintf
      "another writer changed the file: %d bytes long, %d expected"
      size
      expected_size
  | Rollback_error { error; function_name; argument = _ } ->
    Printf.sprintf "%s: %s" function_name (Unix.error_message error)
;;

let rollback_to_string = function
  | Nothing_written -> "file unchanged"
  | Rolled_back { bytes } -> Printf.sprintf "%d bytes removed again" bytes
  | Not_rolled_back { bytes; reason } ->
    Printf.sprintf "%d bytes not removed (%s)" bytes (not_rolled_back_to_string reason)
;;

let failure_to_string = function
  | End_unreadable { error; function_name; argument = _ } ->
    Printf.sprintf
      "the end of the file could not be read (%s: %s); nothing written"
      function_name
      (Unix.error_message error)
  | Last_byte_missing { size } ->
    Printf.sprintf
      "the file is %d bytes long and has no byte before its end; nothing written"
      size
  | Write_failed { write_failure; rollback } ->
    write_failure_to_string write_failure ^ "; " ^ rollback_to_string rollback
;;
