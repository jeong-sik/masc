(* Typed Docker sandbox daemon errors — RFC-0070 §2 G2.
   See sandbox_error.mli for context and the constructor contract. *)

type t =
  | Daemon_unreachable of { message : string }
  | Image_pull_failed of { image : string; message : string }
  | Container_oom of { container_id : string }
  | Exec_timeout of { container_id : string; budget_sec : float }
  | Probe_format_drift of { command : string; raw : string }
  | Cleanup_failed of { container_id : string; message : string }
  | Image_not_found of { image : string }

let to_string = function
  | Daemon_unreachable _ -> "daemon_unreachable"
  | Image_pull_failed _ -> "image_pull_failed"
  | Container_oom _ -> "container_oom"
  | Exec_timeout _ -> "exec_timeout"
  | Probe_format_drift _ -> "probe_format_drift"
  | Cleanup_failed _ -> "cleanup_failed"
  | Image_not_found _ -> "image_not_found"
;;
