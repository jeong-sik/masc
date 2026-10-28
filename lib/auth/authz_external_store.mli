(* HIGH-RISK-UNREVIEWED: this module reads and writes the file of the external
   store. A line it writes decides whether a boot trusts the authorization log,
   and a line that does not read back stops every later start. *)

(** The external store of design 8.2 and 8.4: a file outside the backup of the
    base path. Before an event is appended to the authorization log, the store
    gets an intent that names the record the event will become. After the
    append it gets the answer: the record is in the log, or the intent is given
    up. A restore of the base path does not take the file back in time, so a
    boot can tell a log that was reverted from a log that was never ahead.

    The file machinery (the recovery read, the cut of a last line that never
    ended, the zone, the append at the cursor, the stop after a failure) is that
    of {!Authz_jsonl_file}. This module fixes the format of the lines and the
    rules that a line must follow the lines before it. What a boot concludes
    from the file belongs to the layers above.

    {b Entries.} A line is one {!entry}. [Intent_pending] says that an event is
    about to be appended to the log. It names the hash of the record before the
    event and the hash of the record the event will be. [Committed] says that
    the record is in the log. [Aborted_intent] says that the intent will not be
    carried out, and repeats it.

    {b Rules.} At most one intent is pending. An [Intent_pending] comes only
    when none is pending. A [Committed] closes the pending intent and carries
    the hash that the intent named. An [Aborted_intent] closes the pending
    intent and repeats it exactly. A second committed [Fresh_bootstrap] is
    refused. A line that breaks a rule is refused when it is appended
    ({!Rejected}) and when the file is opened ({!Line_rejected}). *)

(** What an intent is about to change (design 8.2). *)
module Change : sig
  (** The events that raise a scoped epoch or change a credential generation. *)
  type authz_event =
    | Grant
    | Revoke
    | Disable
    | Delete
    | Block
    | Purge
    | Policy_revoke
    | Credential_replace

  (** The events that set the mode of the installation (design 5.1). *)
  type mode_event =
    | Fresh_bootstrap
    | Off
    | Reactivate

  (** An authorization event is about a {!Authz_records.Subject.t}. A mode event
      is about the workspace. Neither can be paired with the other kind of
      subject. *)
  type t =
    | Authz of
        { event : authz_event
        ; subject : Authz_records.Subject.t
        }
    | Mode of
        { event : mode_event
        ; workspace_id : Authz_types.Workspace_id.t
        }

  val authz_events : authz_event list
  val mode_events : mode_event list
  val equal : t -> t -> bool

  (** Whether the change reduces authority or invalidates a credential
      (design 8.3): every authorization event except [Grant]. A mode event does
      not. *)
  val is_reduction : t -> bool

  (** A label for logs and messages. It is not parsed back. *)
  val to_string : t -> string
end

type intent =
  { previous_record_hash : Authz_record.Hash.t
        (** The hash of the last record of the log before the event. *)
  ; intended_next_record_digest : Authz_record.Hash.t
        (** The hash of the record the event will be. *)
  ; change : Change.t
  }

type entry =
  | Intent_pending of intent
  | Committed of { record_hash : Authz_record.Hash.t }
  | Aborted_intent of intent

(** What the lines of a file add up to. *)
module State : sig
  type t

  (** The state of a file that holds no line. *)
  val empty : t

  (** The intent that has no answer yet. *)
  val pending : t -> intent option

  (** The hash of the record of the last [Committed]. *)
  val last_committed : t -> Authz_record.Hash.t option

  (** Every [Aborted_intent], in file order. *)
  val aborted : t -> intent list

  (** The workspace of the committed [Fresh_bootstrap], if there is one. *)
  val workspace_id : t -> Authz_types.Workspace_id.t option
end

(** The rule that a line breaks. *)
type violation =
  | Intent_while_pending  (** An [Intent_pending] while an intent is pending. *)
  | Committed_without_intent  (** A [Committed] while none is pending. *)
  | Committed_other_digest
      (** The hash of a [Committed] is not the hash that the pending intent
          named. *)
  | Aborted_without_intent  (** An [Aborted_intent] while none is pending. *)
  | Aborted_other_intent
      (** An [Aborted_intent] that is not the pending intent, field for field. *)
  | Bootstrap_committed_again
      (** A [Committed] that closes a [Fresh_bootstrap] when one is committed. *)

val violation_to_string : violation -> string

(** Why a line is not the next line of the file. *)
type line_error =
  | Not_json
  | Unexpected_shape  (** Not exactly the members of an entry, in order. *)
  | Unknown_kind of string
  | Invalid_hash  (** A hash that is not 64 lowercase hex characters. *)
  | Invalid_change  (** A change that is not one of the shapes of {!Change.t}. *)
  | Breaks_a_rule of violation
  | Non_canonical  (** Parses to an entry but is not the line {!to_line} writes. *)

val line_error_to_string : line_error -> string

(** The entry as one line, without the trailing newline. *)
val to_line : entry -> string

(** Reads a line that is expected after the lines that [State.t] adds up. The
    line must be the exact bytes {!to_line} writes for the entry it names. The
    checks run in the order of the constructors of {!line_error}, and the first
    failure is the result. *)
val of_line : State.t -> string -> (entry, line_error) result

type t

(** Proof that the caller is inside the zone of a store. See
    {!Authz_jsonl_file.Make.with_writer}. *)
type writer

type stop = Authz_jsonl_file.stop =
  { path : string
  ; reason : string
  }

(** [Some] once the store is stopped, for the caller that reports health. *)
val stopped : t -> stop option

(** These are the types of {!Authz_jsonl_file}, with their constructors listed
    so that a caller matches on them here. *)
type contents = Authz_jsonl_file.contents =
  | Missing
  | Empty
  | Lines of int

type tail = Authz_jsonl_file.tail =
  | Complete
  | Cut of
      { kept_bytes : int
      ; discarded_bytes : int
      }

type recovered = Authz_jsonl_file.recovered =
  { contents : contents
  ; tail : tail
  }

(** Why the file did not open. [Line_rejected] carries a {!line_error}. The other
    constructors are those of {!Authz_jsonl_file.Make}. *)
type 'reason open_error =
  | Locked of { path : string }
  | Unreadable of
      { path : string
      ; detail : string
      }
  | Line_rejected of
      { path : string
      ; line_number : int
      ; error : line_error
      }
  | Fold_refused of
      { path : string
      ; line_number : int
      ; reason : 'reason
      }

val open_error_to_string : ('reason -> string) -> 'reason open_error -> string

(** For process start only. Reads the whole file, cuts a last line that never
    ended, checks the lines one by one with {!of_line} from the empty state, and
    folds the entries in file order with [step], starting from [init]. See
    {!Authz_jsonl_file.Make.open_at_start} for the rest, [step] included. The
    file is created by the first append, not by this call. *)
val open_at_start
  :  path:string
  -> init:'state
  -> step:('state -> entry -> ('state, 'reason) result)
  -> (t * 'state * recovered, 'reason open_error) result

(** Runs [f] inside the zone of [t], with what the lines add up to at that
    moment. See {!Authz_jsonl_file.Make.with_writer}. *)
val with_writer : t -> (writer -> State.t -> 'a) -> ('a, stop) result

(** Why an append wrote nothing, or failed. [Rejected] carries the
    {!violation}. [Would_not_read_back] means that {!of_line} refuses the line
    that {!to_line} writes, and [Read_back_changed] means that it reads the line
    as another entry. Both are bugs in this module. The other constructors are
    those of {!Authz_jsonl_file.Make}. *)
type append_error =
  | Writer_expired
  | Stopped of stop
  | Rejected of
      { index : int
      ; reject : violation
      }
  | Would_not_read_back of
      { index : int
      ; error : line_error
      }
  | Read_back_changed of { index : int }
  | Write_locked of { path : string }
  | Diverged of { path : string }
  | Write_failed of
      { path : string
      ; detail : string
      }

val append_error_to_string : append_error -> string

(** Writes the entries, in order, with one write call and one sync, and returns
    the state after the last one. Each entry must follow the rules against the
    entries before it. See {!Authz_jsonl_file.Make.append}. *)
val append : writer -> entry list -> (State.t, append_error) result
