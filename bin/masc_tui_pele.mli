(** Offline Pele subprocess, called only by the image acquisition worker. *)
type format = Mermaid | Svg
type scene = private {
  format : format;
  source : string;
  max_width : int;
  font_size : int;
  now_ms : int64;
  colors : (string * string) option;
}
type crop = { left : float; top : float; right : float; bottom : float }
type raster = { width : int; height : int; crop : crop option }
(** Original source and frozen layout metrics. Raster requests never relayout a
    scene. The acquisition edge captures [now_ms] once so time-derived diagram
    coordinates stay fixed during inspection. Crop corners are normalized to its original rendered viewport,
    including authored viewBox letterboxing or clipping. *)
val scene : format:format -> max_width:int -> font_size:int -> now_ms:int64 ->
  colors:(string * string) option -> string -> scene

val render :
  cache_dir:string -> ?raster:raster -> scene -> (string, string) result
(** Pass explicit source format, exact markup and captured geometry/palette over stdin to [masc-pele].
    Returns PNG bytes or an explicit failure. Owns and removes all temporary
    files; never reads or writes the terminal. *)
