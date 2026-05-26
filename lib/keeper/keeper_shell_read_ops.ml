(* Keeper_shell_read_ops — read-side operation handlers for SearchFiles.

   This module owns structured read/list/search operations so
   the SearchFiles facade stays as the public dispatcher instead of reabsorbing
   read-backend, path-resolution, and host Shell IR details. *)

open Keeper_types
open Keeper_exec_shared
open Keeper_workspace_ops_setup

let try_handle
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(config : Coord.config)
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
    match Keeper_shell_path.resolve_tool_read_path ~config ~meta ~args with
    | Error _ as e -> e
    | Ok target ->
      (match containment_check target with
       | Error msg -> Error msg
       | Ok () ->
         match repo_check target with
         | Error msg -> Error msg
         | Ok () -> Ok target)
  in
  let cwd_target () =
    match Keeper_shell_path.resolve_tool_read_cwd ~config ~meta ~args with
    | Error _ as e -> e
    | Ok cwd ->
      (match containment_check cwd with
       | Error msg -> Error msg
       | Ok () ->
         match repo_check cwd with
         | Error msg -> Error msg
         | Ok () -> Ok cwd)
  in
  let path_error e =
    actionable_path_error ~op ~meta ~raw_path ~error:e
  in
  (* TEL-OK: read-op adapter delegates to Keeper_shell_ir/Exec_dispatch or the
     sandbox read runner; execution telemetry stays with those runtime paths. *)
  let dispatch_host_shell_ir
        ?(allowed_commands = Dev_exec_allowlist.readonly)
        ?timeout_sec
        ~workdir
        ir
    =
    Keeper_shell_ir.dispatch ~allowed_commands ~keeper_id:meta.name
      ~base_path:root ~workdir ~sandbox:(Masc_exec.Sandbox_target.host ())
      ?timeout_sec ir
  in
  let run_host_shell_ir
        ?(allowed_commands = Dev_exec_allowlist.readonly)
        ?timeout_sec
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
    match dispatch_host_shell_ir ~allowed_commands ?timeout_sec ~workdir ir with
    | Error (Gate_reject diagnostic) -> error_json ~fields diagnostic
    | Error Cannot_parse -> error_json ~fields "Cannot parse command"
    | Error Too_complex -> error_json ~fields "Command too complex"
    | Error (Path_reject e) -> error_json ~fields:[ "blocked_cmd", `String cmd ] e
    | Ok result -> on_ok result
  in
  let dispatch_result_output (result : Masc_exec.Exec_dispatch.dispatch_result) =
    if String.equal result.stderr "" then result.stdout else result.stdout ^ result.stderr
  in
  let sandbox_read_error ~target msg =
    error_json ~fields:[ "op", `String op; "path", `String target ] msg
  in
  let hostify_turn_runtime_output out =
    Keeper_shell_runtime_paths.rewrite_turn_runtime_paths_to_host ~config ~meta out
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
  let run_in_turn_runtime ?(ok_exit_codes = [ 0 ]) ~cwd ~cmd ~command_argv
      ?host_ir ?(host_allowed_commands = Dev_exec_allowlist.readonly)
      ~max_bytes ~timeout_sec ?(map_output = fun out -> out) ?(extra = []) () =
    match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
    | Some runtime ->
      (match
         Keeper_turn_sandbox_runtime.run_command_with_status
           ~ok_exit_codes runtime ~cwd ~command_argv ~max_bytes ~timeout_sec ()
       with
       | Error msg ->
         error_json
           ~fields:([ "op", `String op; "cwd", `String cwd ] @ extra) msg
       | Ok (st, out) ->
         render_completed_process_result ~root ~keeper_name:meta.name ~op ~cwd
           ~cmd ~extra st (map_output out))
    | None ->
      (match host_ir with
       | None ->
         error_json
           ~fields:[ "op", `String op; "cwd", `String cwd ]
           "missing host Shell IR fallback"
       | Some ir ->
         run_host_shell_ir ~allowed_commands:host_allowed_commands ~timeout_sec
           ~workdir:cwd ~cmd ~path:cwd ir
           ~on_ok:(fun result ->
             render_completed_process_result ~root ~keeper_name:meta.name ~op
               ~cwd ~cmd ~extra result.status
               (map_output (dispatch_result_output result))))
  in
  let render_sandbox_process_result ~cwd ~cmd ~backend_cmd ~timeout_sec =
    match
      Keeper_sandbox_runner.run_shell_command_with_status ~config ~meta ~cwd ~timeout_sec
        ~cmd:backend_cmd ~git_creds_enabled:false ~network_mode:Network_none
    with
    | Error msg -> error_json ~fields:[ "op", `String op; "cwd", `String cwd ] msg
    | Ok result ->
      let cwd_response =
        Keeper_cwd_response.docker ~host_cwd:cwd
          ~container_cwd:
            (Keeper_sandbox_runner.private_workspace_cwd ~config
               ~meta cwd)
      in
      Yojson.Safe.to_string
        (Exec_core.process_result_json
           ~artifact_policy:Exec_core.Inline_only
           ~base_path:root
           ~keeper_name:meta.name
           ~cmd
           ~extra:
             [
               "op", `String op;
               "cmd", `String cmd;
               "cwd", Keeper_cwd_response.to_yojson_response cwd_response;
               "via", `String Keeper_sandbox_read_runner.backend_via;
             ]
           ~status:result.status
           ~output:result.output
           ())
  in
  let sandbox_git_log_path host_path =
    if String.trim host_path = "" then Ok ""
    else if Filename.is_relative host_path then Ok host_path
    else
      Keeper_sandbox_read_runner.container_path_of_host ~config ~meta ~host_path
  in
  match op with
  | "pwd" ->
    Some
      (match cwd_target () with
       | Error e -> path_error e
       | Ok cwd ->
         if Keeper_sandbox_read_runner.should_route_read ~meta then
           render_sandbox_process_result ~cwd ~cmd:"pwd" ~backend_cmd:"pwd"
             ~timeout_sec:Keeper_shell_timeout.io_timeout_sec
         else
           let host_ir =
             Keeper_shell_ir.simple ~cwd_raw:cwd ~cwd_base:root Masc_exec.Exec_program.Pwd []
           in
           run_in_turn_runtime ~cwd ~cmd:"pwd" ~command_argv:[ coreutils.pwd ]
             ~host_ir ~map_output:hostify_turn_runtime_output ~max_bytes:4096
             ~timeout_sec:Keeper_shell_timeout.io_timeout_sec ())
  | "git_status" ->
    Some
      (match cwd_target () with
       | Error e -> path_error e
       | Ok cwd ->
         if Keeper_sandbox_read_runner.should_route_read ~meta then
           render_sandbox_process_result ~cwd
             ~cmd:"git -C <cwd> --no-optional-locks status --short --branch"
             ~backend_cmd:"git --no-optional-locks status --short --branch"
             ~timeout_sec:Keeper_shell_timeout.read_timeout_sec
         else
           let ir =
             Keeper_shell_ir.simple
               ~cwd_raw:cwd
               ~cwd_base:root
               Masc_exec.Exec_program.Git
               [ "--no-optional-locks"; "status"; "--short"; "--branch" ]
           in
           run_host_shell_ir
             ~allowed_commands:Dev_exec_allowlist.dev
             ~workdir:cwd
             ~cmd:"git status"
             ~path:cwd
             ir
             ~on_ok:(fun result ->
               render_completed_process_result ~root ~keeper_name:meta.name ~op
                 ~cwd
                 ~cmd:"git --no-optional-locks status --short --branch"
                 ~extra:[]
                 result.status
                 result.stdout))
  | "ls" ->
    Some
      (match read_target () with
       | Error e -> path_error e
       | Ok target ->
         let limit = shell_readonly_limit args in
         if Keeper_sandbox_read_runner.should_route_read ~meta then
           (match
              Keeper_sandbox_read_runner.container_path_of_host ~config ~meta
                ~host_path:target
            with
            | Error e ->
              error_json
                ~fields:[ "op", `String op; "path", `String target ] e
            | Ok cpath ->
              (match
                 Keeper_sandbox_read_runner.run_command
                   ?turn_sandbox_factory ~config ~meta
                   ~command_argv:[ "ls"; "-la"; cpath ]
                   ~max_bytes:1_000_000
                   ~timeout_sec:Keeper_shell_timeout.io_timeout_sec
                   ()
               with
               | Error msg ->
                 error_json
                   ~fields:[ "op", `String op; "path", `String target ] msg
               | Ok out ->
                 Yojson.Safe.to_string
                   (`Assoc
                       [ "ok", `Bool true
                       ; "op", `String op
                       ; "path", `String target
                       ; "via", `String Keeper_sandbox_read_runner.backend_via
                       ; "entries", lines_to_json ~limit out
                       ])))
         else
           let ir = Keeper_shell_ir.simple Masc_exec.Exec_program.Ls [ "-la"; target ] in
           run_host_shell_ir
             ~workdir:target
             ~cmd:"ls -la"
             ~path:target
             ir
             ~on_ok:(fun result ->
               let output =
                 if String.equal result.stderr ""
                 then result.stdout
                 else result.stdout ^ result.stderr
               in
               render_completed_process_result ~root ~keeper_name:meta.name ~op
                 ~cmd:"ls -la"
                 ~extra:[ "path", `String target; "entries", lines_to_json ~limit output ]
                 result.status
                 output))
  | "cat" ->
    Some
      (match read_target () with
       | Error e -> path_error e
       | Ok target ->
         let max_bytes = shell_readonly_cat_max_bytes args in
         if Keeper_sandbox_read_runner.should_route_read ~meta then
           (match
              Keeper_sandbox_read_runner.read_file
                ?turn_sandbox_factory ~config ~meta
                ~host_path:target ~max_bytes
                ~timeout_sec:Keeper_shell_timeout.read_timeout_sec
                ()
            with
            | Error msg ->
              error_json
                ~fields:[ "op", `String op; "path", `String target ] msg
            | Ok body ->
              let total = String.length body in
              let truncated = total >= max_bytes in
              Yojson.Safe.to_string
                (`Assoc
                    [ "ok", `Bool true
                    ; "op", `String op
                    ; "path", `String target
                    ; "via", `String Keeper_sandbox_read_runner.backend_via
                    ; "bytes", `Int total
                    ; "truncated", `Bool truncated
                    ; "content", `String body
                    ]))
         else
           let ir = Keeper_shell_ir.simple Masc_exec.Exec_program.Cat [ target ] in
           run_host_shell_ir
             ~workdir:target
             ~cmd:"cat"
             ~path:target
             ir
             ~on_ok:(fun result ->
               let out = result.stdout in
               let body =
                 if String.length out > max_bytes then String.sub out 0 max_bytes else out
               in
               Yojson.Safe.to_string
                 (`Assoc
                     [ "ok", `Bool (match result.status with Unix.WEXITED 0 -> true | _ -> false)
                     ; "op", `String op
                     ; "path", `String target
                     ; "via", `String "host"
                     ; "status", Keeper_alerting_path.process_status_to_json result.status
                     ; "truncated", `Bool (String.length out > max_bytes)
                     ; "content", `String body
                     ])))
  | "rg" ->
    Some
      (let pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
       if pattern = ""
       then error_json ~fields:[ "op", `String op ] "pattern is required for rg. Good: pattern='handle_request'. Bad: pattern=''."
       else (
         match read_target () with
         | Error e -> path_error e
         | Ok target ->
           let limit = shell_readonly_limit args in
           let file_type = Safe_ops.json_string ~default:"" "type" args |> String.trim in
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
                  ~timeout_sec:Keeper_shell_timeout.read_timeout_sec
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
             let rg_available = Keeper_shell_path.shell_command_available "rg" in
             if not rg_available then
               path_error "rg executable not found; SearchFiles requires rg"
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
               let ir = Keeper_shell_ir.simple Masc_exec.Exec_program.Rg argv in
               run_host_shell_ir
                 ~workdir:target
                 ~cmd:op
                 ~path:target
                 ir
                 ~on_ok:(fun result ->
                   let is_ok =
                     match result.status with
                     | Unix.WEXITED 0 | Unix.WEXITED 1 -> true
                     | _ -> false
                   in
                   Yojson.Safe.to_string
                     (`Assoc
                         [ "ok", `Bool is_ok
                         ; "op", `String op
                         ; "path", `String target
                         ; "pattern", `String pattern
                         ; "via", `String "host"
                         ; "status", Keeper_alerting_path.process_status_to_json result.status
                         ; "matches", lines_to_json ~limit result.stdout
                         ]))))
  | "git_log" ->
    Some
      (match cwd_target () with
       | Error e -> path_error e
       | Ok cwd ->
         let count = max 1 (min 50 (Safe_ops.json_int ~default:10 "count" args)) in
         let format = Safe_ops.json_string ~default:"%h %s" "format" args in
         let file_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
         let grep = Safe_ops.json_string ~default:"" "grep" args |> String.trim in
         if Keeper_sandbox_read_runner.should_route_read ~meta then
           (match sandbox_git_log_path file_path with
            | Error err ->
              error_json
                ~fields:
                  [ "op", `String op; "cwd", `String cwd; "path", `String file_path ]
                err
            | Ok backend_file_path ->
              let backend_cmd =
                let base =
                  Printf.sprintf "git --no-optional-locks log --format=%s -%d%s"
                    (Filename.quote format) count
                    (if grep = "" then "" else " --grep=" ^ Filename.quote grep)
                in
                if backend_file_path = "" then
                  base
                else
                  Printf.sprintf "%s -- %s" base (Filename.quote backend_file_path)
              in
              render_sandbox_process_result ~cwd
                ~cmd:"git -C <cwd> --no-optional-locks log --format=<fmt> -<n>"
                ~backend_cmd ~timeout_sec:Keeper_shell_timeout.read_timeout_sec)
         else
           (match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
            | Some runtime ->
              let argv =
                let base_argv =
                  [
                    "git";
                    "--no-optional-locks";
                    "log";
                    Printf.sprintf "--format=%s" format;
                    Printf.sprintf "-%d" count;
                  ]
                in
                let base_argv =
                  if grep = "" then base_argv else base_argv @ [ "--grep=" ^ grep ]
                in
                if file_path = "" then
                  base_argv
                else
                  let runtime_path =
                    if Filename.is_relative file_path then file_path
                    else
                      match
                        Keeper_turn_sandbox_runtime.container_path_of_host runtime
                          ~host_path:file_path
                      with
                      | Ok mapped -> mapped
                      | Error _ -> file_path
                  in
                  base_argv @ [ "--"; runtime_path ]
              in
              (match
                 Keeper_turn_sandbox_runtime.run_command_with_status runtime
                   ~cwd ~command_argv:argv
                   ~ok_exit_codes:[ 0 ]
                   ~max_bytes:1_000_000
                   ~timeout_sec:Keeper_shell_timeout.read_timeout_sec ()
               with
               | Error msg ->
                 error_json
                   ~fields:[ "op", `String op; "cwd", `String cwd ] msg
               | Ok (st, out) ->
                 let cwd_response =
                   Keeper_cwd_response.docker ~host_cwd:cwd
                     ~container_cwd:
                       (Keeper_turn_sandbox_runtime.container_cwd_of_host
                          runtime ~host_cwd:cwd)
                 in
                 Yojson.Safe.to_string
                   (`Assoc
                       [ "ok", `Bool true
                       ; "op", `String op
                       ; "cwd", Keeper_cwd_response.to_yojson_response cwd_response
                       ; "count", `Int count
                       ; "grep", `String grep
                       ; "via", `String Keeper_sandbox_read_runner.backend_via
                       ; "status", Keeper_alerting_path.process_status_to_json st
                       ; "entries", lines_to_json ~limit:50 out
                       ]))
            | None ->
              let base_args =
                [
                  "--no-optional-locks";
                  "log";
                  Printf.sprintf "--format=%s" format;
                  Printf.sprintf "-%d" count;
                ]
              in
              let args_with_grep =
                if grep = "" then base_args else base_args @ [ "--grep=" ^ grep ]
              in
              let args =
                if file_path = "" then args_with_grep else args_with_grep @ [ "--"; file_path ]
              in
              let ir =
                Keeper_shell_ir.simple ~cwd_raw:cwd ~cwd_base:root Masc_exec.Exec_program.Git args
              in
              run_host_shell_ir
                ~allowed_commands:Dev_exec_allowlist.dev
                ~workdir:cwd
                ~cmd:"git log"
                ~path:cwd
                ir
                ~on_ok:(fun result ->
                  render_completed_process_result ~root ~keeper_name:meta.name ~op
                    ~cwd
                    ~cmd:"git --no-optional-locks log --format=<fmt> -<n>"
                    ~extra:[ "count", `Int count; "grep", `String grep ]
                    result.status
                    result.stdout)))
  | "find" ->
    Some
      (let name_pattern =
         let pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
         if pattern <> ""
         then pattern
         else Safe_ops.json_string ~default:"" "name" args |> String.trim
       in
       if name_pattern = ""
       then error_json ~fields:[ "op", `String op ] "pattern is required for find. Good: pattern='*.ml'. Bad: pattern=''."
       else (
         match read_target () with
         | Error e -> path_error e
         | Ok target ->
           let limit = shell_readonly_limit args in
           if Keeper_sandbox_read_runner.should_route_read ~meta then
             (match
                run_readonly_in_sandbox ~target
                  ~command_argv:(fun cpath ->
                    [ "find"; cpath; "-maxdepth"; "5"; "-name"; name_pattern;
                      "-not"; "-path"; "*/.git/*";
                      "-not"; "-path"; "*/_build/*";
                      "-not"; "-path"; "*/.masc/*" ])
                  ~max_bytes:1_000_000
                  ~timeout_sec:Keeper_shell_timeout.read_timeout_sec
                  ()
              with
              | Error response -> response
              | Ok (st, out) ->
                Yojson.Safe.to_string
                  (`Assoc
                      [ "ok", `Bool true
                      ; "op", `String op
                      ; "path", `String target
                      ; "name", `String name_pattern
                      ; "via", `String Keeper_sandbox_read_runner.backend_via
                      ; "status", Keeper_alerting_path.process_status_to_json st
                      ; "files", lines_to_json ~limit out
                      ]))
           else
             let ir =
               Keeper_shell_ir.simple
                 Masc_exec.Exec_program.Find
                 [ target
                 ; "-maxdepth"
                 ; "5"
                 ; "-name"
                 ; name_pattern
                 ; "-not"
                 ; "-path"
                 ; "*/.git/*"
                 ; "-not"
                 ; "-path"
                 ; "*/_build/*"
                 ; "-not"
                 ; "-path"
                 ; "*/.masc/*"
                 ]
             in
             run_host_shell_ir
               ~workdir:target
               ~cmd:"find"
               ~path:target
               ir
               ~on_ok:(fun result ->
                 let out = dispatch_result_output result in
                 Yojson.Safe.to_string
                   (`Assoc
                       [ "ok", `Bool (result.status = Unix.WEXITED 0)
                       ; "op", `String op
                       ; "path", `String target
                       ; "name", `String name_pattern
                       ; "via", `String "host"
                       ; "status", Keeper_alerting_path.process_status_to_json result.status
                       ; "files", lines_to_json ~limit out
                       ]))))
  | "head" ->
    Some
      (match read_target () with
       | Error e -> path_error e
       | Ok target ->
         let n = Safe_ops.json_int ~default:20 "lines" args |> fun v -> max 1 (min 200 v) in
         if Keeper_sandbox_read_runner.should_route_read ~meta then
           (match
              run_readonly_in_sandbox ~target
                ~command_argv:(fun cpath ->
                  [ "head"; "-n"; string_of_int n; cpath ])
                ~max_bytes:1_000_000
                ~timeout_sec:Keeper_shell_timeout.read_timeout_sec
                ()
            with
            | Error response -> response
            | Ok (st, out) ->
              Yojson.Safe.to_string
                (`Assoc
                    [ "ok", `Bool true
                    ; "op", `String op
                    ; "path", `String target
                    ; "lines", `Int n
                    ; "via", `String Keeper_sandbox_read_runner.backend_via
                    ; "status", Keeper_alerting_path.process_status_to_json st
                    ; "content", `String out
                    ]))
         else
           let ir =
             Keeper_shell_ir.simple
               Masc_exec.Exec_program.Head
               [ "-n"; string_of_int n; target ]
           in
           run_host_shell_ir
             ~workdir:target
             ~cmd:"head"
             ~path:target
             ir
             ~on_ok:(fun result ->
               let out = dispatch_result_output result in
               Yojson.Safe.to_string
                 (`Assoc
                     [ "ok", `Bool (result.status = Unix.WEXITED 0)
                     ; "op", `String op
                     ; "path", `String target
                     ; "lines", `Int n
                     ; "via", `String "host"
                     ; "status", Keeper_alerting_path.process_status_to_json result.status
                     ; "content", `String out
                     ])))
  | "tail" ->
    Some
      (match read_target () with
       | Error e -> path_error e
       | Ok target ->
         let n = Safe_ops.json_int ~default:20 "lines" args |> fun v -> max 1 (min 200 v) in
         if Keeper_sandbox_read_runner.should_route_read ~meta then
           (match
              run_readonly_in_sandbox ~target
                ~command_argv:(fun cpath ->
                  [ "tail"; "-n"; string_of_int n; cpath ])
                ~max_bytes:1_000_000
                ~timeout_sec:Keeper_shell_timeout.read_timeout_sec
                ()
            with
            | Error response -> response
            | Ok (st, out) ->
              Yojson.Safe.to_string
                (`Assoc
                    [ "ok", `Bool true
                    ; "op", `String op
                    ; "path", `String target
                    ; "lines", `Int n
                    ; "via", `String Keeper_sandbox_read_runner.backend_via
                    ; "status", Keeper_alerting_path.process_status_to_json st
                    ; "content", `String out
                    ]))
         else
           let ir =
             Keeper_shell_ir.simple
               Masc_exec.Exec_program.Tail
               [ "-n"; string_of_int n; target ]
           in
           run_host_shell_ir
             ~workdir:target
             ~cmd:"tail"
             ~path:target
             ir
             ~on_ok:(fun result ->
               let out = dispatch_result_output result in
               Yojson.Safe.to_string
                 (`Assoc
                     [ "ok", `Bool (result.status = Unix.WEXITED 0)
                     ; "op", `String op
                     ; "path", `String target
                     ; "lines", `Int n
                     ; "via", `String "host"
                     ; "status", Keeper_alerting_path.process_status_to_json result.status
                     ; "content", `String out
                     ])))
  | "wc" ->
    Some
      (match read_target () with
       | Error e -> path_error e
       | Ok target ->
         if Keeper_sandbox_read_runner.should_route_read ~meta then
           (match
              run_readonly_in_sandbox ~target
                ~command_argv:(fun cpath -> [ "wc"; "-l"; cpath ])
                ~max_bytes:4096
                ~timeout_sec:Keeper_shell_timeout.read_timeout_sec
                ()
            with
            | Error response -> response
            | Ok (st, out) ->
              Yojson.Safe.to_string
                (Exec_core.process_result_json
                   ~artifact_policy:Exec_core.Inline_only
                   ~base_path:root
                   ~keeper_name:meta.name
                   ~cmd:"wc"
                   ~extra:
                     [
                       "op", `String op;
                       "cmd", `String "wc";
                       "cwd", `Null;
                       "path", `String target;
                       "via", `String Keeper_sandbox_read_runner.backend_via;
                     ]
                   ~status:st
                   ~output:out
                   ()))
         else
           let ir = Keeper_shell_ir.simple Masc_exec.Exec_program.Wc [ "-l"; target ] in
           run_host_shell_ir
             ~workdir:target
             ~cmd:"wc"
             ~path:target
             ir
             ~on_ok:(fun result ->
               render_completed_process_result ~root ~keeper_name:meta.name ~op
                 ~cmd:"wc"
                 result.status
                 (dispatch_result_output result)))
  | "tree" ->
    Some
      (match read_target () with
       | Error e -> path_error e
       | Ok target ->
         let limit = shell_readonly_limit args in
         if Keeper_sandbox_read_runner.should_route_read ~meta then
           (match
              run_readonly_in_sandbox ~target
                ~command_argv:(fun cpath ->
                  [ "find"; cpath; "-maxdepth"; "3"; "-print";
                    "-not"; "-path"; "*/.git/*";
                    "-not"; "-path"; "*/_build/*" ])
                ~max_bytes:1_000_000
                ~timeout_sec:Keeper_shell_timeout.read_timeout_sec
                ()
            with
            | Error response -> response
            | Ok (st, out) ->
              Yojson.Safe.to_string
                (`Assoc
                    [ "ok", `Bool true
                    ; "op", `String op
                    ; "path", `String target
                    ; "via", `String Keeper_sandbox_read_runner.backend_via
                    ; "status", Keeper_alerting_path.process_status_to_json st
                    ; "entries", lines_to_json ~limit out
                    ]))
         else
           let ir =
             Keeper_shell_ir.simple
               Masc_exec.Exec_program.Find
               [ target
               ; "-maxdepth"
               ; "3"
               ; "-print"
               ; "-not"
               ; "-path"
               ; "*/.git/*"
               ; "-not"
               ; "-path"
               ; "*/_build/*"
               ]
           in
           run_host_shell_ir
             ~workdir:target
             ~cmd:"find"
             ~path:target
             ir
             ~on_ok:(fun result ->
               let out = dispatch_result_output result in
               Yojson.Safe.to_string
                 (`Assoc
                     [ "ok", `Bool (result.status = Unix.WEXITED 0)
                     ; "op", `String op
                     ; "path", `String target
                     ; "via", `String "host"
                     ; "status", Keeper_alerting_path.process_status_to_json result.status
                     ; "entries", lines_to_json ~limit out
                     ])))
  | _ -> None
;;
