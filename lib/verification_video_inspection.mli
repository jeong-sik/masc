(** Inspect complete, already-contained MP4 bytes with installed FFprobe and
    FFmpeg. Fixed MOV/MP4 demuxing disables external track references. Every
    audio/video stream is decoded from the same private source copy; other
    stream kinds are reported but never claimed as decoded. No producer
    command, path, or shell pipeline is executed. *)
type t
type error =
  | Dependency_unavailable of string list
  | Budget_spent of { program : string; budget_sec : float }
  | Command_failed of { program : string; status : Unix.process_status; detail : string }
  | Invalid_output of string
  | Storage_failed of string

val inspect : base_path:string -> bytes:string -> (t, error) result
val to_yojson : t -> Yojson.Safe.t
val error_to_string : error -> string
