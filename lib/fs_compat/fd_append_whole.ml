(* See [fd_append_whole.mli] for the contract. *)

type io =
  { write : Unix.file_descr -> string -> int -> int -> int
  ; position : Unix.file_descr -> int
  ; truncate : Unix.file_descr -> int -> unit
  }

(* [Unix.single_write_substring], not [Unix.write_substring]: the latter
   loops over [write(2)] itself and, when a later round fails, raises
   without the count of the bytes the earlier rounds wrote (OCaml 5.5.2
   [otherlibs/unix/write_unix.c]). The rollback needs that count. *)
let unix_io =
  { write = Unix.single_write_substring
  ; position = (fun fd -> Unix.lseek fd 0 Unix.SEEK_CUR)
  ; truncate = Unix.ftruncate
  }
;;

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
  | () -> Ok ()
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

let run ~io ~fd content =
  match
    Fd_write_all.run
      ~length:(String.length content)
      ~write:(fun ~offset ~length -> io.write fd content offset length)
  with
  | Ok () -> Ok ()
  | Error write_failure ->
    let rollback = roll_back ~io ~fd ~bytes:(bytes_written write_failure) in
    Error { write_failure; rollback }
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

let failure_to_string { write_failure; rollback } =
  write_failure_to_string write_failure ^ "; " ^ rollback_to_string rollback
;;
