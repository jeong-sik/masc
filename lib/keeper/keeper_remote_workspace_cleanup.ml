open Result.Syntax

type report = {
  removed : int;
  skipped : int;
  failed : int;
  freed_kib : int;
  available_kib : int;
}

let payload_path = "scripts/keeper-remote-workspace-cleanup.py"

(* The sweep keeps this Keeper's cleanup reservation until it returns, and a
   later pass skips a reserved Keeper, so the budget stays in minutes. On
   2026-11-08 a report run over each of the
   three largest review roots (700 to 2,400 entries) took 1 to 2 s; each
   git repository it inspects can add a 20 s ls-remote. *)
let payload_timeout_sec = 5. *. Masc_time_constants.minute

type entry_result = Removed | Skipped | Failed

let entry_result_of_string = function
  | "removed" -> Some Removed
  | "skipped" -> Some Skipped
  | "failed" -> Some Failed
  | _ -> None

let invalid_report = Error "invalid Keeper workspace cleanup report"

let count_entries entries =
  let rec go ((removed, skipped, failed) as counts) = function
    | [] -> Ok counts
    | `Assoc fields :: rest ->
      (match List.assoc_opt "result" fields with
       | Some (`String result) ->
         (match entry_result_of_string result with
          | Some Removed -> go (removed + 1, skipped, failed) rest
          | Some Skipped -> go (removed, skipped + 1, failed) rest
          | Some Failed -> go (removed, skipped, failed + 1) rest
          | None -> invalid_report)
       | Some _ | None -> invalid_report)
    | _ :: _ -> invalid_report
  in
  go (0, 0, 0) entries

let report_of_string stdout =
  match Yojson.Safe.from_string stdout with
  | exception Yojson.Json_error _ -> invalid_report
  | `Assoc fields ->
    (match List.assoc_opt "skip" fields with
     | Some (`String reason) -> Error ("Keeper workspace cleanup skipped: " ^ reason)
     | Some _ -> invalid_report
     | None ->
       (match
          ( List.assoc_opt "entries" fields,
            List.assoc_opt "free_kib_before" fields,
            List.assoc_opt "free_kib_after" fields )
        with
        | Some (`List entries), Some (`Int before), Some (`Int after) ->
          let* removed, skipped, failed = count_entries entries in
          Ok { removed; skipped; failed; freed_kib = after - before; available_kib = after }
        | _ -> invalid_report))
  | _ -> invalid_report

let payload_argv ~root ~retention_sec =
  [ "python3"; "-"; "--root"; root; "--retention-sec"; Float.to_string retention_sec; "--apply" ]

let failure_detail stderr =
  Exec_policy.truncate_for_log (Observability_redact.redact_text (String.trim stderr))

(* Not [Keeper_sandbox_remote_lane.openssh_endpoint]: its [ready] runs the
   disk preflight, which refuses below 1 GiB free. A full disk is when this
   sweep has to run. *)
let run_payload ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta)
    ~retention_sec payload =
  let base_path = config.base_path in
  let* declaration = Keeper_sandbox_ssh.resolve_endpoint ~base_path ~keeper_name:meta.name in
  let* endpoint =
    Keeper_sandbox_ssh.create ~base_path ~keeper_name:meta.name ~endpoint:declaration ()
  in
  let run = Keeper_sandbox_remote.runner ~timeout_sec:payload_timeout_sec endpoint in
  let argv =
    payload_argv ~root:(Keeper_sandbox_remote.workspace_root endpoint) ~retention_sec
  in
  match
    run ~on_stdout_chunk:None ~on_stderr_chunk:None ~stdin_content:(Some payload)
      ~env:[||] ~cwd:None ~argv
  with
  | Masc_exec.Sandbox_target.Ran { status = Unix.WEXITED 0; stdout; _ } ->
    report_of_string stdout
  | Masc_exec.Sandbox_target.Ran
      { status = (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status; stderr; _ }
    ->
    Error
      (Printf.sprintf "Keeper workspace cleanup command failed (%s): %s"
         (Keeper_sandbox_exec_failure.status_label status)
         (failure_detail stderr))
  | Masc_exec.Sandbox_target.Transport_failed { reason; _ } ->
    Error ("Keeper workspace cleanup transport failed: " ^ reason)

let cleanup ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta)
    ~retention_sec () =
  match meta.sandbox_profile with
  | Keeper_types_profile_sandbox.(Docker | Micro_vm) as profile ->
    Error
      (Printf.sprintf "declared sandbox_profile is %s, not remote_ssh"
         (Keeper_types_profile_sandbox.sandbox_profile_to_string profile))
  | Keeper_types_profile_sandbox.Remote_ssh ->
    (match Embedded_config.read payload_path with
     | None -> Error "embedded Keeper workspace cleanup payload missing"
     | Some payload -> run_payload ~config ~meta ~retention_sec payload)
