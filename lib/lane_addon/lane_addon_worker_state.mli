(** Persistent worker state has a host-selected logical installation owner,
    independent of the disposable worker incarnation. No operation here deletes
    state; container cleanup must never imply volume deletion. *)
type owner
val create_owner : workspace_root:string -> installation_id:string ->
  package_id:string -> (owner, string) result
val belongs_to : owner -> package_id:string -> bool
val volume_name : owner -> string
val container_name : owner -> string
val ensure :
  run:(operation:string -> string list -> (string, string) result) ->
  owner -> (string, string) result
(** Creates or verifies an exactly owned local Docker volume, then returns the
    /state mount. Failed enumeration is not interpreted as absence. Callers
    must serialize active writers for a logical installation. *)
