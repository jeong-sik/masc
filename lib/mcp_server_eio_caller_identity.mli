type owner_keeper_identity = string * string option

type direct_call_authority =
  | Catalog_policy
  | Restricted_profile
(** [Restricted_profile] means the call already passed an exact managed or
    operator profile membership gate.  It does not weaken authentication. *)

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

type t = {
  agent_name : string;
  agent_name_is_ephemeral : bool;
      (** Ephemerality of [agent_name] from the carried origin, for the
          resolved-name cache (no substring re-probe on read). *)
  token : string option;
  has_explicit_agent_name : bool;
  verified_internal_keeper_runtime : bool;
  internal_keeper_runtime_tool : bool;
  owner_keeper_identity : owner_keeper_identity option;
  mode_gate_error : string option;
}

val caller_agent_name_from_arguments : Yojson.Safe.t -> string option

val resolve :
  config:Workspace_utils_backend_setup.config ->
  tool_name:string ->
  arguments:Yojson.Safe.t ->
  identity:Client_identity.t ->
  cached_resolved_agent:(string * bool) option ->
  auth_token:string option ->
  internal_keeper_runtime:bool ->
  direct_call_authority:direct_call_authority ->
  workspace_initialized:(unit -> bool) ->
  log_mcp_exn:(label:string -> exn -> unit) ->
  t
