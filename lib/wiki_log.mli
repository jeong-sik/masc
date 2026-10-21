(** The wiki's [log.md] read back (RFC-wiki-lint-and-page-contracts §7).

    A log line is

    {[## [YYYY-MM-DD HH:MM] create r<N> | <page> | <author> | <note>]}

    The reader trusts only the stamp and the first three fields -- the action
    word, the [r<N>] revision and the page -- and keeps [author] and [note] as
    one free string nobody splits further. It never fails: a line it cannot
    read is counted, not raised, so "nothing is wrong" and "nothing could be
    read" stay different answers.

    No file is read or written here, and no clock or time zone is consulted:
    the caller passes the conversion from a stamped minute to a time
    ({!Wiki_log_clock.local_minute} reads it in the host's local time zone, as
    the writer stamps it). {!Tool_wiki} reads the file and hands the text to
    {!parse}. *)

type line =
  { written_at : float
      (** The Unix time at the start of the [YYYY-MM-DD HH:MM] minute between
          the brackets, read in the host's local time zone as the writer
          stamps it. A line whose stamp does not read is unreadable. *)
  ; action : string  (** The action word as written. *)
  ; revision : int  (** The [N] of [r<N>]. *)
  ; page : string  (** The page name as written. *)
  }

val known_actions : string list
(** The action words the parser reads, in the order the journal writes them:
    ["create"] and ["update"]. A line with any other word is counted in
    {!t.unknown_action} rather than read as a line. *)

type t =
  { lines : line list  (** The readable lines, in file order. *)
  ; unknown_action : int
      (** Lines that read as a line but name a word outside {!known_actions}. *)
  ; unreadable_line : int
      (** Lines that do not read as a log line. A last piece the writer had
          not finished -- the file does not end in a newline -- is not a line
          and is counted here neither. *)
  }

val empty : t
(** No lines, nothing counted: what a wiki with no [log.md] yet gives. *)

val parse
  :  minute_time:(year:int -> month:int -> day:int -> hour:int -> minute:int -> float option)
  -> string
  -> t
(** [parse ~minute_time content] reads the whole log file. [minute_time] turns
    a stamp whose fields are in range into the time at the start of that
    minute, or [None] when that minute does not exist (a day past the end of
    its month); a line whose stamp gives [None] is unreadable. The order of {!t.lines} is the
    order of the file: the minute in the timestamp is not fine enough to
    order two lines, so it is not used for that. *)
