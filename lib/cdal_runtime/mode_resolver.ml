type decision =
  { effective_mode : Execution_mode.t
  ; source : string
  }

let min_mode a b = if Execution_mode.compare a b <= 0 then a else b

let capability_cap (capabilities : Cdal_proof.capability_snapshot) =
  if Mode_enforcer.all_read_only capabilities.tools
  then Execution_mode.Diagnose
  else if Mode_enforcer.all_workspace_only capabilities.tools
  then Execution_mode.Draft
  else Execution_mode.Execute
;;

let resolve ~requested ~risk_class ~capabilities =
  match Risk_class.max_mode risk_class with
  | None ->
    Error
      (Printf.sprintf
         "risk class %s forbids all execution"
         (Risk_class.to_string risk_class))
  | Some risk_cap ->
    let cap_limit = capability_cap capabilities in
    let combined_cap = min_mode risk_cap cap_limit in
    let effective = min_mode requested combined_cap in
    if Execution_mode.equal effective requested
    then Ok { effective_mode = effective; source = "passthrough" }
    else if Execution_mode.compare cap_limit risk_cap < 0
    then Ok { effective_mode = effective; source = "capability_limit" }
    else Ok { effective_mode = effective; source = "risk_class_downgrade" }
;;
