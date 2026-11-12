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
    - the run did not finish ([unfinished]): the server stopped, an operator
      cancelled it, or the handler raised. The exit status was not recorded, so
      the command may have run to its end, stopped partway or never started.

    A receipt is written when the run ends, when {!Keeper_msg_async} cuts the
    worker off, and at startup for a run that never recorded an end. An
    [unfinished] receipt is not written when the Keeper's outbox already holds a
    receipt with the same [request_id]: a crash after the end was written and
    before the request was settled leaves the request open, and the next start
    finds that receipt. If the Keeper had acknowledged it before the crash, the
    outbox no longer shows it and the next start writes [unfinished]. The file
    name of a receipt is the digest of its content, so writing the same receipt
    twice leaves one file. *)

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

    The started result has the members the Execute output schema requires
    ([status] with a [kind] of [started], [typed], the call time), so a
    composition plan node that sets [run_in_background] completes with it.

    Nothing starts, and the result is a failure, when the Keeper's runtime route
    cannot receive tool-result receipts, when the server-lifetime switch is not
    available, or when the request is not accepted. When acceptance is
    uncertain ([Reconciliation_required]) the command may start, and the result
    says so. A copy of [args] with credential patterns masked is kept in the
    request record and copied into receipts; [run] has [args] unchanged. *)

val deliver_unfinished_runs : base_path:string -> unit
(** Startup, before {!Keeper_msg_async.recover_lost_disk_records}. Every
    non-terminal request of this producer left by an earlier server process
    gets an [unfinished] receipt, and its Keeper is woken. Recovery then
    settles the record as lost, so a request is visited once; a second visit
    after a crash between the two writes the same receipt bytes. A failed write
    is logged and recovery settles the record anyway, so that run gets no
    receipt. *)

val request_arguments : Keeper_msg_async.entry -> Yojson.Safe.t option
(** The masked arguments a background run keeps in its request record. [None]
    when the request is not a background Execute run. *)

val retain_source_lost_receipt
  :  base_path:string
  -> keeper_name:string
  -> request_id:string
  -> arguments:Keeper_client_tool_outbox.arguments
  -> (unit, string) result
(** Writes one [unfinished] receipt, echoing [arguments], for a run that has
    no worker and no receipt, so a conversation that waits for it receives an
    answer. [arguments] are [Known] ones its request record kept
    ({!request_arguments}), or [Unknown] when it kept none; the receipt says so
    in its message and in its [arguments]. Writes
    nothing when the outbox already holds a receipt for the request. It does not
    wake the Keeper. *)

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

  val started_json : request_id:string -> elapsed_ms:int -> Yojson.Safe.t

  val restart_cause : string

  val holds_receipt
    :  base_path:string
    -> keeper_name:string
    -> request_id:string
    -> (bool, string) result
end
