(** The startup recovery of request records in [Keeper_msg_async].

    [recover_lost_disk_records] looks at every record in the active directory
    of one base path and sweeps the atomic staging directory. A record whose
    terminal copy exists only loses its active source. A terminal record that
    is still in the active directory is moved to the terminal directory. A
    queued or running record that no live worker owns becomes [Lost] and a
    cancelling one becomes [Cancelled] ([status_after_worker_absence]); both
    are written to the terminal directory. A record that a live worker owns is
    left alone. The result is a [recovery_report] that counts what happened and
    lists the stores and records it could not handle.
    [Keeper_msg_async] includes this module. *)
open Keeper_msg_async_types

val status_after_worker_absence :
  reason:string ->
  request_status ->
  request_status

val recover_lost_disk_records :
  base_path:string -> unit -> recovery_report
