(** Types_auth — authentication, authorization, and rate-limit
    types.

    {b Include cascade:} starts with [include Masc_error] so the
    error type / serialisation surface flows through into
    {!Types}.  Adds:

    - {!agent_role} (Worker / Admin) + serialisers.
    - {!agent_credential} record + JSON round-trip.
    - {!auth_config} record + JSON round-trip + default value.
    - {!permission} variant + role->permissions table.
    - Rate-limit role multipliers ({!multiplier_for_role},
      {!effective_limit}). *)

include module type of struct
  include Masc_error
end

(** {1 Result type aliases} *)

type rate_limit_config = Masc_error.rate_limit_config = {
  per_minute : int;
  burst_allowed : int;
  priority_agents : string list;
  worker_multiplier : float;
  admin_multiplier : float;
  broadcast_per_minute : int;
  task_ops_per_minute : int;
}
(** Re-declared for record disambiguation in JSON serialisers.
    Type identity is preserved with {!Masc_error.rate_limit_config}. *)

type masc_error = t
(** Alias to {!Masc_error.t}. *)

val masc_error_to_string : masc_error -> string
val show_masc_error : masc_error -> string

type 'a masc_result = ('a, masc_error) result
(** Standard MASC operation result type. *)

(** {1 Agent role} *)

(** Enforced permission level for an agent. *)
type agent_role =
  | Worker  (** Can claim tasks, lock files, broadcast. *)
  | Admin   (** Full access: init, reset, manage agents. *)
[@@deriving show { with_path = false }]

val agent_role_to_string : agent_role -> string
(** ["worker"] / ["admin"]. *)

val agent_role_of_string : string -> (agent_role, string) result
(** Inverse of {!agent_role_to_string}; returns
    [Error "Unknown agent role: <s>"] for unrecognised inputs. *)

val agent_role_to_yojson : agent_role -> Yojson.Safe.t
(** Serialises as [\`String "worker"] / [\`String "admin"]. *)

val agent_role_of_yojson : Yojson.Safe.t -> (agent_role, string) result
(** Accepts only [\`String _]; non-string yields
    [Error "Expected string for agent_role"]. *)

val valid_agent_role_strings : string list
(** [["worker"; "admin"]] — used as the allowed-values set in
    JSON-schema generators. *)

(** {1 Agent credential} *)

type agent_credential = {
  id : Ids.Credential_id.t option;  [@default None]
  agent_id : Ids.Agent_id.t option;  [@default None]
  agent_name : string;
  token : string;  (** SHA-256 hash of the secret. *)
  role : agent_role;
  created_at : string;  (** ISO 8601 timestamp. *)
  expires_at : string option;  [@default None]
}
(** Token-based authentication record. *)

val agent_credential_to_yojson : agent_credential -> Yojson.Safe.t
(** Emits one extra denormalised field for backward-compat:
    [admin = (role = Admin)]. *)

val agent_credential_of_yojson :
  Yojson.Safe.t -> (agent_credential, string) result
(** Accepts both [role] (string) and the legacy [admin] (bool)
    field; missing role + [admin = true] -> [Admin], else [Worker]. *)

(** {1 Auth configuration} *)

type auth_config = {
  enabled : bool;
  room_secret_hash : string option;  [@default None]
  require_token : bool;  [@default false]
  token_expiry_hours : int;  [@default 24]
}
[@@deriving show]

val default_auth_config : auth_config
(** [enabled = true; room_secret_hash = None; require_token = true;
       token_expiry_hours = 24]. *)

val auth_config_to_yojson : auth_config -> Yojson.Safe.t
val auth_config_of_yojson : Yojson.Safe.t -> (auth_config, string) result

(** {1 Permission matrix} *)

(** What each role can do.  Each constructor maps to an HTTP /
    tool action. *)
type permission =
  | CanInit
  | CanReset
  | CanJoin
  | CanLeave
  | CanReadState
  | CanAddTask
  | CanClaimTask
  | CanCompleteTask
  | CanBroadcast
  | CanOpenPortal
  | CanSendPortal
  | CanCreateWorktree
  | CanRemoveWorktree
  | CanVote
  | CanAdmin
[@@deriving show { with_path = false }]

val permission_to_string : permission -> string
(** Stable wire format for {!permission}.  Returns the same string
    {!show_permission} does today (PascalCase constructor name) but
    locks the contract against [@@deriving show] template drift and
    accidental renames.  Public API/SSE/error output depends on these
    exact strings — prefer this over [show_permission] at any
    externally-observable boundary. *)

val permissions_for_role : agent_role -> permission list
(** [Worker] permissions exclude [CanInit] / [CanReset] / [CanAdmin].
    [Admin] adds those three to the [Worker] set. *)

val has_permission : agent_role -> permission -> bool
(** [has_permission role p] is [List.mem p (permissions_for_role role)]. *)

(** {1 Rate-limit role multipliers} *)

val multiplier_for_role : rate_limit_config -> agent_role -> float
(** [multiplier_for_role cfg role] returns
    [cfg.worker_multiplier] for [Worker] and [cfg.admin_multiplier]
    for [Admin]. *)

val effective_limit :
  rate_limit_config ->
  role:agent_role ->
  category:rate_limit_category ->
  int
(** [effective_limit cfg ~role ~category] returns
    [int_of_float (limit_for_category cfg category *
       multiplier_for_role cfg role)]. *)
