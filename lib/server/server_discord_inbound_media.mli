type failure =
  | Binding_changed
  | Discord_unconfigured
  | Original_unavailable
  | Original_mismatch
  | Attachment_missing
  | Invalid_attachment
  | Byte_budget_exceeded
  | Download_failed
  | Deadline_exceeded

type loaded = {
  images : Keeper_chat_store.attachment list;
  failures : (string * failure) list;
}

val reason : failure -> string

val load :
  base_path:string ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  keeper_name:string ->
  Keeper_chat_operation_payload.decoded_source ->
  loaded
(** Recover the exact attachment IDs from the recorded Discord message under
    its current Keeper binding. A successful attachment contains verified
    image bytes. Failures carry an ID and cause suitable for the turn. *)

module For_testing : sig
  val resolve :
    max_bytes:int ->
    is_bound:(unit -> bool) ->
    fetch_original:(unit -> (Yojson.Safe.t, failure) result) ->
    fetch_bytes:(max_bytes:int -> string -> (string, failure) result) ->
    channel_id:string ->
    message_id:string ->
    author_id:string ->
    attachment_ids:string list ->
    loaded
end
