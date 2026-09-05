(** What an attached work service offers one Keeper.

    A Keeper that consented to a provider has a token in its own secret
    scope. This asks that provider's MCP server what tools it has and writes
    the answer down beside the workspace.

    Written down rather than asked per turn, on purpose. A turn that had to
    reach Atlassian before it could start would fail whenever Atlassian was
    slow, for a question whose answer changes about never. The catalog is
    refreshed when a Keeper attaches and whenever an operator asks; it is not
    refreshed on a timer, because a stale entry is visible and fixable while
    a timer is a network call nobody asked for.

    Calling a tool still reaches the network. That one is the point. *)

type catalog = {
  provider_id : string;
  provider_label : string;
  discovered_at : float;  (** unix seconds *)
  tools : Mcp_client.tool list;
}

val keepers_with :
  base_path:string -> provider_id:string -> excluding:string -> string list
(** Which Keepers hold a catalog for this provider, sorted.

    A Keeper attaches on its own account -- the client is shared, the token
    is not -- so "who has this already" is a question no single Keeper's tab
    can answer, and answering it by opening each of them in turn is how an
    operator loses track of which account went where.

    [excluding] is the Keeper being looked at, left out because the screen
    already says whether that one has it. *)

val load :
  base_path:string ->
  keeper_name:string ->
  provider_id:string ->
  (catalog option, string) result
(** What was written down last time, if anything. [Ok None] means this Keeper
    has never attached to this provider; an [Error] means the file is there
    and unreadable, which is not the same thing and must not be read as
    "no tools". *)

val refresh :
  ?post:Mcp_client.post ->
  base_path:string ->
  keeper_name:string ->
  provider:Keeper_oauth_provider.t ->
  now:float ->
  unit ->
  (catalog, string) result
(** Connect as this Keeper, ask what tools exist, and write the answer down.

    The token comes from the Keeper's own projected environment -- the same
    array its runtime would be handed -- rather than from this process's
    environment, so a variable of the same name here cannot be mistaken for
    a Keeper's credential. *)

type offered_tool = {
  schema : Agent_core.Types.tool_schema;
      (** Model-facing name is the provider id prefixed onto the remote
          name. A provider is free to call something [search], and so is
          masc; the model would otherwise be handed two tools with one name
          and no way to mean either. *)
  read_only : bool option;
      (** The provider's own [annotations.readOnlyHint], written down at
          attach time. [None] means the service said nothing, which is not
          the same as saying no. *)
  provider : Keeper_oauth_provider.t;
  remote_name : string;
}

type offering = {
  offered : offered_tool list;
  unusable : (string * string) list;
      (** Tools the provider named that cannot be offered, each with why.
          Kept rather than dropped: a shorter tool list with no reason for
          it is the shape that has an operator reading code to find out
          what happened. *)
}

val agent_tools : provider:Keeper_oauth_provider.t -> catalog -> offering
(** Project a written catalog onto data a Keeper's runtime can place.

    Data rather than closures on purpose: what runs an offered tool is
    {!Keeper_identity_gate}, which decides per call whether the durable Gate
    is consulted first, and it needs the provider and remote name to do
    that. This module keeps the catalog and the wire; it holds no
    authorization opinion. *)

type call_phase =
  | Before_send  (** the [tools/call] was never sent; no effect happened *)
  | After_send
      (** the request reached the wire; whether the effect happened is the
          service's answer, not this process's *)

type call_error =
  | Precondition of string
      (** no credential, or a renewal this Keeper needed failed permanently;
          nothing was sent *)
  | Transient_precondition of string
      (** a renewal failed for a reason a retry may clear (a network blip, a
          5xx/429 from the token endpoint); nothing was sent *)
  | Mcp of {
      phase : call_phase;
      error : Mcp_client.error;
    }

val run_call :
  ?post:Mcp_client.post ->
      (** How a call reaches the provider. Injected for the same reason it is
          everywhere else here: a test that needs network is a test that does
          not run. *)
  ?token_post:Keeper_oauth_flow.post ->
      (** The OAuth token endpoint, injected so the reactive refresh on a 401
          can be exercised without a live provider. *)
  ?discover:
    (mcp_url:string ->
     (Keeper_oauth_discovery.t, Keeper_oauth_discovery.error) result) ->
      (** Discovery for that same reactive refresh. *)
  base_path:string ->
  keeper_name:string ->
  provider:Keeper_oauth_provider.t ->
  remote_name:string ->
  arguments:Yojson.Safe.t ->
  unit ->
  (Mcp_client.tool_result, call_error) result
(** One call to one attached provider's tool, as this Keeper.

    The wire and nothing else: authorization lives in
    {!Keeper_identity_gate}, which decides before this runs — over the
    durable Gate, so a deferral survives a Keeper nobody is watching — and
    spends a granted approval by host replay from the stored input rather
    than waiting for a byte-identical re-emission (#25947).

    A call reads the token and opens a session of its own rather than
    holding one for the turn. That is three requests where one would do --
    [initialize], the [initialized] notification, then the call -- measured
    against the live server on 2026-08-26, which does mint a session id, so
    the handshake is not free.

    What it buys: a token refreshed mid-turn is picked up, an expired
    session heals by itself, and two concurrent tool calls have no shared
    connection to agree about. Worth paying until someone measures the
    latency and decides otherwise; holding one session per turn needs a
    mutable cell two fibers share, and that is the part to get right
    deliberately rather than on the way past. *)

val tool_result_of_call :
  (Mcp_client.tool_result, call_error) result ->
  Agent_core.Types.tool_result
(** The model's view of one call: a tool that ran and said no is a
    recoverable answer, a refused credential is not, transport is transient.
    Kept beside {!run_call} so the phases and the model vocabulary cannot
    drift apart in two files. *)

val for_turn : base_path:string -> keeper_name:string -> offering
(** Every attached provider's tools, for one turn.

    Reads the declarations through {!Keeper_oauth_declarations} -- the same
    reader the operator screens use, so what a Keeper can call and what a
    screen says it can call cannot disagree -- and then the catalog each one
    wrote down. A provider this Keeper never attached to contributes nothing
    and is not a problem; one whose catalog is unreadable is reported in
    [unusable] rather than passed over.

    A provider an operator switched off ({!Keeper_identity_switch})
    contributes nothing either, and is not [unusable]: nothing is broken,
    the identity screen says off, and the audit log says who threw the
    switch. An unreadable switch store marks every declared provider
    unusable rather than offering tools that may have been turned off. *)

type renewal_error =
  | Renew_transient of string
      (** the renewal failed for a reason a later attempt may clear (a network
          blip, a 5xx/429 from the token endpoint) *)
  | Renew_permanent of string
      (** the renewal cannot succeed without re-attaching the provider (a
          revoked refresh token, no registered client) *)

val renewal_error_message : renewal_error -> string
(** The human-readable reason, without the transient/permanent distinction. *)

val renew_if_needed :
  ?token_post:Keeper_oauth_flow.post ->
  ?discover:
    (mcp_url:string ->
     (Keeper_oauth_discovery.t, Keeper_oauth_discovery.error) result) ->
  base_path:string ->
  keeper_name:string ->
  provider:Keeper_oauth_provider.t ->
  now:float ->
  access_token:string ->
  unit ->
  (string, renewal_error) result
(** The access token to use right now, exchanged for a fresh one first if
    the stored expiry is inside the declaration's renewal window.

    Done where the token is read rather than on a timer. The only moment
    freshness matters is the moment before a call, and a Keeper nobody is
    running does not need a new credential -- a timer would mint one anyway
    and spend a refresh token to do it.

    A stored expiry that is missing or unreadable renews nothing: replacing
    a working credential on a guess costs the refresh token and gains
    nothing. A provider that rotates its refresh token has the new one
    written down; one that does not keeps what is on disk. *)
