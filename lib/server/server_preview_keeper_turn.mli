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

    The other answers are a JSON [{"error": ..., "code": ...}]
    ({!Server_preview_keeper_error}):
    - 400: the body is not that, the message is blank or longer than
      {!max_message_bytes}, the Runtime is neither a Claude Code nor a Codex
      Runtime, or the runtime of its account does not load.
    - 403: {!Runtime_account_access.authorize} refused the turn, or the
      client would start with tools that reach the homes of other people.
      The scope of [pat] not covering the turn is one refusal.
    - 404: the Keeper is not the person's, or the account of its Runtime has
      no login of theirs.
    - 409: the Keeper has no Runtime, a call of the account runs, the owner
      gave the Keeper another Runtime meanwhile, the account is not signed in
      to a subscription, or the conversation of the Keeper began on another
      account.
    - 429: the subscription has no quota left.
    - 504: the client was silent for 120 seconds.
    - 500, 502 or 503: the client did not start, or ended without an answer;
      the record of the conversation has a row that is not understood, could
      not be read or written, or did not take the answer; or the server
      cannot decide now.

    The code of a failed turn is the [failure] its record keeps. The detail
    of a failure goes to the server log, since it can name a path of the
    server (issue #50018). *)
val run
  :  env:Eio_unix.Stdenv.base
  -> person:Server_setup_account_login.person
  -> pat:Authz_types.Pat_binding.t
  -> base_path:string
  -> body:string
  -> Login_routes.answer

(** {1 For the routes of a conversation}

    {!Server_preview_keeper_conversation} answers a Keeper name that is no
    Keeper name, a Keeper that is not the person's, a Keeper with no Runtime,
    and a failure of the record in the words of the turn. *)

(** The Keeper id of a Keeper name ({!Auth_preview_keeper.keeper_id_of}). A
    name that is no Keeper name is an [Invalid_request]. *)
val keeper_id_of : string -> (Authz_types.Keeper_id.t, Server_preview_keeper_error.t) result

(** The Runtime the person gave their Keeper, [None] when they gave it none,
    read in a state the zone can be trusted for. The error is
    [Unknown_keeper] for a Keeper that is not the person's, or
    [Server_unavailable] for a zone that is not trusted. *)
val owned
  :  Server_setup_account_login.person
  -> Authz_types.Keeper_id.t
  -> (Authz_types.Runtime_id.t option, Server_preview_keeper_error.t) result

(** The Runtime of the person's Keeper and the account that Runtime spends.
    The error is one of {!owned}, or [Keeper_has_no_runtime]. *)
val assigned
  :  Server_setup_account_login.person
  -> Authz_types.Keeper_id.t
  -> ( Authz_types.Runtime_id.t * Authz_types.Provider_account_id.t
       , Server_preview_keeper_error.t )
       result

(** The case of a failure of the record of a conversation. The detail goes to
    the server log. *)
val record_error
  :  keeper_id:Authz_types.Keeper_id.t
  -> Server_keeper_conversation.error
  -> Server_preview_keeper_error.t
