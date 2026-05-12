(* RFC-0070 Phase 3b-iv.1a — concrete module type S. See .mli. *)

type sandbox_error =
  | Daemon_unreachable
  | Image_pull_failed
  | Container_oom
  | Exec_timeout
  | Probe_format_drift
  | Cleanup_failed

module type S = sig
  val run
    :  Keeper_sandbox_oneshot_plan.t
    -> (Docker_response.exec_result, sandbox_error) result

  val exec
    :  ?user:int * int
    -> ?workdir:string
    -> container:Keeper_container_name.t
    -> cmd:string
    -> unit
    -> (Docker_response.exec_result, sandbox_error) result

  val ps_query
    :  labels:(string * string) list
    -> (Docker_response.ps_record list, sandbox_error) result

  val rm : Keeper_container_name.t -> (unit, sandbox_error) result

  val info_security_options : unit -> (string list, sandbox_error) result

  val image_present : image:string -> (unit, sandbox_error) result
end
