(* HIGH-RISK-UNREVIEWED: this route starts the official client of a person's
   subscription for a turn of their Keeper. A wrong answer runs a Keeper on
   the subscription of another person. Read it against plan D2-8. *)

(** One turn of a person's Keeper in the localhost preview (plan D2-8): the
    person sends their Keeper a message, and the Runtime they gave it answers
    on the home of their own account.

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

    The turn runs in a private directory that is removed after it, and the
    client may be silent for 120 seconds. One call of an account runs at a
    time ({!Server_setup_account_login.one_call_of}). Nothing is written: the
    log keeps no record of a turn. *)

(** The longest message, in bytes: 4096. *)
val max_message_bytes : int

(** [POST {!Auth_preview_keeper.turn_path}] for [person]. The body is
    [{"keeper_id": <name>, "message": <text>}], and the answer is a 200 JSON
    [{"keeper_id":...,"runtime_id":...,"model":...,"text":...}].

    Field order does not matter. Each request field must occur once and hold
    a string; missing, duplicate and additional fields are refused with 400.

    The other answers are a JSON [{"error": ...}]:
    - 400: the body is not that, the message is blank or longer than
      {!max_message_bytes}, or the Runtime is neither a Claude Code nor a
      Codex Runtime.
    - 403: {!Runtime_account_access.authorize} refused the turn. The scope of
      [pat] not covering the turn is one such refusal.
    - 404: the Keeper is not the person's.
    - 409: the Keeper has no Runtime, a call of the account runs, or the
      account is not signed in to a subscription.
    - 429: the subscription has no quota left.
    - 504: the client was silent for 120 seconds.
    - 500, 502 or 503: the client did not start, or ended without an answer.

    The detail of a failure goes to the server log, since it can name a path
    of the server (issue #50018). *)
val run
  :  env:Eio_unix.Stdenv.base
  -> person:Server_setup_account_login.person
  -> pat:Authz_types.Pat_binding.t
  -> base_path:string
  -> body:string
  -> Login_routes.answer
