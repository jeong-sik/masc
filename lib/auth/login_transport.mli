(** The requests of a login to its provider, as functions (plan C2a-3,
    C2b-1a). The Google and the GitHub login take them as arguments, so
    neither does I/O of its own: the server passes calls of the shared HTTP
    client, and the tests answer for the provider. *)

(** One answer. *)
type response =
  { status : int
  ; headers : (string * string) list
  ; body : string
  }

type get = url:string -> headers:(string * string) list -> (response, string) result
type post = url:string -> headers:(string * string) list -> body:string -> (response, string) result

(** 64 KiB. A login refuses a longer answer. The documents of Google and of
    GitHub that a login reads are a few KiB. The server passes the same bound
    to the shared HTTP client. *)
val max_answer_bytes : int

(** An [https] URL with a host and no query or fragment. Provider endpoints and
    the redirect URI of a client follow this rule. *)
val is_https_url : string -> bool

(** [key=value] pairs joined by [&], with every byte that is not unreserved
    (RFC 3986 section 2.3) percent-encoded. An authorization query and an
    [application/x-www-form-urlencoded] token request both read it. *)
val form : (string * string) list -> string
