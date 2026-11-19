(** One ask of a reading question (RFC librarian-call-only-proposes §7.1,
    §7.2).

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
  (** The writer's tail now: the line of {!Librarian_writer.status}'s
      [Open]. [None] when the writer is no longer open. That writer cancels
      this ask in the same event, so the ask ends as [Ask_failed Flow_stopped]
      and its result is a late answer. *)
  ; lane : Librarian_memory_lane.t (** The lane value the walk starts with. *)
  ; resolved : Runtime_exact_output_registry.resolved_lane
  (** The lane's slots, from the publication [lane] was resolved under. *)
  }

(** Asks once about every unit not yet read (§7.1, steps 1 to 6).

    + Reads the tail, the snapshot bytes it names, and the tail again. A tail
      that changed starts over, so a direct write that lands between the two
      reads is read with its own line. The same tail with other bytes is
      [Memory_diverged].
    + Reads the turn log from the tail to its end. When no unit holds an item
      before where reading stopped, the ask ends there: [Nothing_to_ask] at
      the log's end, [Span_unknown] at an [Unannounced] reset,
      [Input_fault (Line_unreadable _)] at a line that cannot be read,
      whatever its reason. Otherwise every unit read is asked about.
    + Reads each unit's content and makes the question. A question with no
      item that can be read is [Nothing_readable].
    + Sends the question's text as one user message with no system prompt.
      The answer schema is the walk's requirement: the flow and a CLI run
      each write its sentence after the text. The HTTP slots go in the
      order {!Runtime_exact_lane_backpressure.order_at} gives at the clock's
      time, in one flow. A slot whose answer {!Librarian_answer.of_json}
      refuses passes the question to the next. Only when no HTTP slot
      answered are the CLI slots run, one at a time, ordered again by
      {!Keeper_lane_cli_oneshot.order_slots_at} before each, with an empty
      system prompt.
    + The first answer accepted is [Answered]. Otherwise [No_answer] holds
      an outcome for every slot of [lane]: the HTTP slots, then the CLI
      slots, in declared order. A slot the walk did not reach is
      [Silent Not_called].

    A walk that stops on masc's side, or a writer that is no longer open, is
    [Ask_failed Flow_stopped]. A snapshot, turn log or unit file that cannot
    be read is [Ask_failed Read_failed]. An exception is [Ask_failed Raised];
    a cancellation is raised again. The text of an [Ask_failed] goes to the
    Keeper's log. *)
val run : env -> input -> Librarian_read_result.t
