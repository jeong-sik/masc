(** Transport-neutral bearer admission for strict token-bound server surfaces.

    HTTP, WebSocket, and gRPC adapters extract credentials differently, but
    they must all delegate identity binding and role checks to this module.
    Admission is deliberately strict even on loopback: disabled or
    optional-token workspace auth is a configuration error for protected
    transports, not an anonymous-access mode. *)

type requirement =
  | Permission of Masc_domain.permission
  | Tool of string

type identity =
  { agent_name : string
  ; role : Masc_domain.agent_role
  }

type admission =
  { identity : identity
  ; auth_token : string
  }

val admit :
  base_path:string ->
  token:string option ->
  claimed_agent:string option ->
  requirement:requirement ->
  (admission, Masc_domain.masc_error) result
(** [admit] returns the immutable identity plus the normalized credential that
    established it.  Transport adapters that keep a connection open must carry
    this admission context into each protected request instead of treating an
    authenticated upgrade as request authorization. *)

val authorize :
  base_path:string ->
  token:string option ->
  claimed_agent:string option ->
  requirement:requirement ->
  (identity, Masc_domain.masc_error) result
(** [authorize ~base_path ~token ~claimed_agent ~requirement] verifies a
    non-empty bearer token, binds an optional caller-declared agent to the
    token owner, and checks the required role/tool capability.

    A process-wide service token is deliberately insufficient: every admitted
    connection must present a stored credential whose owner matches any
    [claimed_agent].  This identity-only projection is for adapters that do
    not need to retain the admitted credential. *)
