(** The reads of requests in [Keeper_msg_async].

    [poll] answers for one request id: the pending entry of this process wins,
    otherwise the record on disk is read. [owner_rejection] rejects a caller
    other than the one that submitted the request.
    [load_canonical_request] reads the record under the locks of the request.
    [load_canonical_durable_terminal] and [with_canonical_durable_terminal]
    return a proof only for a terminal record in the terminal directory while
    this process holds no pending entry for the request;
    [load_canonical_durable_queued] returns a proof for a queued record in the
    active directory that no pending entry contradicts. A refusal says why in
    a [canonical_terminal_error] or a [canonical_queued_error].
    [list_for_keeper] lists the unsettled pending entries of one caller,
    newest first, for all Keepers or for one. [entry_to_fields] and
    [entry_to_json] render an entry.
    [Keeper_msg_async] includes this module. *)
open Keeper_msg_async_types
open Keeper_msg_async_state

val owner_rejection :
  caller:string ->
  entry ->
  access_rejection option

val poll : base_path:string -> caller:string -> string -> load_result

val load_canonical_request : base_path:string -> caller:string -> string -> load_result

val with_canonical_durable_terminal :
  base_path:string ->
  caller:string ->
  string ->
  f:(durable_terminal_proof -> 'a) ->
  ('a, canonical_terminal_error) result

val load_canonical_durable_terminal :
  base_path:string ->
  caller:string ->
  string ->
  (durable_terminal_proof, canonical_terminal_error) result

val load_canonical_durable_queued :
  base_path:string ->
  caller:string ->
  string ->
  (durable_queued_proof, canonical_queued_error) result

val list_for_keeper :
  base_path:string ->
  caller:string ->
  ?keeper_name:string ->
  unit ->
  (entry list,
   access_rejection)
  result

val entry_to_fields : entry -> (string * Yojson.Safe.t) list

val entry_to_json : entry -> Yojson.Safe.t
