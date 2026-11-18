(* See [fd_append_whole.mli] for the contract. *)

type target =
  | Regular_file of Unix.file_descr
  | Stream of Unix.file_descr

let descriptor = function
  | Regular_file fd | Stream fd -> fd
;;

let append_flags access = [ access; Unix.O_APPEND; Unix.O_CREAT; Unix.O_CLOEXEC ]

(* Whether the path names a regular file, or nothing yet (the open then
   creates one). *)
let regular_file_expected path =
  match (Unix.stat path).Unix.st_kind with
  | Unix.S_REG -> true
  | Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> false
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
;;

let open_target path =
  let readable = regular_file_expected path in
  let fd =
    Unix.openfile path (append_flags (if readable then Unix.O_RDWR else Unix.O_WRONLY)) 0o644
  in
  match readable, (Unix.fstat fd).Unix.st_kind with
  | true, Unix.S_REG -> Regular_file fd
  | false, Unix.S_REG
    (* The path changed between the two calls. The descriptor is open for
       writing only, so it is used as one that cannot be read. *)
  | ( (true | false)
    , (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK) ) ->
    Stream fd
  | exception (Unix.Unix_error _ as error) ->
    Unix.close fd;
    raise error
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

type left_in_place =
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
  | Left_in_place of
      { bytes : int
      ; reason : left_in_place
      }

type failure =
  | End_unreadable of
      { error : Unix.error
      ; function_name : string
      ; argument : string
      }
  | End_moved
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

let observe ~io ~start fd =
  match
    retrying_eintr (fun () ->
      let size = io.end_offset fd in
      match start with
      | Anywhere -> Some { size; ends_mid_line = false }
      | At_line_start ->
        if size = 0
        then Some { size; ends_mid_line = false }
        else
          Option.map
            (fun byte -> { size; ends_mid_line = not (Char.equal byte '\n') })
            (io.last_byte fd ~size))
  with
  | Ok (Some before) -> Ok before
  | Ok None -> Error End_moved
  | Error (error, function_name, argument) ->
    Error (End_unreadable { error; function_name; argument })
;;

(* The call's bytes are removed only when the file is exactly [size_before +
   bytes] long. Every other writer of these files appends, so that length
   means nothing was added since [size_before] was read except this call's
   bytes, and they are everything after [size_before]. *)
let roll_back ~io ~fd ~size_before ~bytes =
  if bytes = 0
  then Nothing_written
  else (
    let expected_size = size_before + bytes in
    match
      retrying_eintr (fun () ->
        let size = io.end_offset fd in
        if size = expected_size then io.truncate fd size_before;
        size)
    with
    | Ok size when size = expected_size -> Rolled_back { bytes }
    | Ok size ->
      Left_in_place { bytes; reason = Changed_by_another_writer { expected_size; size } }
    | Error (error, function_name, argument) ->
      Left_in_place { bytes; reason = Rollback_error { error; function_name; argument } })
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
      | bytes -> Left_in_place { bytes; reason = Not_a_regular_file }
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

let left_in_place_to_string = function
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
  | Left_in_place { bytes; reason } ->
    Printf.sprintf "%d bytes left in the file (%s)" bytes (left_in_place_to_string reason)
;;

let failure_to_string = function
  | End_unreadable { error; function_name; argument = _ } ->
    Printf.sprintf
      "the end of the file could not be read (%s: %s); nothing written"
      function_name
      (Unix.error_message error)
  | End_moved -> "the file became shorter while its end was being read; nothing written"
  | Write_failed { write_failure; rollback } ->
    write_failure_to_string write_failure ^ "; " ^ rollback_to_string rollback
;;
