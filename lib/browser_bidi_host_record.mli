(** What a BiDi browser host leaves about itself under
    [<base>/.masc/browser-lane/], for the TUI, [masc doctor] and a server that
    started after it. The host has no supervisor and its reason for ending
    never reaches a server that is down or restarting, so it is written here.

    Two files:
    - [bidi-host.lock]: the host holds an exclusive lock on it from start to
      exit. The kernel drops the lock however the host dies, so a reader
      learns that a host is running from the lock and from nothing the host
      has to keep fresh. One workspace has one BiDi host; a second is refused
      by this lock.
    - [bidi-host.json]: who the host is, the results it holds no
      acknowledgement for, and, once it left in order, why. Every change
      replaces the whole file, so a reader meets one host's record or the
      next one's, never parts of two.

    A host that starts replaces the record. It carries no token, no request's
    arguments and nothing read from a page: the address is stored without its
    query, a request is named by the UUID the server issued and by a verb this
    build knows, and the one free sentence, the reason for ending, is written
    as printable ASCII. *)

(** Whether the host's BiDi session is still in Firefox after it left.
    Firefox takes one session at a time and keeps one whose socket closed. *)
type session =
  | No_session_left
      (** Nothing of this host's is left in Firefox: Firefox confirmed the
          end or said this connection has no session, the host never got as
          far as asking for one, or Firefox answered its request for one with
          an error other than "session not created". *)
  | Session_left
      (** The host asked Firefox to end it and Firefox did not confirm: it
          answered with an error other than having no session, or did not
          answer in time. Take it that Firefox still holds the session, and
          then refuses the next host until it is restarted. *)
  | Session_unknown
      (** The connection was gone before the host could ask. A Firefox that
          exited took the session along; one still running keeps it. *)
  | Session_refused
      (** Firefox refused the host a session with "session not created". It
          does that while it holds one: another host's that is attached, or
          one a host that died left there. That session is not this host's.
          It was there when this host asked, and stays until its own host
          ends it or that Firefox is restarted: the record does not say
          whether it is there now. *)

type ending =
  { at : float
  ; reason : string
  ; session : session
  }

(** What became of a command whose result the host holds no acknowledgement
    for. *)
type outcome =
  | Succeeded
  | Not_started  (** Refused before any effect on the page. *)
  | Unknown

(** Why the host holds no acknowledgement. Only [Refused] and [Not_sent] say
    the server does not have the result. *)
type cause =
  | Refused  (** The server answered and did not accept the result. *)
  | Not_sent  (** The host could not send it. *)
  | Unconfirmed
      (** No acknowledgement reached the host. The server may have taken the
          result: it takes one before it answers. *)

type unacknowledged =
  { request_id : Uuidm.t option
      (** [None] when the server's ID was not the UUID it issues. *)
  ; verb : Browser_bidi_peer.verb option
      (** [None] for a verb this build cannot name: one the host did not know
          when it wrote the entry, or one added after this reader was built. *)
  ; outcome : outcome
  ; cause : cause
  ; at : float
  }

(** A request's ID as the server sent it, when it is exactly the UUID text
    the server issues. *)
val request_id_of_wire : string -> Uuidm.t option

(** The text {!request_id_of_wire} read. *)
val request_id_to_wire : Uuidm.t -> string

type entry =
  { pid : int
  ; started_at : float
  ; bidi_url : string
      (** The address the host was given, without its query. Its path is kept
          as given. *)
  ; client_id : Browser_lane.client_id
      (** The ID the host polls as now. It changes when the server ended the
          connection and the host registered again. *)
  ; attached_at : float option
      (** When Firefox gave the host its session. [None] while the host is
          still connecting, and for good when it never got one. *)
  ; unacknowledged : unacknowledged list
      (** Oldest first. Nothing is taken off it while the host runs, and each
          addition writes the whole record again. *)
  ; ended : ending option
  }

type state =
  | Never_started  (** No record: no BiDi host has run for this workspace. *)
  | Running of entry
      (** The lock is held. [attached_at] says whether the host has its
          session yet. A server that is down does not change this: the host
          keeps asking. A host that was asked to stop reads as running until
          it has left. *)
  | Ended of entry * ending  (** The host left in order and said why. *)
  | Died of entry
      (** No ending, and nobody holds the lock: the host was killed or
          crashed, or it left in order and could not write its ending. Its
          BiDi session may be left in Firefox. *)
  | Unreadable of { detail : string; held : bool option }
      (** The record is not one this reader understands or cannot be read,
          with whether a host holds the lock all the same: one that does
          refuses the next host, which then cannot replace the record.
          [held = None] is the lock that could not be asked, and [detail] is
          then why. That is also what a record without an ending reads as
          when its lock cannot be asked: whether its host runs is not known.
          A record with its ending, and no record, do not turn on the lock
          and are read without it. *)

(** Where a workspace's [bidi-host.json] is, for a reader that tells the
    operator which file it means. *)
val record_path : base_path:string -> string

(** What [bidi-host.json] and the lock say now. The two are read one after
    the other, the record first, so a reader can be wrong for as long as one
    record write takes, and right on its next read:
    - a host has just taken the lock and not yet written its record: the
      reader sees its predecessor, as [Running] when that one died, as [Ended]
      when it left in order, and [Never_started] when there was none;
    - a host wrote its ending and exited between the two reads: [Died].

    A record write that failed is carried by the host's next one that
    succeeds, so until then the record is behind: a serving host can read as
    still connecting. *)
val observe : base_path:string -> state

(** The state for a record and what the lock says. With no record, or with
    a record that has its ending, the lock changes nothing, and {!observe}
    asks it only for the others. *)
val state_of : lock_held:bool -> (entry option, string) result -> state

(** {1 The host's side} *)

type held

type refusal =
  | Another_host of int option
      (** A BiDi host holds this workspace. The pid is the record's: for the
          instant before a starting host writes its own, it is its
          predecessor's. [None] when the record cannot be read. *)
  | Bad_address of string
      (** The BiDi address is not a loopback [ws] URL this host can use. *)
  | Unavailable of string  (** The lock or the first record could not be written. *)

val refusal_message : refusal -> string

(** A record write that did not complete. *)
type write_failure =
  | Not_written of string  (** The file is what it was before. *)
  | Not_synced of string
      (** The new record is in place and readable; its directory entry was not
          flushed to disk. *)

val write_failure_message : write_failure -> string

type taken =
  { held : held
  ; not_synced : string option
      (** The host holds the workspace and its record is in place, with this
          said of the flush. *)
  }

(** Takes the lock and replaces the previous host's record with this host's.
    The previous record stands when this fails: another host holds the lock,
    the address is refused, or the record cannot be written. *)
val take
  :  base_path:string
  -> pid:int
  -> bidi_url:string
  -> client_id:Browser_lane.client_id
  -> now:float
  -> (taken, refusal) result

(** Firefox gave the host its session. *)
val attached : held -> now:float -> (unit, write_failure) result

(** The host polls under another client ID from here on. *)
val client_changed : held -> client_id:Browser_lane.client_id -> (unit, write_failure) result

val note_unacknowledged : held -> unacknowledged -> (unit, write_failure) result

(** The host is leaving in order. [reason] is written as printable ASCII: any
    other byte as [\xNN], and what passes 512 bytes left out and marked. *)
val ended : held -> reason:string -> session:session -> now:float -> (unit, write_failure) result

(** Gives the workspace up. A host does this as it leaves; the kernel does it
    for one that dies. Nothing is written through [held] afterwards. The
    workspace is given up also when closing the lock file fails, which is
    what [Error] says. *)
val release : held -> (unit, string) result

(** Times are written to the nearest millisecond. *)
val entry_to_json : entry -> Yojson.Safe.t

(** Takes the fields of this layout and no others, with these three in the
    form a host writes them: an address as it is recorded, a client ID the
    lane takes, and a reason in printable ASCII, with [\xNN] only for a byte
    a host does not write as it is, that is within the length a host keeps
    or cut there and marked. That bounds what a reader passes on to one line of known
    bytes; it does not judge what the line says. A time a host wrote is
    written back as the same text. *)
val entry_of_json : Yojson.Safe.t -> (entry, string) result
