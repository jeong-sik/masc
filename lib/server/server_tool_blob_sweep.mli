(** Runs {!Tool_blob_sweep.reclaim} inside the server once a day.
    The clock is the mtime of the scan marker, so a restart
    neither skips a day nor scans twice. The scan runs on a thread of
    {!Systhread_host}'s domain, off the main domain, and its report or error
    goes to the server log. A scan that raises is logged and the loop goes on.
    The scan reads the places {!Server_tool_blob_scope.scope} classifies; a
    scan that leaves entries unclassified or sees an unpinnable malformed
    structured reference deletes nothing and logs a warning naming them. *)

val start :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Workspace.config ->
  unit
