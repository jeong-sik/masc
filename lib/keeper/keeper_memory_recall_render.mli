(** The text of the two blocks a judged turn carries
    (docs/rfc/RFC-keeper-recall-reaches-the-turn.md, section 4.4).

    The status line says what the judgment came to and is sent every turn. The
    body holds the memories the judgment carried and is sent when that set
    changes. Neither is a prompt block yet: this module only makes their text.
    It reads no file and sends nothing. The sentences are the named fragments
    [recall.*] of config/prompts/keeper.md; a fragment that does not render is
    placed in the text under its name, the way the other Keeper fragments are,
    so a missing sentence reads as a broken one. *)

val status :
  memory_search_available:bool ->
  turn_ref:Ids.Turn_ref.t ->
  Keeper_memory_recall_flow.judged ->
  string
(** A sentence line named by the judgment's status: [selected] with the number
    of candidates and the number carried; [none_found] with what the turn
    question answered ([yes] or [unsure]); [none_needed]; [unavailable] with
    its reason, worded to stand out from the other three. When the turn
    question failed after some candidates were judged, the [unavailable] line
    says how many were looked at and that none was chosen. A judgment that
    covered only some of the candidates adds how many it judged, whatever its
    status. The line names the [turn_ref], so the lines a session collects
    over turns can be told apart.

    A [selected] status adds the carried ids on a line of their own after the
    sentences.

    Every state but [selected] ends its sentences with a pointer to
    [keeper_memory_search] when [memory_search_available], for the exact words
    a judgment over whole memories can miss. When the tool is not available no
    sentence names it.

    Raises [Invalid_argument] for a status the flow cannot build, such as
    [none_found] with an unanswered turn question: that is a defect of the
    caller's judgment, not a state to word. *)

val unknown_day : string
(** What a body item writes for a time that is not a representable date. *)

val body :
  Keeper_memory_os_types.fact list ->
  Keeper_memory_recall_flow.judged ->
  string option
(** [Some] for a [selected] judgment and [None] for every other status: a block
    with no memory in it is not sent. The facts are the ones the memories are
    read from. Each carried memory is rendered once, in candidate order, with
    its id, category, the two UTC days ({!unknown_day} for a time no date can
    be made of), the kind of its origin and its claim in full. A line break of
    a claim (LF, CR or CRLF) is written as a line feed and four spaces, so no
    line of a claim can open an item or the heading of the block. A fact read
    from a Board post adds [board:<post_id>], the coordinate a Task completion
    can cite. A memory marked [Time_bound] says it is the value at the time it
    was recorded. One marked [Time_unjudged], or with no mark at all, says its
    time was not judged: it is never worded as standing.

    A carried id with no fact in the list is not an error. A retry within the
    turn reads the facts again and gets the judgment the turn kept, and the
    store may have changed in between. The heading counts the memories shown,
    and one line after them names the ids left out. *)
