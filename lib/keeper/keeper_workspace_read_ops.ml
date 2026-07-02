(* Keeper_workspace_read_ops — read-side operation handlers for Grep.

   This module owns structured read/list/search operations so
   the Grep facade stays as the public dispatcher instead of reabsorbing
   read-backend, path-resolution, and host Shell IR details. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
open Keeper_workspace_ops_setup

(* Ripgrep input validation: reject malformed --type values and regex
   patterns before any Docker spawn or workspace search. *)
let rg_type_name_re = Re.Pcre.re {|^[a-zA-Z0-9_-]+$|} |> Re.compile

let validate_rg_type file_type =
  if file_type = "" || Re.execp rg_type_name_re file_type
  then Ok ()
  else
    Error
      (Printf.sprintf
         "invalid ripgrep --type value %S. Type names may contain only letters, \
          digits, hyphens, and underscores."
         file_type)
;;

let read_process_channel ic =
  let buf = Buffer.create 256 in
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match input ic chunk 0 (Bytes.length chunk) with
    | 0 -> Buffer.contents buf
    | n ->
      Buffer.add_subbytes buf chunk 0 n;
      loop ()
    | exception End_of_file -> Buffer.contents buf
  in
  loop ()
;;

let validate_rg_pattern pattern =
  let argv = [| "rg"; "--regexp"; pattern; "--files-with-matches"; "/dev/null" |] in
  try
    let ic, oc, ec = Unix.open_process_args_full "rg" argv (Unix.environment ()) in
    let _stdout = read_process_channel ic in
    let stderr = read_process_channel ec in
    match Unix.close_process_full (ic, oc, ec) with
    | Unix.WEXITED 0 | Unix.WEXITED 1 -> Ok ()
    | Unix.WEXITED code ->
      let detail =
        String.trim stderr
        |> String_util.utf8_safe ~max_bytes:240 ~suffix:"..."
        |> String_util.to_string
      in
      Error
        (Printf.sprintf
           "invalid ripgrep regex pattern %S: rg exited %d%s"
           pattern
           code
           (if detail = "" then "" else ": " ^ detail))
    | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
      Error
        (Printf.sprintf
           "invalid ripgrep regex pattern %S: rg interrupted by signal %d"
           pattern
           signal)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    Error "ripgrep executable not found while validating regex pattern"
  | exn ->
    Error
      (Printf.sprintf
         "ripgrep regex validation failed for %S: %s"
         pattern
         (Printexc.to_string exn))
;;

let validate_rg_inputs ~pattern ~file_type =
  match validate_rg_type file_type with
  | Error _ as e -> e
  | Ok () -> validate_rg_pattern pattern
;;
let try_handle
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
      ~op
      ~raw_path
  =
  let root = Keeper_alerting_path.project_root_of_config config in
  let containment_check target =
    Keeper_sandbox_containment.check_read_target ~config ~meta ~target
  in
  let repo_check target =
    Keeper_repo_mapping.validate_path_access ~keeper_id:meta.name
      ~base_path:root ~path:target
  in
  let read_target () =
    match Keeper_tool_execute_path.resolve_tool_read_path ~config ~meta ~args with
    | Error _ as e -> e
    | Ok target ->
      (match containment_check target with
       | Error msg -> Error msg
       | Ok () ->
         match repo_check target with
         | Error msg -> Error msg
         | Ok () -> Ok target)
  in
  let path_error e =
    actionable_path_error ~op ~meta ~raw_path ~error:e
  in
  (* TEL-OK: read-op adapter delegates to Keeper_tool_execute_shell_ir/Exec_dispatch or the
     sandbox read runner; execution telemetry stays with those runtime paths. *)
  let dispatch_host_shell_ir ~workdir ir =
    Keeper_tool_execute_shell_ir.dispatch ~keeper_id:meta.name
      ~base_path:root ~workdir ~sandbox:(Masc_exec.Sandbox_target.host ())
      ir
  in
  let run_host_shell_ir
        ?path
        ~workdir
        ~cmd
        ir
        ~on_ok
    =
    let fields =
      [ "typed", `Bool true; "cmd", `String cmd ]
      @
      match path with
        | None -> []
        | Some path -> [ "path", `String path ]
    in
    match dispatch_host_shell_ir ~workdir ir with
    | Error (Gate_reject diagnostic) -> error_json ~fields diagnostic
    | Error Cannot_parse -> error_json ~fields "Cannot parse command"
    | Error Too_complex -> error_json ~fields "Command too complex"
    | Error (Path_reject e) -> error_json ~fields:[ "blocked_cmd", `String cmd ] e
    | Error (Approval_required { summary; _ }) -> error_json ~fields summary
    | Error (Policy_denied { reason }) -> error_json ~fields reason
    | Ok result -> on_ok result
  in
  let sandbox_read_error ~target msg =
    error_json ~fields:[ "op", `String op; "path", `String target ] msg
  in
  let run_readonly_in_sandbox ?(ok_exit_codes = [ 0 ]) ~target ~command_argv
      ~max_bytes ~timeout_sec () =
    let max_eintr_retries = 8 in
    let rec loop attempts_left =
      match
        Keeper_sandbox_read_runner.container_path_of_host ~config ~meta ~host_path:target
      with
      | Error e -> Error (sandbox_read_error ~target e)
      | Ok cpath -> (
          match
            Keeper_sandbox_read_runner.run_command_with_status
              ?turn_sandbox_factory
              ~ok_exit_codes ~config ~meta ~command_argv:(command_argv cpath)
              ~max_bytes ~timeout_sec ()
          with
          | Error msg
            when attempts_left > 0
                 && String_util.contains_substring_ci msg
                      "interrupted system call" ->
              loop (attempts_left - 1)
          | Error msg -> Error (sandbox_read_error ~target msg)
          | Ok payload -> Ok payload)
    in
    loop max_eintr_retries
  in
  let host_search_workdir target =
    if safe_is_dir target then target else Filename.dirname target
  in
  match op with
  | "rg" ->
    Some
      (let pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
       let file_type = Safe_ops.json_string ~default:"" "type" args |> String.trim in
       if pattern = ""
       then error_json ~fields:[ "op", `String op ] "pattern is required for rg. Good: pattern='handle_request'. Bad: pattern=''."
       else (
         match validate_rg_inputs ~pattern ~file_type with
         | Error msg -> error_json ~fields:[ "op", `String op ] msg
         | Ok () -> (
           match read_target () with
           | Error e -> path_error e
           | Ok target ->
             let limit = shell_readonly_limit args in
             let glob = Safe_ops.json_string ~default:"" "glob" args |> String.trim in
             if Keeper_sandbox_read_runner.should_route_read ~meta then
               let base_argv = [ "rg"; "-n"; "-m"; string_of_int limit ] in
               let type_argv = if file_type <> "" then [ "--type"; file_type ] else [] in
               let glob_argv = if glob <> "" then [ "--glob"; glob ] else [] in
               (match
                  run_readonly_in_sandbox ~target
                    ~command_argv:(fun cpath ->
                      base_argv @ type_argv @ glob_argv @ [ pattern; cpath ])
                    ~ok_exit_codes:[ 0; 1 ]
                    ~max_bytes:1_000_000
                    ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Read ())
                    ()
                with
                | Error response -> response
                | Ok (st, out) ->
                  Yojson.Safe.to_string
                    (`Assoc
                        [ "ok", `Bool true
                        ; "op", `String op
                        ; "path", `String target
                        ; "pattern", `String pattern
                        ; "via", `String Keeper_sandbox_read_runner.backend_via
                        ; "status", Keeper_alerting_path.process_status_to_json st
                        ; "matches", lines_to_json ~limit out
                        ]))
           else
             let rg_available = Keeper_tool_execute_path.shell_command_available "rg" in
             if not rg_available then
               path_error "rg executable not found; Grep requires rg"
             else
               let argv =
                 [ "-n"; "-m"; string_of_int limit ]
                 @ (if file_type <> "" then
                      [ "--type"; file_type ]
                    else [])
                 @ (if glob <> "" then
                      [ "--glob"; glob ]
                    else [])
                 @ [ pattern; target ]
               in
               let ir = Keeper_tool_execute_shell_ir.simple Masc_exec.Exec_program.Rg argv in
               run_host_shell_ir
                 ~workdir:(host_search_workdir target)
                 ~cmd:op
                 ~path:target
                 ir
                 ~on_ok:(fun result ->
                   let is_ok =
                     match result.status with
                     | Unix.WEXITED 0 | Unix.WEXITED 1 -> true
                     | _ -> false
                   in
                   (* On non-zero rg exit (exit 2 for an unrecognized
                      --type/--glob value or a missing path), surface rg's
                      own stderr so the keeper can self-correct instead of
                      retrying the same broken argv until the circuit
                      breaker trips. exit_code.ml's generic exit-2 hint
                      already promises "Check stderr for details", but the
                      rg result dropped stderr — this fulfils that broken
                      contract. It does NOT classify stderr (RFC-0089: no
                      new string classifier; status.category stays typed,
                      error_detail is a human-readable diagnostic). *)
                   let trimmed_stderr = String.trim result.stderr in
                   let error_detail =
                     if is_ok || String.equal trimmed_stderr ""
                     then []
                     else [ "error_detail", `String trimmed_stderr ]
                   in
                   Yojson.Safe.to_string
                     (`Assoc
                         ([ "ok", `Bool is_ok
                          ; "op", `String op
                          ; "path", `String target
                          ; "pattern", `String pattern
                          ; "via", `String "host"
                          ; "status", Keeper_alerting_path.process_status_to_json result.status
                          ; "matches", lines_to_json ~limit result.stdout
                          ]
                         @ error_detail))))))
  | _ -> None
;;
