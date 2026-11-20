(** One ask of a reading question, or of the question that makes room (RFC
    librarian-call-only-proposes §7.1, §7.2, §7.4).

    An ask reads Memory and the units not yet read, makes one question, walks
    the lane's slots once and returns how that ended. It keeps no state: the
    writer decides what the result means. It adds no time limit. A request's
    body deadline counts from its dispatch, as the flow counts it, so however
    long the ask waits for a seat the deadline is not shorter. *)

type env =
  { net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  (** Orders the slots, and bounds each request's body from its dispatch. *)
  ; base_dir : string (** Where a CLI slot runs. *)
  }

type input =
  { place : Librarian_machine.place
  ; stores : Librarian_unit_content.stores
  ; tail : unit -> Librarian_log.line option
  (** The writer's tail: the line of {!Librarian_writer.status}'s [Open],
      as the writer shows it while it waits for its next event. A read
      during an event waits for the event to end: the status names a
      commit's line only after the commit replaced the snapshot file, so a
      read in between would pair the old line with the new bytes. [None]
      when the writer is no longer open. That writer cancels this ask in
      the same event, so the ask ends as [Ask_failed Flow_stopped] and its
      result is a late answer. *)
  ; lane : Librarian_memory_lane.t (** The lane value the walk starts with. *)
  ; resolved : Runtime_exact_output_registry.resolved_lane
  (** The lane's slots, from the publication [lane] was resolved under. *)
  ; asked : Librarian_read_result.asked (** What the writer asks for. *)
  ; bottom : Librarian_bottom.t
  (** The head item's size facts as the writer held them when the ask
      started. A slot with one under the question's id is not called. *)
  }

(** What making room reads: no turn log and no size fact. *)
type room_input =
  { place : Librarian_machine.place
  ; tail : unit -> Librarian_log.line option (** As {!input}'s [tail]. *)
  ; lane : Librarian_memory_lane.t (** The lane value the walk starts with. *)
  ; resolved : Runtime_exact_output_registry.resolved_lane
  ; asked : Librarian_room_result.asked
  }

(** Asks once about every unit not yet read (§7.1, steps 1 to 6).

    + Reads the tail, the snapshot bytes it names, and the tail again. A tail
      that changed starts over, so a direct write that lands between the two
      reads is read with its own line. The same tail with other bytes is
      [Memory_diverged].
    + Reads the turn log from the tail at the asked width
      ({!Librarian_width.width}): to its end for [All], up to the [n]th
      unit with items for [Units n], up to the first for [Items _]. When no
      unit holds an item before where reading stopped, the ask ends there:
      [Nothing_to_ask] at the log's end, [Span_unknown] at an
      [Unannounced] reset, [Input_fault (Line_unreadable _)] at a line that
      cannot be read, whatever its reason. Otherwise every unit read is
      asked about.
    + Reads each unit's content and makes the question. [Items k] reads the
      first [k] items of the first unit with items; every other unit is
      read to its end. The question carries what was read
      ({!Librarian_width.offered}), and its reach ends where the last unit's
      read ended. A question with no item that can be read is
      [Nothing_readable]. [Read_item_alone] reads the head item as
      {!Librarian_width.head_item} does and shows it alone
      ({!Librarian_question.Item_alone}); the snapshot is read as for any
      question, and the question's [basis] names it.
    + Leaves out every slot that has a size fact under the question's id in
      [bottom] ({!Librarian_bottom.known}), HTTP and CLI alike. Their
      outcomes are those facts. With no slot left, nothing is called.
    + Sends the question's text as one user message with no system prompt.
      The answer schema of the question's kind
      ({!Librarian_question.Made}'s [schema]) is the walk's requirement: an
      HTTP flow and a CLI run each write its sentence after the text. The
      HTTP and CLI slots go in one {!Exact_lane_slots.walk}, one slot per
      step, ordered again at the clock's time before each step. A full slot
      is passed for a later slot with a free seat, whatever its kind. A CLI
      slot runs with an empty system prompt. A slot whose answer
      {!Librarian_answer.of_json} refuses passes the question to the next.
    + The first answer accepted is [Answered]. Otherwise [No_answer] holds
      an outcome for every slot of [lane]: the HTTP slots, then the CLI
      slots, in declared order. A slot the walk did not reach is
      [Silent Not_called]; one left out for its fact is [Refused (Sized _)].

    A walk that stops on masc's side, or a writer that is no longer open, is
    [Ask_failed Flow_stopped]. A snapshot, turn log or unit file that cannot
    be read is [Ask_failed Read_failed]. An exception is [Ask_failed Raised];
    a cancellation is raised again. The text of an [Ask_failed] goes to the
    Keeper's log. *)
val run : env -> input -> Librarian_read_result.t

(** Asks once to make room (§7.4): reads Memory under the tail as {!run}
    does, makes {!Librarian_question.make_room} of it, and walks every slot
    of the lane as {!run} does, asking each to match the [room] schema. No
    slot is left out: a size fact is about the head item, and this question
    shows no item. No turn log is read.

    The first answer accepted is [Room_answered]. Otherwise
    [Room_not_answered] holds an outcome for every slot of [lane]. The
    snapshot ends it as it ends a reading question: [Room_memory_diverged],
    [Room_snapshot_fault]. A walk that stops on masc's side, a writer that is
    no longer open, or an exception is [Room_failed]; its text goes to the
    Keeper's log. *)
val run_room : env -> room_input -> Librarian_room_result.t

