type failure =
  | Open_file_posix_descriptor_unavailable
  | Open_file_operation_failed of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      ; bytes_written : int
      }

(** Write every byte of [content] to an already-open resource without running
    blocking regular-file writes on the Eio scheduler domain. The caller owns
    the next cancellation checkpoint so it can first commit or report any
    externally visible bytes. *)
val write_string
  :  label:string
  -> _ Eio.Resource.t
  -> string
  -> (unit, failure) result
