(** stderr-capture + process-output formatting helpers for the Eio
    process runtime. *)

val output_for_status
  :  status:Unix.process_status
  -> stdout:string
  -> stderr:string
  -> string

val process_error_output
  :  ?stderr:string
  -> ?partial_stdout:string
  -> label:string
  -> reason:string
  -> unit
  -> string
(** The failure text a caller gets instead of a result. [partial_stdout] is
    whatever the child had already written, appended under a label saying it
    is incomplete: a non-zero exit keeps its stdout, so a timeout throwing it
    away was the inconsistent case. The [process_eio_error:] line stays first
    so a consumer that reads only the head still sees the failure. *)

val reason_of_exn_for_output : exn -> string

val create_stderr_tempfile : unit -> string * Unix.file_descr

val remove_temp_file_quietly : string -> unit

val captured_stderr_or_empty : string option -> string
