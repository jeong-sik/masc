(** An explicitly attached Firefox. Closing the peer never closes its tabs or
    browser. Context IDs are owned by BiDi, not extension tab IDs. *)
type failure = Before_effect of string | Outcome_unknown of string
(** Native host verbs, decoded once from the MASC poll wire. *)
type verb = Browser_info | Tabs_list | Page_read | Page_elements | Page_capture | Page_scene | Page_interact
(** The name a verb goes by on the wire and in the host's record. *)
val verb_to_wire : verb -> string
val verb_of_wire : string -> verb option
(** The browser's error codes this host acts on, and any other one as the
    browser wrote it. A code is made only by {!error_code_of_wire}, so the
    two this host acts on are never carried as [Other_error]. *)
type error_code = private
  | Session_not_created
      (** Firefox will not serve a [session.new]. BiDi answers this for any
          reason a session cannot start; Firefox 157.0.1 was seen to answer
          it while it held a session for another connection. *)
  | Invalid_session_id  (** A session command on a connection that has no session. *)
  | Other_error of string

val error_code_of_wire : string -> error_code
val error_code_to_wire : error_code -> string

(** Why a command has no result. [Rejected] is the browser's own error
    answer, with its code. [Unanswered] is a command that was written and got
    no readable answer: the connection ended under it, the reply did not come
    in time, or it was not a BiDi result. [Unsent] was never written: the
    connection had already ended. *)
type refusal = Rejected of error_code | Unanswered of string | Unsent of string
type t
(** Why a session was not ended. [Connection_gone]: there was no socket left
    to ask over, so a Firefox that has quit holds no session and one that
    still runs keeps it; this side cannot tell which. [Not_confirmed]:
    Firefox could be asked and did not confirm. It answered with an error
    other than having no session, or did not answer in time, and is taken to
    keep the session. *)
type session_end_failure = Connection_gone of string | Not_confirmed of string
val session_end_failure_message : session_end_failure -> string
(** [command] carries one BiDi command; [session_end] ends the session. They
    are separate because the session is also ended on a connection that
    carries no further command. *)
val create
  :  session_end:(unit -> (unit, session_end_failure) result)
  -> command:(string -> Yojson.Safe.t -> (Yojson.Safe.t, refusal) result)
  -> t
(** Why the browser gave no session. [Session_refused]: it answered
    [session.new] with "session not created". Firefox does that while it
    holds a session, which it keeps after the socket that asked for it has
    closed: another host's that is attached, or one a host that died left.
    [Session_failed]: any other way, with nothing said of a session there. *)
type session_failure = Session_refused of string | Session_failed of string
val session_failure_message : session_failure -> string
(** Asks the browser for a BiDi session and answers the browser's version. *)
val metadata : t -> (string, session_failure) result
(** Ends the session {!metadata} asked for; [Ok ()] when there is none to
    end, which is also what Firefox's "invalid session id" says of a session
    that was asked for and never confirmed. There is one to end from the
    moment the request is written, also when no answer came, and none once
    the browser rejected it. Firefox
    keeps a session whose socket closed and takes one at a time, so a session
    left behind refuses every later connection until that Firefox is
    restarted. Ending it closes no tab and leaves the browser running. Under
    {!with_connection} this is sent for as long as the socket is open, also
    after a command got no reply, and waits at most
    {!session_end_window_sec}. *)
val end_session : t -> (unit, session_end_failure) result
val session_end_window_sec : float
val dispatch : t -> verb:verb -> Yojson.Safe.t -> (Yojson.Safe.t, failure) result
(** One socket message carries at most this many bytes; a larger one ends the
    connection. *)
val reply_limit_bytes : int
(** A page script's answer longer than this many UTF-16 units is refused in
    the page, as [Before_effect] for a read, instead of being sent: at three
    bytes a unit it could pass {!reply_limit_bytes}. *)
val script_answer_limit_units : int
(** [with_connection ~env ~timeout ~url use] connects and hands [use] the
    peer. [ended] resolves, with why, once the connection carries no further
    command: Firefox closed it, the socket failed, a message was not BiDi, or
    a command got no reply within [timeout]. From then on every command
    answers that reason; the caller decides when to stop. *)
val with_connection : env:Eio_unix.Stdenv.base -> timeout:float -> url:string ->
  (ended:string Eio.Promise.t -> t -> (unit, string) result) -> (unit, string) result
