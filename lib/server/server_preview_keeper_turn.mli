(* HIGH-RISK-UNREVIEWED: this route starts the official client of a person's
   subscription for a turn of their Keeper. A wrong answer runs a Keeper on
   the subscription of another person. Read it against plan D2-8. *)

(** One turn of a person's Keeper in the localhost preview (plan D2-8): the
    person sends their Keeper a message, and the Runtime they gave it answers
    on the home of their own account. A turn of Claude Code goes on in the
    conversation of the Keeper (plan S1b-3).

    {b Records.} The Keeper record names the Runtime, and the Runtime record
    names the account. The runtime is the workspace provider that the login
    receipt of the account names, with the home of that account and the
    binding whose Runtime id on the account is the one the Keeper record names
    ({!Server_setup_account_login.person_runtime}).

    {b Authorization.} The route decides nothing itself.
    {!Runtime_account_access.authorize} decides a [Keeper_turn] on the
    [Direct] channel from the log, and the client starts only on the account
    it authorizes. A request that a personal access token authenticated runs
    the turn only inside the scope of that token: the scope names the
    Runtime, the [Direct] channel, and the effects [invoke_model] and
    [use_tool] ({!Authz_keeper_turn.requested}).

    {b The call.} One turn of the client of the Runtime:
    - Claude Code: {!Runtime_claude_code.run_turn} in the posture of
      {!Runtime_claude_code.default_config}: no built-in tool but the lookup
      of deferred tools, no MCP server of MASC, and the client's own system
      prompt.
    - Codex: {!Runtime_codex_app_server.run_turn} on an [Ephemeral] thread,
      in the posture of {!Runtime_codex_app_server.default_config}:
      read-only permissions with no shell, no tool of MASC, and the client's
      own instructions. Codex keeps no rollout or history of the thread.

    The client may be silent for 120 seconds. One call of an account runs at
    a time ({!Server_setup_account_login.one_call_of}). The authorization log
    keeps no record of a turn.

    {b The conversation} (Claude Code). A Keeper has one conversation at a
    time ({!Server_keeper_conversation}), and its first turn starts one on
    the account of its Runtime. The model reads the turns before this one
    from the session of the client: the client starts in the directory of
    the conversation and resumes the session of the last answered turn, and
    MASC puts no earlier turn in the prompt. The message is recorded before
    the client starts, and the answer or the kind of the failure after it,
    under the namespace of the person. A conversation stays on the account
    it began on, since the session lies in the home of that account: when
    the Keeper has a Runtime of another account the turn is refused. A turn
    that fails is not started again in a new session.

    A Codex turn runs in a private directory that is removed after it and
    is not recorded. *)

(** The longest message, in bytes: 4096. *)
val max_message_bytes : int

(** [POST {!Auth_preview_keeper.turn_path}] for [person]. The body is
    [{"keeper_id": <name>, "message": <text>}], and the answer is a 200 JSON
    [{"keeper_id":...,"runtime_id":...,"model":...,"text":...,
    "conversation_id":...,"continued":...}]. [continued] is whether the client
    resumed the session of an earlier turn of the conversation.

    Field order does not matter. Each request field must occur once and hold
    a string; missing, duplicate and additional fields are refused with 400.

    The other answers are a JSON [{"error": ...}]:
    - 400: the body is not that, the message is blank or longer than
      {!max_message_bytes}, or the Runtime is neither a Claude Code nor a
      Codex Runtime.
    - 403: {!Runtime_account_access.authorize} refused the turn. The scope of
      [pat] not covering the turn is one such refusal.
    - 404: the Keeper is not the person's.
    - 409: the Keeper has no Runtime, a call of the account runs, the
      account is not signed in to a subscription, or the conversation of the
      Keeper began on another account.
    - 429: the subscription has no quota left.
    - 504: the client was silent for 120 seconds.
    - 500, 502 or 503: the client did not start, or ended without an answer;
      the record of the conversation has a row that is not understood, or
      could not be read or written; or the answer could not be recorded.

    The detail of a failure goes to the server log, since it can name a path
    of the server (issue #50018). *)
val run
  :  env:Eio_unix.Stdenv.base
  -> person:Server_setup_account_login.person
  -> pat:Authz_types.Pat_binding.t
  -> base_path:string
  -> body:string
  -> Login_routes.answer

(** [POST {!Auth_preview_keeper.conversation_path}] for [person]. The body is
    exactly [{"keeper_id": <name>}], and the answer is a 200 JSON
    [{"keeper_id":...,"conversation_id":...}]: the Keeper has a new
    conversation on the account of the Runtime it has now, and its next turn
    starts a session of its own there. The conversations the Keeper had stay
    as they are, and no turn goes on in them. A turn that runs while the
    conversation is started ends in the conversation it began in.

    The person starts a conversation; the server starts none in place of one
    whose turn failed. This is the way on for a Keeper whose conversation
    began on another account.

    The other answers are a JSON [{"error": ...}]:
    - 400: the body is not that, or the name is no Keeper name.
    - 404: the Keeper is not the person's.
    - 409: the Keeper has no Runtime, so there is no account to start on.
    - 500 or 503: the record of the conversations has a row that is not
      understood, or could not be written.

    It starts no client and asks the authorization log for nothing but the
    Keeper and its Runtime: the caller judged the request as
    [Manage_own_keeper]. *)
val start_conversation
  :  env:Eio_unix.Stdenv.base
  -> person:Server_setup_account_login.person
  -> base_path:string
  -> body:string
  -> Login_routes.answer
