(** What an official-client turn left in the history files of its trace (RFC
    librarian-lifecycle §10-3).

    An official-client turn saves no AGENT_CORE checkpoint, so its end line in
    the turn-boundary log says [No_atom_history] and carries no cut point.
    What the turn said, and which tools it called, are lines under
    [<session_dir>/history.jsonl] and [<session_dir>/history.internal.jsonl],
    each naming its turn ([turn_ref]) and its [kind]
    ({!Keeper_context_core_history}). A round reads the fragments of a turn by
    that identity: the main file first, then the internal one, each in file
    order.

    A line without a [turn_ref] was written before lines carried one. It is
    [Untagged] and belongs to no turn; a reader passes over it. A line with a
    [turn_ref] the decoder refuses is an [Error]: it is never read as
    untagged, because that would hide a turn's words behind a shape mistake.

    The full [read] holds the file lock the writer holds. The observational
    recent reader takes a file-end snapshot and reports an unterminated tail
    as unavailable; neither accepts an uncommitted final row. *)

type observed_message =
  { turn_ref : Ids.Turn_ref.t
  ; recorded_at : float
  ; source : string option
  ; message : Agent_core.Types.message
  }

type fragment =
  | Message of observed_message
  | Tool_observation of
      { turn_ref : Ids.Turn_ref.t
      ; recorded_at : float
      ; observation : Keeper_librarian.tool_observation
      }

val fragment_turn_ref : fragment -> Ids.Turn_ref.t

type line =
  | Fragment of fragment
  | Untagged  (** No [turn_ref]: written before lines named their turn. *)

type read_error =
  | Not_json of string
  | Malformed of Keeper_memory_os_types.wire_error
  | Message_rejected of string
      (** The message decoder refused the line's message fields. *)
  | Incomplete_line

val read_error_to_string : read_error -> string

type file =
  | Main
  | Internal

val path : session_dir:string -> file -> string

(** Every newline-terminated line of [file], numbered from 1, decoded. A
    missing file is [Ok []]. A store that cannot be read is [Error]. *)
val read
  :  session_dir:string
  -> file
  -> ((int * (line, read_error) result) list, string) result

val read_recent_messages
  : session_dir:string
  -> roles:Agent_core.Types.role list
  -> limit:int
  -> file
  -> (observed_message list, string) result
(** Recent attributed messages in file order, for prompt observation only.
    Reverse-scans until [limit] messages with the requested roles are found;
    tool observations consume no slots. Whole message bodies and provenance
    survive. Missing files yield [Ok []]; unreadable or malformed encountered
    rows yield [Error], never a silently older excerpt. This observational
    reader does not hold the append lock and must not advance durable cursors. *)

(** The fragments of [turn_ref] among [lines], in file order. *)
val of_turn
  :  Ids.Turn_ref.t
  -> (int * (line, read_error) result) list
  -> fragment list

(** The first refused line that follows the first line naming a turn, if
    any. A round that meets one stops (RFC §4.4 row 2c) rather than read past
    a line it cannot name: the line may be a fragment of the very turn it is
    reading. Lines before the first named one predate turn-named history and
    belong to no turn, so a refusal among them stops nothing. *)
val first_refused
  :  (int * (line, read_error) result) list
  -> (int * read_error) option
