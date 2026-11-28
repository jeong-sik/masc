(** When a refused Board source is read again (#55449, #55465).

    Every source asks the same two questions. A refusal one more read can end
    is read again at every call. A refusal for any other cause is read again
    once the directory no longer says of the source's file and of its lock
    file what it said when the refusing read began. Nothing here opens a file
    or takes a lock. *)

open Board_types

val inspect : path:string -> Source_file.entries
(** [lstat] of the source's file at [path] and of the lock file its
    transactions take ({!Fs_compat.private_jsonl_lock_path}): kind,
    permission bits, device, inode, size, modification time and link count.
    Both are taken in one call on the system thread
    {!Fs_compat.Systhread_host.run} picks, or in place outside Eio. A missing
    entry is [Absent]; any other [lstat] error is kept as [Uninspected]. *)

val same : Source_file.entries -> Source_file.entries -> bool
(** Whether both entries are the same. Two entries that could not be
    inspected are the same when the error is, so a path that stays
    unreachable is not a change. *)

val changed_since : Source_file.seen -> path:string -> bool
(** Whether the entries at [path] differ from the ones a refusal carries.
    [true] without IO for [Unread]; otherwise one {!inspect}. *)

(** What a source's state says about reading it again. A source answers from
    its fields, without IO. *)
type refusal =
  | Not_refused
  (** Never observed, readable, publishing, or holding a write of unknown
      outcome. *)
  | Read_again
  (** Refused for a cause {!Board_posts_source.fresh_read_can_clear} accepts:
      read again at every call. *)
  | Read_again_once_changed of Source_file.seen
  (** Refused for any other cause: read again once {!changed_since}. *)

val still_due : asked:refusal -> refusal -> bool
(** Asked under persistence by a call that found the source due before it
    waited: whether the source is still to be read. [asked] is what the
    source answered then, the other argument what it answers now. A source
    another call read in between is left as that read left it, unless that
    read met a cause {!Read_again} names. No IO. *)
