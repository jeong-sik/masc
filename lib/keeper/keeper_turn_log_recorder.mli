(** Writing what one event adds to a Keeper's turn log
    (RFC librarian-call-only-proposes §5.2).

    One call reads the log's tail, reads where the Keeper's stores end,
    lets {!Keeper_turn_log_writer.plan} say which lines the event adds, and
    appends them at the end that was read. Nothing here decides what a line
    says: the plan does.

    A turn runs whether or not its lines were written. Every failure is
    answered as a value, and the caller counts it and goes on. *)

(** Where one Keeper's log and stores are. *)
type place =
  { keepers_dir : string (** Holds the turn log. *)
  ; base_path : string (** Holds the chat and external stores. *)
  ; keeper_name : string
  ; session_dir : string
  (** Holds the Agent-Core history and the two official-client files. *)
  ; session_id : string
  (** Names that history. A mark carries it as its trace and as its
      session: both are kept in this directory. *)
  }

type not_recorded =
  | Tail_unread of Keeper_turn_log_store.read_error
  | Head_unread of Keeper_checkpoint_store_decode.checkpoint_load_error
  | Ends_unread of Keeper_turn_log_ends.error
  | Run_unnamed of Keeper_turn_log_head.covering_error
  (** The closed messages since the last line could not be named: a segment
      was not read, or the head and the log disagree about a range. *)
  | Not_appended of Keeper_turn_log_store.append_error

val not_recorded_to_string : not_recorded -> string

type recorded =
  | Nothing_to_append
  | Appended of
      { lines : Keeper_turn_log.line list
      ; at : Keeper_turn_log_store.appended
      }

(** Where the Keeper's stores end now, with the turns that hold its closed
    messages. *)
val now
  :  place
  -> (Keeper_turn_log.mark * Keeper_turn_log_marks.covered, not_recorded) result

(** Appends the lines of [event], all of them or none.

    A fragment that an interrupted append left after the last line is cut
    by this append ({!Keeper_turn_log_store.append}).

    When the log's end moved between the read and the append, another
    writer got in: the tail is read again and the lines are planned afresh.
    When the rows still end where the failed attempt read them to end,
    nothing was appended in between and reading again would change nothing:
    the answer is [Not_appended]. *)
val record
  :  at:float
  -> new_log_id:Keeper_turn_log.Log_id.t
  -> place
  -> Keeper_turn_log_writer.event
  -> (recorded, not_recorded) result

(** Appends {!Keeper_turn_log_writer.drop}'s line, the same way as
    {!record}. The head is not read, so a head this build cannot decode does
    not stop the line; the other stores are read for a first line. *)
val record_drop
  :  at:float
  -> new_log_id:Keeper_turn_log.Log_id.t
  -> place
  -> after:(Keeper_turn_log.mark -> Keeper_turn_log.mark)
  -> (recorded, not_recorded) result

(** What an admission's turn carries to its end. *)
val admitted : (recorded, not_recorded) result -> Keeper_turn_log_writer.admitted
