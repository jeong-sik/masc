(* RFC-0199 Phase B — see .mli. Adapts the keeper sandbox file system into a
   Deterministic_evidence_evaluator.probe and reuses the (tested) pure
   evaluator. Only file_bytes is backed by real I/O in v1; the other probe
   functions return None (Indeterminate) so their claim kinds never
   auto-complete until wired. *)

let make_probe ~(config : Workspace.config)
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
        let sandbox = Masc_exec.Sandbox_target.host () in
        match
          Keeper_tool_execute_shell_ir.dispatch
            ~keeper_id:meta.name
            ~base_path:config.base_path
            ~workdir:cwd
            ~sandbox
            ir
        with
        | Error _ -> None
        | Ok res -> (
          match res.Masc_exec.Exec_dispatch.status with
          | Unix.WEXITED code -> Some code
          | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> None)))
  in
  { Deterministic_evidence_evaluator.file_bytes
  ; command_exit
  ; pr_merged = (fun ~repo:_ ~pr:_ -> None)
  ; ci_passed = (fun ~repo:_ ~pr:_ -> None)
  ; custom_check = (fun ~id:_ ~payload:_ -> None)
  }


let all_satisfied ~config ~meta claims =
  match
    Deterministic_evidence_evaluator.eval_all (make_probe ~config ~meta) claims
  with
  | Deterministic_evidence_evaluator.Satisfied -> true
  | Deterministic_evidence_evaluator.Unsatisfied _
  | Deterministic_evidence_evaluator.Indeterminate _ -> false
