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
