type failure =
  | No_progress of { bytes_written : int }
  | Unix_error of
      { bytes_written : int
      ; error : Unix.error
      ; function_name : string
      ; argument : string
      }
  | Operation_failed of
      { bytes_written : int
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }

let run ~length ~write =
  let rec loop offset =
    if offset = length
    then Ok ()
    else
      match write ~offset ~length:(length - offset) with
      | 0 -> Error (No_progress { bytes_written = offset })
      | written -> loop (offset + written)
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop offset
      | exception Unix.Unix_error (error, function_name, argument) ->
        Error
          (Unix_error
             { bytes_written = offset; error; function_name; argument })
      | exception (Eio.Cancel.Cancelled _ as cancellation) -> raise cancellation
      | exception exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        Error (Operation_failed { bytes_written = offset; exception_; backtrace })
  in
  loop 0
;;
