(** Shared helpers for shell-like tool frontends after command policy has
    already accepted a command and produced Shell IR. *)

val shell_ir_with_default_cwd :
  string option -> Masc_exec.Shell_ir.t -> Masc_exec.Shell_ir.t
(** [shell_ir_with_default_cwd cwd ir] fills missing per-stage Shell IR [cwd]
    values with [cwd]. Existing stage-specific cwd values are preserved. *)

val output_for_dispatch_status :
  status:Unix.process_status -> stdout:string -> stderr:string -> string
(** Convert a dispatch status and captured output into the user-visible output
    string. Successful commands return stdout. Failed, signaled, or stopped
    commands return stderr, stdout, or both when both are present. *)
