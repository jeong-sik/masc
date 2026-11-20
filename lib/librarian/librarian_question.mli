(** The text of one question, and what the writer commits of it (RFC
    librarian-call-only-proposes §5.5, §6.1, §6.2): a reading question
    ({!make}) or the question that makes room ({!make_room}).

    A question is a function of the lane's question side, Memory, the commit
    line reading starts from, and the units read. It carries no clock and no
    counter, so the same inputs give the same bytes. All it reads is already
    on disk, so nothing is stored before it is sent.

    {b The text.} The lane's prompt, then these lines, each ending in a line
    break:

    {v
    question: <front half>
    memory: <JSON array, one object per fact>
    working_state: <JSON string, or null>
    units: <JSON array, one object per unit>
    question-end: <back half>
    v}

    A question that shows the head item alone ({!Item_alone}) has no
    [memory:] line and no [working_state:] line (§7.4). The question that
    makes room has a [make_room:] line in place of [units:]: one JSON string
    that says the item just read did not fit any slot with this Memory and
    was read alone. It names no target, neither a count nor a size.

    The value after each label is one JSON document on one line. Text a
    person, a Keeper or a store wrote is a JSON string, so a line break or a
    [question-end:] inside it cannot start a line.

    - A fact is named [m1 … mN] in Memory's order and shows its claim,
      category, basis, [first_seen] and [last_seen]. An observed basis has
      the shape an answer writes. A derived basis lists the premises of each
      proof by those names, [null] for one that is not in Memory, so no
      71-character id is shown.
    - The working state is the [working_state] of a [Committed] line, [null]
      after a [Started] one.
    - A unit is named [u1 … uK] in the order given. It shows its [kind]
      ([turn] or [reset]), [closed_at] and its [missing] parts with their
      sizes. A turn also shows its id (the offset of its [Opened] line),
      [runtime], [outcome], the Task as admitted with each Goal's shown
      text, the stimuli, and two groups of items: [unattributed], shown
      without the Task, then [own]. When the outcome is [close_missing] or
      [process_exited] the second group is [closed_after_admission]: those
      items were closed after the turn was admitted, not by the turn (§5.3).
      A reset shows its [cause] and its [items].
    - An item keeps the index its unit gave it and a [kind]. A tool call
      shows its id and name, a tool result its id and whether it succeeded,
      a tool observation its name and outcome. A row the other side sent
      shows its sender as the store typed it: a chat row's speaker, an
      external row's actor, a message's speaker. A row written before its
      store recorded senders shows [unknown]. A message the runtime put
      before the model again (recalled Memory, instructions, recovery cues)
      shows its origin and not its content, so Memory is not read back as
      something the Keeper saw. Thinking is left out. A request failure
      shows only that it is there: it is the server's result, not speech.

    Times are ISO 8601 UTC to the second.

    {b The id.} [front] is half the SHA-256 of the question side (prompt,
    the answer schema of the question's kind, output reserve, thinking) and
    the memory and working state lines. [back] is half the SHA-256 of the
    units line, or of the [make_room:] line. A change to
    Memory alone changes [front] only, and other units under the same Memory
    change [back] only. A question of the item alone has no memory line, so
    a change to Memory leaves its id as it was: a slot's size fact about it
    holds across Memory versions. A slot that cuts the head or the tail of
    its input cannot write back the half it never saw. *)

type made =
  | Made of
      { question : Librarian_read_result.question
      (** [shown] names every fact and every unit the text gave. *)
      ; text : string (** The whole request: the prompt, then the question. *)
      ; schema : Yojson.Safe.t
      (** The answer schema of the question's kind: [range] for
          {!With_memory}, [item_alone] for {!Item_alone}. The id covers it,
          and the walk asks every slot to match it. *)
      }
  | Nothing_readable of
      { reach : Librarian_read_result.reach
      ; missing : Librarian_unit.missing_at list
      }
  (** No unit holds an item: each one's items are all missing, or it never
      had any. Nothing is asked. *)

(** What a question shows besides its units. *)
type shows =
  | With_memory of Keeper_memory_os_current_types.t
  (** Memory as the snapshot [from] names holds it, and the working state of
      [from]. *)
  | Item_alone (** Nothing: the units are one item ([Read_item_alone]). *)

(** [units] is every unit read, those without items included. [missing]
    collects the parts each unit lacks, in unit order, so the commit records
    them whether or not a question is made. [reach], [trace] and [offered]
    are what the reader gave for the units; the question carries them
    unchanged. [from] is the commit line reading starts from; the question's
    [basis] is the snapshot it names. *)
val make
  :  lane:Librarian_memory_lane.question_side
  -> from:Librarian_log.line
  -> shows:shows
  -> reach:Librarian_read_result.reach
  -> trace:string
  -> offered:Librarian_width.offered
  -> Librarian_read_unit.t list
  -> made

type room =
  { question : Librarian_room_result.question
  (** [memory] names every fact the text gave. *)
  ; text : string (** The whole request: the prompt, then the question. *)
  ; schema : Yojson.Safe.t (** The [room] answer schema. *)
  }

(** The question that makes room (§7.4): Memory as the snapshot [from] names
    holds it and the working state of [from], then the [make_room:] line. It
    reads no unit. [trace] is the trace of the item read alone just before;
    the question carries it unchanged. Like a reading question, it is a
    function of its inputs and carries no clock. *)
val make_room
  :  lane:Librarian_memory_lane.question_side
  -> from:Librarian_log.line
  -> memory:Keeper_memory_os_current_types.t
  -> trace:string
  -> room
