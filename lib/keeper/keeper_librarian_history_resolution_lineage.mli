(** The existing known-basis link or one explicit fenced-original link, with
    a shared cycle check. Read ports grant no dispatch/publication authority. *)
type reader = scope:string -> request_id:string -> (Yojson.Safe.t option, string) result
val validate_predecessor_payload :
  read:(scope:string -> request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  read_fence:reader -> read_resolution:reader -> require_confirmed:bool ->
  Keeper_librarian_durable_request.t -> (unit, string) result
(** Reads every predecessor's body, makes its index from the request it
    restored and requires the record's summary to be that index. Captured
    payloads only: the deployment preflight's check. *)
val confirm_predecessor_by_body : store:Lane_addon_store.t -> require_confirmed:bool ->
  Keeper_librarian_durable_request.t -> (unit, string) result
(** {!validate_predecessor_payload} over the store, with live source roots.
    The host's check before it runs or dispatches an original. *)
val confirm_predecessor : store:Lane_addon_store.t -> require_confirmed:bool ->
  Keeper_librarian_durable_request.t -> (unit, string) result
(** The Keeper pass's check. A predecessor is read as its record and the index
    in that record's summary, without its body; a fenced link compares the two
    indexes, the fence and the resolution record. A known-basis link reads both
    requests as before. The index is bound to the body where the body is read:
    [Keeper_librarian_durable_request.restore_payload], {!fenced_original} and
    {!confirm_predecessor_by_body}. *)
val confirm_predecessor_record : store:Lane_addon_store.t -> require_confirmed:bool ->
  Lane_addon_tool_request_owner.Record.t -> Keeper_librarian_durable_request.index -> (unit, string) result
(** {!confirm_predecessor} for an original the caller holds as its record and
    index. The original's own body is read only when its link to its
    predecessor is a known-basis one. *)
val fenced_original : store:Lane_addon_store.t ->
  request:Keeper_librarian_durable_request.t -> original:Lane_addon_tool_request_owner.retained ->
  (Keeper_librarian_history_resolution_state.t option, string) result
(** The original's fence, read with its body in hand: the record's index must
    be exactly the request's, source digests included. *)
val fenced_record : store:Lane_addon_store.t ->
  record:Lane_addon_tool_request_owner.Record.t -> index:Keeper_librarian_durable_request.index ->
  (Keeper_librarian_history_resolution_state.t option, string) result
(** The same fence from the record and its index, without the body. The fence
    names the source digest computed from the body when it was made, so an
    index whose source digest is not the body's differs from the fence. *)
val confirmed_resolution_child : store:Lane_addon_store.t ->
  record:Lane_addon_tool_request_owner.Record.t -> index:Keeper_librarian_durable_request.index ->
  (string option, string) result
(** Follow only this exact fenced parent's durable child ACK, by the parent's
    record and index. Pending child publication returns None; no ID is minted
    here. *)
