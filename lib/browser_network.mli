(** The requests an owned Firefox tab made, collected from the BiDi [network.*]
    events: method, address, how it ended, and the names of the headers. Header
    values, cookies and bodies are never read, and the address loses its query
    values and anything before the host, because those are where tokens travel.
    A path can still carry one; it is kept because without it a request cannot
    be told from another. *)

(** The wire names to pass to [session.subscribe]. *)
val subscribed_methods : string list

(** At most this many requests are kept for one tab, oldest dropped and counted. *)
val requests_per_context : int

(** A path longer than this many bytes is cut, and the row says so. *)
val path_bytes_limit : int

type t
val create : unit -> t

(** Records one [network.*] event, named by its wire method. A payload that is
    not what BiDi documents, or a method not in {!subscribed_methods}, is an error. *)
val event : t -> method_:string -> Yojson.Safe.t -> (unit, string) result

(** The address as it is kept: scheme, host, port and path, the query's parameter
    names with every value replaced, and no user info or fragment. [None] when it
    is not an absolute address with a host. *)
val redact_url : string -> (string * bool) option

val to_json : t -> context:string -> Yojson.Safe.t
