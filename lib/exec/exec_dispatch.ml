(* P7: Pipeline-Native Dispatch
   Execute Shell_ir.t directly via Exec_gate without going through
   /bin/bash.  Simple commands use argv-based spawn; pipelines chain
   stdout->stdin across stages.  Pipeline support is limited to
   stdout->stdin chaining. *)

type dispatch_result = {
  status : Unix.process_status;
  stdout : string;
  stderr : string;
}

(* --- arg resolution --- *)

let rec resolve_arg = function
  | Shell_ir.Lit s -> s
  | Concat parts ->
      let buf = Buffer.create 64 in
      List.iter (fun a -> Buffer.add_string buf (resolve_arg a)) parts;
      Buffer.contents buf
  | Var name ->
      (match Sys.getenv_opt name with Some v -> v | None -> "")

let resolve_env env_bindings =
  List.map
    (fun (k, v) -> k ^ "=" ^ resolve_arg v)
    env_bindings
  |> Array.of_list

(* --- simple command execution --- *)

(* Dispatch a simple command via the IR-carried Sandbox_target.

   Prior to PR-2 (2026-04-28 root-fix family 3/3) this function called
   [Process_eio.run_argv_with_status_split] directly, which short-
   circuited every command to a host fork/exec regardless of the
   keeper's [sandbox_profile].  The host case now routes through
   [Exec_gate] (no behavior change for non-keeper callers); the Docker
   case is wired up by [lib/keeper] using a closure over
   [Keeper_turn_sandbox_runtime]. *)
let dispatch_timeout_sec = function
  | Some timeout_sec -> timeout_sec
  | None -> Env_config_exec_timeout.timeout_sec ~caller:Dispatch ()

let process_spec_of_simple (s : Shell_ir.simple) =
  let bin = Bin.to_string s.bin in
  let argv = bin :: List.map resolve_arg s.args in
  let env = resolve_env s.env in
  let cwd =
    match s.cwd with
    | None -> None
    | Some scope -> Some (Path_scope.raw scope)
  in
  (argv, env, cwd)

let dispatch_simple ?timeout_sec ?stdin_content (s : Shell_ir.simple) =
  let argv, env, cwd = process_spec_of_simple s in
  let timeout_sec = dispatch_timeout_sec timeout_sec in
  match s.sandbox with
  | Host ->
      let raw_source = String.concat " " argv in
      let run () =
        match stdin_content with
        | None ->
          Exec_gate.run_argv_with_status_split
            ~actor:`Tool_local_runtime
            ~raw_source
            ~summary:"exec dispatch simple"
            ~timeout_sec
            ~env
            ?cwd
            argv
        | Some stdin_content ->
          Exec_gate.run_argv_with_stdin_and_status_split
            ~actor:`Tool_local_runtime
            ~raw_source
            ~summary:"exec dispatch simple stdin"
            ~timeout_sec
            ~env
            ?cwd
            ~stdin_content
            argv
      in
      (match run () with
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception exn ->
         { status = Unix.WEXITED 1; stdout = ""; stderr = Printexc.to_string exn }
       | status, stdout, stderr -> { status; stdout; stderr })
  | Docker { runner; _ } ->
    (match runner ~stdin_content ~argv ~env ~cwd ~timeout_sec with
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
	     | exception exn ->
	       { status = Unix.WEXITED 1; stdout = ""; stderr = Printexc.to_string exn }
	     | status, stdout, stderr -> { status; stdout; stderr })

(* --- pipeline + entry point (mutually recursive) --- *)

let invalid_pipeline stderr = { status = Unix.WEXITED 1; stdout = ""; stderr }

let host_pipeline_specs stages =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | Shell_ir.Simple simple :: rest ->
        (match simple.sandbox with
         | Host ->
             let argv, env, cwd = process_spec_of_simple simple in
             let stage : Process_eio.pipeline_stage =
               { argv; env = Some env; cwd }
             in
             loop (stage :: acc) rest
         | _ -> None)
        [@warning "-4"]
    | Shell_ir.Pipeline _ :: _ -> None
  in
  loop [] stages

let rec dispatch_pipeline ?timeout_sec stages =
  match stages with
  | [] ->
      invalid_pipeline "empty pipeline not supported in native dispatch"
  | [ _ ] ->
      invalid_pipeline "single-stage pipeline not supported in native dispatch"
  | _ ->
      (match host_pipeline_specs stages with
       | Some specs ->
           let raw_source =
             specs
             |> List.map (fun stage -> String.concat " " stage.Process_eio.argv)
             |> String.concat " | "
           in
           let status, stdout, stderr =
             Exec_gate.run_argv_pipeline_with_status_split
               ~actor:`Tool_local_runtime
               ~raw_source
               ~summary:"exec dispatch pipeline"
               ~timeout_sec:(dispatch_timeout_sec timeout_sec)
               specs
           in
           { status; stdout; stderr }
       | None ->
      let rec chain prev_stdout = function
        | [] ->
            { status = Unix.WEXITED 0; stdout = prev_stdout; stderr = "" }
        | [ Shell_ir.Simple s ] ->
            dispatch_simple ?timeout_sec ~stdin_content:prev_stdout s
        | Shell_ir.Simple s :: rest ->
            let stage_result =
              dispatch_simple ?timeout_sec ~stdin_content:prev_stdout s
            in
            let result = chain stage_result.stdout rest in
            let final_status =
              match stage_result.status with
              | Unix.WEXITED 0 -> result.status
              | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
                  stage_result.status
            in
            { result with status = final_status }
        | Pipeline _ :: _ ->
            invalid_pipeline "nested pipeline not supported in native dispatch"
      in
      (match stages with
       | [] | [ _ ] ->
           invalid_pipeline "invalid pipeline arity in native dispatch"
       | first :: rest -> (
         match first with
         | Shell_ir.Simple s ->
           let result = dispatch_simple ?timeout_sec s in
           chain result.stdout rest
         | Pipeline _ ->
           invalid_pipeline "nested pipeline not supported in native dispatch" ))
      )

and dispatch ?timeout_sec (ir : Shell_ir.t) =
  match ir with
  | Shell_ir.Simple s -> dispatch_simple ?timeout_sec s
  | Pipeline stages -> dispatch_pipeline ?timeout_sec stages
