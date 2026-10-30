(** Pure Read coordinate decoding and slicing of bytes acquired by a filesystem backend.
    This module does not resolve paths, read files, or render prompt guidance. *)

type read_line_window =
  { start_line : int (* 1-based first line to return *)
  ; max_lines : int option (* cap on returned lines; None = to EOF *)
  }

type coordinate = Offset | Limit

type argument_error =
  | Invalid_integer of { coordinate : coordinate; value : Yojson.Safe.t }
  | Below_one of { coordinate : coordinate; value : int }
  | Not_an_object of Yojson.Safe.t

val of_args : Yojson.Safe.t -> (read_line_window, argument_error) result
(** Only absent coordinates use defaults. JSON integers, including integer
    literals and integral finite numbers, must fit the native index type.
    Present malformed or out-of-range values are errors, never absence. *)

type read_window_slice =
  { window_content : string
  ; returned_lines : int
  ; next_offset : int option
  ; window_truncated : bool
  ; last_line_partial : bool
  }

val slice_read_window :
  window:read_line_window -> first_line:int -> max_bytes:int ->
  scan_complete:bool -> string ->
  (read_window_slice, [ `Offset_beyond_scan ]) result
(** [first_line] identifies the first line in the supplied bytes.
    [scan_complete] proves EOF; a bounded prefix alone cannot do so.
    [Error `Offset_beyond_scan] means the requested line lies beyond a
    prefix whose EOF has not been observed. Byte truncation preserves complete
    lines where available; [last_line_partial] reports a cut inside one line.
    [next_offset] is absent only when the window has reached proven EOF. *)
