(** Generic file-backed Channel Gate connector state for out-of-process
    sidecars.

    A sidecar heartbeats [status.json] into [.gate/runtime/<connector>/] and
    keeps its bindings beside it. This functor turns that pair of files into
    the same dashboard bind/unbind and connector status API the in-process
    connectors serve, so liveness, staleness and path resolution are decided
    in one place rather than per connector. Telegram and iMessage instantiate
    it. *)

module type Config = sig
  val connector_id : string
  val display_name : string
  val channel : string
  val default_status_path : string
  val default_binding_store_path : string
  val default_binding_audit_path : string
  val status_path_env_names : string list
  val binding_store_path_env_names : string list
  val binding_audit_path_env_names : string list
  val stale_after_env_name : string

  val guild_id_field : Channel_gate_binding_store.guild_id_field
  (** Whether binding and audit rows carry a [guild_id]. Only Discord has
      guilds; a sidecar that does not should [Omit] rather than emit "". *)

  val default_poll_interval_sec : float
  (** Reported as [poll_interval_sec] when the status file has no value —
      either because it is absent or because this sidecar never writes one. *)

  val extra_status_fields :
    Yojson.Safe.t option -> (string * Yojson.Safe.t) list
  (** Connector-specific status fields, derived from the parsed status file
      ([None] when it is missing or unreadable). The keys are carried into
      [connector_json] too, so a connector declares them once. Return the
      same keys in both cases — the [None] result supplies the defaults. *)
end

module Make (_ : Config) : Channel_gate_connector.S
