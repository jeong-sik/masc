(** The agent history media store over {!Tool_blob_store} (RFC-0476 §3.4).

    [put] publishes the raw bytes durably with {!Tool_blob_store.put_durable_reuse},
    so a history that names them survives a restart; [get] reads them back
    with {!Tool_blob_store.fetch}, which checks the digest, and also checks
    the length the reference names. Blobs it writes stay live for
    {!Tool_blob_maintenance} through the [Stored] sources the checkpoints
    carry. *)

val create : Tool_blob_store.t -> Agent_core_base.History.media_store

(** [create (Tool_blob_store.create ~base_path)]: the store of one BasePath,
    which every Keeper agent and every masc producer of history media under
    that BasePath shares. *)
val of_base_path : base_path:string -> Agent_core_base.History.media_store
