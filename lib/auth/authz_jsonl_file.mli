(* HIGH-RISK-UNREVIEWED: this module opens, replays, and appends to the files
   of the authorization layer. A line it writes is a grant, revocation, or
   principal that the whole system treats as true, and a line that does not read
   back stops every later start. *)

(** An append-only JSONL file of the authorization layer, opened for one writer
    (design 8.1, 8.2).

    The module knows the file and nothing about what a line means. A
    {!Line_format} says what a line is and what each line must continue, and
    {!Make} builds the file for one format. At process start the file reads
    every line, checks each one against the lines before it, and hands each
    record to a fold function that the caller passes. Later it appends lines,
    one zone at a time. What the lines add up to, and which events may follow
    which, belong to the layer that owns the format. {!Authz_log} is the first
    file built on it.

    {b The file.} [Fs_compat] creates it with mode 0600 and keeps a stable lock
    file beside it. The module keeps the state after the last line and the end
    of the file (a cursor of [Fs_compat], made of device, inode, and size). Open
    a file once per process and path. A second [t] on the same path does not
    share the zone, so its first append returns [Diverged] and stops it.

    {b Who writes.} Inside the process, one zone per [t]: an [Eio.Mutex] held
    while a function runs ([with_writer]). Between processes, this module relies
    on two things it does not check. Only one server runs on a path, and a
    tool that reads the file takes the lock of [Fs_compat] for the length of one
    read. While a tool holds that lock an append returns [Write_locked]. A
    second writer on the same file shows up as [Diverged].

    {b After a failure.} The file is stopped when an append fails and the module
    cannot say whether the file changed, when the end of the file is not where
    this process left it, or when the write raises an exception. A stopped file
    does not enter a zone ([with_writer] returns [Error]) and every [append]
    returns [Stopped], until the process restarts and opens the file again.
    While the file is stopped, the in-memory state is not trusted, and the file
    is the only truth. A refusal that wrote nothing ([Write_locked],
    [Rejected], [Would_not_read_back], [Read_back_changed]) does not stop the file. *)

(** Why a file is stopped. *)
type stop =
  { path : string
  ; reason : string
  }

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
      (** The file ended inside a line, left by an append that died. The module
          cut it back to the last complete line and synced. The cut bytes were
          never acknowledged to any caller. *)

type recovered =
  { contents : contents  (** After the cut, if there was one. *)
  ; tail : tail
  }

(** What one kind of file holds. [of_line] and [advance] run on a system thread
    when the file is opened, and the others run on the fiber that opens or
    appends. So each function is pure: no Eio, no file or network access, no
    dependence on the domain that runs it, and a refusal is an [Error], not an
    exception. *)
module type Line_format = sig
  (** What the lines before a line add up to, as far as the next line must
      continue it. A chain of hashes keeps the position and the hash of the last
      line here. *)
  type state

  type record

  (** Why a line is not the next line of the file. *)
  type line_error

  (** Why a record is not the next record to write. *)
  type reject

  (** What the messages call the file, for example ["authorization log"]. *)
  val description : string

  (** The name of the system-thread jobs of this file. *)
  val thread_label : string

  (** The state before the first line. *)
  val genesis : state

  (** Reads one line, without its newline, that is expected after the given
      state. The line must be exactly the bytes {!to_line} writes for the record
      it decodes to. *)
  val of_line : state -> string -> (record, line_error) result

  (** One line, without the newline. *)
  val to_line : record -> string

  (** Whether two records are the same record. [append] reads each line back
      with {!of_line} and refuses the record when the result is not equal to it,
      so a format that loses a member in {!to_line} or {!of_line} writes
      nothing. The comparison covers every member that the caller reads and that
      {!check_next} and {!advance} use. *)
  val equal_record : record -> record -> bool

  (** The state once the record has been appended. *)
  val advance : state -> record -> state

  (** Checks whether the record may follow the given state. [append] asks
      before it writes a byte, so a record that fails here is never written. *)
  val check_next : state -> record -> (unit, reject) result

  (** A few words about the state, for the warning logged when the tail is
      cut. *)
  val describe_state : state -> string

  val line_error_to_string : line_error -> string
  val reject_to_string : reject -> string
end

module Make (F : Line_format) : sig
  type t

  (** Proof that the caller is inside the zone of a file. It is valid until the
      function given to {!with_writer} returns. *)
  type writer

  (** [Some] once the file is stopped, for the caller that reports health. *)
  val stopped : t -> stop option

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
        ; error : F.line_error
        }  (** The format refuses the line as the next line of the file. *)
    | Fold_refused of
        { path : string
        ; line_number : int  (** From 1. *)
        ; reason : 'reason
        }  (** The caller's fold function refused the record on this line. *)

  val open_error_to_string : ('reason -> string) -> 'reason open_error -> string

  (** For process start only. Reads the whole file under the lock of
      [Fs_compat], cuts a last line that never ended (see {!tail}), then checks
      the lines one by one with [F.of_line], starting at [F.genesis], and folds
      the records in file order with [step], starting from [init]. The first
      line that fails, or that [step] refuses, is the result.

      The read, the check, and [step] run on a system thread through
      [Systhread_host.run], so the Eio domain keeps serving. [step] must be pure:
      no Eio, no file or network access, and it may not depend on which domain
      runs it. It sees records that are already verified, and it reports a
      refusal as [Error], not as an exception.

      The module keeps the state after the last line and the end of the file. It
      does not keep what [step] folds: what to keep, and how to publish it, is
      for the caller. *)
  val open_at_start
    :  path:string
    -> init:'state
    -> step:('state -> F.record -> ('state, 'reason) result)
    -> (t * 'state * recovered, 'reason open_error) result

  (** Runs [f] inside the zone of [t], with the state of the file at that
      moment, and returns what [f] returns. A stopped file is not entered: the
      result is [Error] and [f] does not run, so no caller gets a state that is
      not trusted.

      Must be called from an Eio fiber, and not from inside a zone of the same
      [t]: that call would wait for itself. Other callers of [with_writer] on the
      same [t] wait. Cancellation is held off while [f] runs, so an append that
      was handed to the file cannot be left written in the file but missing from
      the state. For the same reason keep [f] short: a long wait inside it also
      holds off a shutdown. A fiber that is cancelled while it waits does not
      enter, unless the zone had already been handed to it.

      [f] gets the state the zone starts with and gets the next state from
      {!append}. Hold the zone only for what must be decided against the latest
      state, as design 7.1 asks. One fiber at a time uses a writer, and nobody
      keeps it after [f] returns: {!append} then returns [Writer_expired]. *)
  val with_writer : t -> (writer -> F.state -> 'a) -> ('a, stop) result

  type append_error =
    | Writer_expired  (** The zone of this writer has ended. Nothing was written. *)
    | Stopped of stop
        (** An earlier failure stopped the file. See the top of this file. Nothing
            was written. *)
    | Rejected of
        { index : int  (** In the list, from 0. *)
        ; reject : F.reject
        }
        (** The format refuses the record as the next record. Nothing was
            written. *)
    | Would_not_read_back of
        { index : int
        ; error : F.line_error
        }
        (** The format refuses the line that it writes for this record. This
            means a bug in the format. Nothing was written. *)
    | Read_back_changed of { index : int }
        (** The line reads, but not as the same record. Nothing was written. *)
    | Write_locked of { path : string }
        (** Another process holds the lock. Nothing was written and the file is
            not stopped. The caller may try again later; this module never
            retries. *)
    | Diverged of { path : string }
        (** The end of the file is not where this process left it: another writer
            appended, or the file was cut. The file is identified by device,
            inode, and size, so a file of the same size that reused the old inode
            number is not noticed. The file is stopped. *)
    | Write_failed of
        { path : string
        ; detail : string
        }
        (** The write failed in a way that leaves the file unknown. The file is
            stopped. *)

  val append_error_to_string : append_error -> string

  (** Writes the records, in order, with one write call and one sync, and
      returns the state after the last one. Each record must pass [F.check_next]
      against the state the records before it leave, the first against the state
      of the zone. A list with a record that fails is refused before any byte is
      written. Each line is read back with [F.of_line] before it is written and
      compared with the record by [F.equal_record], so a line that [F.of_line]
      would refuse at the next start, or would read as another record, is never
      written. The fold function of {!open_at_start} is not run here, and a
      record that it refuses stops every later start, so the caller runs the
      same fold function before it appends. An empty list writes nothing.

      Once this returns [Ok], the lines are in the file and synced the way
      [Fs_compat] syncs. [Fs_compat] does not call [F_FULLFSYNC], so the lines
      survive a restart of the process, not a power cut.

      A crash in the middle of the write can leave the first lines of the list in
      the file. The next start keeps every complete line and cuts only a last
      line that never ended. A caller that needs a list to land whole or not at
      all appends one record per call.

      If the call that runs the write on a system thread raises an exception (for
      example [Systhread_host.Host_failed]), the lines may be in the file. The
      file is stopped and the exception goes on to the caller. This holds even
      when the exception was raised before the file work began, because the
      module cannot tell the two cases apart. An exception raised while the
      records are checked comes before any byte is written and does not stop the
      file. The caller must not append the same records again: the next start
      shows what the file holds. *)
  val append : writer -> F.record list -> (F.state, append_error) result
end
