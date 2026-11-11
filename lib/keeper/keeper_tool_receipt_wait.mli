(** [keeper_receipt_wait]: the turn ends on the receipt of one background
    Execute run.

    The call checks that the request is a background Execute run of this
    Keeper whose receipt has not been delivered and acknowledged already, and
    answers with a completed result that carries
    {!Keeper_tool_execution.Receipt_wait_requested}. Nothing is recorded yet.
    The wait joins the conversation's execution record in the same transaction
    that retains the turn's checkpoint
    ({!Keeper_chat_operation_store.defer_direct_checkpoint}), and that
    transaction also refuses a request another execution already waits for. *)

val handle
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t
