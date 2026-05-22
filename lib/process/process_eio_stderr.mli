(** stderr-capture + process-output formatting helpers for the Eio
    process runtime. *)

val output_for_status
  :  status:Unix.process_status
  -> stdout:string
  -> stderr:string
  -> string

val process_error_output
  :  ?stderr:string
  -> label:string
  -> reason:string
  -> unit
  -> string

val reason_of_exn_for_output : exn -> string

val create_stderr_tempfile : unit -> string * Unix.file_descr

val remove_temp_file_quietly : string -> unit

val read_stderr_capture : string -> string

val captured_stderr_or_empty : string option -> string
