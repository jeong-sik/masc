type channel =
  | Hint
  | Approve
  | Reject
  | Redirect

type entry =
  { id : string
  ; at : string
  ; channel : channel
  ; to_ : string list
  ; body : string
  ; ack : bool
  }

val channel_to_string : channel -> string
val entry_to_yojson : entry -> Yojson.Safe.t
val recent : config:Coord.config -> limit:int -> entry list
val json : config:Coord.config -> limit:int -> unit -> Yojson.Safe.t
