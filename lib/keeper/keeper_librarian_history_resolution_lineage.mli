(** The existing known-basis link or one explicit fenced-original link, with
    a shared cycle check. Read ports grant no dispatch/publication authority. *)
type reader = scope:string -> request_id:string -> (Yojson.Safe.t option, string) result
val validate_predecessor_payload :
  read:(scope:string -> request_id:string -> (Lane_addon_tool_request_owner.retained option, string) result) ->
  read_fence:reader -> read_resolution:reader -> require_confirmed:bool ->
  Keeper_librarian_durable_request.t -> (unit, string) result
val confirm_predecessor : store:Lane_addon_store.t -> require_confirmed:bool ->
  Keeper_librarian_durable_request.t -> (unit, string) result
val fenced_original : store:Lane_addon_store.t ->
  request:Keeper_librarian_durable_request.t -> original:Lane_addon_tool_request_owner.retained ->
  (Keeper_librarian_history_resolution_state.t option, string) result
val confirmed_resolution_child : store:Lane_addon_store.t ->
  request:Keeper_librarian_durable_request.t -> original:Lane_addon_tool_request_owner.retained ->
  (string option, string) result
(** Follow only this exact fenced parent's durable child ACK and full payload
    binding. Pending child publication returns None; no ID is minted here. *)
