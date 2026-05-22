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

let is_dev_null target = String.equal (Path_scope.raw target) "/dev/null"

let redirect_plan_of_redirects redirects =
  let step plan = function
    | Redirect_scope.Fd_to_fd { src; dst } ->
        let* target = redirect_target_of_fd plan dst in
        set_redirect_target plan src target
    | Redirect_scope.File
        { fd; target; mode = (Redirect_scope.Write | Redirect_scope.Append) }
      when is_dev_null target ->
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

let env_key entry =
  match String.index_opt entry '=' with
  | None -> entry
  | Some idx -> String.sub entry 0 idx

let resolve_host_env = function
  | [] -> None
  | env_bindings ->
      let overrides = resolve_env env_bindings |> Array.to_list in
      let override_keys = List.map env_key overrides in
      let inherited =
        Unix.environment ()
        |> Array.to_list
        |> List.filter (fun entry ->
          not (List.mem (env_key entry) override_keys))
      in
      Some (Array.of_list (inherited @ overrides))

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
  match redirect_plan_of_redirects s.redirects with
  | Error message -> unsupported_redirect_result message
  | Ok redirect_plan -> (
    match s.sandbox with
    | Host ->
      let raw_source = String.concat " " argv in
      let host_env = resolve_host_env s.env in
      let run () =
        match stdin_content with
        | None ->
          Exec_gate.run_argv_with_status_split
            ~actor:`Tool_local_runtime
            ~raw_source
            ~summary:"exec dispatch simple"
            ~timeout_sec
            ?env:host_env
            ?cwd
            argv
        | Some stdin_content ->
          Exec_gate.run_argv_with_stdin_and_status_split
            ~actor:`Tool_local_runtime
            ~raw_source
            ~summary:"exec dispatch simple stdin"
            ~timeout_sec
            ?env:host_env
            ?cwd
            ~stdin_content
            argv
      in
      (match run () with
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception exn ->
         { status = Unix.WEXITED 1; stdout = ""; stderr = Printexc.to_string exn }
       | status, stdout, stderr ->
         apply_redirect_plan redirect_plan { status; stdout; stderr })
    | Docker { runner; _ } ->
    (match runner ~stdin_content ~argv ~env ~cwd ~timeout_sec with
     | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
     | exception exn ->
       { status = Unix.WEXITED 1; stdout = ""; stderr = Printexc.to_string exn }
     | status, stdout, stderr ->
       apply_redirect_plan redirect_plan { status; stdout; stderr }))

(* --- pipeline + entry point (mutually recursive) --- *)

let invalid_pipeline stderr = { status = Unix.WEXITED 1; stdout = ""; stderr }

let pipeline_timeout_result ~timeout_sec =
  { status = Unix.WEXITED 124
  ; stdout = ""
  ; stderr = Printf.sprintf "pipeline timed out after %.3fs" timeout_sec
  }

let dispatch_simple_before_deadline ?stdin_content ~deadline ~pipeline_timeout_sec s =
  let remaining_timeout_sec = deadline -. Unix.gettimeofday () in
  if remaining_timeout_sec <= 0.0
  then pipeline_timeout_result ~timeout_sec:pipeline_timeout_sec
  else
    dispatch_simple
      ~timeout_sec:remaining_timeout_sec
      ?stdin_content
      s

let host_pipeline_specs stages =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | Shell_ir.Simple simple :: rest ->
        (match simple.sandbox with
         | Host when simple.redirects = [] ->
             let argv, _env, cwd = process_spec_of_simple simple in
             let stage : Process_eio.pipeline_stage =
               { argv; env = resolve_host_env simple.env; cwd }
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

let rec dispatch_pipeline ?timeout_sec stages =
  let pipeline_timeout_sec = dispatch_timeout_sec timeout_sec in
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
               ~timeout_sec:pipeline_timeout_sec
               specs
           in
           { status; stdout; stderr }
       | None -> (
           match docker_pipeline_specs stages with
           | Some (runner, specs) ->
               let status, stdout, stderr =
                 runner ~stages:specs ~timeout_sec:pipeline_timeout_sec
               in
               { status; stdout; stderr }
           | None ->
               let deadline = Unix.gettimeofday () +. pipeline_timeout_sec in
               let rec chain ~prev_stdout ~status ~stderr = function
                 | [] -> { status; stdout = prev_stdout; stderr }
                 | Shell_ir.Simple s :: rest ->
                     let stage_result =
                       dispatch_simple_before_deadline
                         ~stdin_content:prev_stdout
                         ~deadline
                         ~pipeline_timeout_sec
                         s
                     in
                     let status = pipeline_status status stage_result.status in
                     let stderr = stderr ^ stage_result.stderr in
                     if status_is_timeout stage_result.status
                     then { status; stdout = stage_result.stdout; stderr }
                     else
                       chain
                         ~prev_stdout:stage_result.stdout
                         ~status
                         ~stderr
                         rest
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
                      let first_result =
                        dispatch_simple_before_deadline
                          ~deadline
                          ~pipeline_timeout_sec
                          s
                      in
                      let status =
                        pipeline_status (Unix.WEXITED 0) first_result.status
                      in
                      if status_is_timeout first_result.status
                      then
                        { status
                        ; stdout = first_result.stdout
                        ; stderr = first_result.stderr
                        }
                      else
                        chain
                          ~prev_stdout:first_result.stdout
                          ~status
                          ~stderr:first_result.stderr
                          rest
                  | Pipeline _ ->
                      invalid_pipeline
                        "nested pipeline not supported in native dispatch" ))))

and dispatch ?timeout_sec (ir : Shell_ir.t) =
  match ir with
  | Shell_ir.Simple s -> dispatch_simple ?timeout_sec s
  | Pipeline stages -> dispatch_pipeline ?timeout_sec stages
