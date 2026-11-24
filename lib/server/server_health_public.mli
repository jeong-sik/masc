(** What a health route says to a requester the server gives no read of its
    state: that this is a MASC server, its release version, and whether it is
    live and ready, with the startup phase. Nothing of the host, the
    workspace, the build or the process.

    The values here read no credential and no server state beyond the startup
    flags they are handed, so a caller cannot pass a workspace field into a
    public body by argument. *)

val server_field : string
(** ["server"]. *)

val server_name : string
(** ["masc"], the value of {!server_field} in every health body. *)

val version_field : string
(** ["version"]. *)

val auth_methods_field : string
(** ["auth_methods"]. *)

type auth_methods =
  { google : bool
  ; github : bool
  ; dev_token : bool
  }

val auth_methods_to_json : auth_methods -> Yojson.Safe.t
(** [{"google": bool, "github": bool, "dev_token": bool}]. *)

val single_user_auth_methods : dev_token:bool -> auth_methods
(** Public authentication discovery for a single-user server: browser OAuth
    providers are always [false], and [dev_token] reflects whether the loopback
    dev-token route is enabled. *)

val health_json :
  dev_token:bool -> ready:bool -> phase:Server_startup_state.phase -> Yojson.Safe.t
(** [{server; version; live; auth_methods; ready; phase}], six keys and no other.
    [version] is [Build_version.current]; [live] is
    [Server_startup_state.is_live ()]. The body never says the account mode,
    which is what tells an account server's answer from this one. *)

val liveness_json : Yojson.Safe.t
(** [{live}]. *)

val readiness_json : ready:bool -> phase:Server_startup_state.phase -> Yojson.Safe.t
(** [{ready; phase}]. *)

val capabilities : string list
(** Additive server API capability flags advertised on [/api/v1/dashboard/shell]
    and authenticated [/health]. Never added to the unauthenticated public
    {!health_json} probe. *)

val capabilities_json : Yojson.Safe.t
(** JSON string array encoding of {!capabilities}. *)
