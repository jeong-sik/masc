(** Generic file-backed Channel Gate connector state for Python sidecars.

    Slack and Telegram sidecars already read [bindings.json] from
    [.gate/runtime/<connector>/]. This functor wires those sidecars into the
    same dashboard bind/unbind and connector status API as Discord/iMessage. *)

(** [.gate/runtime/<connector_id>] and the three files a sidecar connector
    keeps there. Derived from the id so relocating the tree, or adding a
    channel, does not re-spell the layout. *)
val runtime_dir : connector_id:string -> string

val default_status_path : connector_id:string -> string
val default_binding_store_path : connector_id:string -> string
val default_binding_audit_path : connector_id:string -> string

module type Config = sig
  val connector_id : string
  val display_name : string
  val channel : string
  val status_path_env_names : string list
  val binding_store_path_env_names : string list
  val binding_audit_path_env_names : string list
  val stale_after_env_name : string
end

module Make (_ : Config) : Channel_gate_connector.S
