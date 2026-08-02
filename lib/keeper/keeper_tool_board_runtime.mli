(** Agent board tool runtime — post, reply, vote, list, get. *)

val handle_keeper_board_tool :
  meta:Keeper_meta_contract.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_board_tool_with_outcome :
  meta:Keeper_meta_contract.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t

module For_testing : sig
  val snapshot_execution_of_response :
    Keeper_tool_execution.t ->
    Snapshot_protocol.response ->
    Keeper_tool_execution.t
end
