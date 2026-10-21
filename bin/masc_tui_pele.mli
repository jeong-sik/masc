(** Offline Pele subprocess, called only by the image acquisition worker. *)
type format = Mermaid | Svg
val render :
  format:format ->
  cache_dir:string -> max_width:int -> colors:(string * string) option ->
  string -> (string, string) result
(** Pass explicit source format, exact markup and captured geometry/palette over stdin to [masc-pele].
    Returns PNG bytes or an explicit failure. Owns and removes all temporary
    files; never reads or writes the terminal. *)
