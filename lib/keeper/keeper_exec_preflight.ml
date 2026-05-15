open Keeper_types

(* RFC-0084 host-config-cleanup-B — zsh binary path migration. *)
let host_zsh = (Host_config.host ()).host_zsh

let json_string_field name json = Json_util.get_string json name

let json_string_opt = function
  | Some value -> `String value
  | None -> `Null

let json_string_list values =
  `List (List.map (fun value -> `String value) values)

type cascade_resilience =
  { ok : bool
  ; cascade_name : string
  ; model_labels : string list
  ; pure_local : bool
  ; fallback_cascade : string option
  ; blocker : string option
  ; error : string option
  ; hint : string option
  }

let cascade_resilience_of_name raw_name =
  let cascade_name =
    raw_name
    |> Keeper_cascade_profile.normalize_keeper_runtime_declared_name
    |> String.trim
  in
  let model_labels, error =
    match
      Cascade_runtime.models_of_cascade_name_result
        (Keeper_cascade_profile.runtime_name_of_string cascade_name)
    with
    | Ok models -> models, None
    | Error err -> [], Some err
  in
  let fallback_cascade =
    Keeper_cascade_profile.fallback_cascade_for cascade_name
  in
  let pure_local =
    match model_labels with
    | [] -> false
    | models -> Cascade_runtime.labels_are_pure_local models
  in
  let blocker =
    match error with
    | Some _ -> Some "cascade_resolution_error"
    | None when model_labels = [] -> Some "cascade_no_candidates"
    | None
      when pure_local
           && List.length model_labels <= 1
           && Option.is_none fallback_cascade ->
      Some "pure_local_single_provider_no_fallback"
    | None -> None
  in
  let hint =
    match blocker with
    | Some "cascade_resolution_error" ->
      Some "fix active cascade.toml resolution before autonomous PR fan-out"
    | Some "cascade_no_candidates" ->
      Some "configure at least one executable provider for the keeper cascade"
    | Some "pure_local_single_provider_no_fallback" ->
      Some
        "add a non-local fallback cascade or avoid autonomous PR fan-out while \
         local-only guard is active"
    | Some blocker -> Some ("cascade resilience blocked: " ^ blocker)
    | None -> None
  in
  { ok = Option.is_none blocker
  ; cascade_name
  ; model_labels
  ; pure_local
  ; fallback_cascade
  ; blocker
  ; error
  ; hint
  }

let cascade_resilience_of_meta (meta : keeper_meta) =
  cascade_resilience_of_name (cascade_name_of_meta meta)

let cascade_resilience_to_json resilience =
  `Assoc
    [ "ok", `Bool resilience.ok
    ; "cascade", `String resilience.cascade_name
    ; "model_labels", json_string_list resilience.model_labels
    ; "model_label_count", `Int (List.length resilience.model_labels)
    ; "pure_local", `Bool resilience.pure_local
    ; "fallback_cascade", json_string_opt resilience.fallback_cascade
    ; "blocker", json_string_opt resilience.blocker
    ; "error", json_string_opt resilience.error
    ; "hint", json_string_opt resilience.hint
    ]

let cascade_resilience_error_message resilience =
  match resilience.blocker with
  | None -> None
  | Some blocker ->
    let hint =
      match resilience.hint with
      | Some value -> "; hint=" ^ value
      | None -> ""
    in
    Some
      (Printf.sprintf
         "keeper cascade_resilience failed: cascade=%s blocker=%s%s"
         resilience.cascade_name
         blocker
         hint)

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
        [ host_zsh; "-lc"; "gh auth status 2>&1" ]
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
          [ host_zsh; "-lc";
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
  (* Check 5: cascade resilience for autonomous work *)
  let cascade_resilience = cascade_resilience_of_meta meta in
  let cascade_check_value =
    match cascade_resilience.blocker with
    | None -> "ok"
    | Some blocker -> blocker
  in
  let () =
    add_check "cascade_resilience" cascade_resilience.ok cascade_check_value
  in
  (* Check 6: accountability risk *)
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
  (* Check 7: autonomous activation *)
  let activation_blocker =
    if meta.paused then Some "paused"
    else if not meta.autoboot_enabled then Some "autoboot_disabled"
    else None
  in
  let activation_ok = Option.is_none activation_blocker in
  let activation_hint =
    match activation_blocker with
    | None -> None
    | Some "paused" ->
      Some "resume keeper before expecting autonomous keepalive or PR fan-out"
    | Some "autoboot_disabled" ->
      Some "set autoboot_enabled=true before expecting autonomous keepalive or PR fan-out"
    | Some reason -> Some ("activation blocked: " ^ reason)
  in
  let activation_check_value =
    match activation_blocker with
    | None -> "ok"
    | Some reason -> reason
  in
  let () =
    add_check "autonomous_activation" activation_ok activation_check_value
  in
  (* Check 8: sandbox clone target *)
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
        ; "cascade_resilience", cascade_resilience_to_json cascade_resilience
        ; "accountability_risk", `Bool accountability_risk
        ; "risk_band", `String risk_band
        ; "routing_hint", `String routing_hint
        ; "autonomous_activation"
        , `Assoc
            [ "ok", `Bool activation_ok
            ; "autoboot_enabled", `Bool meta.autoboot_enabled
            ; "paused", `Bool meta.paused
            ; "blocker", json_string_opt activation_blocker
            ; "hint", json_string_opt activation_hint
            ]
        ; "clone_target", `String clone_target
        ; "repo_readiness", repo_readiness
        ; "keeper", `String meta.name
        ])
