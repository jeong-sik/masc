(** Keeper_chat_reply_text — the reply text a connector delivers for one run.

    One Keeper run can hold several provider messages: in a tool loop the
    model writes, calls a tool, and writes again in the next message.
    {!Keeper_chat_discord} and {!Keeper_chat_slack} send all of it as one
    channel reply. Glued together, the end of one message ran straight into
    the start of the next (#29494). Here each provider message starts its own
    paragraph, so the reply reads as the steps the Keeper took.

    A provider message is named by the [response] on its [Text_delta]:
    {!Keeper_chat_agent_core_stream_bridge} tags every delta with its
    generation and stream scope, and the scope moves on with each provider
    call. The terminal reply that the turn publishes itself carries
    [Unobserved_scope None], which differs from every streamed response.

    Nothing is removed. Every delta is kept, including repeated text and
    whitespace; the only bytes added are the newlines of a paragraph break. *)

type t

val empty : t

val of_string : string -> t
(** Text that belongs to no provider response, such as a status line that
    replaces the reply. Provider text after it starts a new paragraph. *)

val append : t -> response:Keeper_chat_events.text_response -> string -> t
(** [append t ~response delta] adds one admitted [Text_delta].

    When [response] differs from the response of the text before it, the next
    delta of [response] that holds a non-whitespace character starts a
    paragraph. The text so far is then topped up with newlines until it ends
    in a blank line ("\n\n"), and [delta] follows.

    No break is added before the first visible text of the run, so the reply
    never starts with a blank line. A message with no visible text adds no
    break, so there is never a break after the last message and never two
    breaks in a row. An empty [delta] changes nothing. *)

val to_string : t -> string
