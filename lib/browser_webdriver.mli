(** Native Firefox WebDriver client. The session and tab handles belong to
    this client; callers never supply a remote session id or JavaScript. *)
type error = Transport of string | Protocol of string | Remote of { code : string; message : string }
type request = method_:Masc_http_client.Pool.http_method -> path:string -> body:Yojson.Safe.t option -> (Yojson.Safe.t, error) result
type t
val create : ?binary:string -> start_downloads:Browser_downloads.start -> request:request -> unit -> t
(** [binary] is forwarded verbatim to moz:firefoxOptions.binary. Missing means
    geckodriver discovers its default Firefox; an invalid explicit path fails. *)
val execute : t -> Browser_lane.verb -> Browser_lane.answer
val observe_document_if_idle : t -> tab_id:int -> Browser_lane.answer
(** Observe the already selected document only when no owned command is active.
    Does not create a session, switch tab/frame, release actions, or enqueue
    behind a busy driver. Refusal describes missing optional coverage. *)
(** [request] supplies a transport with its own lifetime during server teardown.
    The owned session is cleared only after a confirmed deletion. *)
val close : ?request:request -> t -> (unit, error) result
val error_message : error -> string
val decode_response : status:int -> string -> (Yojson.Safe.t, error) result
