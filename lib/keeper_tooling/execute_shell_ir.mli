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

type validated_dispatch
(** A Shell IR dispatch whose syntax, sandbox projection, and workspace paths
    have all been validated. *)

val validate_paths :
  workdir:string ->
  Masc_exec.Shell_ir.t ->
  (unit, string) result
(** Validate explicit Shell IR [cwd] and redirect targets against the keeper
    workspace boundary. Positional argv stays opaque to policy. *)

val validate_dispatch :
  ?allow_pipes:bool ->
  workdir:string ->
  sandbox:Masc_exec.Sandbox_target.t ->
  Masc_exec.Shell_ir.t ->
  (validated_dispatch, dispatch_error) result
(** Build the exact dispatch plan before an outer authorization boundary. *)

val dispatch_validated :
  ?base_host_env:string array ->
  ?timeout_sec:float ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  validated_dispatch ->
  Masc_exec.Exec_dispatch.dispatch_result
(** Execute a previously validated plan without any further policy decision. *)
