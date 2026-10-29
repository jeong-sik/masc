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
(** One of four, named by the judgment's status: [selected] with the number of
    candidates, the number carried and their ids; [none_found] with what the
    turn question answered ([yes] or [unsure]); [none_needed]; [unavailable]
    with its reason, worded to stand out from the other three. A judgment that
    covered only some of the candidates adds how many it judged, whatever its
    status. The line names the [turn_ref], so the lines a session collects
    over turns can be told apart.

    Every state but [selected] ends with a pointer to [keeper_memory_search]
    when [memory_search_available], for the exact words a judgment over whole
    memories can miss. When the tool is not available no sentence names it.

    Raises [Invalid_argument] for a status the flow cannot build, such as
    [none_found] with an unanswered turn question: that is a defect of the
    caller's judgment, not a state to word. *)

val body :
  Keeper_memory_os_types.fact list ->
  Keeper_memory_recall_flow.judged ->
  string option
(** [Some] for a [selected] judgment and [None] for every other status: a block
    with no memory in it is not sent. The facts are those the candidates were
    made from. Each carried candidate is rendered once, in candidate order,
    with its id, category, the two UTC days, the kind of its origin and its
    claim in full. A claim of several lines keeps its lines, and each line
    after the first is indented by four spaces, so no line of a claim can open
    an item or the heading of the block. A fact read from a Board post adds
    [board:<post_id>], the coordinate a Task completion can cite. A memory marked [Time_bound] says it
    is the value at the time it was recorded. One marked [Time_unjudged], or
    with no mark at all, says its time was not judged: it is never worded as
    standing.

    Raises [Invalid_argument] when a carried id has no fact in the list. The
    caller built the candidates from these facts, so that is a defect. *)
