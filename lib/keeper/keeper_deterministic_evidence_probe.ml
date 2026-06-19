(* RFC-0199 Phase B — see .mli. Adapts the keeper sandbox file system into a
   Deterministic_evidence_evaluator.probe and reuses the (tested) pure
   evaluator. File probes and Shell-IR command probes are backed by real I/O;
   the forge/custom probe functions return None (Indeterminate) so their claim
   kinds never auto-complete until wired. *)

type dispatch_target =
  { sandbox : Masc_exec.Sandbox_target.t
  ; base_host_env : string array option
  }

let local_dispatch_target ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) =
  match
    Keeper_secret_projection.local_env_for_keeper
      ~base_path:config.base_path
      ~keeper_name:meta.name
      ()
  with
  | Error _ -> None
  | Ok base_host_env ->
    Some { sandbox = Masc_exec.Sandbox_target.host (); base_host_env }

let command_dispatch_target
    ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
    ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta)
    ~(cwd : string) =
  match Keeper_sandbox_runner.effective_sandbox_profile ~meta with
  | Keeper_types_profile_sandbox.Local, _ -> local_dispatch_target ~config ~meta
  | Keeper_types_profile_sandbox.Docker, _ -> (
    match
      Keeper_sandbox_shell_ir_target.docker_target
        ~turn_sandbox_factory
        ~meta
        ~cwd
    with
    | Error _ -> None
    | Ok sandbox -> Some { sandbox; base_host_env = None })

let make_probe
    ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
    ~(config : Workspace.config)
    ~(meta : Keeper_meta_contract.keeper_meta) :
    Deterministic_evidence_evaluator.probe =
  let file_bytes raw_path =
    match
      Keeper_tool_shared_runtime.resolve_keeper_read_path ~config ~meta ~raw_path
    with
    | Error _ -> None
    | Ok abs_path -> Fs_compat.file_size abs_path
  in
  let command_exit cmd =
    let args = `Assoc [] in
    match
      Keeper_tool_execute_path.resolve_tool_execute_cwd
        ~config
        ~meta
        ~write_enabled:true
        ~args
    with
    | Error _ -> None
    | Ok cwd -> (
      match Exec_policy.parse_string_to_ir ~mode:Tool_execute cmd with
      | Error _ -> None
      | Ok ir -> (
        match
          command_dispatch_target
            ~turn_sandbox_factory
            ~config
            ~meta
            ~cwd
        with
        | None -> None
        | Some { sandbox; base_host_env } -> (
          match
            Keeper_tool_execute_shell_ir.dispatch
              ~keeper_id:meta.name
              ~base_path:config.base_path
              ~workdir:cwd
              ~sandbox
              ?base_host_env
              ir
          with
          | Error _ -> None
          | Ok res -> (
            match res.Masc_exec.Exec_dispatch.status with
            | Unix.WEXITED code -> Some code
            | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> None))))
  in
  { Deterministic_evidence_evaluator.file_bytes
  ; command_exit
  ; pr_merged = (fun ~repo:_ ~pr:_ -> None)
  ; ci_passed = (fun ~repo:_ ~pr:_ -> None)
  ; custom_check = (fun ~id:_ ~payload:_ -> None)
  }


let all_satisfied ?turn_sandbox_factory ~config ~meta claims =
  match
    Deterministic_evidence_evaluator.eval_all
      (make_probe ~turn_sandbox_factory ~config ~meta)
      claims
  with
  | Deterministic_evidence_evaluator.Satisfied -> true
  | Deterministic_evidence_evaluator.Unsatisfied _
  | Deterministic_evidence_evaluator.Indeterminate _ -> false
