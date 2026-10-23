(** Native Firefox WebDriver client. The session and tab handles belong to
    this client; callers never supply a remote session id or JavaScript. *)
(** W3C WebDriver error codes the client recovers from, parsed once by
    [decode_response]. [Other] carries an unlisted code verbatim. *)
type remote_error = Invalid_session_id | No_such_window | No_such_alert | Unexpected_alert_open | Other of string
type error = Transport of string | Protocol of string | Remote of { code : remote_error; message : string }
type request = method_:Masc_http_client.Pool.http_method -> path:string -> body:Yojson.Safe.t option -> (Yojson.Safe.t, error) result
type t
type located_node = { node_id : string; description : string }
type locate = scene:Browser_scene.t -> instruction:string option ->
  (located_node list, string) result
(** Read-only selection over a supplied scene. Returns only node references;
    the driver checks them against both original and current observations.
    May suspend in the original command scope; must not re-enter the driver. *)
val session_observation : t -> Browser_lane.session_observation
(** Nonblocking local lifecycle observation. Registration or a driver process
    alone does not establish an open Firefox session. *)
type profiles = { fresh : unit -> (string, string) result; ended : string -> unit }
(** Where each new session's Firefox profile comes from. [fresh] makes one;
    Firefox runs it through [-profile], and a session whose browser reports
    another [moz:profile] is closed and refused. [ended] receives the path once
    that session has ended or failed to start. *)
val create : ?binary:string -> ?locate:locate -> ?profiles:profiles -> ?lost:(unit -> unit) ->
  start_downloads:Browser_downloads.start -> request:request -> unit -> t
(** [binary] is forwarded verbatim to moz:firefoxOptions.binary. Missing means
    geckodriver discovers its default Firefox; an invalid explicit path fails.
    Without [profiles], geckodriver makes and deletes a temporary profile.
    [lost] is called when the driver may hold a browser this client can no
    longer address: a session creation that raised, failed in transport or
    protocol, or answered without a session id, and an [invalid session id]
    reply about the current session. A creation the driver refused with a
    WebDriver error started no session and is not a loss. *)
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
