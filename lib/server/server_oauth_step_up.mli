(** Scope challenge for OAuth-authenticated [tools/call] requests (MCP
    2026-07-28 Scope Challenge Handling).

    A tool names the permission it needs ([Tool_catalog] [required_permission]).
    An OAuth access token carries the role its scopes granted. When that role
    lacks the permission and a wider OAuth scope would grant it, the request is
    refused before any response starts, with HTTP 403 and an
    [insufficient_scope] challenge naming that scope. Every other request
    follows the existing path: a static bearer or a keeper token has no OAuth
    scope to widen, and a tool that no scope can unlock keeps its tool-level
    refusal. *)

val required_scope :
  base_path:string -> auth_token:string option -> allowed_tool:(string -> bool) ->
  body:string -> Auth_oauth.scope option
(** [Some scope] when authentication is enabled and [body] is a valid
    [tools/call] request with an ID for a registered public MCP tool allowed by
    [allowed_tool], [auth_token] is a current OAuth access token, the token's
    role lacks the tool's permission, and [scope] is the narrowest supported
    scope whose role grants it. [None] in every other case, including
    notifications, invalid requests, an unreadable body or token store: the
    caller's ordinary path then answers. Non-public tools follow that path so
    their existing authorization audit remains authoritative.

    Call it inside {!Auth_oauth.with_expected_resource}; OAuth access tokens
    fail closed outside it. The scope-to-role fact is read from
    {!Auth_oauth.effective_role} and the role-to-permission fact from
    [Masc_domain.has_permission], so no scope table is kept here. A token's
    scope can never exceed the bootstrap credential that approved it, so for a
    worker approval the named scope is reached only by approving again with an
    admin bearer. *)
