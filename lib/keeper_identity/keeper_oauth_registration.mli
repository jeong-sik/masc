(** Registering this installation as a client, when the authorization server
    lets a client register itself (RFC 7591).

    An operator who has already created an app has a client id and should
    keep using it. This is for the case where nobody has: the server hands
    one out, and the installation stops needing a step in a browser that has
    nothing to do with what the operator was trying to do.

    The registration is per installation, not per Keeper. Which person a
    Keeper acts as is decided at consent; the client id only says which
    software is asking. *)

type error =
  | Transport of string
  | Refused of { status : int; body : string }
      (** the server answered and declined. The body is kept: a server that
          refuses a redirect URI says so there, and that is the one thing an
          operator can act on. *)
  | Malformed of string

val error_to_string : error -> string

type registered = {
  client_id : string;
  issued_at : float;  (** unix seconds, as the server dated it *)
}

(** How registration reaches the server. Injected so the request this builds
    and the answer it reads can be exercised against a recorded response. *)
type post =
  url:string -> headers:(string * string) list -> body:string ->
  (int * string, string) result

val register :
  ?post:post ->
  registration_url:string ->
  client_name:string ->
  redirect_uri:string ->
  unit ->
  (registered, error) result
(** Ask for a client id.

    Registers as a public client: the token endpoint is told [none], and PKCE
    proves the redemption instead. A server may still return a client secret,
    and this deliberately does not keep it -- storing a credential nothing
    sends is worse than not having one, because the next reader has to work
    out whether it matters. *)
