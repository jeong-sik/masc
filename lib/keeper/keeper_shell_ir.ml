module Shell_gate = Masc_exec_command_gate.Shell_command_gate

let classify ir =
  Masc_exec.Shell_ir_risk.classify (Masc_exec.Shell_ir_risk.undecided ir)
;;

let with_cwd ~raw ~cwd ir =
  let scope = Some (Masc_exec.Path_scope.classify ~raw ~cwd) in
  let rec map = function
    | Masc_exec.Shell_ir.Simple simple ->
      Masc_exec.Shell_ir.Simple { simple with cwd = scope }
    | Masc_exec.Shell_ir.Pipeline stages ->
      Masc_exec.Shell_ir.Pipeline (List.map map stages)
  in
  map ir
;;

let gate_verdict_map verdict ~f_allow ~f_reject ~f_cannot_parse ~f_too_complex =
  match verdict with
  | Shell_gate.Allow ctx -> f_allow ctx
  | Shell_gate.Reject { diagnostic; _ } -> f_reject diagnostic
  | Shell_gate.Cannot_parse _ -> f_cannot_parse
  | Shell_gate.Too_complex _ -> f_too_complex
;;
