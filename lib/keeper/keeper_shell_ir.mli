val classify :
  Masc_exec.Shell_ir.t ->
  Masc_exec.Shell_ir_risk.decided Masc_exec.Shell_ir_risk.decided_ir

val with_cwd : raw:string -> cwd:string -> Masc_exec.Shell_ir.t -> Masc_exec.Shell_ir.t

val of_cmd : string -> Masc_exec.Shell_ir.t

(** Map over a [Shell_command_gate] verdict, handling each constructor
    with a dedicated callback. Eliminates the repeated 4-way match in
    typed-bash and gh dispatch paths. *)
val gate_verdict_map :
  Masc_exec_command_gate.Shell_command_gate.verdict ->
  f_allow:(Masc_exec_command_gate.Shell_command_gate.parsed_context -> 'b) ->
  f_reject:(string -> 'b) ->
  f_cannot_parse:'b ->
  f_too_complex:'b ->
  'b
