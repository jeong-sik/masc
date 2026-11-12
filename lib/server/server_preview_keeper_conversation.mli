(* HIGH-RISK-UNREVIEWED: these routes start and read the record of what a
   person asked their Keeper and what it answered. A wrong answer gives one
   person the conversation of another. Read it against plan S1b-3. *)

(** The conversations of a person's Keeper in the localhost preview (plan
    S1b-3): the person starts a new one and reads what was asked and
    answered. The record is {!Server_keeper_conversation}, under the
    namespace of the person, and a turn writes it
    ({!Server_preview_keeper_turn}).

    Neither function starts a client. Each asks the authorization log for
    the Keeper of the person alone: the caller judged the request. *)

(** [POST {!Auth_preview_keeper.conversation_path}] for [person]. The body is
    exactly [{"keeper_id": <name>}], and the answer is a 200 JSON
    [{"keeper_id":...,"conversation_id":...}]: the Keeper has a new
    conversation on the account of the Runtime it has now, and its next turn
    starts a session of its own there. The conversations the Keeper had stay
    as they are, and no turn goes on in them. The start runs inside the call
    of the account of the current conversation, as each turn of it does, so
    no turn of that conversation writes after the start
    ({!Server_keeper_conversation.start}).

    The person starts a conversation; the server starts none in place of one
    whose turn failed. This is the way on for a Keeper whose conversation
    began on another account.

    The other answers are a JSON [{"error": ..., "code": ...}]
    ({!Server_preview_keeper_error}):
    - 400: the body is not that, or the name is no Keeper name.
    - 404: the Keeper is not the person's.
    - 409: the Keeper has no Runtime, so there is no account to start on, or
      a call of the account of its current conversation runs.
    - 500 or 503: the record has a row that is not understood, or could not
      be written; or the server cannot decide now. *)
val start
  :  env:Eio_unix.Stdenv.base
  -> person:Server_setup_account_login.person
  -> base_path:string
  -> body:string
  -> Login_routes.answer

(** [GET {!Auth_preview_keeper.conversation_path}] for [person]. [query] is
    the query of the request: [keeper_id] once, and [conversation_id] at most
    once. The answer is a 200 JSON:
    - [keeper_id]
    - [current_conversation_id]: the conversation the next turn of the
      Keeper goes on in, or [null] for a Keeper with none
    - [conversations]: the conversations of the Keeper in the order they
      were started, each
      [{"conversation_id":...,"provider_account_id":...,"started_at_ms":...}].
      [provider_account_id] is the account of the person the conversation
      began on: a turn goes on in the current one while the Runtime of the
      Keeper is of that account. It holds no text.
    - [conversation_id]: the conversation whose turns follow. It is the one
      [query] names, or the current one, or [null] with no turn.
    - [turns]: the turns in order. Each has [message], [asked_at_ms] and
      [outcome]:
      - ["answered"], with [text], [model] and [answered_at_ms]
      - ["failed"], with [failure] (the kind, as the record spells it),
        [failed_at_ms], and [model_may_have_read]
      - ["unrecorded"], with [model_may_have_read]: the server stopped in
        the turn, or the row of its end was not written

      [model_may_have_read] is whether the client was started with the
      message, so the Keeper may go on as one who read it though the record
      has no answer.

    The whole conversation is one answer: the read has no page.

    The other answers are a JSON [{"error": ..., "code": ...}]
    ({!Server_preview_keeper_error}):
    - 400: [query] is not that, or a value is no Keeper name or no id.
    - 404: the Keeper is not the person's, or the Keeper has no conversation
      of that id.
    - 500 or 503: the record has a row that is not understood, or could not
      be read; or the server cannot decide now. A row a stopped server left
      half written answers 503 [conversation_row_half_written] until a new
      conversation of the Keeper, or its next turn on a Claude Code Runtime,
      cuts the row. *)
val read
  :  person:Server_setup_account_login.person
  -> base_path:string
  -> query:(string * string) list
  -> Login_routes.answer
