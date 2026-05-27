let parse_cmd_to_ir_opt cmd =
  match Exec_policy.parse_string_to_ir ~mode:Strict cmd with
  | Ok ir -> Some ir
  | Error _ -> None
;;
