(** What a page wrote to its console and the errors it raised, collected from the
    BiDi [log.entryAdded] event on an owned Firefox. Entry text is whatever the page
    printed: it is data from the page, and a page can print anything. *)

(** The wire name to pass to [session.subscribe]. *)
val subscribed_method : string

(** At most this many entries are kept for one tab. When more arrive the oldest
    are dropped, and {!to_json} says how many. *)
val entries_per_context : int

(** An entry's text is cut at this many bytes, and the entry says it was. *)
val text_bytes_limit : int

type t
val create : unit -> t

(** Records one [log.entryAdded] event. It never fails, because the connection
    that feeds it also carries download evidence, and a log entry must not end
    that. What BiDi documents as optional is accepted: a [null] text is kept as
    [null], and an entry whose source names no browsing context is counted as
    unattributed instead of being given to a tab. An event that is not what BiDi
    documents is counted as malformed, with the reason of the last one. *)
val event : t -> Yojson.Safe.t -> unit

(** The entries kept for one tab, oldest first, and how many older ones were
    dropped to stay within {!entries_per_context}. [unattributedEntries] and
    [malformedEvents] are about the whole session, not the tab. *)
val to_json : t -> context:string -> Yojson.Safe.t
