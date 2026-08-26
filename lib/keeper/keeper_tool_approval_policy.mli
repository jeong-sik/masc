(** Which tool calls an operator is asked about before they run.

    Read from what the tool already declares: its group, and whether this
    particular input only reads. Nothing here matches on tool names — the
    groups are a closed type, so a group added later has to be classified here
    or the build stops. That is the point: a new family of tools must not
    inherit "runs without asking" by saying nothing. *)

(** Why a call was or was not put to an operator. Carried rather than reduced
    to a bool so a decision can be explained where it is shown or logged. *)
type verdict =
  | Ask of { because : string }
  | Run of { because : string }

val verdict_because : verdict -> string

val verdict_for :
  ?composition_plan_index:Keeper_tool_composition_plan_index.t ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  unit ->
  verdict
(** Decide about one call.

    A name this build cannot place is asked about: it is not a safe tool, and
    running it unasked would make "no descriptor" the quietest way past the
    gate.

    A name with no descriptor is not automatically that. Composition tools are
    materialised outside the descriptor registry and are judged by the tools
    their plan runs — from the turn-local [composition_plan_index] for
    [keeper_compose_*], from the input for [keeper_plan_execute]. A plan of
    reads runs; one node that would be asked about makes the whole plan asked
    about, and the reason names that node. An absent index asks rather than
    borrowing another turn's plan.

    A tool from a work service this Keeper is attached to is judged by what
    that service said: [annotations.readOnlyHint] on its own listing, carried
    to here through {!Keeper_identity_tool_index}. A service that said
    nothing leaves the call asked about -- silence is not permission, and
    writing to somebody else's Jira unasked is the outcome that has to stay
    unreachable.

    A call whose descriptor says this input only reads runs without asking,
    whatever its group. Reading a file to answer a question is the bulk of
    what a keeper does, and an operator asked about every read would stop
    reading the questions. *)

val classifies :
  ?composition_plan_index:Keeper_tool_composition_plan_index.t ->
  tool_name:string ->
  unit ->
  bool
(** Whether this build can place [tool_name] at all.

    Not the same question as {!verdict_for}, and not answerable by calling it
    with an empty input. [keeper_plan_execute] is a name this policy knows
    while what it decides depends on nodes that arrive in the call — asking
    {!verdict_for} with [{}] would read that as "cannot classify" and pin a
    fabricated input's answer as the fact about the name.

    Both this and {!verdict_for} read one closed variant, so an arm added to
    one is an arm added to the other. The bundle gate
    ([test_keeper_tool_bundle_classifiable]) walks every tool a keeper is
    handed through this: a tool the policy cannot place asks its operator a
    question with no reason they can act on, which is what four composition
    tools did before they were classified. *)

val question_for : tool_name:string -> input:Yojson.Safe.t -> string
(** The prompt an operator sees: what the call would do, named by the one
    argument that identifies it — the same argument the chat surfaces already
    show for a tool call. *)
