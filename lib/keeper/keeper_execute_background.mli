(** Execute with [run_in_background]: the call returns at once and the command
    runs on the server after the calling turn has moved on.

    The command runs in a {!Keeper_msg_async} worker on the server-lifetime
    switch. When it ends, its result is written to the Keeper's tool-result
    outbox ({!Keeper_client_tool_outbox}) and the Keeper is woken with
    [Tool_result_ready], the same path an ended vendor turn uses for results it
    could not receive. Every later request of the Keeper carries the receipt
    until a completed turn acknowledges it.

    What a receipt says about the end of a run:

    - the command exited, timed out or was refused: [outcome] is the
      disposition of the foreground call ([completed], [deferred] or
      [failed]) and [result] is the payload that call would have returned;
    - the run did not finish ([unfinished]): the server stopped, the run was
      cancelled, or the handler raised. The exit status was not recorded, so
      the command may have run to its end, stopped partway or never started.

    A receipt is written once per run. The file name is the digest of its
    content, so writing the same receipt twice leaves one file. *)

val defer
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> args:Yojson.Safe.t
  -> (turn_sandbox_factory:Keeper_sandbox_factory.t option -> Keeper_tool_execution.t)
  -> Keeper_tool_execution.t
(** [defer ~config ~meta ~args run] has the shape of the [?defer] argument of
    {!Keeper_tool_execute_runtime.handle_tool_execute_with_outcome}. It accepts
    the run, returns a [started] result carrying the [request_id], and calls
    [run] on a server worker with a sandbox factory of the worker's own. The
    factory is created with [config] and [meta] as they are at the call and is
    cleaned up when the worker ends, as the async composition worker does.

    Nothing starts, and the result is a failure, when the Keeper's runtime route
    cannot receive tool-result receipts, when the server-lifetime switch is not
    available, or when the request is not accepted. When acceptance is
    uncertain ([Reconciliation_required]) the command may start, and the result
    says so. [args] are kept in the request record and copied into the receipt.
    *)

val deliver_unfinished_runs : base_path:string -> unit
(** Startup, before {!Keeper_msg_async.recover_lost_disk_records}. Every
    non-terminal request of this producer left by an earlier server process
    gets an [unfinished] receipt, and its Keeper is woken. Recovery then
    settles the record as lost, so a request is visited once; a second visit
    after a crash between the two writes the same receipt bytes. Failures are
    logged and leave the record for recovery. *)

(** Pure parts, exposed for tests. *)
module For_testing : sig
  val receipt_of_unfinished
    :  request_id:string
    -> arguments:Yojson.Safe.t
    -> cause:string
    -> Keeper_client_tool_outbox.receipt

  val receipt_of_execution
    :  request_id:string
    -> arguments:Yojson.Safe.t
    -> Keeper_tool_execution.t
    -> Keeper_client_tool_outbox.receipt

  val started_json : request_id:string -> Yojson.Safe.t

  val restart_cause : string
end
