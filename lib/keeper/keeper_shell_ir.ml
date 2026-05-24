let of_cmd cmd =
  match Masc_exec.Bash_parser.parse_string cmd with
  | Parsed.Parsed ir -> ir
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
