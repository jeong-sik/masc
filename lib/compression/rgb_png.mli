(** Deterministic, lossless RGB8 PNG encoding. No filesystem or subprocesses. *)
val encode : width:int -> height:int -> rgb:string -> (string, string) result
