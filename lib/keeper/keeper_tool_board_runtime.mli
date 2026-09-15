(** Agent board tool runtime — post, reply, vote, list, get. *)

val handle_board_tool :
  meta:Keeper_meta_contract.keeper_meta ->
  result_projection:Tool_output.model_projection ->
  name:string ->
  args:Yojson.Safe.t ->
  string

val handle_board_tool_with_outcome :
  meta:Keeper_meta_contract.keeper_meta ->
  result_projection:Tool_output.model_projection ->
  name:string ->
  args:Yojson.Safe.t ->
  Keeper_tool_execution.t
(** [result_projection] is the projection this call's result crosses on its
    way to the model. A thread read ([masc_board_post_get]) fits each comment
    page inside it. *)

module For_testing : sig
  val snapshot_execution_of_response :
    Keeper_tool_execution.t ->
    Snapshot_protocol.response ->
    Keeper_tool_execution.t
end
