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
    stable lock file beside it.

    {b Who writes.} Inside the process, one zone per {!t}: an [Eio.Mutex] held
    while a function runs ({!with_writer}). Between processes, this module
    relies on two things it does not check. Only one server runs on a base
    path, and a tool that reads the file takes the lock of [Fs_compat] for the
    length of one read. While a tool holds that lock an append returns
    {!Write_locked}. A second writer on the same file shows up as {!Diverged}.

    {b After a failure.} When an append fails and the module cannot say whether
    the file changed, or the end of the file is not where the zone left it, the
    log refuses every later append ({!Stopped}) until the process starts again
    and opens the file again. The in-memory head is then not trusted, and the
    file is the only truth. A refusal that wrote nothing ({!Write_locked},
    {!Wrong_seq}, {!Wrong_previous_hash}, {!Would_not_read_back}) does not
    stop the log. *)

type t

(** Proof that the caller is inside the zone of a log. It is valid until the
    function given to {!with_writer} returns. *)
type writer

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
    cuts a torn last line (see {!tail}), then checks the lines one by one with
    {!Authz_record.of_line}, starting at {!Authz_record.genesis}, and folds the
    records in file order with [step], starting from [init]. The first line
    that fails, or that [step] refuses, is the result.

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

(** Runs [f] inside the zone of [t], with the head of the log at that moment.
    Must be called from an Eio fiber. Other callers of [with_writer] on the same
    [t] wait. Cancellation is held off while [f] runs, so an append that was
    handed to the file cannot be left half-accounted. A fiber cancelled while
    it waits for the zone never enters it.

    [f] gets the head the zone starts with and gets the next head from
    {!append}. Build records from those ({!Authz_record.make}). Hold the zone
    only for what must be decided against the latest state, as design 7.1 asks.
    The writer must not be kept after [f] returns: {!append} then answers
    {!Writer_expired}. *)
val with_writer : t -> (writer -> Authz_record.head -> 'a) -> 'a

type append_error =
  | Writer_expired  (** The zone of this writer has ended. Nothing was written. *)
  | Stopped of
      { path : string
      ; reason : string
      }  (** An earlier failure stopped the log. See the top of this file. Nothing was written. *)
  | Wrong_seq of
      { index : int  (** In the list, from 0. *)
      ; expected : int
      ; actual : int
      }  (** The record does not continue the chain. Nothing was written. *)
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
      (** The end of the file is not where this zone left it: another writer
          appended, or the file was replaced or cut. The log is stopped. *)
  | Write_failed of
      { path : string
      ; detail : string
      }
      (** The write failed in a way that leaves the file unknown. The log is
          stopped. *)

val append_error_to_string : append_error -> string

(** Writes the records, in order, as one write followed by one sync, and
    returns the head after the last one. The first record must continue the
    head the zone has, each next record the one before it. A list that does not
    is refused before any byte is written. Each line is read back with
    {!Authz_record.of_line} before it is written, so a line that the next start
    would refuse is never written. An empty list writes nothing.

    Once this returns [Ok], the lines are in the file and synced the way
    [Fs_compat] syncs. [Fs_compat] does not call [F_FULLFSYNC], so the lines
    survive a restart of the process, not a power cut. *)
val append : writer -> Authz_record.t list -> (Authz_record.head, append_error) result
