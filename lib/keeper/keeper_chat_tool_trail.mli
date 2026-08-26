(** Keeper_chat_tool_trail — the tool calls of one keeper turn, rendered as one
    block of text a connector can carry on the reply it already sends.

    Connector adapters see every tool event and project none of them:
    {!Keeper_chat_discord} keeps tool activity on Discord's native typing
    surface and {!Keeper_chat_slack} shows a transient "사용 중" line, both
    because a message per call would bury the channel it posts to. What arrives
    is therefore a reply with no trace of the work behind it — a turn that read
    six files and edited two reads exactly like one answered from memory.

    This collects a turn's calls and renders them once, so the work is visible
    without a message per call and the adapters' no-standalone-message contract
    holds.

    The renderer names each call by one argument, the way the dashboard chat
    does: see [toolSubject] in [dashboard/src/components/tool-call-shared.ts],
    whose key order this mirrors. The two are separate because one runs in a
    browser over a persisted trace and this one runs in the server over a live
    stream; they are expected to name the same call the same way. *)

type t

val create : unit -> t

val on_event : t -> Keeper_chat_events.keeper_chat_event -> unit
(** Feed one chat event. [Tool_call_start] opens a call, [Tool_call_args]
    appends an argument fragment to it, [Tool_call_args_snapshot] replaces the
    fragments accumulated so far (the provider sends a snapshot instead of, not
    in addition to, its deltas), and every other event is ignored. Calls are
    keyed by the server-owned stream occurrence; provider ids are optional
    correlation data and may repeat. A fragment for an occurrence that never
    opened is dropped: a row with no tool name would say less than no row. *)

val call_count : t -> int
(** How many calls opened this turn, including ones whose arguments never
    arrived. *)

val render : ?max_rows:int -> t -> string option
(** The turn's calls as one text block, or [None] when the turn called no tools.

    Rows past [max_rows] (default 8) are replaced by a count, because the block
    rides along with a reply that a channel may already be close to truncating
    and the reply is the part the reader asked for. Argument text is redacted
    through {!Observability_redact.redact_text} before it is rendered. *)

val append_to : ?max_rows:int -> t -> text:string -> string
(** [text] with the trail appended as a fenced block — the fence is the same
    syntax on every connector this serves, and it holds the rows' alignment.

    Returns [text] unchanged when the turn called no tools, and when [text] is
    empty: the reply is what the reader asked for, so a turn that produced none
    keeps whatever no-text outcome its adapter already has rather than being
    answered with a bare trail. *)

val tool_result_digest : result:string -> string option
(** One short line for what a call answered, from the result text as served.

    A sibling of {!tool_subject}: that one names a call by what it was asked,
    this one by what it said back. [None] means the result was empty -- a call
    that answered nothing, which a row can leave blank rather than pad. *)

val tool_subject : name:string -> args:string -> string option
(** The one argument a reader identifies a call by, or [None] when the
    argument shape carries none of the known keys.

    Public because the terminal UI names the calls in its live turn view and
    has to name them the same way. The key order this walks already exists
    twice — here and in [SUBJECT_KEYS] in
    [dashboard/src/components/tool-call-shared.ts] — and a third copy is how
    the three surfaces would start naming the same call differently. *)
