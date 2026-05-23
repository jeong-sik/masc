open Keeper_types
open Keeper_exec_shared

(* RFC-0084 host-config-cleanup-C — coreutils path migration.
   Resolve the 6 absolute binary paths once at module-init time
   from the typed [Host_config.coreutils] field, then reference
   the bound names at each shell-op call-site.  Behaviour byte-
   identical today; a future PR can flip [host]
   to PATH-resolved binaries for portability without touching
   this module's call sites. *)
let coreutils = (Host_config.host ()).coreutils


let handle_keeper_shell
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~exec_cache:(_exec_cache : Masc_exec.Exec_cache.t option)
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let raw_op =
    Safe_ops.json_string ~default:"" "op" args |> String.trim |> String.lowercase_ascii
  in
  (* Normalize common aliases so the model's naming variation doesn't cause
     unsupported_op failures. *)
  let op = match raw_op with
    | "git status" | "status" -> "git_status"
    | "git log" -> "git_log"
    | "git diff" -> "git_diff"
    | "git worktree" | "worktree" -> "git_worktree"
    | "read" | "file" | "type" -> "cat"
    | "grep" | "search" -> "rg"
    | "dir" | "list" -> "ls"
    | "git clone" | "clone" -> "git_clone"
    | _ -> raw_op
  in
  let root = Keeper_alerting_path.project_root_of_config config in
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  (* RFC-0006 Phase B-1.5: pin host-FS read guard for Docker keeper
     shell read ops. Local keepers remain on the host path. *)
  (* Actionable error: Samchon/Claude Code validateInput pattern.
     Returns structured JSON with tried path, playground root, and concrete next action. *)
  let path_error e =
    actionable_path_error ~op ~meta ~raw_path ~error:e
  in
  match op with
  | "pwd" ->
    (match Keeper_shell_runtime.cwd_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok cwd ->
       Keeper_shell_runtime.run_cwd_op ~root ~keeper_name:meta.name ~op ~config ~meta
         ?turn_sandbox_factory ~cwd ~cmd:"pwd" ~docker_cmd:"pwd"
         ~command_argv:[ coreutils.pwd ]
         ~map_output:(Keeper_shell_runtime.hostify_turn_runtime_output ~config ~meta)
         ~max_bytes:4096 ~timeout_sec:Keeper_shell_shared.io_timeout_sec ())
  | "git_status" ->
    (match Keeper_shell_runtime.cwd_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok cwd ->
       Keeper_shell_runtime.run_cwd_op ~root ~keeper_name:meta.name ~op ~config ~meta
         ?turn_sandbox_factory ~cwd
         ~cmd:"git -C <cwd> --no-optional-locks status --short --branch"
         ~docker_cmd:"git --no-optional-locks status --short --branch"
         ~command_argv:[ "git"; "--no-optional-locks"; "status"; "--short"; "--branch" ]
         ~max_bytes:1_000_000
         ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
  | "ls" ->
    (match Keeper_shell_runtime.read_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok target ->
       let limit = shell_readonly_limit args in
       match
         Keeper_shell_runtime.run_readonly_op ~config ~meta ?turn_sandbox_factory
           ~op ~target
           ~host_argv:[ coreutils.ls; "-la"; target ]
           ~docker_argv:(fun cpath -> [ "ls"; "-la"; cpath ])
           ~max_bytes:1_000_000
           ~timeout_sec:Keeper_shell_shared.io_timeout_sec ()
       with
       | Error response -> response
       | Ok (via, st, out) ->
         let fields =
           Keeper_shell_runtime.readonly_json_fields ~op ~path:target ~via
             ~status:st ~output_field:"entries" ~output:(lines_to_json ~limit out)
             ()
         in
         Keeper_shell_runtime.readonly_json_string fields)
  | "cat" ->
    (match Keeper_shell_runtime.read_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok target ->
       let max_bytes = shell_readonly_cat_max_bytes args in
       (* RFC-0006 Phase B-3b: docker route via the existing
          read_file_in_container helper (which is already a [cat]
          wrapper around run_command_in_container). Symmetry with
          keeper_fs_read's [via: "docker"] response field. *)
       if Keeper_docker_read.should_route_read ~meta then
         (match
            Keeper_docker_read.read_file_in_container
              ?turn_sandbox_factory ~config ~meta
              ~host_path:target ~max_bytes
              ~timeout_sec:Keeper_shell_shared.read_timeout_sec
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
                  ; "via", `String "docker"
                  ; "bytes", `Int total
                  ; "truncated", `Bool truncated
                  ; "content", `String body
                  ]))
       else
         let st, out =
           Keeper_shell_shared.run_argv_with_status_retry_eintr
             ~timeout_sec:Keeper_shell_shared.read_timeout_sec
             [ coreutils.cat; target ]
         in
         let body =
           if String.length out > max_bytes then String.sub out 0 max_bytes else out
         in
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool (st = Unix.WEXITED 0)
               ; "op", `String op
               ; "path", `String target
               ; "via", `String "host"
               ; "status", Keeper_alerting_path.process_status_to_json st
               ; "truncated", `Bool (String.length out > max_bytes)
               ; "content", `String body
               ]))
  | "rg" ->
    Keeper_shell_rg.handle ~op ~meta ~config ~args ?turn_sandbox_factory ~root ~raw_path
  | "git_log" ->
    (match Keeper_shell_runtime.cwd_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok cwd ->
       let count = max 1 (min 50 (Safe_ops.json_int ~default:10 "count" args)) in
       let format = Safe_ops.json_string ~default:"%h %s" "format" args in
       let file_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
       let grep = Safe_ops.json_string ~default:"" "grep" args |> String.trim in
       if Keeper_docker_read.should_route_read ~meta then
         (match Keeper_shell_runtime.docker_git_log_path ~config ~meta file_path with
          | Error err ->
            error_json
              ~fields:
                [ "op", `String op; "cwd", `String cwd; "path", `String file_path ]
              err
          | Ok docker_file_path ->
            let docker_cmd =
              let base =
                Printf.sprintf "git --no-optional-locks log --format=%s -%d%s"
                  (Filename.quote format) count
                  (if grep = "" then "" else " --grep=" ^ Filename.quote grep)
              in
              if docker_file_path = "" then
                base
              else
                Printf.sprintf "%s -- %s" base (Filename.quote docker_file_path)
            in
            Keeper_shell_runtime.render_docker_process_result ~root ~keeper_name:meta.name ~op ~config ~meta ~cwd
              ~cmd:"git -C <cwd> --no-optional-locks log --format=<fmt> -<n>"
              ~docker_cmd ~timeout_sec:Keeper_shell_shared.read_timeout_sec)
       else
         let argv = [ "git"; "-C"; cwd ] @ Keeper_shell_runtime.git_log_argv_core ~format ~count ~grep ~file_path () in
         (match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
          | Some runtime ->
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
                let argv = Keeper_shell_runtime.git_log_argv_core ~format ~count ~grep ~file_path:runtime_path () in
            (match
               Keeper_turn_sandbox_runtime.run_command_with_status runtime
                 ~cwd ~command_argv:argv
                 ~ok_exit_codes:[ 0 ]
                 ~max_bytes:1_000_000
                 ~timeout_sec:Keeper_shell_shared.read_timeout_sec ()
             with
             | Error msg ->
               error_json
                 ~fields:[ "op", `String op; "cwd", `String cwd ] msg
             | Ok (st, out) ->
               (* PR #11080 sibling sweep: docker-route response — use
                  the in-container cwd to keep the LLM aligned with the
                  actual exec environment. *)
               let cwd_response =
                 Keeper_cwd_response.docker ~host_cwd:cwd
                   ~container_cwd:
                     (Keeper_turn_sandbox_runtime.container_cwd_of_host
                        runtime ~host_cwd:cwd)
               in
               let json =
                 Keeper_shell_runtime.git_log_response_json
                   ~ok:true ~op
                   ~cwd:(Keeper_cwd_response.to_yojson_response cwd_response)
                   ~count ~grep ~via:"docker" ~status:st
                   ~output:out ~limit:50
               in
               Yojson.Safe.to_string json)
          | None ->
            let st, out =
              Masc_exec.Exec_gate.run_argv_with_status ~actor:`Keeper_shell
                ~raw_source:(String.concat " " argv)
                ~summary:"keeper shell op"
                ~timeout_sec:Keeper_shell_shared.read_timeout_sec argv
            in
            let json =
              Keeper_shell_runtime.git_log_response_json
                ~ok:(st = Unix.WEXITED 0) ~op ~cwd:(`String cwd)
                ~count ~grep ~status:st
                ~output:out ~limit:50
            in
            Yojson.Safe.to_string json))
  | "find" ->
    Keeper_shell_find.handle ~op ~meta ~config ~args ?turn_sandbox_factory ~root ~raw_path
  | "head" | "tail" ->
    (match Keeper_shell_runtime.read_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok target ->
       let n = max 1 (min 200 (Safe_ops.json_int ~default:20 "lines" args)) in
       let coreutil = if op = "head" then coreutils.head else coreutils.tail in
       match
         Keeper_shell_runtime.run_readonly_op ~config ~meta ?turn_sandbox_factory
           ~op ~target
           ~host_argv:[ coreutil; "-n"; string_of_int n; target ]
           ~docker_argv:(fun cpath -> [ coreutil; "-n"; string_of_int n; cpath ])
           ~max_bytes:1_000_000
           ~timeout_sec:Keeper_shell_shared.read_timeout_sec ()
       with
       | Error response -> response
       | Ok (via, st, out) ->
         let fields =
           Keeper_shell_runtime.readonly_json_fields ~op ~path:target ~via
             ~status:st ~output_field:"content" ~output:(`String out)
             ~extra:[ "lines", `Int n ]
             ()
         in
         Keeper_shell_runtime.readonly_json_string fields)
  | "wc" ->
    (match Keeper_shell_runtime.read_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok target ->
       match
         Keeper_shell_runtime.run_readonly_op ~config ~meta ?turn_sandbox_factory
           ~op ~target
           ~host_argv:[ coreutils.wc; "-l"; target ]
           ~docker_argv:(fun cpath -> [ "wc"; "-l"; cpath ])
           ~max_bytes:4096
           ~timeout_sec:Keeper_shell_shared.read_timeout_sec ()
       with
       | Error response -> response
       | Ok (via, st, out) ->
         Keeper_shell_runtime.render_completed_process_result ~root ~keeper_name:meta.name ~op
           ~cmd:"wc" ~extra:[ "path", `String target; "via", `String via ] st out)
  | "tree" ->
    (match Keeper_shell_runtime.read_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok target ->
       let limit = shell_readonly_limit args in
       let tree_base path =
         [ "find"; path; "-maxdepth"; "3"; "-print";
           "-not"; "-path"; "*/.git/*";
           "-not"; "-path"; "*/_build/*" ]
       in
       let docker_argv cpath = tree_base cpath in
       let host_argv = tree_base target in
       match
         Keeper_shell_runtime.run_readonly_op ~config ~meta ?turn_sandbox_factory
           ~op ~target ~host_argv ~docker_argv
           ~max_bytes:1_000_000
           ~timeout_sec:Keeper_shell_shared.read_timeout_sec ()
       with
       | Error response -> response
       | Ok (via, st, out) ->
         let fields =
           Keeper_shell_runtime.readonly_json_fields ~op ~path:target ~via
             ~status:st ~output_field:"entries" ~output:(lines_to_json ~limit out)
             ()
         in
         Keeper_shell_runtime.readonly_json_string fields)
  | "git_diff" ->
    (match Keeper_shell_runtime.cwd_target ~config ~meta ~args ~root with
     | Error e -> path_error e
     | Ok cwd ->
       Keeper_shell_runtime.run_cwd_op ~root ~keeper_name:meta.name ~op ~config ~meta
         ?turn_sandbox_factory ~cwd ~cmd:"git diff --stat"
         ~docker_cmd:"git --no-optional-locks diff --stat"
         ~command_argv:[ "git"; "--no-optional-locks"; "diff"; "--stat" ]
         ~max_bytes:1_000_000 ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
  | "git_worktree" ->
    Keeper_shell_git_worktree.handle ~op ~meta ~config ~args ?turn_sandbox_factory
      ~root ~raw_path
  | "git_clone" ->
    Keeper_shell_clone.handle ~op ~meta ~config ~args
  | "gh" ->
    Keeper_shell_gh.handle ~op ~meta ~config ~args
  | _ ->
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool false
          ; "error", `String "unsupported_op"
          ; "op", `String op
          ; ( "supported_ops"
              (* Issue #8524: derive from Variant SSOT instead of a
                 hand-rolled duplicate. *)
            , `List
                (List.map
                   (fun name -> `String name)
                   Keeper_shell_shared.valid_shell_op_strings) )
          ])
;;
