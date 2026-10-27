val run :
  base_path:string ->
  port:int ->
  host:string ->
  log_path:string option ->
  agent:string ->
  login:(unit -> int) ->
  int
(** Replaces this workspace's running server with the executable running this
    command. A server of this workspace that answers on loopback [port] is
    asked to stop once, through the same sign-in and identity check as setup;
    any other holder of the port or the workspace is refused untouched, and so
    is a [host] that is not an IP address or that 127.0.0.1 cannot reach. The replacement is
    [masc start --wait-for-previous-owner] when a server was asked to stop and
    plain [masc start] when none ran, spawned in its own process group with
    its output appended to [log_path] (default
    [<base>/.masc/logs/masc-start-<UTC time>.log], opened only after the stop
    request). Returns 0 once [/health/ready] answers 200 with the
    replacement's pid, 1 when it is refused or the replacement exits first
    (for example because another replacement already waits). There is no
    deadline: the predecessor's own shutdown watchdog bounds the wait, and
    Ctrl-C ends only the watching. *)
