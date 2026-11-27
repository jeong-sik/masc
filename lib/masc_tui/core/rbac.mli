(** Typed RBAC & auth-session Single Source of Truth for the MASC TUI.

    Every access decision is derived from a closed sum type {!auth_session}
    and a closed capability requirement {!route_access} via exhaustive pattern
    matching with zero catch-all defaults and zero default admin elevation on
    unknown or unverified states. *)

type account_mode =
  | Single_user
  | Multi_account

type auth_methods = {
  google : bool;
  github : bool;
  dev_token : bool;
}

val default_auth_methods : auth_methods

type role =
  | Admin
  | Worker
  | Player

type principal_kind =
  | Human
  | Service

type principal = {
  kind : principal_kind;
  id : string;
}

type binding_kind =
  | Session
  | Pat
  | Service_credential

type credential_binding = {
  kind : binding_kind;
  id : string;
}

type auth_gate_reason =
  | Token_required
  | Token_invalid of string
  | Signed_out of string option
  | Forbidden_credential of string
  | Auth_unavailable of string

type auth_session =
  | Probing_health
      (** Initial fail-closed state before [GET /health] succeeds. *)
  | Probing_single_user of { auth_methods : auth_methods }
      (** [GET /health] confirmed single-user mode; awaiting
          [GET /api/v1/dashboard/shell] to resolve effective role and token
          validity. *)
  | Probing_multi_account of { auth_methods : auth_methods }
      (** [GET /health] confirmed multi-account mode; awaiting
          [GET /api/v1/auth/whoami] to resolve principal, role, and binding. *)
  | Single_user_local of {
      auth_methods : auth_methods;
      auth_enabled : bool;
      require_token : bool;
      token_present : bool;
      token_valid : bool;
      effective_agent : string option;
      role : role;
      effective_admin : bool;
      can_keeper_msg : bool;
      auth_error_code : string option;
      auth_error_detail : string option;
    }
  | Single_user_auth_required of {
      auth_methods : auth_methods;
      reason : auth_gate_reason;
    }
  | Multi_account_signed_out of {
      auth_methods : auth_methods;
      reason : auth_gate_reason;
    }
  | Multi_account_signed_in of {
      principal : principal;
      role : role;
      binding : credential_binding;
      auth_methods : auth_methods;
    }
  | Auth_unavailable of {
      mode : account_mode option;
      reason : string;
    }

(** Server capability requirement matching [lib/route_access.mli],
    [lib/auth_gate.ml], and [lib/server/server_account_dashboard_bridge.ml]. *)
type route_access =
  | Always_public
      (** Open in every mode and session state ([GET /health]). *)
  | Single_user_shell_probe
      (** [GET /api/v1/dashboard/shell]: probes single-user auth summary and
          serves bridged workspace shell in multi-account. *)
  | Multi_account_whoami_probe
      (** [GET /api/v1/auth/whoami]: multi-account identity probe. *)
  | Workspace_read
      (** Bridged [Workspace_read] in multi-account AND [Public_read] /
          [CanReadState] in single-user (Admin or Worker). *)
  | Single_user_read
      (** Single-user [Public_read] / [CanReadState] route returning 404 in
          multi-account. *)
  | Single_user_token_read
      (** Single-user [Token_permission CanReadState] route requiring
          [auth_enabled && require_token && token_valid] with Worker or Admin
          role, and returning 404 in multi-account. *)
  | Single_user_write
      (** Single-user worker mutation ([CanBroadcast], [CanVote],
          [CanAddTask], [CanClaimTask], [CanCompleteTask]); 404 in
          multi-account. *)
  | Su_read_ma_admin
      (** Dual-mode read ([GET /api/v1/infra/sandboxes],
          [GET /api/v1/dashboard/logs]): [Public_read] / [CanReadState] in
          single-user (Admin or Worker), and bridged [Admin_only] browser
          session in multi-account (PAT returns 403). *)
  | Bridged_token_admin
      (** Bridged admin operation ([/api/v1/config/*],
          [POST /api/v1/infra/sandboxes/probe], [PUT /api/v1/wiki/:slug],
          [/api/v1/dashboard/standalone-lanes], [/api/v1/dashboard/exact-lane-runs]):
          requires [Token_permission CanAdmin] in single-user
          ([auth_enabled && require_token && token_valid && effective_admin])
          and [Admin_only] browser session in multi-account (PAT returns 403). *)
  | Single_user_role_admin
      (** Single-user [Tool] / [Tool_actor] [admin_tool] route: allows
          [Single_user_local] whenever [role = Admin && effective_admin]
          (including local loopback with [auth_enabled = false]), denies Worker
          and Player with [Requires_admin], and returns 404 in multi-account. *)
  | Single_user_token_admin_only
      (** Single-user [Token_permission CanAdmin] route requiring
          [auth_enabled && require_token && token_valid && effective_admin]
          and returning 404 in multi-account. *)
  | Own_provider_manage
      (** Dual-mode route ([/api/v1/setup/accounts/login*]): requires
          [Token_permission CanAdmin] in single-user, and
          [Manage_own_provider] (any active Human Admin or Worker, Session or
          PAT; Service denied) in multi-account. *)
  | Multi_account_own_provider
      (** Multi-account-only own-provider route
          ([/api/v1/auth/provider-accounts], [/api/v1/auth/integrations],
          [/api/v1/setup/accounts/verify], [/api/v1/setup/accounts/key*]):
          requires [Manage_own_provider] (active Human Admin or Worker, Session
          or PAT; Service denied) in multi-account and returns 404 in
          single-user. *)
  | Own_keeper_sandbox_read
      (** [GET /api/v1/infra/sandboxes/:keeper]: [Public_read] in single-user,
          ownership-checked bridged read for authenticated Admin/Worker in
          multi-account. *)
  | Memory_diff_read of { keeper_scoped : bool }
      (** [GET /api/v1/memory/diff]: [Public_read] in single-user; in
          multi-account [world] is [Workspace_read] and [keeper] is
          human-owner-scoped. *)
  | Machine_play
      (** [CanPlayMachine] route in single-user (Admin, Worker, or Player). *)

type deny_reason =
  | Probing_auth
  | Auth_required of auth_gate_reason
  | Requires_admin
  | Pat_cannot_admin
  | Token_auth_not_enabled
  | Service_cannot_manage_own_provider
  | Requires_worker_or_admin
  | Single_user_only_in_multi_account
  | Multi_account_only_in_single_user

type access_verdict =
  | Allowed
  | Denied of deny_reason

(** {1 Strict Parsers (Parse, Don't Validate)} *)

val account_mode_of_string : string -> (account_mode, string) result
val account_mode_to_string : account_mode -> string
val role_of_string : string -> (role, string) result
val role_to_string : role -> string
val principal_kind_of_string : string -> (principal_kind, string) result
val principal_kind_to_string : principal_kind -> string
val binding_kind_of_string : string -> (binding_kind, string) result
val binding_kind_to_string : binding_kind -> string

(** {1 Session Constructors & Classification} *)

val single_user_local_admin : auth_session
(** Verified single-user local admin session with token auth enabled. Never
    used as a fallback or initial boot state. *)

val single_user_local_worker : auth_session
(** Verified single-user local worker session with token auth enabled. *)

val single_user_local_player : auth_session
(** Verified single-user local player session with token auth enabled. *)

val session_of_single_user_shell_auth :
  auth_methods:auth_methods ->
  enabled:bool ->
  require_token:bool ->
  token_present:bool ->
  token_valid:bool ->
  effective_agent:string option ->
  effective_role:role option ->
  effective_admin:bool option ->
  can_keeper_msg:bool ->
  auth_error_code:string option ->
  auth_error_detail:string option ->
  auth_session
(** Project single-user [GET /api/v1/dashboard/shell] ["auth"] payload into a
    fail-closed {!auth_session}. Handles non-strict loopback HTTP 200 replies
    carrying [enabled && require_token && not token_valid] as
    {!Single_user_auth_required}, and never elevates missing/mismatched role
    metadata to Admin. *)

val account_mode_of_session : auth_session -> account_mode option
val auth_methods_of_session : auth_session -> auth_methods
val role_of_session : auth_session -> role option
val is_authenticated : auth_session -> bool
val requires_auth_gate : auth_session -> bool
val is_multi_account : auth_session -> bool
val is_single_user : auth_session -> bool
val can_admin : auth_session -> bool
val can_single_user_token_admin : auth_session -> bool

val decide : auth_session -> route_access -> access_verdict
(** Exhaustive 2D access decision matrix with zero catch-alls. *)

val is_allowed : auth_session -> route_access -> bool

(** {1 Demotion & Identity Change Detection} *)

val is_privilege_demotion : prev:auth_session -> next:auth_session -> bool
(** True whenever [next] loses authenticated status, loses admin capability,
    loses token-admin capability, or drops from Worker to Player relative to
    [prev]. *)

val session_identity_changed : prev:auth_session -> next:auth_session -> bool
(** True whenever account mode, authenticated principal/agent, role, or
    credential binding changed across two verified sessions. *)

(** {1 Structural Equality} *)

val equal_account_mode : account_mode -> account_mode -> bool
val equal_auth_methods : auth_methods -> auth_methods -> bool
val equal_role : role -> role -> bool
val equal_principal_kind : principal_kind -> principal_kind -> bool
val equal_principal : principal -> principal -> bool
val equal_binding_kind : binding_kind -> binding_kind -> bool
val equal_credential_binding : credential_binding -> credential_binding -> bool
val equal_auth_gate_reason : auth_gate_reason -> auth_gate_reason -> bool
val equal_auth_session : auth_session -> auth_session -> bool
val equal_route_access : route_access -> route_access -> bool
val equal_deny_reason : deny_reason -> deny_reason -> bool
val equal_access_verdict : access_verdict -> access_verdict -> bool

(** {1 Localized Operator Display Helpers} *)

val session_badge : compact:bool -> auth_session -> Say.t
(** Concise top-rail pill text naming mode, role, and credential binding. *)

val deny_reason_say : deny_reason -> Say.t
(** Operator-facing explanation for a blocked screen, action, or command. *)

val auth_gate_title : auth_session -> Say.t
val auth_gate_detail : auth_session -> Say.t
val auth_gate_remediation : auth_session -> Say.t

(** {1 Account/Session Inspection & Capability Matrix} *)

type binding_display =
  | Binding_session
  | Binding_pat
  | Binding_service_credential
  | Binding_dev_token
  | Binding_none

val equal_binding_display : binding_display -> binding_display -> bool
val binding_display_to_string : binding_display -> string
val binding_display_of_session : auth_session -> binding_display
val binding_id_of_session : auth_session -> string option
val principal_display : auth_session -> string
val role_display : auth_session -> string
val auth_error_detail_of_session : auth_session -> string option

type capability_matrix = {
  can_read : bool;
  can_write : bool;
  can_admin : bool;
  can_token_read : bool;
  can_token_admin : bool;
  can_manage_own_provider : bool;
}

type capability_row = {
  key : string;
  label : Say.t;
  route : route_access;
  allowed : bool;
  verdict : access_verdict;
}

val capability_matrix_of_session : auth_session -> capability_matrix
val capability_rows_of_session : auth_session -> capability_row list
val short_deny_reason_say : deny_reason -> Say.t
