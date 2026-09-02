val with_cwd : raw:string -> cwd:string -> Masc_exec.Shell_ir.t -> Masc_exec.Shell_ir.t

val simple_bin :
  ?cwd_raw:string ->
  ?cwd_base:string ->
  ?sandbox:Masc_exec.Sandbox_target.t ->
  ?redirects:Masc_exec.Redirect_scope.t list ->
  Masc_exec.Exec_program.t ->
  string list ->
  Masc_exec.Shell_ir.t
(** Build a simple Shell IR command from an opaque executable name.
    [redirects] defaults to [[]] when omitted. *)

val pipeline : Masc_exec.Shell_ir.t list -> Masc_exec.Shell_ir.t
(** Build an explicit Shell IR pipeline from already-lowered stages. *)

(** Why a structured command was refused.  Every arm carries what was refused,
    not just that something was.

    [Cannot_parse] and [Too_complex] were nullary while the typed gate could
    not produce them: [decide_typed] wrapped its own input as already-parsed,
    so those arms were unreachable and dropping the reason cost nothing.  The
    gate now checks the structural invariants a typed caller can violate, so
    the arms are reachable, and a caller told only "Command too complex"
    cannot tell a nested pipeline from a one-stage one. *)
type dispatch_error =
  | Gate_reject of string
  | Cannot_parse of Masc_exec_command_gate.Shell_command_gate.parse_reason
  | Too_complex of Masc_exec_command_gate.Shell_command_gate.too_complex_reason
  | Path_reject of string

val parse_reason_tag :
  Masc_exec_command_gate.Shell_command_gate.parse_reason -> string

val too_complex_reason_tag :
  Masc_exec_command_gate.Shell_command_gate.too_complex_reason -> string
(** Closed-vocabulary tags for the reasons {!Cannot_parse} and {!Too_complex}
    carry.  Re-exported so a caller that already matched the arm can render it
    without taking a direct dependency on the gate. *)

val validate_paths :
  workdir:string ->
  Masc_exec.Shell_ir.t ->
  (unit, string) result
(** Validate explicit Shell IR [cwd] and redirect targets against the keeper
    workspace boundary. Positional argv stays opaque to policy. *)

val dispatch :
  ?allow_pipes:bool ->
  workdir:string ->
  sandbox:Masc_exec.Sandbox_target.t ->
  ?base_host_env:string array ->
  ?timeout_sec:float ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  Masc_exec.Shell_ir.t ->
  (Masc_exec.Exec_dispatch.dispatch_result, dispatch_error) result
(** Validate a structured command and dispatch it:
    typed gate -> path boundary -> sandbox-aware execution.  Authorization is
    an outer product concern and is deliberately absent from this adapter. *)
