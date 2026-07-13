val with_cwd : raw:string -> cwd:string -> Masc_exec.Shell_ir.t -> Masc_exec.Shell_ir.t

val simple_bin :
  ?cwd_raw:string ->
  ?cwd_base:string ->
  ?sandbox:Masc_exec.Sandbox_target.t ->
  ?env:(string * string) list ->
  ?redirects:Masc_exec.Redirect_scope.t list ->
  Masc_exec.Exec_program.t ->
  string list ->
  Masc_exec.Shell_ir.t
(** Build a simple Shell IR command from an opaque executable name.
    [redirects] defaults to [[]] when omitted. *)

val pipeline : Masc_exec.Shell_ir.t list -> Masc_exec.Shell_ir.t
(** Build an explicit Shell IR pipeline from already-lowered stages. *)

type dispatch_error =
  | Gate_reject of string
  | Cannot_parse
  | Too_complex
  | Path_reject of string

val validate_paths :
  workdir:string ->
  Masc_exec.Shell_ir.t ->
  (unit, string) result
(** Validate explicit Shell IR [cwd] and redirect targets against the keeper
    workspace boundary. Positional argv stays opaque to policy. *)

val dispatch :
  ?allow_pipes:bool ->
  ?redirect_allowed:bool ->
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
