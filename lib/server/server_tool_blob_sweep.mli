(** Runs {!Tool_blob_sweep.observe} inside the server once a day
    (RFC-0499 §4.1). The clock is the mtime of the scan marker, so a restart
    neither skips a day nor scans twice. The scan runs on a thread of
    {!Systhread_host}'s domain, off the main domain, and its report or error
    goes to the server log. A scan that raises is logged and the loop goes on.
    Layer one deletes nothing. *)

val start :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Workspace.config ->
  unit
