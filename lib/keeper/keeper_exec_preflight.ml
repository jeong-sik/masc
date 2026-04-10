open Keeper_types

let handle_keeper_preflight_check
      ~(config : Room.config)
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
      Process_eio.run_argv_with_status ~timeout_sec:10.0
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
        Process_eio.run_argv_with_status ~timeout_sec:10.0
          [ "/bin/zsh"; "-lc";
            Printf.sprintf "gh repo view %s --json name,defaultBranchRef 2>&1"
              (Filename.quote repo) ]
      in
      let ok = st = Unix.WEXITED 0 in
      (* Extract default branch from JSON if available *)
      (if ok then
         try
           let json = Yojson.Safe.from_string out in
           let branch_ref =
             Yojson.Safe.Util.(
               json |> member "defaultBranchRef" |> member "name" |> to_string)
           in
           default_branch := branch_ref
         with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ());
      add_check "repo_access" ok out
  in
  (* Check 3: keeper identity *)
  let author = Keeper_identity.keeper_git_author ~keeper_name:meta.name in
  let email = Keeper_identity.keeper_git_email ~keeper_name:meta.name in
  let () = add_check "identity" true author in
  (* Check 4: preset level *)
  let preset_ok =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some (Coding | Delivery | Full) -> true
    | _ -> false
  in
  let preset_name =
    match Keeper_types.tool_access_preset meta.tool_access with
    | Some p -> Keeper_tool_policy.preset_name_of_tool_preset p
    | None -> "custom"
  in
  let () = add_check "preset" preset_ok preset_name in
  (* Check 5: playground clone target *)
  let clone_target =
    let repos_path = Keeper_alerting_path.playground_repos_path meta.name in
    if repo <> "" then
      Filename.concat repos_path (Filename.basename repo)
    else
      Filename.concat repos_path (Filename.basename root)
  in
  Yojson.Safe.to_string
    (`Assoc
        [ "ok", `Bool !all_ok
        ; "checks", `String (Buffer.contents results)
        ; "gh_auth", `String (if !all_ok then "ok" else "check_failed")
        ; "default_branch", `String !default_branch
        ; "identity", `Assoc [ "name", `String author; "email", `String email ]
        ; "preset", `String preset_name
        ; "preset_sufficient", `Bool preset_ok
        ; "clone_target", `String clone_target
        ; "keeper", `String meta.name
        ])
