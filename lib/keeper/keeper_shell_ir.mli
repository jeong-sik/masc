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
  Masc_exec.Exec_program.t ->
  string list ->
  Masc_exec.Shell_ir.t
(** Build a simple Shell IR command from an already-classified binary.
    Keeper typed-input lowerers use this entrypoint when the executable came
    from JSON and must be classified before Shell IR construction. *)

val pipeline : Masc_exec.Shell_ir.t list -> Masc_exec.Shell_ir.t
(** Build an explicit Shell IR pipeline from already-lowered stages. *)

type dispatch_error =
  | Gate_reject of string
  | Cannot_parse
  | Too_complex
  | Path_reject of string

val validate_paths :
  ?keeper_id:string ->
  ?base_path:string ->
  workdir:string ->
  Masc_exec.Shell_ir.t ->
  (unit, string) result
(** Validate Shell IR path arguments through the keeper Shell IR facade. *)

val coding_command_context :
  ?caller:Masc_exec_command_gate.Shell_command_gate.caller ->
  ?allow_pipes:bool ->
  allowed_commands:string list ->
  string ->
  (Masc_exec_command_gate.Shell_command_gate.parsed_context, string) result
(** Parse and validate a legacy raw coding command through the shared Shell IR
    policy path. This preserves coding-surface checks such as direct-dune,
    glob, wrapped-stage, allowlist, pipe, and redirect policy before callers
    dispatch through {!dispatch_classified}. *)

val dispatch_classified :
  ?timeout_sec:float ->
  ?before_path_validation:(Masc_exec.Shell_ir.t -> (unit, string) result) ->
  ?caller:Masc_exec_command_gate.Shell_command_gate.caller ->
  ?allow_pipes:bool ->
  ?redirect_allowed:bool ->
  allowed_commands:string list ->
  ?keeper_id:string ->
  ?base_path:string ->
  workdir:string ->
  sandbox:Masc_exec.Sandbox_target.t ->
  Masc_exec.Shell_ir_risk.decided Masc_exec.Shell_ir_risk.decided_ir ->
  (Masc_exec.Exec_dispatch.dispatch_result, dispatch_error) result
(** Run the canonical keeper Shell IR pipeline for an already-classified IR:
    typed gate -> optional pre-path validation -> path validation ->
    dispatch_decided. [redirect_allowed] defaults to [true] for the historical
    keeper shell path; legacy code-shell callers pass [false]. *)

val dispatch :
  ?timeout_sec:float ->
  ?before_path_validation:(Masc_exec.Shell_ir.t -> (unit, string) result) ->
  ?caller:Masc_exec_command_gate.Shell_command_gate.caller ->
  ?allow_pipes:bool ->
  ?redirect_allowed:bool ->
  allowed_commands:string list ->
  ?keeper_id:string ->
  ?base_path:string ->
  workdir:string ->
  sandbox:Masc_exec.Sandbox_target.t ->
  Masc_exec.Shell_ir.t ->
  (Masc_exec.Exec_dispatch.dispatch_result, dispatch_error) result
(** Run the canonical keeper Shell IR pipeline:
    classify -> typed gate -> optional pre-path validation -> path validation ->
    dispatch_decided. *)
