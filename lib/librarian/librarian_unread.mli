(** A Keeper's turn log read on from where its commit log says reading
    stands (RFC librarian-call-only-proposes §5.3, §5.4, §9.2).

    Reading starts at the commit line's [turn_log_offset] and goes forward.
    The lines before it are not read, with one exception: when reading
    starts inside a turn, that turn's lines from its [Opened] are read
    again, because its [Closed] needs what they say. So what a read costs
    follows the lines not yet read, not the lines before them.

    A unit is named here, not read: what its line and the marks around it
    say each store holds. Its content is read by {!Librarian_unit_content}. *)

(** What one segment of a unit holds in each store.

    A range runs from where the unit starts to where it ends, and is empty
    when [until] is not past [from]. The official-client files belong to a
    session: a unit that starts in another session than the one it ends in
    holds the end session's files from their first byte, since no unit
    before it covered them. The chat and external stores are the Keeper's
    own and are not split by session. *)
(** Where a segment's conversation is recorded (§5.3).

    A turn on Agent Core saves the messages it closed in its checkpoint. Its
    context runtime also writes to the session's history files
    ({!Keeper_context_core_history.history_path_for_source}): a direct turn's
    user and assistant messages to the main file, which the checkpoint holds
    again, and an internal turn's reply to the internal file, which the
    checkpoint never replays ({!Keeper_replay_checkpoint}). A turn on an
    official client saves no Agent Core checkpoint
    ({!Runtime_execution.checkpoint_owner}). Its history files are its record,
    and only its turn writes tool observations to the internal file.

    One turn's segment ([own]) is read from the record its slices name. The
    stretch before a turn opens ([unattributed]) and the stretch a reset
    closes can hold several turns, among them turns whose lines were not
    written, and a slice does not name its turn. There a history row cannot
    be told from the messages that say it again, so every record is read. *)
type record =
  | Checkpoint of
      { slices : Keeper_turn_log.slice list
      ; internal : Librarian_unit.range
      }
  (** One turn, and a slice takes a message. These are the Agent Core
      messages, as the line names them, then the internal file's rows: on
      Agent Core they are the replies the checkpoint does not replay. The main
      file says what the messages say and is not read. *)
  | Official_files of
      { history : Librarian_unit.range
      ; internal : Librarian_unit.range
      (** Bytes of the official-client files of the session the unit ends in. *)
      }
  (** One turn, and no slice takes a message: a turn on an official client,
      or a turn on Agent Core that closed no message and left its words only
      in these files. *)
  | Every_record of
      { slices : Keeper_turn_log.slice list
      ; history : Librarian_unit.range
      ; internal : Librarian_unit.range
      }
  (** A stretch that can hold several turns: the Agent Core messages, then
      every row of both files. A message can show twice; none is left out. *)

type segment =
  { record : record
  ; chat : Librarian_unit.range
  ; external_rows : Librarian_unit.range
  }

(** What a unit's line says it is.

    A turn splits each store at its [Opened]'s [baseline]: before it is
    [unattributed], after it is [own]. When a [Reset] followed that [Opened],
    or the baseline names another session's official-client files than the
    unit ends in, the store is not split and all of it is [unattributed]. *)
type source =
  | Turn of
      { turn : int (** Byte offset of the turn's [Opened] line. *)
      ; outcome : Keeper_turn_log.outcome
      ; opened : Librarian_read_unit.opened
      ; unattributed : segment
      ; own : segment
      }
  | Announced_reset of
      { cause : Keeper_turn_log.announced
      ; segment : segment
      }

type span =
  { line : int (** Byte offset of the unit's line. *)
  ; past_line : int (** Just past the line: where reading goes on after the unit. *)
  ; at : float (** When the line was written. *)
  ; through : Keeper_turn_log.mark
  (** Where the unit's content ends: a [Closed]'s [after], a [Reset]'s
      [before]. Its [trace] names the session that keeps the unit's bundles. *)
  ; next : Keeper_turn_log.mark
  (** Where the unit after it starts: a [Closed]'s [after], a [Reset]'s
      [after]. *)
  ; source : source
  }

(** Why a line cannot be read. *)
type unreadable =
  | Undecodable of Keeper_turn_log_store.undecodable
  | Out_of_order of Keeper_turn_log.order_error
  (** The line decodes and is not where {!Keeper_turn_log.step} accepts it. *)

(** Where reading stopped. *)
type stop =
  | Log_end (** Every complete line was read. *)
  | Limit_reached (** The units [until] asks for were read. *)
  | Unannounced_reset of
      { line : int
      ; past_line : int
      ; before : Keeper_turn_log.mark
      ; after : Keeper_turn_log.mark
      }
  (** What was closed before this line is not known. Reading does not go
      past it. *)
  | Unreadable_line of
      { offset : int
      ; reason : unreadable
      }

type reading =
  { spans : span list (** In line order. Units with no item are included. *)
  ; stop : stop
  ; bytes : int
  (** Bytes of the lines read from the stored offset on, the lines of an
      open turn read again included. The id check reads the log's first line
      on every read, and that line is not counted. *)
  }

type read_error =
  | Fault of Librarian_unit.input_fault
  (** [Turn_log_replaced] or [Position_lost]: the file is not the one the
      commit log names, or the stored offset does not start a line of it. *)
  | Unread of { detail : string }
  (** The file could not be read, or it changed while it was read. *)

type until =
  | To_end
  | First_with_items of int
  (** Stop after the unit that makes this many units with items. The units
      with no item before it are read with them. The count is checked after
      a unit with items, so at least one is read. *)

(** Whether the unit's line names any item: a slice that takes a message, or
    a store whose range is not empty. Its content is not read. *)
val has_items : span -> bool

(** Where reading stands once the unit is read whole: through its line,
    [covered] at [next], and the next read starting just past the line. *)
val reach_whole : span -> Librarian_read_result.reach

(** §9.2 "there is something unread": a unit with items was read, or reading
    stopped at a line it cannot go past, or the read failed. A failed read is
    unread because asking reads again and names the fault. *)
val has_unread : (reading, read_error) result -> bool

(** Reads [turns_path] from the [turn_log_offset] of [tail], [Started] or
    [Committed] alike, until [until] or a line that stops reading. The
    file's id is checked first, then the stored offset, then the lines
    (§5.4). The first unit starts at the tail's [covered], or at the mark of
    the [Log_started] line when reading starts there. *)
val read
  :  turns_path:string
  -> until:until
  -> Librarian_log.line
  -> (reading, read_error) result
