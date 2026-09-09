(** The spectator's single advancing POST. Only pixels are retained: every
    successful response supplies fresh machine and player metadata. *)
type t
val create : unit -> t

val frame_of_json : Yojson.Safe.t -> Masc_tui_types.msx_frame option
(** Decode a full frame, also used by the read-only GET. *)

val fetch :
  t -> host:string -> port:int -> headers:(string * string) list ->
  request:(body:string -> (Yojson.Safe.t, string) result) ->
  (Masc_tui_types.msx_frame option, string) result
(** Capture the host/port/authorization scope before requesting exactly once.
    Reuse pixels only when the response matches this request's advertised
    revision and dimensions. Errors clear the current request's cache and
    never retry the mutation. Network and decoding do not hold the cache lock.
    A late request cannot publish over a newer request's cache. *)
