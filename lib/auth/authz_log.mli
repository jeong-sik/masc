(* HIGH-RISK-UNREVIEWED: this module opens, replays, and appends to the
   authorization log. A line it writes is a grant, revocation, or principal that
   the whole system treats as true, and a line that does not read back stops
   every later start. *)

(** The file of the authorization log, [authz.jsonl] (design 6.3, 8.1).

    The file machinery is that of {!Authz_jsonl_file}: the recovery read at
    process start, the cut of a last line that never ended, the zone, the append
    at the cursor, and the stop after a failure. This module fixes the format of
    the lines. Each line is an {!Authz_record.t} that carries the hash of the
    line before it, so the file is a chain, and the state of the file is the
    head of the chain ({!Authz_record.head}). The module knows the file and
    nothing about what a record means. What the records add up to (the value
    that the caller folds them into), which events may follow which, and what a
    pointer into the external high-water mark means belong to the layers above.

    {b The log.} [<base path>/.masc/auth/authz.jsonl], next to [config.json]
    ({!path_of_base_path}). Open the log once per process and path.

    {b Who writes, and after a failure.} The rules are those of
    {!Authz_jsonl_file}. Inside the process there is one zone per {!t}, entered
    through {!with_writer}. A log is stopped when an append fails and the module
    cannot say whether the file changed, when the end of the file is not where
    this process left it, or when the write raises an exception. A stopped log
    does not enter a zone ({!with_writer} returns [Error]) and every {!append}
    returns {!Stopped}, until the process restarts and opens the file again.
    While the log is stopped, the in-memory head is not trusted, and the file is
    the only truth. A refusal that wrote nothing ({!Write_locked}, {!Rejected},
    {!Would_not_read_back}) does not stop the log. *)

type t

(** Proof that the caller is inside the zone of a log. It is valid until the
    function given to {!with_writer} returns. *)
type writer

(** Why a log is stopped. *)
type stop = Authz_jsonl_file.stop =
  { path : string
  ; reason : string
  }

(** [Some] once the log is stopped, for the caller that reports health. *)
val stopped : t -> stop option

(** [<base path>/.masc/auth/authz.jsonl]. *)
val path_of_base_path : base_path:string -> string

(** What the file was when it was opened. This is the type of
    {!Authz_jsonl_file}, with its constructors listed so that a caller matches
    on them here. *)
type contents = Authz_jsonl_file.contents =
  | Missing
  | Empty
  | Lines of int

(** How the file ended when it was opened. Same re-export as {!contents}. *)
type tail = Authz_jsonl_file.tail =
  | Complete
  | Cut of
      { kept_bytes : int
      ; discarded_bytes : int
      }

(** What opening found: the {!contents} after the cut, if there was one, and the
    {!tail}. Same re-export as {!contents}. *)
type recovered = Authz_jsonl_file.recovered =
  { contents : contents
  ; tail : tail
  }

(** Why the file did not open. [Line_rejected] means that {!Authz_record.of_line}
    refuses the line as the next line of the chain. The other constructors are
    those of {!Authz_jsonl_file.Make}. *)
type 'reason open_error =
  | Locked of { path : string }
  | Unreadable of
      { path : string
      ; detail : string
      }
  | Line_rejected of
      { path : string
      ; line_number : int
      ; error : Authz_record.decode_error
      }
  | Fold_refused of
      { path : string
      ; line_number : int
      ; reason : 'reason
      }

val open_error_to_string : ('reason -> string) -> 'reason open_error -> string

(** For process start only. Reads the whole file under the lock of [Fs_compat],
    cuts a last line that never ended (see {!tail}), then checks the lines one
    by one with {!Authz_record.of_line}, starting at {!Authz_record.genesis},
    and folds the records in file order with [step], starting from [init]. The
    first line that fails, or that [step] refuses, is the result.

    The read, the check, and [step] run on a system thread through
    [Systhread_host.run], so the Eio domain keeps serving. [step] must be pure:
    no Eio, no file or network access, and it may not depend on which domain
    runs it. It sees records that are already verified, and it reports a
    refusal as [Error], not as an exception.

    The module keeps the head and the end of the file. It does not keep the
    state: what to keep, and how to publish it, is for the caller. *)
val open_at_start
  :  path:string
  -> init:'state
  -> step:('state -> Authz_record.t -> ('state, 'reason) result)
  -> (t * 'state * recovered, 'reason open_error) result

(** Runs [f] inside the zone of [t], with the head of the log at that moment,
    and returns what [f] returns. A stopped log is not entered: the result is
    [Error] and [f] does not run, so no caller gets a head that is not trusted.

    Must be called from an Eio fiber, and not from inside a zone of the same
    [t]: that call would wait for itself. Other callers of [with_writer] on the
    same [t] wait. Cancellation is held off while [f] runs, so an append that
    was handed to the file cannot be left written in the file but missing from
    the head. For the same reason keep [f] short: a long wait inside it also
    holds off a shutdown. A fiber that is cancelled while it waits does not
    enter, unless the zone had already been handed to it.

    [f] gets the head the zone starts with and gets the next head from
    {!append}. Build records from those ({!Authz_record.make}). Hold the zone
    only for what must be decided against the latest state, as design 7.1 asks.
    One fiber at a time uses a writer, and nobody keeps it after [f] returns:
    {!append} then returns {!Writer_expired}. *)
val with_writer : t -> (writer -> Authz_record.head -> 'a) -> ('a, stop) result

(** Why the chain refuses a record as the next record. *)
type reject =
  | Wrong_seq of
      { expected : int
      ; actual : int
      }  (** The seq of the record is not the next seq. *)
  | Wrong_previous_hash  (** The record names a different record before it. *)

(** Why an append wrote nothing, or failed. The constructors are those of
    {!Authz_jsonl_file.Make}. [Rejected] carries a {!reject}.
    [Would_not_read_back] means that {!Authz_record.of_line} refuses the line
    that {!Authz_record.to_line} writes for the record, which is a bug in
    [Authz_record]. *)
type append_error =
  | Writer_expired
  | Stopped of stop
  | Rejected of
      { index : int
      ; reject : reject
      }
  | Would_not_read_back of
      { index : int
      ; error : Authz_record.decode_error
      }
  | Write_locked of { path : string }
  | Diverged of { path : string }
  | Write_failed of
      { path : string
      ; detail : string
      }

val append_error_to_string : append_error -> string

(** Writes the records, in order, with one write call and one sync, and
    returns the head after the last one. The first record must continue the
    current head of the zone (the head [f] was given, or the one the last
    {!append} returned), each next record the one before it. A list that does
    not continue the chain is refused with [Rejected] before any byte is
    written. Each line is read back with {!Authz_record.of_line} before it is
    written, so a line that {!Authz_record.of_line} would refuse at the next
    start is never written. The fold function of {!open_at_start} is not run
    here, and a record that it refuses stops every later start, so the caller
    runs the same fold function before it appends. An empty list writes
    nothing.

    Once this returns [Ok], the lines are in the file and synced the way
    [Fs_compat] syncs. [Fs_compat] does not call [F_FULLFSYNC], so the lines
    survive a restart of the process, not a power cut.

    A crash in the middle of the write can leave the first lines of the list
    in the file. The next start keeps every complete line and cuts only a last
    line that never ended. A caller that needs a list to land whole or not at
    all appends one record per call.

    If the call that runs the write on a system thread raises an exception (for
    example [Systhread_host.Host_failed]), the lines may be in the file. The
    log is stopped and the exception goes on to the caller. This holds even when
    the exception was raised before the file work began, because the module
    cannot tell the two cases apart. An exception raised while the records are
    checked comes before any byte is written and does not stop the log. The
    caller must not append the same records again: the next start shows what
    the file holds. *)
val append : writer -> Authz_record.t list -> (Authz_record.head, append_error) result
