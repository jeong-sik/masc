(** Authentication & Authorization — token lifecycle, credential management,
    and permission enforcement for MASC agents.

    Types ([auth_config], [agent_credential], [masc_error], [agent_role],
    [permission]) are re-exported from the [Types] module via [open Types].

    @since 0.4.0 *)

open Types

(** {1 Token Generation} *)

val generate_token : unit -> string
(** Generate a cryptographically random hex token (64 chars). *)

val save_private_text_file : string -> string -> unit
(** [save_private_text_file path content] writes [content] to [path] with
    mode 0o600. Creates the file if missing, truncates otherwise. *)

(** {1 Auth Config} *)

val load_auth_config : string -> auth_config
(** [load_auth_config config] reads [.masc/auth/config.json] under [config].
    Returns [default_auth_config] on missing / parse errors. *)

val save_auth_config : string -> auth_config -> unit
(** [save_auth_config config cfg] persists the auth config. *)

(** {1 Credentials} *)

val load_credential : string -> string -> agent_credential option
(** [load_credential config agent_name] looks up the agent's credential.
    Falls back to agent-type prefix for generated nicknames. *)

val save_credential : string -> agent_credential -> unit

val delete_credential : string -> string -> unit

val list_credentials : string -> agent_credential list

val find_credential_by_token :
  string -> token:string -> (agent_credential, masc_error) result

val resolve_agent_from_token :
  string -> token:string -> (string, masc_error) result

(** {1 Token Lifecycle} *)

val create_token :
  string -> agent_name:string -> role:agent_role ->
  (string * agent_credential, masc_error) result
(** [create_token config ~agent_name ~role] returns [(raw_token, credential)]. *)

val verify_token :
  string -> agent_name:string -> token:string ->
  (agent_credential, masc_error) result

val refresh_token :
  string -> agent_name:string -> old_token:string ->
  (string * agent_credential, masc_error) result

(** {1 Permission Checks} *)

val check_permission :
  string -> agent_name:string -> token:string option ->
  permission:permission -> (unit, masc_error) result

val permission_for_tool : string -> permission option

val is_tool_auth_strict_enabled : unit -> bool

val authorize_tool :
  string -> agent_name:string -> token:string option ->
  tool_name:string -> (unit, masc_error) result

(** {1 Role Resolution} *)

val resolve_role :
  string -> agent_name:string -> token:string option ->
  (agent_role, masc_error) result

val resolve_role_with_auth_config :
  string -> auth_cfg:auth_config -> agent_name:string -> token:string option ->
  (agent_role, masc_error) result

val authorize_tool_for_role :
  agent_name:string -> role:agent_role -> tool_name:string ->
  (unit, masc_error) result

val authorize_tool_v2 :
  string -> agent_name:string -> token:string option ->
  tool_name:string -> (unit, masc_error) result

(** {1 Room Secret} *)

val init_room_secret : string -> string
(** [init_room_secret config] generates and persists a room secret.
    Returns the raw secret (shown once). *)

val verify_room_secret : string -> string -> bool

(** {1 Auth Toggle} *)

val enable_auth :
  string -> require_token:bool -> agent_name:string ->
  string * string option
(** [enable_auth config ~require_token ~agent_name] returns
    [(room_secret, bootstrap_token)]. *)

val disable_auth : string -> unit

val is_auth_enabled : string -> bool

val read_initial_admin : string -> string option
(** [read_initial_admin config] returns the bootstrap admin agent name. *)
