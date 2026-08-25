(** Imessage_chat_db -- read inbound messages out of Messages.app's chat.db.

    Messages.app keeps its history in a SQLite database at
    [~/Library/Messages/chat.db]. This module is the only place that opens it.
    Everything above it works on {!inbound_row} values and never sees SQL.

    Reading the file needs Full Disk Access for whichever process is on the
    hook for the TCC prompt. When the grant is missing SQLite answers
    "authorization denied" rather than "file not found", so that case gets its
    own constructor: a connector that is configured and silently reading
    nothing is the failure this whole module tree is trying not to repeat. *)

type error =
  | Db_missing of string
      (** No file at the path. Carries the path that was tried. *)
  | Access_denied of string
      (** The file is there and SQLite refused. Full Disk Access is missing. *)
  | Query_failed of string
      (** Open succeeded and the statement did not. Carries SQLite's detail. *)

val error_to_string : error -> string

type inbound_row =
  { rowid : int
        (** [message.ROWID]. Monotonic per database, and the cursor the poll
            loop advances. *)
  ; text : string  (** Message body. Never empty; the query excludes those. *)
  ; sent_at_unix : float  (** Unix seconds, converted from Apple's epoch. *)
  ; service : string  (** Always ["iMessage"]; the query excludes SMS. *)
  ; sender : string  (** [handle.id] — a phone number or an email address. *)
  ; chat_guid : string  (** Messages.app chat handle, used to address replies. *)
  ; chat_identifier : string  (** Stable per-conversation id, used for binding. *)
  ; display_name : string  (** Group chat name; empty for one-to-one chats. *)
  }

val apple_ns_to_unix : int64 -> float
(** Apple's Core Data epoch is 2001-01-01T00:00:00Z and [message.date] counts
    nanoseconds from it. Pure, so the conversion is tested without a database. *)

val redact_chat_guid : string -> string
(** Replace the addressable tail of a chat guid with ["[redacted]"], keeping
    the routing prefix. A guid names a person, so it is not logged whole. *)

val default_db_path : unit -> string
(** [~/Library/Messages/chat.db], or [MASC_IMESSAGE_CHAT_DB_PATH] when set.
    The override exists so tests can point at a fixture. *)

val check_access : db_path:string -> (unit, error) result
(** Whether the file is there and this process may read it, without opening a
    connection. Separated so [status_json] can report the Full Disk Access
    verdict on every call without running a query. *)

val read_new : db_path:string -> after_rowid:int -> (inbound_row list, error) result
(** Inbound messages with [ROWID > after_rowid], oldest first, at most 100 per
    call. Excludes messages this account sent, empty bodies, and SMS. *)

val resolve_self_chat_guid : db_path:string -> (string option, error) result
(** The chat guid of the note-to-self conversation — the one whose identifier
    matches an alias of the signed-in account. Picks the most recently active
    when there are several. [None] when the account has never used one. *)
