(** Native Firefox WebDriver client. The session and tab handles belong to
    this client; callers never supply a remote session id or JavaScript. *)
type error = Transport of string | Protocol of string | Remote of { code : string; message : string }
type request = method_:Masc_http_client.Pool.http_method -> path:string -> body:Yojson.Safe.t option -> (Yojson.Safe.t, error) result
type t
val create : request:request -> t
val execute : t -> Browser_lane.verb -> Browser_lane.answer
val close : t -> (unit, error) result
val error_message : error -> string
val decode_response : status:int -> string -> (Yojson.Safe.t, error) result
