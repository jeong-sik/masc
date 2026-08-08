(** Read-only implementation of one canonical durable Agent execution.

    The public surface is owned solely by {!Agent_execution_projection_intf.S}.
    The constructor below remains private to the wrapped OAS implementation. *)

include Agent_execution_projection_intf.S

val open_durable
  :  codec:Execution_codec_executor.t
  -> dir:Eio.Fs.dir_ty Eio.Path.t
  -> locator_run_id:Execution_event.Run_id.t
  -> unit
  -> (t, error) result
