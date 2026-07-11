(* P7: Pipeline-Native Dispatch
   Execute Shell_ir.t directly via Exec_gate without going through
   /bin/bash. Simple commands use argv-based spawn. Redirect-free host
   and Docker pipelines use streaming process pipes; unsupported shapes
   fall back to deterministic stdout->stdin chaining. *)

type dispatch_result = {
  status : Unix.process_status;
  stdout : string;
  stderr : string;
}

let ( let* ) = Result.bind

type redirect_target =
  | Capture_stdout
  | Capture_stderr
  | Drop

type redirect_plan = {
  stdout_target : redirect_target;
  stderr_target : redirect_target;
}

let default_redirect_plan =
  { stdout_target = Capture_stdout; stderr_target = Capture_stderr }

let redirect_target_of_fd plan = function
  | 1 -> Ok plan.stdout_target
  | 2 -> Ok plan.stderr_target
  | fd -> Error (Printf.sprintf "unsupported redirect fd: %d" fd)

let set_redirect_target plan fd target =
  match fd with
  | 1 -> Ok { plan with stdout_target = target }
  | 2 -> Ok { plan with stderr_target = target }
  | fd -> Error (Printf.sprintf "unsupported redirect fd: %d" fd)

let redirect_plan_of_redirects redirects =
  let step plan = function
    | Redirect_scope.Fd_to_fd { src; dst } ->
        let* target = redirect_target_of_fd plan dst in
        set_redirect_target plan src target
    | Redirect_scope.File
        { fd; target; mode = (Redirect_scope.Write | Redirect_scope.Append) }
      when Path_scope.is_discard_sink target ->
        set_redirect_target plan fd Drop
    | Redirect_scope.File { fd; target; mode = Redirect_scope.Read } ->
        Error
          (Printf.sprintf
             "unsupported redirect in native dispatch: fd %d read from %s"
             fd
             (Path_scope.raw target))
    | Redirect_scope.File
        { fd; target; mode = (Redirect_scope.Write | Redirect_scope.Append) } ->
        Error
          (Printf.sprintf
             "unsupported redirect in native dispatch: fd %d write to %s"
             fd
             (Path_scope.raw target))
  in
  List.fold_left
    (fun acc redirect -> Result.bind acc (fun plan -> step plan redirect))
    (Ok default_redirect_plan)
    redirects

let add_redirected_output target text (stdout, stderr) =
  match target with
  | Capture_stdout -> stdout ^ text, stderr
  | Capture_stderr -> stdout, stderr ^ text
  | Drop -> stdout, stderr

let apply_redirect_plan plan result =
  (* Captured stdout/stderr are already split by the lower process layer, so
     fd-to-fd redirection is deterministic but cannot preserve temporal
     interleaving between the two original streams. *)
  let stdout, stderr =
    ("", "")
    |> add_redirected_output plan.stdout_target result.stdout
    |> add_redirected_output plan.stderr_target result.stderr
  in
  { result with stdout; stderr }

let unsupported_redirect_result message =
  { status = Unix.WEXITED 1; stdout = ""; stderr = message }

type output_emission =
  { stdout_emitted : bool ref
  ; stderr_emitted : bool ref
  }

let tracked_output_callback on_output_chunk =
  let emitted = { stdout_emitted = ref false; stderr_emitted = ref false } in
  match on_output_chunk with
  | None -> None, emitted
  | Some on_chunk ->
      let on_chunk = function
        | `Stdout chunk ->
            emitted.stdout_emitted := true;
            on_chunk (`Stdout chunk)
        | `Stderr chunk ->
            emitted.stderr_emitted := true;
            on_chunk (`Stderr chunk)
      in
      Some on_chunk, emitted

let emit_unseen_captured_output on_output_chunk emitted result =
  match on_output_chunk with
  | None -> result
  | Some on_chunk ->
      if (not !(emitted.stdout_emitted)) && result.stdout <> ""
      then on_chunk (`Stdout result.stdout);
      if (not !(emitted.stderr_emitted)) && result.stderr <> ""
      then on_chunk (`Stderr result.stderr);
      result

let emit_stdout_if_captured on_output_chunk stdout =
  match on_output_chunk with
  | None -> ()
  | Some on_chunk when stdout <> "" -> on_chunk (`Stdout stdout)
  | Some _ -> ()

let emit_pipeline_stage_result ?(emit_stdout = false) on_output_chunk result =
  match on_output_chunk with
  | None -> ()
  | Some on_chunk ->
      if emit_stdout && result.stdout <> "" then on_chunk (`Stdout result.stdout);
      if result.stderr <> "" then on_chunk (`Stderr result.stderr)

let status_is_success = function
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let status_is_timeout = function
  | Unix.WEXITED 124 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let pipeline_status current stage_status =
  if status_is_success stage_status then current else stage_status

(* --- arg resolution --- *)

let rec resolve_arg = function
  | Shell_ir.Lit (s, _) -> s
  | Concat parts ->
      let buf = Buffer.create 64 in
      List.iter (fun a -> Buffer.add_string buf (resolve_arg a)) parts;
      Buffer.contents buf
  | Var (name, _) ->
      (match Sys.getenv_opt name with Some v -> v | None -> "")

let resolve_env env_bindings =
  List.map
    (fun (key, value) ->
      { Sandbox_target.key; value = resolve_arg value })
    env_bindings
  |> Array.of_list

let render_env_binding (binding : Sandbox_target.env_binding) =
  binding.key ^ "=" ^ binding.value

let env_key entry =
  match String.index_opt entry '=' with
  | None -> entry
  | Some idx -> String.sub entry 0 idx

let resolve_host_env ?base_host_env = function
  | [] -> base_host_env
  | env_bindings ->
      let overrides = resolve_env env_bindings |> Array.to_list in
      let override_keys =
        List.map (fun (binding : Sandbox_target.env_binding) -> binding.key) overrides
      in
      let base =
        match base_host_env with
        | Some env -> env
        | None -> Unix.environment ()
      in
      let inherited =
        base
        |> Array.to_list
        |> List.filter (fun entry ->
          not (List.mem (env_key entry) override_keys))
      in
      Some (Array.of_list (inherited @ List.map render_env_binding overrides))

(* --- simple command execution --- *)

(* Dispatch a simple command via the IR-carried Sandbox_target.

   Prior to PR-2 (2026-04-28 root-fix family 3/3) this function called
   [Process_eio.run_argv_with_status_split] directly, which short-
   circuited every command to a host fork/exec regardless of the
   keeper's [sandbox_profile].  The host case now routes through
   [Exec_gate] (no behavior change for non-keeper callers); the Docker
   case is wired up by [lib/keeper] using a closure over
   [Keeper_turn_sandbox_runtime]. *)
let process_spec_of_simple (s : Shell_ir.simple) =
  let bin = Exec_program.to_string s.bin in
  let argv = bin :: List.map resolve_arg s.args in
  let env = resolve_env s.env in
  let cwd =
    match s.cwd with
    | None -> None
    | Some scope -> Some (Path_scope.raw scope)
  in
  (argv, env, cwd)

let dispatch_simple ?base_host_env ?stdin_content ?on_output_chunk (s : Shell_ir.simple) =
  let on_output_chunk, emitted = tracked_output_callback on_output_chunk in
  let argv, env, cwd = process_spec_of_simple s in
  let result =
    match redirect_plan_of_redirects s.redirects with
    | Error message -> unsupported_redirect_result message
    | Ok redirect_plan -> (
      let child_on_output_chunk =
        if s.redirects = [] then on_output_chunk else None
      in
      match s.sandbox with
      | Host ->
        let raw_source = String.concat " " argv in
        let host_env = resolve_host_env ?base_host_env s.env in
        let run () =
          match stdin_content with
          | None ->
            (match child_on_output_chunk with
             | None ->
               Exec_gate.run_argv_with_status_split
                 ~actor:`Tool_local_runtime
                 ~raw_source
                 ~summary:"exec dispatch simple"
                 ?env:host_env
                 ?cwd
                 argv
             | Some on_chunk ->
               Exec_gate.run_argv_with_status_split_streaming
                 ~actor:`Tool_local_runtime
                 ~raw_source
                 ~summary:"exec dispatch simple streaming"
                 ?env:host_env
                 ?cwd
                 ~on_stdout_chunk:(fun chunk -> on_chunk (`Stdout chunk))
                 ~on_stderr_chunk:(fun chunk -> on_chunk (`Stderr chunk))
                 argv)
          | Some stdin_content ->
            (match child_on_output_chunk with
             | None ->
               Exec_gate.run_argv_with_stdin_and_status_split
                 ~actor:`Tool_local_runtime
                 ~raw_source
                 ~summary:"exec dispatch simple stdin"
                 ?env:host_env
                 ?cwd
                 ~stdin_content
                 argv
             | Some on_chunk ->
               Exec_gate.run_argv_with_stdin_and_status_split
                 ~actor:`Tool_local_runtime
                 ~raw_source
                 ~summary:"exec dispatch simple stdin streaming"
                 ?env:host_env
                 ?cwd
                 ~on_stdout_chunk:(fun chunk -> on_chunk (`Stdout chunk))
                 ~on_stderr_chunk:(fun chunk -> on_chunk (`Stderr chunk))
                 ~stdin_content
                 argv)
        in
        (match run () with
         | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
         | exception exn ->
             { status = Unix.WEXITED 1
             ; stdout = ""
             ; stderr = Printexc.to_string exn
             }
         | status, stdout, stderr ->
             apply_redirect_plan redirect_plan { status; stdout; stderr })
      | Docker { runner; _ } ->
        let on_stdout_chunk, on_stderr_chunk =
          match child_on_output_chunk with
          | None -> None, None
          | Some on_chunk ->
              ( Some (fun chunk -> on_chunk (`Stdout chunk))
              , Some (fun chunk -> on_chunk (`Stderr chunk)) )
        in
        (match
           runner ~on_stdout_chunk ~on_stderr_chunk ~stdin_content ~argv ~env ~cwd
         with
         | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
         | exception exn ->
             { status = Unix.WEXITED 1
             ; stdout = ""
             ; stderr = Printexc.to_string exn
             }
         | status, stdout, stderr ->
             apply_redirect_plan redirect_plan { status; stdout; stderr }))
  in
  emit_unseen_captured_output on_output_chunk emitted result

(* --- pipeline + entry point (mutually recursive) --- *)

let invalid_pipeline stderr = { status = Unix.WEXITED 1; stdout = ""; stderr }

let host_pipeline_specs ?base_host_env stages =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | Shell_ir.Simple simple :: rest ->
        (match simple.sandbox with
         | Host when simple.redirects = [] ->
             let argv, _env, cwd = process_spec_of_simple simple in
             let stage : Process_eio.pipeline_stage =
               { argv; env = resolve_host_env ?base_host_env simple.env; cwd }
             in
             loop (stage :: acc) rest
         | _unsupported -> None)
        [@warning "-4"]
    | Shell_ir.Pipeline _ :: _ -> None
  in
  loop [] stages

let docker_pipeline_specs stages =
  let rec loop pipeline_runner sandbox_target acc = function
    | [] -> Option.map (fun runner -> runner, List.rev acc) pipeline_runner
    | Shell_ir.Simple simple :: rest ->
        let same_sandbox_target =
          match sandbox_target with
          | None -> true
          | Some first_target -> simple.sandbox == first_target
        in
        (match simple.sandbox with
         | Docker { pipeline_runner = Some runner; _ }
           when simple.redirects = [] && same_sandbox_target ->
             let argv, env, cwd = process_spec_of_simple simple in
             let stage : Sandbox_target.pipeline_stage = { argv; env; cwd } in
             let pipeline_runner = Option.value pipeline_runner ~default:runner in
             let sandbox_target =
               Option.value sandbox_target ~default:simple.sandbox
             in
             loop (Some pipeline_runner) (Some sandbox_target) (stage :: acc) rest
         | _ -> None)
        [@warning "-4"]
    | Shell_ir.Pipeline _ :: _ -> None
  in
  loop None None [] stages

(* TEL-OK: this lower-level Shell IR dispatcher is wrapped by Execute/keeper
   telemetry at the action boundary; it preserves output delivery but does not
   record action-level telemetry directly. *)
let rec dispatch_pipeline ?base_host_env ?stdin_content ?on_output_chunk stages =
  let on_output_chunk, emitted = tracked_output_callback on_output_chunk in
  let decomposed_stage_callback ~is_final (simple : Shell_ir.simple) on_output_chunk =
    match on_output_chunk with
    | None -> None
    | Some _ when simple.redirects <> [] -> None
    | Some on_chunk ->
        Some
          (function
          | `Stdout chunk ->
              if is_final then on_chunk (`Stdout chunk)
          | `Stderr chunk -> on_chunk (`Stderr chunk))
  in
  let result =
    match stages with
    | [] ->
        invalid_pipeline "empty pipeline not supported in native dispatch"
    | [ _ ] ->
        invalid_pipeline "single-stage pipeline not supported in native dispatch"
    | _ ->
        (match host_pipeline_specs ?base_host_env stages with
         | Some specs ->
             let raw_source =
               specs
               |> List.map (fun stage -> String.concat " " stage.Process_eio.argv)
               |> String.concat " | "
             in
             let status, stdout, stderr =
               match on_output_chunk with
               | None ->
                   Exec_gate.run_argv_pipeline_with_status_split
                     ~actor:`Tool_local_runtime
                     ~raw_source
                     ~summary:"exec dispatch pipeline"
                     specs
               | Some on_chunk ->
                   Exec_gate.run_argv_pipeline_with_status_split
                     ~actor:`Tool_local_runtime
                     ~raw_source
                     ~summary:"exec dispatch pipeline streaming"
                     ~on_stdout_chunk:(fun chunk -> on_chunk (`Stdout chunk))
                     ~on_stderr_chunk:(fun chunk -> on_chunk (`Stderr chunk))
                     specs
               in
             { status; stdout; stderr }
         | None -> (
             match docker_pipeline_specs stages with
             | Some (runner, specs) ->
                 let on_stdout_chunk, on_stderr_chunk =
                   match on_output_chunk with
                   | None -> None, None
                   | Some on_chunk ->
                       ( Some (fun chunk -> on_chunk (`Stdout chunk))
                       , Some (fun chunk -> on_chunk (`Stderr chunk)) )
                 in
                 let status, stdout, stderr =
                   runner ~on_stdout_chunk ~on_stderr_chunk ~stages:specs
                 in
                 { status; stdout; stderr }
             | None ->
                 let rec chain ~prev_stdout ~status ~stderr = function
                   | [] -> { status; stdout = prev_stdout; stderr }
                   | Shell_ir.Simple s :: rest ->
                       let is_final = match rest with [] -> true | _ -> false in
                       let stage_on_output_chunk =
                         decomposed_stage_callback ~is_final s on_output_chunk
                       in
                       let stage_result =
                         dispatch_simple
                           ?base_host_env
                           ?on_output_chunk:stage_on_output_chunk
                           ~stdin_content:prev_stdout
                           s
                       in
                       let stage_streamed =
                         Option.is_some stage_on_output_chunk
                       in
                       let status = pipeline_status status stage_result.status in
                       let stderr = stderr ^ stage_result.stderr in
                       if status_is_timeout stage_result.status
                       then (
                         (* OCaml binds [else] to the nearest [if]: without
                            the parentheses the [else] below attached to
                            [if not is_final], so a streamed final-stage
                            timeout re-emitted output that had already been
                            streamed live, and a non-streamed (redirected)
                            stage timeout emitted nothing. *)
                         let () =
                           if stage_streamed
                           then (
                             if not is_final
                             then
                               emit_stdout_if_captured
                                 on_output_chunk
                                 stage_result.stdout)
                           else
                             emit_pipeline_stage_result
                               ~emit_stdout:true
                               on_output_chunk
                               stage_result
                         in
                         { status; stdout = stage_result.stdout; stderr })
                       else (
                         let () =
                           if stage_streamed
                           then ()
                           else
                             emit_pipeline_stage_result
                               ~emit_stdout:is_final
                               on_output_chunk
                               stage_result
                         in
                         chain
                           ~prev_stdout:stage_result.stdout
                           ~status
                           ~stderr
                           rest)
                   | Pipeline _ :: _ ->
                       { status = Unix.WEXITED 1
                       ; stdout = ""
                       ; stderr =
                           stderr ^ "nested pipeline not supported in native dispatch"
                       }
                 in
                 (match stages with
                  | [] | [ _ ] ->
                      invalid_pipeline "invalid pipeline arity in native dispatch"
                  | first :: rest -> (
                    match first with
                    | Shell_ir.Simple s ->
                        let first_on_output_chunk =
                          decomposed_stage_callback
                            ~is_final:false
                            s
                            on_output_chunk
                        in
                        let first_result =
                          dispatch_simple
                            ?base_host_env
                            ?on_output_chunk:first_on_output_chunk
                            s
                        in
                        let first_streamed =
                          Option.is_some first_on_output_chunk
                        in
                        let status =
                          pipeline_status (Unix.WEXITED 0) first_result.status
                        in
                        if status_is_timeout first_result.status
                        then (
                          let () =
                            if first_streamed
                            then
                              emit_stdout_if_captured
                                on_output_chunk
                                first_result.stdout
                            else
                              emit_pipeline_stage_result
                                ~emit_stdout:true
                                on_output_chunk
                                first_result
                          in
                          { status
                          ; stdout = first_result.stdout
                          ; stderr = first_result.stderr
                          })
                        else (
                          let () =
                            if first_streamed
                            then ()
                            else
                              emit_pipeline_stage_result
                                on_output_chunk
                                first_result
                          in
                          chain
                            ~prev_stdout:first_result.stdout
                            ~status
                            ~stderr:first_result.stderr
                            rest)
                    | Pipeline _ ->
                        invalid_pipeline
                          "nested pipeline not supported in native dispatch" ))))
  in
  emit_unseen_captured_output on_output_chunk emitted result

and dispatch ?base_host_env ?on_output_chunk (ir : Shell_ir.t) =
  match ir with
  | Shell_ir.Simple s -> dispatch_simple ?base_host_env ?on_output_chunk s
  | Pipeline stages -> dispatch_pipeline ?base_host_env ?on_output_chunk stages

let dispatch_decided ?base_host_env ?on_output_chunk (envelope : Shell_ir_risk.decided Shell_ir_risk.decided_ir) :
    dispatch_result =
  (match envelope.Shell_ir_risk.risk with
   | Shell_ir_risk.Destructive_protected ->
       Logs.warn (fun m ->
         m
           "Exec_dispatch: destructive_protected command dispatched: %a"
           Shell_ir.pp
           envelope.Shell_ir_risk.ir)
   | Shell_ir_risk.R0_Read
   | Shell_ir_risk.R1_Reversible_mutation
   | Shell_ir_risk.R2_Irreversible ->
       ());
  dispatch ?base_host_env ?on_output_chunk envelope.Shell_ir_risk.ir
