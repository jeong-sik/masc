val classify :
  Masc_exec.Shell_ir.t ->
  Masc_exec.Shell_ir_risk.decided Masc_exec.Shell_ir_risk.decided_ir

val with_cwd : raw:string -> cwd:string -> Masc_exec.Shell_ir.t -> Masc_exec.Shell_ir.t

val simple :
  ?cwd_raw:string ->
  ?cwd_base:string ->
  ?sandbox:Masc_exec.Sandbox_target.t ->
  Masc_exec.Exec_program.known ->
  string list ->
  Masc_exec.Shell_ir.t
(** Build a backend-neutral simple Shell IR command from typed argv. *)

val simple_bin :
  ?cwd_raw:string ->
  ?cwd_base:string ->
  ?sandbox:Masc_exec.Sandbox_target.t ->
  ?env:(string * string) list ->
  ?redirects:Masc_exec.Redirect_scope.t list ->
  Masc_exec.Exec_program.t ->
  string list ->
  Masc_exec.Shell_ir.t
(** Build a simple Shell IR command from an already-classified binary.
    Keeper typed-input lowerers use this entrypoint when the executable came
    from JSON and must be classified before Shell IR construction.
    [redirects] defaults to [[]] when omitted; RFC-0198 Phase B uses this
    parameter to thread typed stdin/stdout/stderr redirects from the JSON
    boundary into the Shell IR. *)

val pipeline : Masc_exec.Shell_ir.t list -> Masc_exec.Shell_ir.t
(** Build an explicit Shell IR pipeline from already-lowered stages. *)

type dispatch_error =
  | Gate_reject of string
  | Cannot_parse
  | Too_complex
  | Path_reject of string
  | Approval_required of { summary : string; bin : string }
  | Policy_denied of { reason : string }

val validate_paths :
  ?keeper_id:string ->
  ?base_path:string ->
  workdir:string ->
  Masc_exec.Shell_ir.t ->
  (unit, string) result
(** Validate Shell IR path arguments through the keeper Shell IR facade. *)

val tool_execute_command_context :
  ?allow_pipes:bool ->
  string ->
  (Masc_exec_command_gate.Shell_command_gate.parsed_context, string) result
(** Parse and validate a legacy raw Execute command through the shared Shell IR
    policy path. This preserves execution-surface checks such as direct-dune,
    glob, pipe, and redirect policy before callers dispatch through
    {!dispatch_classified}. *)

val dispatch_classified :
  ?allow_pipes:bool ->
  ?redirect_allowed:bool ->
  ?keeper_id:string ->
  ?base_path:string ->
  workdir:string ->
  sandbox:Masc_exec.Sandbox_target.t ->
  ?base_host_env:string array ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  Masc_exec.Shell_ir_risk.decided Masc_exec.Shell_ir_risk.decided_ir ->
  (Masc_exec.Exec_dispatch.dispatch_result, dispatch_error) result
(** Run the canonical keeper Shell IR pipeline for an already-classified IR:
    typed gate -> path validation -> dispatch_decided. [redirect_allowed]
    defaults to [true] for the historical tool execute path; legacy code-shell
    callers pass [false].  [?on_output_chunk] is forwarded to the host
    dispatch path for live output streaming. *)

val dispatch_classified_with_approval :
  ?allow_pipes:bool ->
  ?redirect_allowed:bool ->
  ?keeper_id:string ->
  ?base_path:string ->
  workdir:string ->
  sandbox:Masc_exec.Sandbox_target.t ->
  ?base_host_env:string array ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  agent_id:Masc_exec.Agent_id.t ->
  approval_config:Masc_exec.Approval_config.t ->
  Masc_exec.Shell_ir_risk.decided Masc_exec.Shell_ir_risk.decided_ir ->
  (Masc_exec.Exec_dispatch.dispatch_result, dispatch_error) result
(** Same pipeline as {!dispatch_classified}, but runs the capability-based
    approval policy gate {i before} the typed gate and path validation.
    [Ask] produces [Approval_required] (binary and risk class in the summary);
    [Deny] produces [Policy_denied] carrying the rendered typed
    [Verdict.deny_reason].  [Allow] and [Suggest_confirm] proceed to dispatch.
    A nested pipeline whose last stage is itself a pipeline yields
    [Too_complex], matching {!dispatch_classified}. *)

val dispatch :
  ?allow_pipes:bool ->
  ?redirect_allowed:bool ->
  ?keeper_id:string ->
  ?base_path:string ->
  workdir:string ->
  sandbox:Masc_exec.Sandbox_target.t ->
  ?base_host_env:string array ->
  ?on_output_chunk:([ `Stdout of string | `Stderr of string ] -> unit) ->
  Masc_exec.Shell_ir.t ->
  (Masc_exec.Exec_dispatch.dispatch_result, dispatch_error) result
(** Run the canonical keeper Shell IR pipeline:
    classify -> typed gate -> path validation -> dispatch_decided. *)
