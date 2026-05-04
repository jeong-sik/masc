(* P7: Pipeline-Native Dispatch
   Execute Shell_ir.t directly via Process_eio without going through
   /bin/bash.  Simple commands use argv-based spawn; pipelines chain
   stdout->stdin across stages.

   Controlled by [MASC_BASH_NATIVE_DISPATCH] env var:
   - "1" (default): native dispatch for Simple, bash fallback for Pipeline
   - "0": always fall back to bash

   This module is the first step toward eliminating shell injection
   entirely.  Pipeline support is limited to stdout->stdin chaining. *)

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

(* Dispatch a simple command via the IR-carried Sandbox_target runner.

   Prior to PR-2 (2026-04-28 root-fix family 3/3) this function called
   [Process_eio.run_argv_with_status_split] directly, which short-
   circuited every command to a host fork/exec regardless of the
   keeper's [sandbox_profile]. The runner closure on the Shell_ir node
   now carries the sandbox decision: the host case forwards to the
   same Process_eio call (no behavior change for non-keeper callers),
   the Docker case is wired up by [lib/keeper] using a closure over
   [Keeper_turn_sandbox_runtime]. *)
let dispatch_simple (s : Shell_ir.simple) =
  let bin = Bin.to_string s.bin in
  let argv = bin :: List.map resolve_arg s.args in
  let env = resolve_env s.env in
  let cwd =
    match s.cwd with
    | None -> None
    | Some scope -> Some (Path_scope.raw scope)
  in
  match s.sandbox.runner ~argv ~env ~cwd ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Dispatch ()) with
  | exception exn ->
      { status = Unix.WEXITED 1;
        stdout = "";
        stderr = Printexc.to_string exn }
  | (status, stdout, stderr) ->
      { status; stdout; stderr }

(* --- pipeline + entry point (mutually recursive) --- *)

let rec dispatch_pipeline stages =
  match stages with
  | [] ->
      { status = Unix.WEXITED 0; stdout = ""; stderr = "" }
  | [ stage ] -> dispatch stage
  | _ ->
      let rec chain prev_stdout = function
        | [] ->
            { status = Unix.WEXITED 0; stdout = prev_stdout; stderr = "" }
        | [ Shell_ir.Simple s ] ->
            let bin = Bin.to_string s.bin in
            let argv = bin :: List.map resolve_arg s.args in
            let env = resolve_env s.env in
            (match
               Process_eio.run_argv_with_stdin_and_status_split
                 ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Dispatch ()) ~env
                 ~stdin_content:prev_stdout argv
             with
            | exception exn ->
                { status = Unix.WEXITED 1;
                  stdout = "";
                  stderr = Printexc.to_string exn }
            | (status, stdout, stderr) ->
                { status; stdout; stderr })
        | Shell_ir.Simple s :: rest ->
            let bin = Bin.to_string s.bin in
            let argv = bin :: List.map resolve_arg s.args in
            let env = resolve_env s.env in
            (match
               Process_eio.run_argv_with_stdin_and_status_split
                 ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Dispatch ()) ~env
                 ~stdin_content:prev_stdout argv
             with
            | exception exn ->
                { status = Unix.WEXITED 1;
                  stdout = "";
                  stderr = Printexc.to_string exn }
            | (status, stdout, stderr) ->
                let last_status = status in
                let result = chain stdout rest in
                let final_status =
                  match last_status with
                  | Unix.WEXITED 0 -> result.status
                  | _ -> last_status
                in
                { result with status = final_status })
        | Pipeline _ :: _ ->
            { status = Unix.WEXITED 1;
              stdout = "";
              stderr = "nested pipeline not supported in native dispatch" }
      in
      (match stages with
       | [] ->
           { status = Unix.WEXITED 0; stdout = ""; stderr = "" }
       | first :: rest ->
           (match first with
            | Shell_ir.Simple s ->
                let result = dispatch_simple s in
                chain result.stdout rest
            | Pipeline _ ->
                { status = Unix.WEXITED 1;
                  stdout = "";
                  stderr = "nested pipeline not supported" }))

and dispatch (ir : Shell_ir.t) =
  match ir with
  | Shell_ir.Simple s -> dispatch_simple s
  | Pipeline stages -> dispatch_pipeline stages

let native_dispatch_enabled () =
  match Unix.getenv "MASC_BASH_NATIVE_DISPATCH" with
  | exception Not_found -> true
  | "0" -> false
  | _ -> true
