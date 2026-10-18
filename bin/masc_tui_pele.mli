(** Offline Pele subprocess, called only by the image acquisition worker. *)
val render :
  cache_dir:string -> max_width:int -> colors:(string * string) option ->
  string -> (string, string) result
(** Pass exact source and captured geometry/palette over stdin to [masc-pele].
    Returns PNG bytes or an explicit failure. Owns and removes all temporary
    files; never reads or writes the terminal. *)
