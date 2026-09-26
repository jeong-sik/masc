(** The assistant text one official-client turn (Codex app-server, Claude
    Code, Antigravity) forwards to the Keeper live stream.

    A client can write more than one assistant message in a turn: a Codex
    commentary item and then its final-answer item, two Claude Code
    responses around a built-in tool call, two Antigravity response steps.
    The adapters forward all of it as text deltas of one content block, and
    every chat surface appends those deltas into one text. With nothing
    between them, two messages read as one sentence: "확인할게요." and
    "완료" showed as "확인할게요.완료".

    This state puts a paragraph break in front of the first text of every
    message after the first, unless a tool row was forwarded since the
    previous message's text. A [tool_use] block becomes a tool row on the
    chat surfaces (the TUI trail, the dashboard), which already shows the
    text before and after it apart; a break there would start that later
    stretch with blank lines. A native tool block
    ({!Runtime_native_tools.stream_content_type}) is not a row, so text
    across one still gets the break.

    The break belongs to no message, and a turn's recorded text does not
    contain it. {!remainder} therefore compares the recorded text with the
    whole stream and then with the last message alone. *)

type 'message t

val create : equal:('message -> 'message -> bool) -> unit -> 'message t
(** State for one turn. [equal] compares the client's message identities:
    a Codex [agentMessage] item id, a Claude Code [message.id], an
    Antigravity [step_index]. *)

val forward : 'message t -> message:'message option -> string -> string
(** The text delta to forward for one piece of assistant text, in the order
    the client wrote them. [message] is the client's identity for the
    message the piece belongs to. [None], a piece the wire did not name,
    continues the message that is streaming: it never starts a new one.

    The first non-empty piece of a message other than the streaming one comes
    back with the newlines that complete a Markdown paragraph break after the
    text already forwarded: two, one when that text ends in a newline, none
    when it ends in a blank line. Every chat surface draws that break as a
    new paragraph. No newlines are added when {!tool_row} was
    called after the last non-empty piece. An empty piece comes back
    unchanged and starts nothing. *)

val tool_row : 'message t -> unit
(** A [tool_use] block was forwarded. The next message's text needs no
    break. *)

val remainder : 'message t -> final_text:string -> string option
(** The part of the turn's recorded text the stream has not shown, to forward
    after the last text when the turn ends. [Some suffix] when everything
    forwarded so far, or else the last message's text alone, is a strict
    prefix of [final_text]: Codex and Claude Code record one message as the
    turn's text, the last one. [None] when nothing is missing, or when the
    recorded text does not continue what streamed; sending it then could
    repeat text the viewer already has. *)
