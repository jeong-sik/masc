(* HIGH-RISK-UNREVIEWED: this module opens, replays, and appends to the
   authorization log. A line it writes is a grant, revocation, or principal that
   the whole system treats as true, and a line that does not read back stops
   every later start. *)

(** The file of the authorization log, [authz.jsonl] (design 6.3, 8.1).

    The module knows the file and nothing about what a line means. At process
    start it reads every line, checks the chain with {!Authz_record.of_line},
    and hands each record to a fold function that the caller passes. Later it
    appends lines, one zone at a time. What state the lines add up to, which
    events may follow which, and what a pointer into the external high-water
    mark means belong to the layers above.

    {b The file.} [<base path>/.masc/auth/authz.jsonl], next to [config.json]
    ({!path_of_base_path}). [Fs_compat] creates it with mode 0600 and keeps a
    stable lock file beside it. The module keeps the head of the chain and the
    end of the file (a cursor of [Fs_compat], made of device, inode, and size).
    Open the log once per process and path. A second {!t} on the same path does
    not share the zone, so its first append returns {!Diverged} and stops it.

    {b Who writes.} Inside the process, one zone per {!t}: an [Eio.Mutex] held
    while a function runs ({!with_writer}). Between processes, this module
    relies on two things it does not check. Only one server runs on a base
    path, and a tool that reads the file takes the lock of [Fs_compat] for the
    length of one read. While a tool holds that lock an append returns
    {!Write_locked}. A second writer on the same file shows up as {!Diverged}.

    {b After a failure.} The log is stopped when an append fails and the module
    cannot say whether the file changed, when the end of the file is not where
    this process left it, or when the write raises an exception. A stopped log
    does not enter a zone ({!with_writer} returns [Error]) and every {!append}
    returns {!Stopped}, until the process starts again and opens the file
    again. The in-memory head is then not trusted, and the file is the only
    truth. A refusal that wrote nothing ({!Write_locked}, {!Wrong_seq},
    {!Wrong_previous_hash}, {!Would_not_read_back}) does not stop the log. *)

type t

(** Proof that the caller is inside the zone of a log. It is valid until the
    function given to {!with_writer} returns. *)
type writer

(** Why a log is stopped. *)
type stop =
  { path : string
  ; reason : string
  }

(** [Some] once the log is stopped, for the caller that reports health. *)
val stopped : t -> stop option

(** [<base path>/.masc/auth/authz.jsonl]. *)
val path_of_base_path : base_path:string -> string

(** What the file was when it was opened. *)
type contents =
  | Missing  (** There is no file. *)
  | Empty  (** The file exists and holds no complete line. *)
  | Lines of int  (** The file holds this many complete lines. *)

type tail =
  | Complete  (** The file ended after a complete line. *)
  | Cut of
      { kept_bytes : int
      ; discarded_bytes : int
      }
      (** The file ended inside a line, left by an append that died. The
          module cut it back to the last complete line and synced. The cut
          bytes were never acknowledged to any caller. *)

type recovered =
  { contents : contents  (** After the cut, if there was one. *)
  ; tail : tail
  }

type 'reason open_error =
  | Locked of { path : string }
      (** Another process holds the lock. Nothing was read. *)
  | Unreadable of
      { path : string
      ; detail : string
      }  (** The file, or a directory above it, cannot be read. [detail] says why. *)
  | Line_rejected of
      { path : string
      ; line_number : int  (** From 1. *)
      ; error : Authz_record.decode_error
      }  (** The line is not the next line of the chain. *)
  | Fold_refused of
      { path : string
      ; line_number : int  (** From 1. *)
      ; reason : 'reason
      }  (** The caller's fold function refused the record on this line. *)

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

type append_error =
  | Writer_expired  (** The zone of this writer has ended. Nothing was written. *)
  | Stopped of stop
      (** An earlier failure stopped the log. See the top of this file. Nothing
          was written. *)
  | Wrong_seq of
      { index : int  (** In the list, from 0. *)
      ; expected : int
      ; actual : int
      }  (** The seq of the record is not the next seq. Nothing was written. *)
  | Wrong_previous_hash of { index : int }
      (** The record names a different record before it. Nothing was written. *)
  | Would_not_read_back of
      { index : int
      ; error : Authz_record.decode_error
      }
      (** {!Authz_record.of_line} refuses the line that {!Authz_record.to_line}
          writes for this record. This means a bug in [Authz_record]. Nothing
          was written. *)
  | Write_locked of { path : string }
      (** Another process holds the lock. Nothing was written and the log is
          not stopped. The caller may try again later; this module never
          retries. *)
  | Diverged of { path : string }
      (** The end of the file is not where this process left it: another writer
          appended, or the file was cut. The file is identified by device,
          inode, and size, so a file of the same size that took the old inode
          number is not noticed. The log is stopped. *)
  | Write_failed of
      { path : string
      ; detail : string
      }
      (** The write failed in a way that leaves the file unknown. The log is
          stopped. *)

val append_error_to_string : append_error -> string

(** Writes the records, in order, with one write call and one sync, and
    returns the head after the last one. The first record must continue the
    head the zone has, each next record the one before it. A list that does not
    continue the chain is refused before any byte is written. Each line is
    read back with {!Authz_record.of_line} before it is written, so a line that
    [of_line] would refuse at the next start is never written. The fold
    function of {!open_at_start} is not run here, and a record that it refuses
    stops every later start, so the caller runs the same step before it
    appends. An empty list writes nothing.

    Once this returns [Ok], the lines are in the file and synced the way
    [Fs_compat] syncs. [Fs_compat] does not call [F_FULLFSYNC], so the lines
    survive a restart of the process, not a power cut.

    A crash in the middle of the write can leave the first lines of the list
    in the file. The next start keeps every complete line and cuts only a last
    line that never ended. A caller that needs a list to land whole or not at
    all appends one record per call.

    If the write raises an exception (for example
    [Systhread_host.Host_failed]), the lines may be in the file. The log is
    stopped and the exception goes on to the caller. The caller does not
    append the same records again: the next start shows what the file holds. *)
val append : writer -> Authz_record.t list -> (Authz_record.head, append_error) result
