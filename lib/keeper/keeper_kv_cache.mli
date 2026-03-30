(** Keeper KV cache persistence via llama-server slot save/restore.

    Wraps llama-server's slot save/restore HTTP API. Requires
    [--slot-save-path] to be set on the server.

    @since 2.177.0 *)

(** Save a slot's KV cache to disk.
    Returns [Ok ()] on success, [Error message] on failure. *)
val save_slot :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  endpoint:string ->
  slot_id:int ->
  filename:string ->
  (unit, string) result

(** Restore a slot's KV cache from disk.
    Returns [Ok ()] on success, [Error message] on failure.
    Restore failure is non-fatal (first session has no prior save). *)
val restore_slot :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  endpoint:string ->
  slot_id:int ->
  filename:string ->
  (unit, string) result

(** Generate a stable cache filename for a keeper agent. *)
val cache_filename : keeper_name:string -> slot_id:int -> string
