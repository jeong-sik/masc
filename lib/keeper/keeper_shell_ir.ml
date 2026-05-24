let classify ir =
  Masc_exec.Shell_ir_risk.classify (Masc_exec.Shell_ir_risk.undecided ir)
;;

let with_cwd ~raw ~cwd ir =
  let scope = Some (Masc_exec.Path_scope.classify ~raw ~cwd) in
  Masc_exec.Shell_ir.with_cwd scope ir
;;

let of_cmd cmd =
  match Masc_exec_bash_parser.Bash.parse_string cmd with
  | Masc_exec.Parsed.Parsed ir -> ir
  | _ ->
    let trimmed = String.trim cmd in
    let bin_str =
      match String.index_opt trimmed ' ' with
      | Some i -> String.sub trimmed 0 i
      | None -> trimmed
    in
    let bin =
      match Masc_exec.Bin.of_string bin_str with
      | Ok b -> b
      | Error _ -> (
        match Masc_exec.Bin.of_string "sh" with
        | Ok b -> b
        | Error _ -> failwith "Keeper_shell_ir.of_cmd: impossible bin fallback")
    in
    Masc_exec.Shell_ir.Simple
      { bin
      ; args = [ Masc_exec.Shell_ir.Lit (cmd, Masc_exec.Shell_ir.default_meta) ]
      ; env = []
      ; cwd = None
      ; redirects = []
      ; sandbox = Masc_exec.Sandbox_target.host ()
      }
;;
