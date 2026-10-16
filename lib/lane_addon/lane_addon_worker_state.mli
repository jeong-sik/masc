(** Persistent worker state has a host-selected logical installation owner,
    independent of the disposable worker incarnation. No operation here deletes
    state; container cleanup must never imply volume deletion. *)
type owner
val create_owner : workspace_root:string -> installation_id:string ->
  package_id:string -> (owner, string) result
val belongs_to : owner -> package_id:string -> bool
val identity : owner -> string
(** The text of the [masc.lane.state.owner] label on this owner's volume and
    on every container created for it. *)
val volume_name : ?runtime:Lane_addon_types.runtime -> owner -> string
val container_name : ?runtime:Lane_addon_types.runtime -> owner -> string
val container_name_of_identity : ?runtime:Lane_addon_types.runtime -> string -> (string, string) result
(** The writer name for the identity text of a [masc.lane.state.owner] label. *)
val ensure :
  ?runtime:Lane_addon_types.runtime ->
  run:(operation:string -> string list -> (string, string) result) ->
  owner -> (string, string) result
(** Creates or verifies an exactly owned runtime-local volume, then returns the
    /state mount. Failed enumeration is not interpreted as absence. Callers
    must serialize active writers for a logical installation. *)
