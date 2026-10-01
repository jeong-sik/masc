(** The last answer to each dashboard read, kept with its entity tag so the
    next read of the same address can ask the server whether it changed.

    The TUI reads most dashboard addresses again on every refresh, and most
    answers do not change between refreshes. A read sends the kept tag as
    [If-None-Match]; a [304] means the server would send the same bytes
    again, and the value decoded from them last time answers the read. A tag
    names the bytes of a body, so a changed answer always comes back whole.

    What is kept follows the refresh passes: {!start_generation} runs when a
    full refresh pass starts, and an answer that no read got back in this
    generation or the one before is dropped. *)

type 'a t

val create : unit -> 'a t

type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

val read :
  'a t ->
  address:string ->
  send:((string * string) list -> (response, 'e) result) ->
  decode:(response -> ('a, 'e) result) ->
  ('a, 'e) result
(** [read t ~address ~send ~decode] reads [address] once. [send] gets the
    request headers: [If-None-Match] with the tag kept for [address], or none.

    - A [304] to a read that sent a tag answers with the kept value, and
      [decode] is not run. The answer stays kept for this generation, unless
      a read that finished meanwhile kept a different one.
    - Any other response is [decode response]. An [Ok] value from a response
      with an [ETag] header is kept for [address]; any other outcome drops
      what was kept for it.
    - An [Error] from [send] leaves what was kept as it was. *)

val start_generation : 'a t -> unit
(** Starts a new generation. The TUI calls it when a full refresh pass starts,
    so a pass that outlives several refresh ticks is still one generation. *)
