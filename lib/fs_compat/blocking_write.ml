type failure =
  | Open_file_posix_descriptor_unavailable
  | Open_file_operation_failed of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      ; bytes_written : int
      }

let write_string ~label resource content =
  match Eio_unix.Resource.fd_opt resource with
  | None -> Error Open_file_posix_descriptor_unavailable
  | Some fd ->
    Eio_unix.run_in_systhread ~label (fun () ->
      Eio_unix.Fd.use_exn label fd (fun unix_fd ->
        match
          Fd_write_all.run
            ~length:(String.length content)
            ~write:(fun ~offset ~length ->
              Unix.write_substring unix_fd content offset length)
        with
        | Ok () -> Ok ()
        | Error (Fd_write_all.No_progress { bytes_written }) ->
          Error
            (Open_file_operation_failed
               { exception_ =
                   Unix.Unix_error
                     (Unix.EIO, "write", "regular file accepted zero bytes")
               ; backtrace = Printexc.get_callstack 0
               ; bytes_written
               })
        | Error
            (Fd_write_all.Unix_error
              { bytes_written; error; function_name; argument }) ->
          Error
            (Open_file_operation_failed
               { exception_ = Unix.Unix_error (error, function_name, argument)
               ; backtrace = Printexc.get_callstack 0
               ; bytes_written
               })
        | Error
            (Fd_write_all.Operation_failed
              { bytes_written; exception_; backtrace }) ->
          Error
            (Open_file_operation_failed
               { exception_; backtrace; bytes_written })))
;;
