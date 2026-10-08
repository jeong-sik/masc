(** An explicitly attached Firefox. Closing the peer never closes its tabs or
    browser. Context IDs are owned by BiDi, not extension tab IDs. *)
type failure = Before_effect of string | Outcome_unknown of string
(** Native host verbs, decoded once from the MASC poll wire. *)
type verb = Browser_info | Tabs_list | Page_read | Page_elements | Page_capture | Page_scene | Page_interact
(** Why a command has no result. [Rejected] is the browser's own error
    answer, with its code. [Unanswered] is a command that was written and got
    no readable answer: the connection ended under it, the reply did not come
    in time, or it was not a BiDi result. [Unsent] was never written: the
    connection had already ended. *)
type refusal = Rejected of string | Unanswered of string | Unsent of string
type t
(** [command] carries one BiDi command; [session_end] ends the session. They
    are separate because the session is also ended on a connection that
    carries no further command. *)
val create
  :  session_end:(unit -> (unit, string) result)
  -> command:(string -> Yojson.Safe.t -> (Yojson.Safe.t, refusal) result)
  -> t
(** Asks the browser for a BiDi session and answers the browser's version. *)
val metadata : t -> (string, string) result
(** Ends the session {!metadata} asked for; [Ok ()] when there is none to
    end. There is one to end from the moment the request is written, also
    when no answer came, and none once the browser rejected it. Firefox
    keeps a session whose socket closed and takes one at a time, so a session
    left behind refuses every later connection until that Firefox is
    restarted. Ending it closes no tab and leaves the browser running. Under
    {!with_connection} this is sent for as long as the socket is open, also
    after a command got no reply, and waits at most
    {!session_end_window_sec}. *)
val end_session : t -> (unit, string) result
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
