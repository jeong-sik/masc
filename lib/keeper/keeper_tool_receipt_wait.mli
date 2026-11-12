(** [keeper_receipt_wait]: the turn ends on the receipt of a background
    Execute run. Several calls in one turn wait for all of their runs.

    The call checks that the request is a background Execute run of this
    Keeper whose receipt has not been delivered and acknowledged already, and
    answers with a completed result that carries
    {!Keeper_tool_execution.Receipt_wait_requested}. Nothing is recorded yet.
    The wait joins the conversation's execution record in the same transaction
    that retains the turn's checkpoint
    ({!Keeper_chat_operation_store.defer_direct_checkpoint}).

    A request that an execution other than [execution_scope] already waits for
    is refused with a message the model reads, and nothing is recorded. That
    check reads the journal without the Owner, so the transaction above still
    refuses a wait that began after it. A run with no [execution_scope] serves
    no conversation and its call is refused. *)

val handle
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> execution_scope:Keeper_execution_scope_id.t option
  -> args:Yojson.Safe.t
  -> Keeper_tool_execution.t
