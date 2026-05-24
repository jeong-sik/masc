open Keeper_types
open Keeper_exec_shared

module Shell_gate = Masc_exec_command_gate.Shell_command_gate

(* RFC-0084 host-config-cleanup-C — coreutils path migration.
   Resolve the 6 absolute binary paths once at module-init time
   from the typed [Host_config.coreutils] field, then reference
   the bound names at each shell-op call-site.  Behaviour byte-
   identical today; a future PR can flip [host]
   to PATH-resolved binaries for portability without touching
   this module's call sites. *)
let coreutils = (Host_config.host ()).coreutils

(* Domain-owned Prometheus metric (RFC-0043 Phase 0): the metric name
   and registration live next to the bumper here rather than in the
   central prometheus.ml registry, keeping that file under the
   godfile-size-regression cap. *)
let metric_bash_history_append_failures =
  "masc_bash_history_append_failures_total"

let () =
  Prometheus.register_counter
    ~name:metric_bash_history_append_failures
    ~help:
      "Total bash-history audit append failures observed at \
       keeper_shell_ops. Bash_history.append returned Error (Sys_error \
       from open/write/close). Decoupled from tool-call success/failure. \
       No labels."
    ()

(* Bash_history.append now returns [Result] (audit-trail write
   decoupled from tool-call semantics). Centralise the swallow +
   observe at both call sites — Sys_error from open/write/close no
   longer surfaces as a keeper tool failure, but increments
   masc_bash_history_append_failures_total and emits a WARN with
   keeper/path/exn for correlation. *)
let observe_history_append ~root ~keeper_name entry =
  match Masc_exec.Bash_history.append ~base_path:root ~keeper_name entry with
  | Ok () -> ()
  | Error exn ->
      Prometheus.inc_counter
        metric_bash_history_append_failures ();
      Log.KeeperExec.warn
        "bash_history.append failed: keeper=%s base=%s exn=%s"
        keeper_name root (Printexc.to_string exn)
;;

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
    | _ -> raw_op
  in
  let root = Keeper_alerting_path.project_root_of_config config in
  let raw_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
  (* RFC-0006 Phase B-1.5: pin host-FS read guard for sandbox-backed
     keeper shell read ops. Host-backed keepers remain on the host path. *)
  let containment_check target =
    Keeper_sandbox_containment.check_read_target ~config ~meta ~target
  in
  let repo_check target =
    Keeper_repo_mapping.validate_path_access ~keeper_id:meta.name
      ~base_path:root ~path:target
  in
  let read_target () =
    match Keeper_shell_shared.resolve_keeper_shell_read_path ~config ~meta ~args with
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
    match Keeper_shell_shared.resolve_keeper_shell_read_cwd ~config ~meta ~args with
    | Error _ as e -> e
    | Ok cwd ->
      (match containment_check cwd with
       | Error msg -> Error msg
       | Ok () ->
         match repo_check cwd with
         | Error msg -> Error msg
         | Ok () -> Ok cwd)
  in
  (* Actionable error: Samchon/Claude Code validateInput pattern.
     Returns structured JSON with tried path, playground root, and concrete next action. *)
  let path_error e =
    actionable_path_error ~op ~meta ~raw_path ~error:e
  in
  let render_process_result ?cwd ~cmd argv =
    let st, out =
      Keeper_shell_shared.run_argv_with_status_retry_eintr ?cwd ~timeout_sec:Keeper_shell_shared.io_timeout_sec argv
    in
    (* P16: Record execution in history for failure pattern detection *)
    let success = st = Unix.WEXITED 0 in
    let cmd_prefix = Keeper_shell_command_semantics.cmd_prefix cmd in
    let entry = Masc_exec.Bash_history.{
      ts = Unix.time ();
      cmd_hash = Masc_exec.Bash_history.cmd_hash cmd;
      cmd_prefix;
      semantic_kind = op;
      duration_ms = 0;
      success;
    } in
    observe_history_append ~root ~keeper_name:meta.name entry;
    let insight_extra =
      let patterns = Masc_exec.Bash_history.failure_insight
        ~base_path:root ~keeper_name:meta.name
      in
      if patterns = [] then []
      else [
        "failure_insight", `List (
          List.map Masc_exec.Bash_history.failure_pattern_to_json patterns)
      ]
    in
    Yojson.Safe.to_string
      (Exec_core.process_result_json
         ~artifact_policy:Exec_core.Inline_only
         ~base_path:root
         ~keeper_name:meta.name
         ~cmd
         ~extra:
           ([
             "op", `String op;
             "cmd", `String cmd;
             ( "cwd",
               match cwd with
               | Some dir -> `String dir
               | None -> `Null );
             (* host execution path: route discriminator must be present so
                the dashboard / LLM cannot mistake a host-side run for a
                sandbox-backed run (#11080 sibling sweep). *)
             "via", `String "host";
           ] @ insight_extra)
         ~status:st
         ~output:out
         ())
  in
  let render_completed_process_result ?cwd ~cmd ?(extra = []) st out =
    (* P16: Record execution in history for failure pattern detection *)
    let success = st = Unix.WEXITED 0 in
    let cmd_prefix = Keeper_shell_command_semantics.cmd_prefix cmd in
    let elapsed_ms =
      List.find_map (fun (k, v) ->
        if k = "execution_time_ms" then
          match v with `Int n -> Some n | _ -> None
        else None) extra
      |> Option.value ~default:0
    in
    let entry = Masc_exec.Bash_history.{
      ts = Unix.time ();
      cmd_hash = Masc_exec.Bash_history.cmd_hash cmd;
      cmd_prefix;
      semantic_kind = op;
      duration_ms = elapsed_ms;
      success;
    } in
    observe_history_append ~root ~keeper_name:meta.name entry;
    let insight_extra =
      let patterns = Masc_exec.Bash_history.failure_insight
        ~base_path:root ~keeper_name:meta.name
      in
      if patterns = [] then []
      else [
        "failure_insight", `List (
          List.map Masc_exec.Bash_history.failure_pattern_to_json patterns)
      ]
    in
    (* Caller-supplied [extra] may already declare ["via"] (e.g. wc backend
       branch); only inject the default ["via", "host"] when absent so the
       backend route's explicit route label still wins. *)
    let extra_with_via =
      if List.exists (fun (k, _) -> k = "via") extra then extra
      else ("via", `String "host") :: extra
    in
    Yojson.Safe.to_string
      (Exec_core.process_result_json
         ~artifact_policy:Exec_core.Inline_only
         ~base_path:root
         ~keeper_name:meta.name
         ~cmd
         ~extra:([
             "op", `String op;
             "cmd", `String cmd;
             ( "cwd",
               match cwd with
               | Some dir -> `String dir
               | None -> `Null );
           ] @ extra_with_via @ insight_extra)
         ~status:st
         ~output:out
         ())
  in
  let sandbox_read_error ~target msg =
    error_json ~fields:[ "op", `String op; "path", `String target ] msg
  in
  let hostify_turn_runtime_output out =
    Keeper_shell_shared.rewrite_turn_runtime_paths_to_host ~config ~meta out
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
         render_completed_process_result ~cwd ~cmd ~extra st (map_output out))
    | None ->
      render_process_result ~cwd ~cmd command_argv
  in
  let render_sandbox_process_result ~cwd ~cmd ~backend_cmd ~timeout_sec =
    match
      Keeper_sandbox_runner.run_shell_command_with_status ~config ~meta ~cwd ~timeout_sec
        ~cmd:backend_cmd ~git_creds_enabled:false ~network_mode:Network_none
    with
    | Error msg -> error_json ~fields:[ "op", `String op; "cwd", `String cwd ] msg
    | Ok result ->
      (* PR #11080 sibling sweep: this helper always routes through the
         sandbox backend, so the LLM-facing [cwd] field must hold the
         in-container path.  Operator-side log fields above keep the
         host path. *)
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
    (match cwd_target () with
     | Error e -> path_error e
     | Ok cwd ->
       if Keeper_sandbox_read_runner.should_route_read ~meta then
         render_sandbox_process_result ~cwd ~cmd:"pwd" ~backend_cmd:"pwd"
           ~timeout_sec:Keeper_shell_shared.io_timeout_sec
       else
         run_in_turn_runtime ~cwd ~cmd:"pwd" ~command_argv:[ coreutils.pwd ]
           ~map_output:hostify_turn_runtime_output
           ~max_bytes:4096 ~timeout_sec:Keeper_shell_shared.io_timeout_sec ())
  | "git_status" ->
    (match cwd_target () with
     | Error e -> path_error e
     | Ok cwd ->
       if Keeper_sandbox_read_runner.should_route_read ~meta then
         render_sandbox_process_result ~cwd
           ~cmd:"git -C <cwd> --no-optional-locks status --short --branch"
           ~backend_cmd:"git --no-optional-locks status --short --branch"
           ~timeout_sec:Keeper_shell_shared.read_timeout_sec
       else
         (* P11: Host git_status via Shell IR pipeline.
            Preserves P16 Bash_history + failure_insight. *)
         let dispatch_sandbox = Masc_exec.Sandbox_target.host () in
         let cwd_scope = Masc_exec.Path_scope.classify ~raw:cwd ~cwd:root in
         let ir =
           Masc_exec.Shell_ir.Simple
             { bin = Masc_exec.Bin.of_known Masc_exec.Bin.Git
             ; args =
                 [ Masc_exec.Shell_ir.Lit ("--no-optional-locks", Masc_exec.Shell_ir.default_meta)
                 ; Masc_exec.Shell_ir.Lit ("status", Masc_exec.Shell_ir.default_meta)
                 ; Masc_exec.Shell_ir.Lit ("--short", Masc_exec.Shell_ir.default_meta)
                 ; Masc_exec.Shell_ir.Lit ("--branch", Masc_exec.Shell_ir.default_meta)
                 ]
             ; env = []
             ; cwd = Some cwd_scope
             ; redirects = []
             ; sandbox = dispatch_sandbox
             }
         in
         let envelope =
           Masc_exec.Shell_ir_risk.classify (Masc_exec.Shell_ir_risk.undecided ir)
         in
         let allowed_commands = Dev_exec_allowlist.dev in
         let gate_verdict =
           Shell_gate.gate_typed
             ~caller:Shell_gate.Keeper_shell_ir
             ~ir:envelope.Masc_exec.Shell_ir_risk.ir
             ~allowlist:{ allowed_commands; allow_pipes = true; redirect_allowed = true }
             ~path_policy:Shell_gate.allow_all_paths
             ~sandbox:{ target = dispatch_sandbox }
             ()
         in
         (match gate_verdict with
          | Reject { diagnostic; _ } ->
            error_json
              ~fields:[ "typed", `Bool true; "cmd", `String "git status"; "path", `String cwd ]
              diagnostic
          | Cannot_parse _ ->
            error_json
              ~fields:[ "typed", `Bool true; "cmd", `String "git status"; "path", `String cwd ]
              "Cannot parse command"
          | Too_complex _ ->
            error_json
              ~fields:[ "typed", `Bool true; "cmd", `String "git status"; "path", `String cwd ]
              "Command too complex"
          | Allow _context ->
            let path_validation =
              Exec_policy.validate_shell_ir_paths
                ~keeper_id:meta.name
                ~base_path:root
                ~workdir:cwd
                envelope.Masc_exec.Shell_ir_risk.ir
            in
            (match path_validation with
             | Error e -> error_json ~fields:[ "blocked_cmd", `String "git status" ] e
             | Ok () ->
               let result =
                 Masc_exec.Exec_dispatch.dispatch_decided envelope
               in
               render_completed_process_result ~cwd
                 ~cmd:"git --no-optional-locks status --short --branch"
                 ~extra:[]
                 result.status result.stdout
             )))
  | "ls" ->
    (match read_target () with
     | Error e -> path_error e
     | Ok target ->
       let limit = shell_readonly_limit args in
       (* RFC-0006 Phase B-3b: sandbox-backed keepers route ls through
          the same backend read prelude as keeper_fs_read so the backend
          mount is the load-bearing isolation. The host-side containment
          guard above remains as defense in depth. *)
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
                 ~timeout_sec:Keeper_shell_shared.io_timeout_sec
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
         (* P10: Host ls via Shell IR pipeline. Sandbox-backend read path
            preserved above because backend runner semantics (fresh vs reuse,
            container_path_of_host) differ from host dispatch. *)
         let dispatch_sandbox = Masc_exec.Sandbox_target.host () in
         let ir =
           Masc_exec.Shell_ir.Simple
             { bin = Masc_exec.Bin.of_known Masc_exec.Bin.Ls
             ; args =
                 [ Masc_exec.Shell_ir.Lit ("-la", Masc_exec.Shell_ir.default_meta)
                 ; Masc_exec.Shell_ir.Lit (target, Masc_exec.Shell_ir.default_meta)
                 ]
             ; env = []
             ; cwd = None
             ; redirects = []
             ; sandbox = dispatch_sandbox
             }
         in
         let envelope =
           Masc_exec.Shell_ir_risk.classify (Masc_exec.Shell_ir_risk.undecided ir)
         in
         let allowed_commands = Dev_exec_allowlist.readonly in
         let gate_verdict =
           Shell_gate.gate_typed
             ~caller:Shell_gate.Keeper_shell_ir
             ~ir:envelope.Masc_exec.Shell_ir_risk.ir
             ~allowlist:{ allowed_commands; allow_pipes = true; redirect_allowed = true }
             ~path_policy:Shell_gate.allow_all_paths
             ~sandbox:{ target = dispatch_sandbox }
             ()
         in
         (match gate_verdict with
          | Reject { diagnostic; _ } ->
            error_json
              ~fields:[ "typed", `Bool true; "cmd", `String "ls -la"; "path", `String target ]
              diagnostic
          | Cannot_parse _ ->
            error_json
              ~fields:[ "typed", `Bool true; "cmd", `String "ls -la"; "path", `String target ]
              "Cannot parse command"
          | Too_complex _ ->
            error_json
              ~fields:[ "typed", `Bool true; "cmd", `String "ls -la"; "path", `String target ]
              "Command too complex"
          | Allow _context ->
            let path_validation =
              Exec_policy.validate_shell_ir_paths
                ~keeper_id:meta.name
                ~base_path:root
                ~workdir:target
                envelope.Masc_exec.Shell_ir_risk.ir
            in
            (match path_validation with
             | Error e -> error_json ~fields:[ "blocked_cmd", `String "ls -la" ] e
             | Ok () ->
               let result =
                 Masc_exec.Exec_dispatch.dispatch_decided envelope
               in
               let output =
                 if String.equal result.stderr ""
                 then result.stdout
                 else result.stdout ^ result.stderr
               in
               render_completed_process_result
                 ~cmd:"ls -la"
                 ~extra:[
                   "path", `String target;
                   "entries", lines_to_json ~limit output;
                 ]
                 result.status output
             )))
     | "cat" ->
       (match read_target () with
        | Error e -> path_error e
        | Ok target ->
          let max_bytes = shell_readonly_cat_max_bytes args in
       (* RFC-0006 Phase B-3b: sandbox-backend route via the read-file helper.
          Symmetry with keeper_fs_read's backend response field. *)
       if Keeper_sandbox_read_runner.should_route_read ~meta then
         (match
            Keeper_sandbox_read_runner.read_file
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
                  ; "via", `String Keeper_sandbox_read_runner.backend_via
                  ; "bytes", `Int total
                  ; "truncated", `Bool truncated
                  ; "content", `String body
                  ]))
       else
         (* P11: Host cat via Shell IR pipeline. Backend read path preserved
            above per RFC-0006 Phase B-3b. *)
         let dispatch_sandbox = Masc_exec.Sandbox_target.host () in
         let ir =
           Masc_exec.Shell_ir.Simple
             { bin = Masc_exec.Bin.of_known Masc_exec.Bin.Cat
             ; args =
                 [ Masc_exec.Shell_ir.Lit (target, Masc_exec.Shell_ir.default_meta)
                 ]
             ; env = []
             ; cwd = None
             ; redirects = []
             ; sandbox = dispatch_sandbox
             }
         in
         let envelope =
           Masc_exec.Shell_ir_risk.classify (Masc_exec.Shell_ir_risk.undecided ir)
         in
         let allowed_commands = Dev_exec_allowlist.readonly in
         let gate_verdict =
           Shell_gate.gate_typed
             ~caller:Shell_gate.Keeper_shell_ir
             ~ir:envelope.Masc_exec.Shell_ir_risk.ir
             ~allowlist:{ allowed_commands; allow_pipes = true; redirect_allowed = true }
             ~path_policy:Shell_gate.allow_all_paths
             ~sandbox:{ target = dispatch_sandbox }
             ()
         in
         (match gate_verdict with
          | Reject { diagnostic; _ } ->
            error_json
              ~fields:[ "typed", `Bool true; "cmd", `String "cat"; "path", `String target ]
              diagnostic
          | Cannot_parse _ ->
            error_json
              ~fields:[ "typed", `Bool true; "cmd", `String "cat"; "path", `String target ]
              "Cannot parse command"
          | Too_complex _ ->
            error_json
              ~fields:[ "typed", `Bool true; "cmd", `String "cat"; "path", `String target ]
              "Command too complex"
          | Allow _context ->
            let path_validation =
              Exec_policy.validate_shell_ir_paths
                ~keeper_id:meta.name
                ~base_path:root
                ~workdir:target
                envelope.Masc_exec.Shell_ir_risk.ir
            in
            (match path_validation with
             | Error e -> error_json ~fields:[ "blocked_cmd", `String "cat" ] e
             | Ok () ->
               let result =
                 Masc_exec.Exec_dispatch.dispatch_decided envelope
               in
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
                     ]))))
  | "rg" ->
    let pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
    if pattern = ""
    then error_json ~fields:[ "op", `String op ] "pattern is required for rg. Good: pattern='handle_request'. Bad: pattern=''."
    else (
      match read_target () with
      | Error e -> path_error e
      | Ok target ->
        let limit = shell_readonly_limit args in
        (* Optional file-type filter (e.g. "ml", "py") *)
        let file_type = Safe_ops.json_string ~default:"" "type" args |> String.trim in
        (* Optional glob filter (e.g. "*.ml", "lib/**/*.ml") *)
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
               ~timeout_sec:Keeper_shell_shared.read_timeout_sec
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
          let rg_available = Keeper_shell_shared.shell_command_available "rg" in
          let grep_available = Keeper_shell_shared.shell_command_available "grep" in
          if not rg_available && not grep_available then
            path_error "rg executable not found, and grep fallback is unavailable"
          else if not rg_available && (file_type <> "" || glob <> "") then
            path_error "rg executable not found; grep fallback only supports pattern and path"
          else
            (* P11: Host rg via Shell IR pipeline (rg or grep fallback). *)
            let dispatch_sandbox = Masc_exec.Sandbox_target.host () in
            let bin_known, args =
              if rg_available then
                ( Masc_exec.Bin.Rg
                , [ Masc_exec.Shell_ir.Lit ("-n", Masc_exec.Shell_ir.default_meta)
                  ; Masc_exec.Shell_ir.Lit ("-m", Masc_exec.Shell_ir.default_meta)
                  ; Masc_exec.Shell_ir.Lit (string_of_int limit, Masc_exec.Shell_ir.default_meta)
                  ]
                  @ (if file_type <> "" then
                       [ Masc_exec.Shell_ir.Lit ("--type", Masc_exec.Shell_ir.default_meta)
                       ; Masc_exec.Shell_ir.Lit (file_type, Masc_exec.Shell_ir.default_meta)
                       ]
                     else [])
                  @ (if glob <> "" then
                       [ Masc_exec.Shell_ir.Lit ("--glob", Masc_exec.Shell_ir.default_meta)
                       ; Masc_exec.Shell_ir.Lit (glob, Masc_exec.Shell_ir.default_meta)
                       ]
                     else [])
                  @ [ Masc_exec.Shell_ir.Lit (pattern, Masc_exec.Shell_ir.default_meta)
                    ; Masc_exec.Shell_ir.Lit (target, Masc_exec.Shell_ir.default_meta)
                    ]
                )
              else
                ( Masc_exec.Bin.Grep
                , [ Masc_exec.Shell_ir.Lit ("-R", Masc_exec.Shell_ir.default_meta)
                  ; Masc_exec.Shell_ir.Lit ("-n", Masc_exec.Shell_ir.default_meta)
                  ; Masc_exec.Shell_ir.Lit ("-I", Masc_exec.Shell_ir.default_meta)
                  ; Masc_exec.Shell_ir.Lit ("-m", Masc_exec.Shell_ir.default_meta)
                  ; Masc_exec.Shell_ir.Lit (string_of_int limit, Masc_exec.Shell_ir.default_meta)
                  ; Masc_exec.Shell_ir.Lit ("--", Masc_exec.Shell_ir.default_meta)
                  ; Masc_exec.Shell_ir.Lit (pattern, Masc_exec.Shell_ir.default_meta)
                  ; Masc_exec.Shell_ir.Lit (target, Masc_exec.Shell_ir.default_meta)
                  ]
                )
            in
            let ir =
              Masc_exec.Shell_ir.Simple
                { bin = Masc_exec.Bin.of_known bin_known
                ; args
                ; env = []
                ; cwd = None
                ; redirects = []
                ; sandbox = dispatch_sandbox
                }
            in
            let envelope =
              Masc_exec.Shell_ir_risk.classify (Masc_exec.Shell_ir_risk.undecided ir)
            in
            let allowed_commands = Dev_exec_allowlist.readonly in
            let gate_verdict =
              Shell_gate.gate_typed
                ~caller:Shell_gate.Keeper_shell_ir
                ~ir:envelope.Masc_exec.Shell_ir_risk.ir
                ~allowlist:{ allowed_commands; allow_pipes = true; redirect_allowed = true }
                ~path_policy:Shell_gate.allow_all_paths
                ~sandbox:{ target = dispatch_sandbox }
                ()
            in
            (match gate_verdict with
             | Reject { diagnostic; _ } ->
               error_json
                 ~fields:[ "typed", `Bool true; "cmd", `String op; "path", `String target ]
                 diagnostic
             | Cannot_parse _ ->
               error_json
                 ~fields:[ "typed", `Bool true; "cmd", `String op; "path", `String target ]
                 "Cannot parse command"
             | Too_complex _ ->
               error_json
                 ~fields:[ "typed", `Bool true; "cmd", `String op; "path", `String target ]
                 "Command too complex"
             | Allow _context ->
               let path_validation =
                 Exec_policy.validate_shell_ir_paths
                   ~keeper_id:meta.name
                   ~base_path:root
                   ~workdir:target
                   envelope.Masc_exec.Shell_ir_risk.ir
               in
               (match path_validation with
                | Error e -> error_json ~fields:[ "blocked_cmd", `String op ] e
                | Ok () ->
                  let result =
                    Masc_exec.Exec_dispatch.dispatch_decided envelope
                  in
                  (* rg/grep exit codes: 0=matches found, 1=no matches (not an error), 2+=real error.
                     Treat exit 1 as success with empty results — "no match" is a valid answer. *)
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
              ~backend_cmd ~timeout_sec:Keeper_shell_shared.read_timeout_sec)
       else
         (match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
          | Some runtime ->
            let argv =
              let base_argv =
                [ "git"; "--no-optional-locks"; "log";
                  Printf.sprintf "--format=%s" format;
                  Printf.sprintf "-%d" count ]
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
                 ~timeout_sec:Keeper_shell_shared.read_timeout_sec ()
             with
             | Error msg ->
               error_json
                 ~fields:[ "op", `String op; "cwd", `String cwd ] msg
             | Ok (st, out) ->
               (* PR #11080 sibling sweep: backend-route response uses the
                  runtime cwd to keep the LLM aligned with the actual exec
                  environment. *)
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
            (* P11: Host git_log via Shell IR pipeline.
               Preserves P16 Bash_history + failure_insight. *)
            let dispatch_sandbox = Masc_exec.Sandbox_target.host () in
            let cwd_scope = Masc_exec.Path_scope.classify ~raw:cwd ~cwd:root in
            let base_args =
              [ Masc_exec.Shell_ir.Lit ("--no-optional-locks", Masc_exec.Shell_ir.default_meta)
              ; Masc_exec.Shell_ir.Lit ("log", Masc_exec.Shell_ir.default_meta)
              ; Masc_exec.Shell_ir.Lit (Printf.sprintf "--format=%s" format, Masc_exec.Shell_ir.default_meta)
              ; Masc_exec.Shell_ir.Lit (Printf.sprintf "-%d" count, Masc_exec.Shell_ir.default_meta)
              ]
            in
            let args_with_grep =
              if grep = "" then base_args
              else base_args @ [ Masc_exec.Shell_ir.Lit ("--grep=" ^ grep, Masc_exec.Shell_ir.default_meta) ]
            in
            let args =
              if file_path = "" then args_with_grep
              else
                args_with_grep
                @ [ Masc_exec.Shell_ir.Lit ("--", Masc_exec.Shell_ir.default_meta)
                  ; Masc_exec.Shell_ir.Lit (file_path, Masc_exec.Shell_ir.default_meta)
                  ]
            in
            let ir =
              Masc_exec.Shell_ir.Simple
                { bin = Masc_exec.Bin.of_known Masc_exec.Bin.Git
                ; args
                ; env = []
                ; cwd = Some cwd_scope
                ; redirects = []
                ; sandbox = dispatch_sandbox
                }
            in
            let envelope =
              Masc_exec.Shell_ir_risk.classify (Masc_exec.Shell_ir_risk.undecided ir)
            in
            let allowed_commands = Dev_exec_allowlist.dev in
            let gate_verdict =
              Shell_gate.gate_typed
                ~caller:Shell_gate.Keeper_shell_ir
                ~ir:envelope.Masc_exec.Shell_ir_risk.ir
                ~allowlist:{ allowed_commands; allow_pipes = true; redirect_allowed = true }
                ~path_policy:Shell_gate.allow_all_paths
                ~sandbox:{ target = dispatch_sandbox }
                ()
            in
            (match gate_verdict with
             | Reject { diagnostic; _ } ->
               error_json
                 ~fields:[ "typed", `Bool true; "cmd", `String "git log"; "path", `String cwd ]
                 diagnostic
             | Cannot_parse _ ->
               error_json
                 ~fields:[ "typed", `Bool true; "cmd", `String "git log"; "path", `String cwd ]
                 "Cannot parse command"
             | Too_complex _ ->
               error_json
                 ~fields:[ "typed", `Bool true; "cmd", `String "git log"; "path", `String cwd ]
                 "Command too complex"
             | Allow _context ->
               let path_validation =
                 Exec_policy.validate_shell_ir_paths
                   ~keeper_id:meta.name
                   ~base_path:root
                   ~workdir:cwd
                   envelope.Masc_exec.Shell_ir_risk.ir
               in
               (match path_validation with
                | Error e -> error_json ~fields:[ "blocked_cmd", `String "git log" ] e
                | Ok () ->
                  let result =
                    Masc_exec.Exec_dispatch.dispatch_decided envelope
                  in
                  render_completed_process_result ~cwd
                    ~cmd:"git --no-optional-locks log --format=<fmt> -<n>"
                    ~extra:[
                      "count", `Int count;
                      "grep", `String grep;
                    ]
                    result.status result.stdout
                ))))
  | "find" ->
    let name_pattern =
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
               ~timeout_sec:Keeper_shell_shared.read_timeout_sec
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
          let st, out =
            Keeper_shell_shared.run_argv_with_status_retry_eintr ~timeout_sec:Keeper_shell_shared.read_timeout_sec
              [ "find"; target; "-maxdepth"; "5"; "-name"; name_pattern;
                "-not"; "-path"; "*/.git/*";
                "-not"; "-path"; "*/_build/*";
                "-not"; "-path"; "*/.masc/*" ]
          in
          Yojson.Safe.to_string
            (`Assoc
                [ "ok", `Bool (st = Unix.WEXITED 0)
                ; "op", `String op
                ; "path", `String target
                ; "name", `String name_pattern
                ; "via", `String "host"
                ; "status", Keeper_alerting_path.process_status_to_json st
                ; "files", lines_to_json ~limit out
                ]))
  | "head" ->
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
              ~timeout_sec:Keeper_shell_shared.read_timeout_sec
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
         let st, out =
           Keeper_shell_shared.run_argv_with_status_retry_eintr ~timeout_sec:Keeper_shell_shared.read_timeout_sec
             [ coreutils.head; "-n"; string_of_int n; target ]
         in
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool (st = Unix.WEXITED 0)
               ; "op", `String op
               ; "path", `String target
               ; "lines", `Int n
               ; "via", `String "host"
               ; "status", Keeper_alerting_path.process_status_to_json st
               ; "content", `String out
               ]))
  | "tail" ->
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
              ~timeout_sec:Keeper_shell_shared.read_timeout_sec
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
         let st, out =
           Keeper_shell_shared.run_argv_with_status_retry_eintr ~timeout_sec:Keeper_shell_shared.read_timeout_sec
             [ coreutils.tail; "-n"; string_of_int n; target ]
         in
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool (st = Unix.WEXITED 0)
               ; "op", `String op
               ; "path", `String target
               ; "lines", `Int n
               ; "via", `String "host"
               ; "status", Keeper_alerting_path.process_status_to_json st
               ; "content", `String out
               ]))
  | "wc" ->
    (match read_target () with
     | Error e -> path_error e
     | Ok target ->
       if Keeper_sandbox_read_runner.should_route_read ~meta then
         (match
            run_readonly_in_sandbox ~target
              ~command_argv:(fun cpath -> [ "wc"; "-l"; cpath ])
              ~max_bytes:4096
              ~timeout_sec:Keeper_shell_shared.read_timeout_sec
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
         render_process_result ~cmd:"wc" [ coreutils.wc; "-l"; target ])
  | "tree" ->
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
              ~timeout_sec:Keeper_shell_shared.read_timeout_sec
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
         let st, out =
           Keeper_shell_shared.run_argv_with_status_retry_eintr ~timeout_sec:Keeper_shell_shared.read_timeout_sec
             [ "find"; target; "-maxdepth"; "3"; "-print";
               "-not"; "-path"; "*/.git/*";
               "-not"; "-path"; "*/_build/*" ]
         in
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool (st = Unix.WEXITED 0)
               ; "op", `String op
               ; "path", `String target
               ; "via", `String "host"
               ; "status", Keeper_alerting_path.process_status_to_json st
               ; "entries", lines_to_json ~limit out
               ]))
  | "git_diff" ->
    (match cwd_target () with
     | Error e -> path_error e
     | Ok cwd ->
       run_in_turn_runtime ~cwd ~cmd:"git diff --stat"
         ~command_argv:[ "git"; "--no-optional-locks"; "diff"; "--stat" ]
         ~max_bytes:1_000_000 ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
  | "git_worktree" ->
    let action =
      Safe_ops.json_string ~default:"list" "action" args
      |> String.trim |> String.lowercase_ascii
    in
    begin match action with
    | "list" ->
      (match cwd_target () with
       | Error e -> path_error e
       | Ok cwd ->
         run_in_turn_runtime ~cwd ~cmd:"git worktree list"
           ~map_output:hostify_turn_runtime_output
           ~command_argv:[ "git"; "worktree"; "list" ]
           ~max_bytes:1_000_000 ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
    | "add" ->
      let branch = Safe_ops.json_string ~default:"" "branch" args |> String.trim in
      let base = Safe_ops.json_string ~default:"origin/main" "base" args |> String.trim in
      if branch = "" then
        error_json ~fields:[ "op", `String op ]
          "branch is required. Good: action='add', branch='feature/my-task'. Bad: branch=''."
      else (
        match cwd_target () with
	        | Error e -> path_error e
	        | Ok cwd ->
	          let wt_out_result =
	            let _st, wt_out =
	              Keeper_shell_shared.run_argv_with_status_retry_eintr
	                ~timeout_sec:Keeper_shell_shared.git_meta_timeout_sec
	                [ "git"; "-C"; cwd; "worktree"; "list"; "--porcelain" ]
	            in
	            Ok wt_out
          in
          match wt_out_result with
          | Error msg ->
            error_json ~fields:[ "op", `String op; "cwd", `String cwd ] msg
          | Ok wt_out ->
          if String_util.contains_substring_ci wt_out branch then
            let existing_path =
              String.split_on_char '\n' wt_out
              |> List.find_map (fun line ->
                if String_util.contains_substring_ci line "worktree"
                   && String_util.contains_substring_ci wt_out branch
                then Some (String.trim line) else None)
              |> Option.value ~default:"(unknown)"
            in
            Yojson.Safe.to_string
              (`Assoc
                  [ "ok", `Bool false
                  ; "op", `String op
                  ; "error", `String "branch_already_in_worktree"
                  ; "branch", `String branch
                  ; "existing_worktree", `String existing_path
                  ; "hint", `String "Branch is already in a worktree. Use 'cd' to the existing path, or choose a different branch name."
                  ])
	          else
	            let wt_path = Printf.sprintf ".worktrees/%s"
	              (String.map (fun c -> if c = '/' then '-' else c) branch)
	            in
	            render_process_result ~cwd
	              ~cmd:(Printf.sprintf "git worktree add %s -b %s %s" wt_path branch base)
	              [ "git"; "worktree"; "add"; wt_path; "-b"; branch; base ]
	      )
    | other ->
      error_json ~fields:[ "op", `String op ]
        (Printf.sprintf "Unknown git_worktree action '%s'. Use: list, add." other)
    end
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
