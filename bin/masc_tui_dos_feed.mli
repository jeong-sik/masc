(** The DOS spectator's reading of [GET /api/v1/dos/frame] (#38424). No I/O. *)

val known_query : Masc_tui_types.dos_frame option -> (string * string) list
(** The query parameters naming the held frame ([incarnation], [steps]), or
    none when nothing is held. *)

val decode :
  held:Masc_tui_types.dos_frame option
  -> Yojson.Safe.t
  -> (Masc_tui_types.dos_frame option, string) result
(** [Ok None] when the server says no machine is loaded. An answer with
    [pixels:"unchanged"] reuses [held]'s pixels, and is an [Error] when [held]
    is not the frame the server named. Any unreadable answer is an [Error]. *)
