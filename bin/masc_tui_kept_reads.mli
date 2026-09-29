(** The last answer to each dashboard read, kept with its entity tag so the
    next read of the same address can ask the server whether it changed.

    The TUI reads most dashboard addresses again on every refresh tick, and
    most answers do not change between ticks. A read sends the kept tag as
    [If-None-Match]; a [304] means the server would send the same bytes
    again, and the value decoded from them last time answers the read. A tag
    names the bytes of a body, so a changed answer always comes back whole.

    What is kept follows the refresh cadence: {!start_generation} runs once
    per tick, and an answer that no read asked for during the last two
    generations is dropped. *)

type 'a t

val create : unit -> 'a t

type 'a kept
(** An answer as kept: its entity tag and the value decoded from its body. *)

val find : 'a t -> address:string -> 'a kept option
(** The answer kept for [address] when a read asked for it in this generation
    or the one before. Finding it keeps it for this generation too. *)

val request_headers : 'a kept option -> (string * string) list
(** [If-None-Match] with the kept tag, or no header. *)

val settle :
  'a t ->
  address:string ->
  sent:'a kept option ->
  status:int ->
  headers:(string * string) list ->
  decode:(unit -> ('a, 'e) result) ->
  ('a, 'e) result
(** The value that answers a read of [address] that sent
    [request_headers sent] and got [status] and [headers]. A [304] to a read
    that sent a tag is the kept value, and [decode] is not run. Any other
    answer is [decode ()]: an [Ok] value from an answer with an [ETag] header
    is kept for [address], and any other outcome drops what was kept for it. *)

val start_generation : 'a t -> unit
(** Starts a new generation. Called once per refresh tick. *)
