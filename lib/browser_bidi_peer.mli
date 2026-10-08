(** An explicitly attached Firefox. Closing the peer never closes its tabs or
    browser. Context IDs are owned by BiDi, not extension tab IDs. *)
type failure = Before_effect of string | Outcome_unknown of string
(** Native host verbs, decoded once from the MASC poll wire. *)
type verb = Browser_info | Tabs_list | Page_read | Page_elements | Page_capture | Page_scene | Page_interact
type t
val create : command:(string -> Yojson.Safe.t -> (Yojson.Safe.t, string) result) -> t
val metadata : t -> (string, string) result
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
