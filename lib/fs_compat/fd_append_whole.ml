(* See [fd_append_whole.mli] for the contract. *)

type observed_end =
  | Empty
  | Last_byte of char

type io =
  { write : Unix.file_descr -> string -> int -> int -> int
  ; position : Unix.file_descr -> int
  ; truncate : Unix.file_descr -> int -> unit
  ; observe_end : Unix.file_descr -> observed_end
  }

let unix_observe_end fd =
  let size = Unix.lseek fd 0 Unix.SEEK_END in
  if size = 0
  then Empty
  else (
    let (_ : int) = Unix.lseek fd (size - 1) Unix.SEEK_SET in
    let byte = Bytes.create 1 in
    match Unix.read fd byte 0 1 with
    | 1 -> Last_byte (Bytes.get byte 0)
    | _ ->
      (* Another descriptor made the file shorter between the two calls. *)
      raise (Unix.Unix_error (Unix.EIO, "read", "last byte of the file")))
;;

(* [Unix.single_write_substring], not [Unix.write_substring]: the latter
   loops over [write(2)] itself and, when a later round fails, raises
   without the count of the bytes the earlier rounds wrote (OCaml 5.5.2
   [otherlibs/unix/write_unix.c]). The rollback needs that count. *)
let unix_io =
  { write = Unix.single_write_substring
  ; position = (fun fd -> Unix.lseek fd 0 Unix.SEEK_CUR)
  ; truncate = Unix.ftruncate
  ; observe_end = unix_observe_end
  }
;;

type start =
  | Anywhere
  | At_line_start

type rollback =
  | Nothing_written
  | Rolled_back of { bytes : int }
  | Rollback_failed of
      { bytes : int
      ; error : Unix.error
      ; function_name : string
      ; argument : string
      }

type failure =
  | End_unreadable of
      { error : Unix.error
      ; function_name : string
      ; argument : string
      }
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

(* The writes of one call are consecutive: the caller holds the per-path
   mutex and the descriptor is [O_APPEND]. So the descriptor's offset after
   the last write that succeeded is the end of this call's bytes, and the
   call's first byte sits [bytes] before it. *)
let roll_back ~io ~fd ~bytes =
  if bytes = 0
  then Nothing_written
  else (
    match retrying_eintr (fun () -> io.truncate fd (io.position fd - bytes)) with
    | Ok () -> Rolled_back { bytes }
    | Error (error, function_name, argument) ->
      Rollback_failed { bytes; error; function_name; argument })
;;

(* The bytes one call writes: the content, behind a newline when the append
   has to start a line and the file ends in the middle of one. *)
let bytes_to_write ~io ~start ~fd content =
  match start with
  | Anywhere -> Ok content
  | At_line_start ->
    (match retrying_eintr (fun () -> io.observe_end fd) with
     | Ok Empty -> Ok content
     | Ok (Last_byte byte) ->
       if Char.equal byte '\n' then Ok content else Ok ("\n" ^ content)
     | Error (error, function_name, argument) ->
       Error (End_unreadable { error; function_name; argument }))
;;

let run ~io ~start ~fd content =
  if String.equal content ""
  then Ok ()
  else (
    match bytes_to_write ~io ~start ~fd content with
    | Error failure -> Error failure
    | Ok bytes ->
      (match
         Fd_write_all.run
           ~length:(String.length bytes)
           ~write:(fun ~offset ~length -> io.write fd bytes offset length)
       with
       | Ok () -> Ok ()
       | Error write_failure ->
         let rollback = roll_back ~io ~fd ~bytes:(bytes_written write_failure) in
         Error (Write_failed { write_failure; rollback })))
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

let rollback_to_string = function
  | Nothing_written -> "file unchanged"
  | Rolled_back { bytes } -> Printf.sprintf "%d bytes removed again" bytes
  | Rollback_failed { bytes; error; function_name; argument = _ } ->
    Printf.sprintf
      "%d bytes left at the end of the file (%s: %s)"
      bytes
      function_name
      (Unix.error_message error)
;;

let failure_to_string = function
  | End_unreadable { error; function_name; argument = _ } ->
    Printf.sprintf
      "the end of the file could not be read (%s: %s); nothing written"
      function_name
      (Unix.error_message error)
  | Write_failed { write_failure; rollback } ->
    write_failure_to_string write_failure ^ "; " ^ rollback_to_string rollback
;;
