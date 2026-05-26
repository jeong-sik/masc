open Keeper_types

let json_string_field name json = Json_util.get_string json name

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
        (Cascade_name.of_string_exn cascade_name)
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
    ; "model_labels", Json_util.json_string_list resilience.model_labels
    ; "model_label_count", `Int (List.length resilience.model_labels)
    ; "pure_local", `Bool resilience.pure_local
    ; "fallback_cascade", Json_util.string_opt_to_json resilience.fallback_cascade
    ; "blocker", Json_util.string_opt_to_json resilience.blocker
    ; "error", Json_util.string_opt_to_json resilience.error
    ; "hint", Json_util.string_opt_to_json resilience.hint
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
  (* Check 1: configured credential binding.

     This intentionally does not run [gh auth status] or [gh repo view].
     Runtime identity comes from keeper_repo_mappings.toml +
     credentials.toml; the first real GitHub operation will surface any
     stale token failure under that scoped environment. *)
  let credential_binding =
    Keeper_gh_env.keeper_binding config ~keeper_name:meta.name
  in
  let credential_binding_json =
    match credential_binding with
    | Ok binding ->
        `Assoc
          [ "ok", `Bool true
          ; "effective_github_identity", `String binding.effective_github_identity
          ; ( "configured_github_identity"
            , match binding.github_identity with
              | Some id -> `String id
              | None -> `Null )
          ; ( "credential_scope"
            , `String
                (Keeper_gh_env.credential_scope_to_string
                   binding.credential_scope) )
          ; "git_identity_mode", `String binding.git_identity_mode
          ]
    | Error reason -> `Assoc [ "ok", `Bool false; "reason", `String reason ]
  in
  let () =
    add_check "credential_binding" (Result.is_ok credential_binding) ""
  in
  (* Check 2: repo argument shape. Network access is deferred to the actual
     scoped operation; preflight should not probe GitHub CLI state. *)
  let default_branch = "main" in
  let repo_arg_ok =
    repo = ""
    ||
    match Keeper_gh_repo.validate_repo_slug repo with
    | Ok _ -> true
    | Error _ -> false
  in
  let () =
    add_check "repo_arg" repo_arg_ok
      (if repo = "" then "(current project)" else repo)
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
  let activation_readiness = Keeper_activation_readiness.of_meta meta in
  let autonomous_activation =
    activation_readiness.Keeper_activation_readiness.autonomous_activation
  in
  let () =
    add_check
      "autonomous_activation"
      autonomous_activation.ok
      (Keeper_activation_readiness.autonomous_check_value autonomous_activation)
  in
  let work_discovery_activation =
    activation_readiness.Keeper_activation_readiness.work_discovery_activation
  in
  let () =
    add_check
      "work_discovery_activation"
      work_discovery_activation.ok
      (Keeper_activation_readiness.work_discovery_check_value
         work_discovery_activation)
  in
  let activation_readiness_json =
    Keeper_activation_readiness.to_yojson activation_readiness
  in
  (* Check 9: sandbox clone target *)
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
      ~repo ~default_branch ()
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
        ; "credential_binding_ok", `Bool (Result.is_ok credential_binding)
        ; "credential_binding", credential_binding_json
        ; "repo_arg_ok", `Bool repo_arg_ok
        ; "default_branch", `String default_branch
        ; "identity", `Assoc [ "name", `String author; "email", `String email ]
        ; "preset", `String preset_name
        ; "preset_sufficient", `Bool preset_ok
        ; "cascade_resilience", cascade_resilience_to_json cascade_resilience
        ; "accountability_risk", `Bool accountability_risk
        ; "risk_band", `String risk_band
        ; "routing_hint", `String routing_hint
        ; ( "autonomous_activation"
          , Yojson.Safe.Util.member
              "autonomous_activation"
              activation_readiness_json )
        ; ( "work_discovery_activation"
          , Yojson.Safe.Util.member
              "work_discovery_activation"
              activation_readiness_json )
        ; "clone_target", `String clone_target
        ; "repo_readiness", repo_readiness
        ; "keeper", `String meta.name
        ])
