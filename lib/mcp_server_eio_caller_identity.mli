type owner_keeper_identity = string * string option

type direct_call_authority =
  | Catalog_policy
  | Restricted_profile
(** [Restricted_profile] means the call already passed an exact managed,
    operator or seat profile membership gate.  It does not weaken
    authentication. *)

(** What a [tools/call] knows about its bearer when it reaches the executor
    (RFC a-request-reads-its-bearer-once-at-the-door, D5).

    HIGH-RISK-UNREVIEWED: [Admitted] is a bearer a door resolved to a
    credential. It carries the credential the door's lookup found and the
    role the door gave the bearer, and the executor takes them instead of
    reading the token again. [token] stays for a call whose name is not the
    credential's owner: that check still pairs the name with the token.

    [Unread] is a token no door answer stands in for, and the executor reads
    it as it did before a door answered. Auth was off at the door, no door
    ran (gRPC, the dashboard WebSocket, a direct caller), or the bearer is
    the internal Keeper token, which dispatch still looks up (D3).

    The type is private, so [Admitted] comes only from a door's principal. *)
type bearer = private
  | Admitted of {
      token : string;
      credential : Masc_domain.agent_credential;
      role : Masc_domain.agent_role;
    }
  | Unread of {
      token : string option;
      internal_keeper_runtime : bool;
    }

val of_sender :
  Mcp_server_eio_types.sender ->
  auth_token:string option ->
  internal_keeper_runtime:bool ->
  bearer
(** The bearer of a request the dispatcher received from this sender.
    [auth_token] and [internal_keeper_runtime] are read only when no door
    answer stands in for them. *)

val unread : string option -> internal_keeper_runtime:bool -> bearer
(** A token no door read: a caller that reaches the executor without a
    door, such as gRPC with no token. *)

(** A resolved caller name tagged with the origin decided at mint time.

    Replaces the [Client_name_kind] string classifier: the
    auth-fallback gate matches this closed sum totally instead of
    re-probing the name with [String.starts_with ~prefix:"agent-"]. *)
type minted_name =
  | Stable of string             (** Caller supplied [_agent_name]; stable identity. *)
  | Ephemeral of string          (** System-minted (own fallback / [`System_fallback] identity / cached ephemeral). *)
  | Resolved_external of string  (** Tool-domain [agent_name] or cached non-ephemeral name; never token-rewritten by string shape. *)

val minted_name_to_string : minted_name -> string

val minted_name_is_transient : minted_name -> bool
(** Total match deciding whether the silent auth-token fallback should
    fire (and, after re-tagging, the ephemerality cached for a session).
    This is origin-based, not shape-based: [Stable -> false],
    [Ephemeral -> true], [Resolved_external _ -> false]. *)

val alias_may_rewrite_identity :
  credential_owner:string option -> agent_name:string -> bool
(** Whether the workspace display alias ([Workspace.resolve_agent_name], a
    prefix scan over [agents_dir]) may replace this caller name.

    The resolved name becomes the subject of [Auth.authorize_tool], which
    checks the presented token against that subject's credential. A prefix
    match onto an unrelated record therefore turns a valid credential into
    [InvalidToken "Token mismatch"]. Answers [false] exactly when the
    presented credential already owns [agent_name]. *)

val resolve_identity_alias :
  credential_owner:string option ->
  resolve_alias:(string -> string) ->
  string ->
  string
(** The authorization subject: the caller name put through [resolve_alias]
    (the workspace display lookup) only where
    {!alias_may_rewrite_identity} allows it. *)

type t = {
  agent_name : string;
  agent_name_is_ephemeral : bool;
      (** Ephemerality of [agent_name] from the carried origin, for the
          resolved-name cache (no substring re-probe on read). *)
  bearer : bearer;
  has_explicit_agent_name : bool;
  verified_internal_keeper_runtime : bool;
  owner_keeper_identity : owner_keeper_identity option;
  mode_gate_error : string option;
}

val caller_agent_name_from_arguments : Yojson.Safe.t -> string option

val without_caller_marker : Yojson.Safe.t -> Yojson.Safe.t
(** The arguments without the caller marker that
    {!caller_agent_name_from_arguments} reads. The marker names the caller,
    not a tool input, so a Lane Add-on export is validated and invoked
    without it; its caller travels in the host-context envelope. Other
    underscore names stay, because an export schema may declare them. *)

val resolve :
  config:Workspace_utils_backend_setup.config ->
  tool_name:string ->
  arguments:Yojson.Safe.t ->
  identity:Client_identity.t ->
  cached_resolved_agent:(string * bool) option ->
  bearer:bearer ->
  direct_call_authority:direct_call_authority ->
  workspace_initialized:(unit -> bool) ->
  log_mcp_exn:(label:string -> exn -> unit) ->
  t
