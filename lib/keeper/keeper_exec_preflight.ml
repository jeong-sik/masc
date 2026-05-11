open Keeper_types

let json_string_field name json = Json_util.get_string json name

let handle_keeper_preflight_check
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let repo = Safe_ops.json_string ~default:"" "repo" args |> String.trim in
  let root = Keeper_alerting_path.project_root_of_config config in
  let results = Buffer.create 256 in
  let all_ok = ref true in
  let add_check name ok _value =
    Buffer.add_string results
      (Printf.sprintf "  %s: %s\n" name (if ok then "ok" else "FAILED"));
    if not ok then all_ok := false
  in
  (* Check 1: gh auth status *)
  let () =
    let st, out =
      Masc_exec.Exec_gate.run_argv_with_status
        ~actor:`Coord_git
        ~raw_source:"/bin/zsh -lc gh auth status 2>&1"
        ~summary:"keeper preflight gh auth status"
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Preflight ())
        [ "/bin/zsh"; "-lc"; "gh auth status 2>&1" ]
    in
    add_check "gh_auth" (st = Unix.WEXITED 0) out
  in
  (* Check 2: repo access *)
  let default_branch = ref "main" in
  let () =
    if repo = "" then
      add_check "repo_access" true "(current project)"
    else
      let st, out =
        Masc_exec.Exec_gate.run_argv_with_status
          ~actor:`Coord_git
          ~raw_source:(Printf.sprintf "/bin/zsh -lc gh repo view %s --json name,defaultBranchRef 2>&1" (Filename.quote repo))
          ~summary:"keeper preflight gh repo view"
          ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Preflight ())
          [ "/bin/zsh"; "-lc";
            Printf.sprintf "gh repo view %s --json name,defaultBranchRef 2>&1"
              (Filename.quote repo) ]
      in
      let ok = st = Unix.WEXITED 0 in
      (* Extract default branch from JSON if available *)
      (if ok then
         Safe_ops.protect ~default:() (fun () ->
           let json = Yojson.Safe.from_string out in
           let branch_ref =
             Yojson.Safe.Util.(
               json |> member "defaultBranchRef" |> member "name" |> to_string)
           in
           default_branch := branch_ref));
      add_check "repo_access" ok out
  in
  (* Check 3: keeper identity *)
  let author = Keeper_identity.keeper_git_author ~keeper_name:meta.name in
  let email = Keeper_identity.keeper_git_email ~keeper_name:meta.name in
  let () = add_check "identity" true author in
  (* Check 4: preset level *)
  let preset_ok =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some (Research | Coding | Delivery | Full) -> true
    | Some (Minimal | Social | Messaging | Dispatch) -> false
    | None -> false
  in
  let preset_name =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some p -> Keeper_tool_policy.preset_name_of_tool_preset p
    | None -> "custom"
  in
  let () = add_check "preset" preset_ok preset_name in
  (* Check 5: accountability risk *)
  let accountability_summary =
    Keeper_accountability.accountability_summary_json config ~keeper_name:meta.name
      ~agent_name:meta.agent_name
  in
  let risk_band =
    json_string_field "risk_band" accountability_summary
    |> Option.value ~default:"unknown"
  in
  let routing_hint =
    json_string_field "routing_hint" accountability_summary
    |> Option.value ~default:"normal_routing"
  in
  let accountability_risk =
    String.equal risk_band "high"
  in
  let () =
    add_check "accountability_risk" (not accountability_risk)
      (if accountability_risk then "RISK_HIGH" else "ok")
  in
  (* Check 6: sandbox clone target *)
  let repo_name_arg =
    Safe_ops.json_string ~default:"" "repo_name" args |> String.trim
  in
  let clone_target =
    let repo_name =
      if repo_name_arg <> "" then repo_name_arg
      else Keeper_repo_readiness.repo_name_of_repo_arg ~project_root:root repo
    in
    Filename.concat "repos" repo_name
  in
  (* Check 6: sandbox repo readiness *)
  let repo_readiness =
    Keeper_repo_readiness.inspect ~config ~meta
      ?repo_name:(if repo_name_arg = "" then None else Some repo_name_arg)
      ~repo ~default_branch:!default_branch ()
  in
  let repo_ready =
    match repo_readiness with
    | `Assoc fields -> (
        match List.assoc_opt "ok" fields with
        | Some (`Bool ok) -> ok
        | _ -> false)
    | _ -> false
  in
  let repo_state =
    json_string_field "state" repo_readiness |> Option.value ~default:"unknown"
  in
  let () = add_check "repo_readiness" repo_ready repo_state in
  Yojson.Safe.to_string
    (`Assoc
        [ "ok", `Bool !all_ok
        ; "checks", `String (Buffer.contents results)
        ; "gh_auth", `String (if !all_ok then "ok" else "check_failed")
        ; "default_branch", `String !default_branch
        ; "identity", `Assoc [ "name", `String author; "email", `String email ]
        ; "preset", `String preset_name
        ; "preset_sufficient", `Bool preset_ok
        ; "accountability_risk", `Bool accountability_risk
        ; "risk_band", `String risk_band
        ; "routing_hint", `String routing_hint
        ; "clone_target", `String clone_target
        ; "repo_readiness", repo_readiness
        ; "keeper", `String meta.name
        ])
