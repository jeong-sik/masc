(* A4a exec_gate — typed verdict dispatch plus first production
   wrappers around Process_eio.  Callers stay on explicit argv; this
   module performs the typed check before the actual spawn. *)

type error =
  [ `Ask_required of Verdict.request
  | `Denied of Verdict.deny_reason
  ]

type mode =
  | Off
  | Parallel
  | Enforced

let internal_git_admin_overlay : Approval_config.agent_overlay =
  {
    safe_trust = Auto_safe;
    audited_trust = Auto_safe;
    privileged_trust = Auto_safe;
  }

let notify_overlay : Approval_config.agent_overlay =
  {
    safe_trust = Auto_safe;
    audited_trust = Auto_safe;
    privileged_trust = Enforced;
  }

let internal_observer_overlay : Approval_config.agent_overlay =
  {
    safe_trust = Auto_safe;
    audited_trust = Auto_safe;
    privileged_trust = Enforced;
  }

let rollout_config : Approval_config.t =
  {
    defaults = Approval_config.strict_default;
    per_agent =
      [
        ("coord/git", internal_git_admin_overlay);
        ("coord/worktree", internal_git_admin_overlay);
        ("system/task_sandbox", internal_git_admin_overlay);
        ("system/notify", notify_overlay);
        ("autoresearch/git", internal_git_admin_overlay);
        ("voice/bridge", internal_observer_overlay);
        ("voice/bridge_core", internal_observer_overlay);
        ("system/graphql_client_eio", internal_observer_overlay);
        ("system/build_identity", internal_observer_overlay);
        ("system/runtime_info", internal_observer_overlay);
        ("system/worktree_live_context", internal_observer_overlay);
        ("system/startup_takeover", internal_observer_overlay);
        ("system/worker_container_types", internal_observer_overlay);
        ("system/worker_runtime_docker", internal_observer_overlay);
        ("system/spawn", internal_observer_overlay);
        ("system/auto_responder", internal_observer_overlay);
        ("swarm/goal_loop", internal_observer_overlay);
        ("coord/identity", internal_observer_overlay);
        ("tool/local_runtime", internal_observer_overlay);
        ("tool/local_runtime_bench", internal_observer_overlay);
        ("tool/a2a_discovery", internal_observer_overlay);
        ("tool/autoresearch_cycle", internal_git_admin_overlay);
      ];
  }

let mode_of_env () =
  match Sys.getenv_opt "MASC_EXEC_GATE" with
  | Some ("parallel" | "shadow") -> Parallel
  | Some ("enforced" | "true" | "1") -> Enforced
  | _ -> Off

let lit s = Shell_ir.Lit s

let env_bindings_of_array env =
  Array.to_list env
  |> List.map (fun binding ->
         match String.index_opt binding '=' with
         | Some idx ->
           let key = String.sub binding 0 idx in
           let value =
             String.sub binding (idx + 1) (String.length binding - idx - 1)
           in
           (key, lit value)
         | None -> (binding, lit ""))

let simple_of_argv ?env ?cwd (argv : string list) =
  match argv with
  | [] -> Error `Empty_argv
  | bin_raw :: args_raw -> (
    match Bin.of_string bin_raw with
    | Error (`Unknown _) -> Error `Parse_failed
    | Ok bin ->
      let args = List.map lit args_raw in
      let env =
        match env with
        | Some bindings -> env_bindings_of_array bindings
        | None -> []
      in
      let cwd =
        Option.map
          (fun dir -> Path_scope.classify ~raw:dir ~cwd:dir)
          cwd
      in
      Ok
        { Shell_ir.bin
        ; args
        ; env
        ; cwd
        ; redirects = []
        ; sandbox = Sandbox_target.host ()
        })

let verdict_to_string = function
  | Verdict.Allow _ -> "allow"
  | Verdict.Suggest_confirm _ -> "suggest_confirm"
  | Verdict.Ask _ -> "ask"
  | Verdict.Deny _ -> "deny"

let error_to_string = function
  | `Ask_required _ -> "ask_required"
  | `Denied _ -> "denied"

let blocked_output ~summary ~raw_source ~reason =
  Printf.sprintf "exec_gate_blocked: %s (%s) [%s]" reason raw_source summary

let record_decision ~actor ~raw_source ~summary ~mode ~verdict ~argv ?env ?cwd () =
  match mode with
  | Off -> ()
  | Parallel | Enforced ->
    Exec_tap.record_gate_decision
      ~actor
      ~raw_source
      ~summary
      ~gate_mode:
        (match mode with
         | Parallel -> "parallel"
         | Enforced -> "enforced"
         | Off -> "off")
      ~gate_verdict:(verdict_to_string verdict)
      ~gate_enforced:(mode = Enforced)
      ~argv
      ?env
      ?cwd
      ()

let verdict_for_argv ~actor ~raw_source ~summary ~argv ?env ?cwd () =
  match simple_of_argv ?env ?cwd argv with
  | Error `Empty_argv ->
    Error (`Denied Verdict.Parse_failed)
  | Error `Parse_failed ->
    Error (`Denied Verdict.Parse_failed)
  | Ok simple ->
    let caps = Capability_check.of_simple simple in
    let overlay = Approval_config.lookup rollout_config ~actor in
    let policy : Approval_policy.t = { raw_source; summary } in
    let verdict = Approval_policy.decide policy ~overlay ~caps ~simple in
    Ok verdict

let with_verdict ~actor ~raw_source ~summary ~argv ?env ?cwd
    ~(on_allow : unit -> 'a)
    ~(on_blocked : string -> 'a) () =
  match verdict_for_argv ~actor ~raw_source ~summary ~argv ?env ?cwd () with
  | Error gate_error ->
    let mode = mode_of_env () in
    let verdict =
      match gate_error with
      | `Ask_required request -> Verdict.Ask request
      | `Denied reason -> Verdict.Deny { caps = []; reason }
    in
    record_decision ~actor ~raw_source ~summary ~mode ~verdict ~argv ?env
      ?cwd ();
    (match mode with
     | Off | Parallel -> on_allow ()
     | Enforced -> on_blocked (error_to_string gate_error))
  | Ok verdict ->
    let mode = mode_of_env () in
    record_decision ~actor ~raw_source ~summary ~mode ~verdict ~argv ?env
      ?cwd ();
    match verdict with
    | Verdict.Allow _trusted -> on_allow ()
    | Verdict.Suggest_confirm (_trusted, _token) -> on_allow ()
    | Verdict.Ask request ->
      let gate_error = (`Ask_required request : error) in
      (match mode with
       | Off | Parallel -> on_allow ()
       | Enforced -> on_blocked (error_to_string gate_error))
    | Verdict.Deny { reason; _ } ->
      let gate_error = (`Denied reason : error) in
      (match mode with
       | Off | Parallel -> on_allow ()
       | Enforced -> on_blocked (error_to_string gate_error))

let run : Verdict.t -> (Verdict.Trusted_argv.t, error) result = function
  | Verdict.Allow trusted -> Ok trusted
  | Verdict.Suggest_confirm (trusted, _) -> Ok trusted
  | Verdict.Ask request -> Error (`Ask_required request)
  | Verdict.Deny { reason; _ } -> Error (`Denied reason)

let run_argv ~actor ~raw_source ~summary ?(timeout_sec = 60.0) ?env argv =
  with_verdict ~actor ~raw_source ~summary ~argv ?env
    ~on_allow:(fun () -> Process_eio.run_argv ~timeout_sec ?env argv)
    ~on_blocked:(fun reason ->
      blocked_output ~summary ~raw_source ~reason)
    ()

let run_argv_with_status ~actor ~raw_source ~summary ?(timeout_sec = 60.0)
    ?env ?cwd argv =
  with_verdict ~actor ~raw_source ~summary ~argv ?env ?cwd
    ~on_allow:(fun () ->
      Process_eio.run_argv_with_status ~timeout_sec ?env ?cwd argv)
    ~on_blocked:(fun reason ->
      ( Unix.WEXITED 126,
        blocked_output ~summary ~raw_source ~reason ))
    ()

let run_argv_with_status_split ~actor ~raw_source ~summary
    ?(timeout_sec = 60.0) ?env ?cwd argv =
  with_verdict ~actor ~raw_source ~summary ~argv ?env ?cwd
    ~on_allow:(fun () ->
      Process_eio.run_argv_with_status_split ~timeout_sec ?env ?cwd argv)
    ~on_blocked:(fun reason ->
      ( Unix.WEXITED 126,
        "",
        blocked_output ~summary ~raw_source ~reason ))
    ()

let run_argv_with_stdin_and_status ~actor ~raw_source ~summary
    ?(timeout_sec = 60.0) ?env ?cwd ~stdin_content argv =
  with_verdict ~actor ~raw_source ~summary ~argv ?env ?cwd
    ~on_allow:(fun () ->
      Process_eio.run_argv_with_stdin_and_status ~timeout_sec ?env ?cwd
        ~stdin_content argv)
    ~on_blocked:(fun reason ->
      ( Unix.WEXITED 126,
        blocked_output ~summary ~raw_source ~reason ))
    ()

let run_argv_with_stdin_and_status_split ~actor ~raw_source ~summary
    ?(timeout_sec = 60.0) ?env ?cwd ~stdin_content argv =
  with_verdict ~actor ~raw_source ~summary ~argv ?env ?cwd
    ~on_allow:(fun () ->
      Process_eio.run_argv_with_stdin_and_status_split ~timeout_sec ?env ?cwd
        ~stdin_content argv)
    ~on_blocked:(fun reason ->
      ( Unix.WEXITED 126,
        "",
        blocked_output ~summary ~raw_source ~reason ))
    ()
