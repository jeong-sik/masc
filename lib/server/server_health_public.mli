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

val health_json : ready:bool -> phase:Server_startup_state.phase -> Yojson.Safe.t
(** [{server; version; live; ready; phase}], five keys and no other.
    [version] is [Runtime_build_version.current]; [live] is
    [Server_startup_state.is_live ()]. The body never says the account mode,
    which is what tells an account server's answer from this one. *)

val liveness_json : Yojson.Safe.t
(** [{live}]. *)

val readiness_json : ready:bool -> phase:Server_startup_state.phase -> Yojson.Safe.t
(** [{ready; phase}]. *)
