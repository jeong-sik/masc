(* RFC-0070 Phase 3a — Docker daemon client stub. See docker_client.mli
   for the contract. Phase 3b adds [module Real], Phase 3c adds
   [module Mock]; both satisfy [S]. *)

type sandbox_error =
  | Daemon_unreachable
  | Image_pull_failed
  | Container_oom
  | Exec_timeout
  | Probe_format_drift
  | Cleanup_failed

module type S = sig
  type plan
  type exec_result
  type ps_record
  type container_name

  val run : plan -> (exec_result, sandbox_error) result

  val exec
    :  container:container_name
    -> cmd:string
    -> (exec_result, sandbox_error) result

  val ps_query
    :  labels:(string * string) list
    -> (ps_record list, sandbox_error) result

  val rm : container_name -> (unit, sandbox_error) result
end
