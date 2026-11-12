(* HIGH-RISK-UNREVIEWED: answers MCP requests for whoever a credential names.
   What a tool does it does as the principal of that credential. *)

(** The MCP endpoint of a person on the account server (plan S1b-1).

    A person's MCP client posts one JSON-RPC message to {!path} with their
    personal access token, and gets one JSON answer. The endpoint keeps
    nothing between two requests:

    - It issues no [Mcp-Session-Id] and reads none. The caller of a request
      is the principal that {!Auth_gate.decide} gives for the credential of
      that request, and no name, header or session id in the request changes
      it. A token that was revoked, or a person who was disabled, is refused
      from the next request on.
    - It opens no stream. A notification gets a 202 with no body, and no
      server-to-client message exists.

    The methods are [server/discover], [initialize], [ping], [tools/list]
    and [tools/call]. A tool calls the function that the person's route
    calls, with the judgment that route makes, so the endpoint lets nothing
    through that the route refuses.

    The tools, each with its route and the judgment of that route:
    - [masc_whoami]: [GET /api/v1/auth/whoami], [Read_auth]
    - [masc_my_runtimes]: [GET /api/v1/auth/provider-accounts],
      [Manage_own_provider] ({!Auth_preview.person})
    - [masc_my_keepers], [masc_my_keeper_create], [masc_my_keeper_assign]:
      [GET] and [POST /api/v1/auth/keepers] and
      [POST /api/v1/auth/keepers/assign], [Manage_own_keeper]
      ({!Auth_preview.keeper_owner}). A PAT whose scope lacks the effect is
      refused, and a Keeper or a Runtime of another person is answered as
      one that is not there.
    - [masc_my_keeper_turn]: [POST /api/v1/auth/keepers/turn],
      [Manage_own_keeper] with the namespace of the person and the token
      that authenticated the request ({!Auth_preview.keeper_turn_caller}).
      The scope of a PAT must cover the turn: its Runtime, the [Direct]
      channel, and the effects [invoke_model] and [use_tool]
      ({!Authz_keeper_turn.decide}). The request stays open until the
      Runtime answers or {!Server_preview_keeper_turn} gives the turn up, and
      the result is the JSON of that route.
    - [masc_my_keeper_conversation_new]:
      [POST /api/v1/auth/keepers/conversation], [Manage_own_keeper] with the
      namespace of the person ({!Auth_preview.keeper_turn_caller}). It starts
      no client, so the scope of a PAT needs no more than that effect. *)

(** [/mcp]. *)
val path : string

(** The most bytes of one message. *)
val max_message_bytes : int

(** The installation the endpoint answers for: the zone, where a tool that
    makes or changes a record of the person commits it, the environment of
    the process, from which a turn starts the client, and the workspace base
    path, under which the account homes are. *)
type installation =
  { zone : Authz_zone.t
  ; env : Eio_unix.Stdenv.base
  ; base_path : string
  }

(** What a request is judged with: one snapshot the zone could be trusted
    for, the time, and what the server read of the credential. *)
type caller =
  { trusted : Authz_zone.trusted
  ; now_ms : int
  ; gate : Auth_gate.request
  }

(** Judges the request as [Read_auth], which every method needs, before its
    body is read. A request that does not pass gets the answer to write: the
    JSON [{"error": ...}] with a 401 or a 403 that the who-am-I route
    gives. *)
val admitted : caller -> (unit, Login_routes.answer) result

type answer =
  { status : Httpun.Status.t
  ; headers : (string * string) list  (** Lowercase names, with [cache-control: no-store]. *)
  ; body : string
  }

(** The answer to the message [body] of an admitted [caller].

    - An [Accept] that does not take both [application/json] and
      [text/event-stream], or MCP routing headers that disagree with the
      body: a 400 with a JSON-RPC error.
    - A message that {!Mcp_request_admission.admit} refuses: its answer.
    - A notification: a 202 with no body.
    - A request: the result of its method. A tool that the caller may not
      use, or whose arguments its definition does not take, answers a tool
      result with [isError], and so does a tool whose route function refuses.

    The status is 200, but a 400 or a 404 where the single-user endpoint
    gives one: an error with a null id, and on a revision that selects its
    protocol per request an error that the revision maps to a status. *)
val answer : installation -> caller -> Httpun.Request.t -> body:string -> answer
