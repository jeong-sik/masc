(** Generic file-backed Channel Gate connector state for Python sidecars.

    Slack and Telegram sidecars already read [bindings.json] from
    [.gate/runtime/<connector>/]. This functor wires those sidecars into the
    same dashboard bind/unbind and connector status API as Discord/iMessage. *)

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
end

module Make (_ : Config) : Channel_gate_connector.S
