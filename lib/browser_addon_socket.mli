(** Host-selected socket resource of a native browser installation. Blocking
    filesystem operations must be offloaded by the server caller. *)
type t
val context : instance_id:string -> automation:Browser_configuration.automation option ->
  stagehand:Browser_addon_stagehand.configuration option ->
  models:Browser_addon_models.configuration option -> (Yojson.Safe.t, string) result
(** Selects a private per-instance socket directory without creating it. Persist
    this immutable descriptor through Native_addon_lease.prepare before mkdir. *)
val acquire : admission:Native_addon_lease.t -> directory:string -> (t, string) result
(** Before payload spawn, acquire the directory selected by the original native
    reservation and persist its exact identity in that host claim slot. *)
val socket_path : t -> string
val with_download_snapshot : t -> Browser_addon_downloads.descriptor ->
  (Unix.file_descr -> ('a, string) result) -> ('a, string) result
(** Blocking host import scope. Pin the original acquired allocation, private
    snapshot root and regular descriptor, and recheck them after the callback.
    The worker supplies a UUID and identity/digest, never a pathname. The callback
    must consume this descriptor without reopening a path. *)
val arguments : t -> max_message_bytes:int -> string list
val cleanup : admission:Native_addon_lease.t -> directory:string -> (unit, string) result
(** Existing claim must be Settled. The original native reservation decides
    whether cleanup is required, including orphan recovery. Known directories
    are never reused and unknown contents are never recursively deleted. A
    missing acquisition record with an existing socket is unconfirmed. *)
