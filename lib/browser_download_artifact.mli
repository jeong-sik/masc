(** Publish a previously verified, session-owned download into the existing
    durable blob store. The reader accepts the returned sha256 on every runtime. *)
val publish : base_path:string -> string -> (Yojson.Safe.t, string) result
val publish_descriptor : store:Tool_blob_store.t -> socket:Browser_addon_socket.t ->
  Browser_addon_downloads.descriptor -> (Yojson.Safe.t, string) result
(** Import the original worker's immutable grant through the same checked open
    descriptor, matching its expected digest before durable publication. *)
