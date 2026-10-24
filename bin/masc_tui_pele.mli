(** Offline Pele subprocess, called only by the image acquisition worker. *)
type format = Mermaid | Svg
type scene = private {
  format : format;
  source : string;
  max_width : int;
  font_size : int;
  colors : (string * string) option;
}
type crop = { left : float; top : float; right : float; bottom : float }
type raster = { width : int; height : int; crop : crop option }
val scene : format:format -> max_width:int -> font_size:int ->
  colors:(string * string) option -> string -> scene
(** Original source and frozen layout metrics. Raster requests never relayout a
    scene. Crop corners are normalized to its full viewBox, including origin. *)
val render :
  cache_dir:string -> ?raster:raster -> scene -> (string, string) result
(** Pass explicit source format, exact markup and captured geometry/palette over stdin to [masc-pele].
    Returns PNG bytes or an explicit failure. Owns and removes all temporary
    files; never reads or writes the terminal. *)
