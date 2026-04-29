open Keeper_types
open Keeper_exec_shared

let split_once_on_substring s sep =
  let len = String.length s in
  let sep_len = String.length sep in
  if sep_len = 0 then None
  else
    let rec loop i =
      if i + sep_len > len then None
      else if String.sub s i sep_len = sep then
        Some
          ( String.sub s 0 i,
            String.sub s (i + sep_len) (len - i - sep_len) )
      else loop (i + 1)
    in
    loop 0

let split_shell_chain_for_retry cmd =
  let rec split_all sep acc s =
    match split_once_on_substring s sep with
    | None -> List.rev (String.trim s :: acc)
    | Some (left, right) -> split_all sep (String.trim left :: acc) right
  in
  let commands =
    if String_util.contains_substring cmd "&&" then split_all "&&" [] cmd
    else if String_util.contains_substring cmd "||" then split_all "||" [] cmd
    else if String_util.contains_substring cmd ";" then split_all ";" [] cmd
    else [ cmd ]
  in
  let commands = List.filter (fun s -> String.trim s <> "") commands in
  match commands with
  | _ :: _ :: _ when List.length commands <= 8 -> Some commands
  | _ -> None

let readonly_chain_rewrite_extra ~category cmd =
  if not (String.equal category "chaining") then []
  else
    match split_shell_chain_for_retry cmd with
    | None -> []
    | Some commands ->
        [
          "rewrite_kind", `String "split_shell_chain";
          ( "rewrite_hint",
            `String
              "Retry each split command as a separate keeper_shell op=bash call in order; keep the same cwd." );
          "split_commands", `List (List.map (fun c -> `String c) commands);
          ( "suggested_calls",
            `List
              (List.map
                 (fun c ->
                   `Assoc [ "op", `String "bash"; "cmd", `String c ])
                 commands) );
        ]

let handle_keeper_shell
      ~(turn_sandbox_factory : Keeper_sandbox_factory.t option)
      ~(exec_cache : Masc_exec.Exec_cache.t option)
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
  let containment_check target =
    Keeper_sandbox_containment.check_read_target ~config ~meta ~target
  in
  let read_target () =
    match Keeper_shell_shared.resolve_keeper_shell_read_path ~config ~meta ~args with
    | Error _ as e -> e
    | Ok target ->
      (match containment_check target with
       | Ok () -> Ok target
       | Error msg -> Error msg)
  in
  let cwd_target () =
    match Keeper_shell_shared.resolve_keeper_shell_read_cwd ~config ~meta ~args with
    | Error _ as e -> e
    | Ok cwd ->
      (match containment_check cwd with
       | Ok () -> Ok cwd
       | Error msg -> Error msg)
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
    let cmd_prefix =
      match String.split_on_char ' ' cmd with
      | [] -> cmd | w :: _ -> w
    in
    let entry = Masc_exec.Bash_history.{
      ts = Unix.time ();
      cmd_hash = Masc_exec.Bash_history.cmd_hash cmd;
      cmd_prefix;
      semantic_kind = op;
      duration_ms = 0;
      success;
    } in
    Masc_exec.Bash_history.append ~base_path:root ~keeper_name:meta.name entry;
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
                docker-sandboxed run (#11080 sibling sweep). *)
             "via", `String "host";
           ] @ insight_extra)
         ~status:st
         ~output:out
         ())
  in
  let render_completed_process_result ?cwd ~cmd ?(extra = []) st out =
    (* P16: Record execution in history for failure pattern detection *)
    let success = st = Unix.WEXITED 0 in
    let cmd_prefix =
      match String.split_on_char ' ' cmd with
      | [] -> cmd | w :: _ -> w
    in
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
    Masc_exec.Bash_history.append ~base_path:root ~keeper_name:meta.name entry;
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
    (* Caller-supplied [extra] may already declare ["via"] (e.g. wc docker
       branch); only inject the default ["via", "host"] when absent so the
       docker route's explicit ["via", "docker"] still wins. *)
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
  let docker_read_error ~target msg =
    error_json ~fields:[ "op", `String op; "path", `String target ] msg
  in
  let hostify_turn_runtime_output out =
    Keeper_shell_shared.rewrite_turn_runtime_paths_to_host ~config ~meta out
  in
  let run_readonly_in_docker ?(ok_exit_codes = [ 0 ]) ~target ~command_argv
      ~max_bytes ~timeout_sec () =
    let max_eintr_retries = 8 in
    let rec loop attempts_left =
      match
        Keeper_docker_read.container_path_of_host ~config ~meta ~host_path:target
      with
      | Error e -> Error (docker_read_error ~target e)
      | Ok cpath -> (
          match
            Keeper_docker_read.run_command_in_container_with_status
              ?turn_sandbox_factory
              ~ok_exit_codes ~config ~meta ~command_argv:(command_argv cpath)
              ~max_bytes ~timeout_sec ()
          with
          | Error msg
            when attempts_left > 0
                 && String_util.contains_substring_ci msg
                      "interrupted system call" ->
              loop (attempts_left - 1)
          | Error msg -> Error (docker_read_error ~target msg)
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
  let render_docker_process_result ~cwd ~cmd ~docker_cmd ~timeout_sec =
    match
      Keeper_shell_shared.run_docker_shell_command_with_status ~config ~meta ~cwd ~timeout_sec
        ~cmd:docker_cmd ~git_creds_enabled:false ~network_mode:Network_none
    with
    | Error msg -> error_json ~fields:[ "op", `String op; "cwd", `String cwd ] msg
    | Ok result ->
      (* PR #11080 sibling sweep: this helper always routes through
         docker exec, so the LLM-facing [cwd] field must hold the
         in-container path.  Operator-side log fields above keep the
         host path. *)
      let cwd_response =
        Keeper_cwd_response.docker ~host_cwd:cwd
          ~container_cwd:
            (Keeper_shell_docker.docker_private_workspace_cwd ~config
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
               "via", `String "docker";
             ]
           ~status:result.status
           ~output:result.output
           ())
  in
  let docker_git_log_path host_path =
    if String.trim host_path = "" then Ok ""
    else if Filename.is_relative host_path then Ok host_path
    else
      Keeper_docker_read.container_path_of_host ~config ~meta ~host_path
  in
  if Env_config_keeper.KeeperSandbox.hard_mode ()
     && meta.sandbox_profile <> Docker
  then
    error_json
      ~fields:[ "op", `String op ]
      "MASC_KEEPER_SANDBOX_HARD_MODE requires sandbox_profile=docker"
  else
  match op with
  | "pwd" ->
    (match cwd_target () with
     | Error e -> path_error e
     | Ok cwd ->
       if Keeper_docker_read.should_route_read ~meta then
         render_docker_process_result ~cwd ~cmd:"pwd" ~docker_cmd:"pwd"
           ~timeout_sec:Keeper_shell_shared.io_timeout_sec
       else
         run_in_turn_runtime ~cwd ~cmd:"pwd" ~command_argv:[ "/bin/pwd" ]
           ~map_output:hostify_turn_runtime_output
           ~max_bytes:4096 ~timeout_sec:Keeper_shell_shared.io_timeout_sec ())
  | "git_status" ->
    (match cwd_target () with
     | Error e -> path_error e
     | Ok cwd ->
       if Keeper_docker_read.should_route_read ~meta then
         render_docker_process_result ~cwd
           ~cmd:"git -C <cwd> --no-optional-locks status --short --branch"
           ~docker_cmd:"git --no-optional-locks status --short --branch"
           ~timeout_sec:Keeper_shell_shared.read_timeout_sec
       else
         run_in_turn_runtime ~cwd
           ~cmd:"git --no-optional-locks status --short --branch"
           ~command_argv:
             [ "git"; "--no-optional-locks"; "status"; "--short"; "--branch" ]
           ~max_bytes:1_000_000
           ~timeout_sec:Keeper_shell_shared.read_timeout_sec ())
  | "ls" ->
    (match read_target () with
     | Error e -> path_error e
     | Ok target ->
       let limit = shell_readonly_limit args in
       (* RFC-0006 Phase B-3b: Docker keepers route ls through the same
          docker prelude as keeper_fs_read so the container's mount is
          the load-bearing isolation. The host-side containment guard
          above remains as defense in depth. *)
       if Keeper_docker_read.should_route_read ~meta then
         (match
            Keeper_docker_read.container_path_of_host ~config ~meta
              ~host_path:target
          with
          | Error e ->
            error_json
              ~fields:[ "op", `String op; "path", `String target ] e
          | Ok cpath ->
            (match
               Keeper_docker_read.run_command_in_container
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
                     ; "via", `String "docker"
                     ; "entries", lines_to_json ~limit out
                     ])))
        else
          let st, out =
           Keeper_shell_shared.run_argv_with_status_retry_eintr
             ~timeout_sec:Keeper_shell_shared.io_timeout_sec
             [ "/bin/ls"; "-la"; target ]
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
  | "cat" ->
    (match read_target () with
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
             [ "/bin/cat"; target ]
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
        if Keeper_docker_read.should_route_read ~meta then
          let base_argv = [ "rg"; "-n"; "-m"; string_of_int limit ] in
          let type_argv = if file_type <> "" then [ "--type"; file_type ] else [] in
          let glob_argv = if glob <> "" then [ "--glob"; glob ] else [] in
          (match
             run_readonly_in_docker ~target
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
                   ; "via", `String "docker"
                   ; "status", Keeper_alerting_path.process_status_to_json st
                   ; "matches", lines_to_json ~limit out
                   ]))
        else
          let rg_available = Keeper_shell_shared.shell_command_available "rg" in
          let grep_available = Keeper_shell_shared.shell_command_available "grep" in
          let argv =
            if rg_available then
              let base_argv = [ "rg"; "-n"; "-m"; string_of_int limit ] in
              let type_argv = if file_type <> "" then [ "--type"; file_type ] else [] in
              let glob_argv = if glob <> "" then [ "--glob"; glob ] else [] in
              Ok (base_argv @ type_argv @ glob_argv @ [ pattern; target ])
            else if not grep_available then
              Error "rg executable not found, and grep fallback is unavailable"
            else if file_type <> "" || glob <> "" then
              Error
                "rg executable not found; grep fallback only supports pattern and path"
            else
              (* Keep readonly rg usable in lean CI images that do not ship ripgrep. *)
              Ok
                [ "grep"; "-R"; "-n"; "-I"; "-m"; string_of_int limit; "--"; pattern; target ]
          in
          match argv with
          | Error e -> path_error e
          | Ok argv ->
            let st, out =
              Keeper_shell_shared.run_argv_with_status_retry_eintr ~timeout_sec:Keeper_shell_shared.read_timeout_sec argv
            in
            (* rg exit codes: 0=matches found, 1=no matches (not an error), 2+=real error.
               Treat exit 1 as success with empty results — "no match" is a valid answer. *)
            let is_ok = st = Unix.WEXITED 0 || st = Unix.WEXITED 1 in
            Yojson.Safe.to_string
              (`Assoc
                  [ "ok", `Bool is_ok
                  ; "op", `String op
                  ; "path", `String target
                  ; "pattern", `String pattern
                  ; "via", `String "host"
                  ; "status", Keeper_alerting_path.process_status_to_json st
                  ; "matches", lines_to_json ~limit out
                  ]))
  | "git_log" ->
    (match cwd_target () with
     | Error e -> path_error e
     | Ok cwd ->
       let count = max 1 (min 50 (Safe_ops.json_int ~default:10 "count" args)) in
       let format = Safe_ops.json_string ~default:"%h %s" "format" args in
       let file_path = Safe_ops.json_string ~default:"" "path" args |> String.trim in
       if Keeper_docker_read.should_route_read ~meta then
         (match docker_git_log_path file_path with
          | Error err ->
            error_json
              ~fields:[ "op", `String op; "cwd", `String cwd; "path", `String file_path ]
              err
          | Ok docker_file_path ->
            let docker_cmd =
              let base =
                Printf.sprintf "git --no-optional-locks log --format=%s -%d"
                  (Filename.quote format) count
              in
              if docker_file_path = "" then
                base
              else
                Printf.sprintf "%s -- %s" base (Filename.quote docker_file_path)
            in
            render_docker_process_result ~cwd
              ~cmd:"git -C <cwd> --no-optional-locks log --format=<fmt> -<n>"
              ~docker_cmd ~timeout_sec:Keeper_shell_shared.read_timeout_sec)
       else
         let base_argv =
           [ "git"; "-C"; cwd; "--no-optional-locks"; "log";
             Printf.sprintf "--format=%s" format;
             Printf.sprintf "-%d" count ]
         in
         let argv = if file_path <> "" then base_argv @ [ "--"; file_path ] else base_argv in
         (match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
          | Some runtime ->
            let argv =
              let base_argv =
                [ "git"; "--no-optional-locks"; "log";
                  Printf.sprintf "--format=%s" format;
                  Printf.sprintf "-%d" count ]
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
               (* PR #11080 sibling sweep: docker-route response — use
                  the in-container cwd to keep the LLM aligned with the
                  actual exec environment. *)
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
                     ; "via", `String "docker"
                     ; "status", Keeper_alerting_path.process_status_to_json st
                     ; "entries", lines_to_json ~limit:50 out
                     ]))
          | None ->
            let st, out =
              Process_eio.run_argv_with_status ~timeout_sec:Keeper_shell_shared.read_timeout_sec argv
            in
            Yojson.Safe.to_string
              (`Assoc
                  [ "ok", `Bool (st = Unix.WEXITED 0)
                  ; "op", `String op
                  ; "cwd", `String cwd
                  ; "count", `Int count
                  ; "status", Keeper_alerting_path.process_status_to_json st
                  ; "entries", lines_to_json ~limit:50 out
                  ])))
  | "find" ->
    let name_pattern = Safe_ops.json_string ~default:"" "pattern" args |> String.trim in
    if name_pattern = ""
    then error_json ~fields:[ "op", `String op ] "pattern is required for find. Good: pattern='*.ml'. Bad: pattern=''."
    else (
      match read_target () with
      | Error e -> path_error e
      | Ok target ->
        let limit = shell_readonly_limit args in
        if Keeper_docker_read.should_route_read ~meta then
          (match
             run_readonly_in_docker ~target
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
                   ; "via", `String "docker"
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
       if Keeper_docker_read.should_route_read ~meta then
         (match
            run_readonly_in_docker ~target
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
                  ; "via", `String "docker"
                  ; "status", Keeper_alerting_path.process_status_to_json st
                  ; "content", `String out
                  ]))
       else
         let st, out =
           Keeper_shell_shared.run_argv_with_status_retry_eintr ~timeout_sec:Keeper_shell_shared.read_timeout_sec
             [ "/usr/bin/head"; "-n"; string_of_int n; target ]
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
       if Keeper_docker_read.should_route_read ~meta then
         (match
            run_readonly_in_docker ~target
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
                  ; "via", `String "docker"
                  ; "status", Keeper_alerting_path.process_status_to_json st
                  ; "content", `String out
                  ]))
       else
         let st, out =
           Keeper_shell_shared.run_argv_with_status_retry_eintr ~timeout_sec:Keeper_shell_shared.read_timeout_sec
             [ "/usr/bin/tail"; "-n"; string_of_int n; target ]
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
       if Keeper_docker_read.should_route_read ~meta then
         (match
            run_readonly_in_docker ~target
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
                     "via", `String "docker";
                   ]
                 ~status:st
                 ~output:out
                 ()))
       else
         render_process_result ~cmd:"wc" [ "/usr/bin/wc"; "-l"; target ])
  | "tree" ->
    (match read_target () with
     | Error e -> path_error e
     | Ok target ->
       let limit = shell_readonly_limit args in
       if Keeper_docker_read.should_route_read ~meta then
         (match
            run_readonly_in_docker ~target
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
                   ; "via", `String "docker"
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
            match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
            | Some runtime ->
              Keeper_turn_sandbox_runtime.run_command runtime
                ~cwd
                ~command_argv:[ "git"; "worktree"; "list"; "--porcelain" ]
                ~max_bytes:1_000_000
                ~timeout_sec:Keeper_shell_shared.git_meta_timeout_sec ()
            | None ->
              let _st, wt_out =
                Keeper_shell_shared.run_argv_with_status_retry_eintr ~timeout_sec:Keeper_shell_shared.git_meta_timeout_sec
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
            run_in_turn_runtime ~cwd
              ~cmd:(Printf.sprintf "git worktree add %s -b %s %s" wt_path branch base)
              ~command_argv:[ "git"; "worktree"; "add"; wt_path; "-b"; branch; base ]
              ~max_bytes:1_000_000
              ~timeout_sec:Keeper_shell_shared.io_timeout_sec ()
      )
    | other ->
      error_json ~fields:[ "op", `String op ]
        (Printf.sprintf "Unknown git_worktree action '%s'. Use: list, add." other)
    end
  | "bash" ->
    let cmd_str = Safe_ops.json_string ~default:"" "command" args |> String.trim in
    let timeout_sec = Keeper_shell_shared.clamp_shell_timeout ~default:Keeper_shell_shared.io_timeout_sec args in
    if cmd_str = "" then error_json ~fields:[ "op", `String op ] "command is required for bash op. Good: command='env'. Bad: command=''."

    else
      (* Non-overridable deny layer (runs after preset gate).
         First match wins — specific patterns before generic. *)
      let substring_rules =
        [ (* chaining *)
          "&&", "chaining"
        ; "||", "chaining"
        ; ";", "chaining"
        (* redirect *)
        ; "| tee ", "redirect"
        ; ">> ", "redirect"
        ; "> ", "redirect"
        ]
      in
      let matched =
        match List.find_opt (fun (pat, _cat) ->
          String_util.contains_substring_ci cmd_str pat
        ) substring_rules with
        | Some (pat, category) -> Some (pat, category)
        | None -> Keeper_shell_shared.readonly_shell_token_match (Keeper_shell_shared.lowercase_shell_words cmd_str)
      in
      (match matched with
      | Some (pat, category) ->
        let hint = Keeper_shell_shared.readonly_hint_of_category category in
        Yojson.Safe.to_string
          (Exec_core.blocked_result_json
             ~cmd:cmd_str
             ~error:"command_blocked_readonly"
             ~reason:
               (Printf.sprintf
                  "Readonly shell blocked pattern '%s' in category '%s'."
                  pat category)
             ~hint
             ~diag:(Keeper_shell_shared.diagnosis_of_readonly_category category)
             ~extra:
               ([
                  "op", `String op;
                  "blocked_pattern", `String pat;
                  "category", `String category;
                ]
                @ readonly_chain_rewrite_extra ~category cmd_str)
             ())
      | None ->
        (match cwd_target () with
         | Error e -> path_error e
         | Ok cwd ->
           (match Worker_dev_tools.validate_command_paths ~workdir:cwd cmd_str with
            | Error e -> path_error e
            | Ok () ->
              (* PR #11080 sibling sweep: when [turn_sandbox_factory]
                 is bound the bash exec runs inside the keeper's
                 container, so the LLM-facing [cwd] field must hold
                 the in-container path.  When the runtime is absent
                 (Local-effective keepers) the host path is what the
                 keeper sees and the [Local] variant passes it
                 through unchanged. *)
              let cwd_response =
                match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
                | Some runtime ->
                  Keeper_cwd_response.docker ~host_cwd:cwd
                    ~container_cwd:
                      (Keeper_turn_sandbox_runtime.container_cwd_of_host
                         runtime ~host_cwd:cwd)
                | None ->
                  Keeper_cwd_response.local ~host_cwd:cwd
              in
              let cwd_field =
                Keeper_cwd_response.to_yojson_response cwd_response
              in
              (* P21: exec cache — skip execution on hit, store on miss *)
              (match exec_cache with
               | Some cache ->
                 (match Masc_exec.Exec_cache.lookup cache cmd_str with
                  | Some entry ->
                    let st = Unix.WEXITED entry.exit_code in
                    Yojson.Safe.to_string
                      (Exec_core.process_result_json
                         ~artifact_policy:Exec_core.Inline_only
                         ~base_path:root
                         ~keeper_name:meta.name
                         ~cmd:cmd_str
                         ~extra:
                           [ "op", `String op
                           ; "cwd", cwd_field
                           ; "command", `String cmd_str
                           ; "cached", `Bool true
                           ; "cache_age_ms",
                               `Int (int_of_float
                                       ((Unix.time () -. entry.cached_at) *. 1000.))
                           ]
                         ~status:st
                         ~output:entry.output
                         ())
                  | None ->
                    let t0 = Unix.gettimeofday () in
                    let st, out =
                      match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
                      | Some runtime ->
                        (match
                           Keeper_turn_sandbox_runtime.run_bash_with_status runtime
                             ~cwd ~cmd:cmd_str ~timeout_sec ()
                         with
                         | Ok payload -> payload
                         | Error msg -> (Unix.WEXITED 127, msg))
                      | None ->
                        Keeper_shell_shared.run_argv_with_status_retry_eintr ~cwd ~timeout_sec
                          [ "bash"; "-lc"; cmd_str ^ " 2>&1" ]
                    in
                    let elapsed_ms =
                      int_of_float ((Unix.gettimeofday () -. t0) *. 1000.)
                    in
                    if not (Keeper_shell_shared.process_status_is_timeout st) then begin
                      let exit_code = match st with
                        | Unix.WEXITED n -> n
                        | Unix.WSIGNALED n -> 128 + n
                        | Unix.WSTOPPED n -> 256 + n
                      in
                      Masc_exec.Exec_cache.store cache
                        ~cmd:cmd_str ~exit_code ~output:out ~duration_ms:elapsed_ms
                    end;
                    if Keeper_shell_shared.process_status_is_timeout st then
                      Yojson.Safe.to_string
                        (Exec_core.process_result_json
                           ~artifact_policy:Exec_core.Inline_only
                           ~base_path:root
                           ~keeper_name:meta.name
                           ~cmd:cmd_str
                           ~extra:
                             [ "op", `String op
                             ; "cwd", cwd_field
                             ; "command", `String cmd_str
                             ; "error", `String "command_timed_out"
                             ; "timeout_sec", `Float timeout_sec
                             ]
                           ~status:st
                           ~output:out
                           ())
                    else
                      Yojson.Safe.to_string
                        (Exec_core.process_result_json
                           ~artifact_policy:Exec_core.Inline_only
                           ~base_path:root
                           ~keeper_name:meta.name
                           ~cmd:cmd_str
                           ~extra:
                             [ "op", `String op
                             ; "cwd", cwd_field
                             ; "command", `String cmd_str
                             ]
                           ~status:st
                           ~output:out
                           ()))
               | None ->
                 let st, out =
                   match Keeper_sandbox_factory.resolve_opt turn_sandbox_factory ~cwd with
                   | Some runtime ->
                     (match
                        Keeper_turn_sandbox_runtime.run_bash_with_status runtime
                          ~cwd ~cmd:cmd_str ~timeout_sec ()
                      with
                      | Ok payload -> payload
                      | Error msg -> (Unix.WEXITED 127, msg))
                   | None ->
                     Keeper_shell_shared.run_argv_with_status_retry_eintr ~cwd ~timeout_sec
                       [ "bash"; "-lc"; cmd_str ^ " 2>&1" ]
                 in
                 if Keeper_shell_shared.process_status_is_timeout st then
                   Yojson.Safe.to_string
                     (Exec_core.process_result_json
                        ~artifact_policy:Exec_core.Inline_only
                        ~base_path:root
                        ~keeper_name:meta.name
                        ~cmd:cmd_str
                        ~extra:
                          [ "op", `String op
                          ; "cwd", cwd_field
                          ; "command", `String cmd_str
                          ; "error", `String "command_timed_out"
                          ; "timeout_sec", `Float timeout_sec
                          ]
                        ~status:st
                        ~output:out
                        ())
                 else
                   Yojson.Safe.to_string
                     (Exec_core.process_result_json
                        ~artifact_policy:Exec_core.Inline_only
                        ~base_path:root
                        ~keeper_name:meta.name
                        ~cmd:cmd_str
                        ~extra:
                          [ "op", `String op
                          ; "cwd", cwd_field
                          ; "command", `String cmd_str
                          ]
                        ~status:st
                        ~output:out
                        ())))))
  | "git_clone" ->
    (* Clone a repo into this keeper's playground repos directory.
       Sandboxed: always targets .masc/playground/<keeper_name>/repos/<repo_name>.
       Validates against tool_policy.toml git_clone.allowed_orgs. *)
    let url = Safe_ops.json_string ~default:"" "url" args |> String.trim in
    if url = "" then
      error_json ~fields:[ "op", `String op ]
        "url is required for git_clone. Good: url='https://github.com/org/repo'. Bad: url=''."
    else
      let base_path = config.base_path in
      (match Tool_code_write.validate_clone_url ~base_path url with
       | Error reason ->
         Yojson.Safe.to_string
           (`Assoc
               [ "ok", `Bool false
               ; "op", `String op
               ; "error", `String "clone_blocked"
               ; "reason", `String reason
               ; "url", `String url
               ])
       | Ok () ->
         let _bundle_paths = Keeper_alerting_path.ensure_sandbox_bundle ~config ~meta in
         ignore (_bundle_paths : string list);
         let playground = keeper_playground_root ~config ~meta in
         let repos_dir = Filename.concat playground "repos" in
         Fs_compat.mkdir_p repos_dir;
         (* Derive repo name from URL: strip trailing slash, .git, then basename.
            Guard against empty/traversal names (e.g. url ending with "/" or ".."). *)
         let repo_name =
           let stripped =
             let s = String.trim url in
             if String.ends_with ~suffix:"/" s
             then String.sub s 0 (String.length s - 1) else s
           in
           let base = Filename.basename stripped in
           let name =
             if String.ends_with ~suffix:".git" base
             then String.sub base 0 (String.length base - 4)
             else base
           in
           (* Sanitize: only allow alphanumeric, hyphen, underscore, dot.
              Reject empty, ".", ".." to prevent traversal. *)
           let safe = String.map (fun c ->
             if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.'
             then c else '_') name
           in
           if safe = "" || safe = "." || safe = ".." then "repo" else safe
         in
         let clone_path = Filename.concat repos_dir repo_name in
         let docker_hard_mode_brokered =
           meta.sandbox_profile = Docker
           && Env_config_keeper.KeeperSandbox.hard_mode ()
         in
         let route_fields =
           if meta.sandbox_profile = Docker then
             [ "via", `String
                 (if docker_hard_mode_brokered then "brokered" else "docker") ]
           else
             []
         in
         let run_brokered_git ~cwd ~timeout_sec argv =
           match Keeper_gh_env.keeper_process_env config ~keeper_name:meta.name with
           | Error err -> (Unix.WEXITED 127, err)
           | Ok env ->
               Process_eio.run_argv_with_status ?env ~cwd ~timeout_sec argv
         in
         if Fs_compat.file_exists clone_path then
           (* Existing sandbox clones may have a .git directory but no
              checked-out files. Repair that locally before a pull, otherwise
              git can report "Already up to date" while the worktree stays
              unusable for read/search tools. *)
           (match Coord_worktree.ensure_sandbox_clone_ready clone_path with
            | Error err ->
                Yojson.Safe.to_string
                  (`Assoc
                      ([ "ok", `Bool false
                       ; "op", `String op
                       ; "action", `String "repair_existing_clone"
                       ; "path", `String clone_path
                       ; "error", `String "sandbox_clone_not_ready"
                       ; "status",
                         Keeper_alerting_path.process_status_to_json
                           (Unix.WEXITED 1)
                       ; "output", `String (Types.masc_error_to_string err)
                       ]
                      @ route_fields))
            | Ok repair_note ->
                (* Already cloned — pull latest instead *)
                let st, out =
                  if docker_hard_mode_brokered then
                    run_brokered_git ~cwd:repos_dir ~timeout_sec:60.0
                      [ "git"; "-C"; clone_path; "pull"; "--ff-only" ]
                  else if meta.sandbox_profile = Docker then
                    match
                      Keeper_shell_shared.run_docker_shell_command_with_status ~config ~meta
                        ~cwd:repos_dir ~timeout_sec:60.0
                        ~cmd:(Printf.sprintf "git -C %s pull --ff-only"
                                (Filename.quote repo_name))
                        ~git_creds_enabled:true ~network_mode:Network_inherit
                    with
                    | Ok result -> (result.status, result.output)
                    | Error msg -> (Unix.WEXITED 127, msg)
                  else
                    Process_eio.run_argv_with_status ~timeout_sec:60.0
                      [ "git"; "-C"; clone_path; "pull"; "--ff-only" ]
                in
                if st = Unix.WEXITED 0 then
                  Keeper_shell_shared.update_playground_repo_cache
                    ~playground_dir:playground ~repo_name ~repo_path:clone_path
                    ~action:"pull" ~shallow:false;
                let repair_fields =
                  match repair_note with
                  | None -> []
                  | Some note -> [ "repair_note", `String note ]
                in
                Yojson.Safe.to_string
                  (`Assoc
                      ([ "ok", `Bool (st = Unix.WEXITED 0)
                       ; "op", `String op
                       ; "action", `String "pull"
                       ; "path", `String clone_path
                       ; "status", Keeper_alerting_path.process_status_to_json st
                       ; "output", `String out
                       ]
                      @ repair_fields
                      @ route_fields)))
         else
           let depth = Keeper_tool_policy.clone_depth () |> max 0 in
           let depth_args =
             if depth > 0 then ["--depth"; string_of_int depth] else []
           in
           let shallow = depth > 0 in
           let st, out =
             if docker_hard_mode_brokered then
               run_brokered_git ~cwd:repos_dir
                 ~timeout_sec:(Keeper_tool_policy.clone_timeout_sec ())
                 ("git" :: "clone" :: depth_args @ [ url; clone_path ])
             else if meta.sandbox_profile = Docker then
               let clone_cmd =
                 String.concat " "
                   (List.map Filename.quote
                      ("git" :: "clone" :: depth_args @ [ url; repo_name ]))
               in
               match
                 Keeper_shell_shared.run_docker_shell_command_with_status ~config ~meta ~cwd:repos_dir
                   ~timeout_sec:(Keeper_tool_policy.clone_timeout_sec ())
                   ~cmd:clone_cmd
                   ~git_creds_enabled:true ~network_mode:Network_inherit
               with
               | Ok result -> (result.status, result.output)
               | Error msg -> (Unix.WEXITED 127, msg)
             else
               Process_eio.run_argv_with_status
                 ~timeout_sec:(Keeper_tool_policy.clone_timeout_sec ())
                 ("git" :: "clone" :: depth_args @ [ url; clone_path ])
           in
           if st = Unix.WEXITED 0 then
             Keeper_shell_shared.update_playground_repo_cache
               ~playground_dir:playground ~repo_name ~repo_path:clone_path
               ~action:"clone" ~shallow;
           Yojson.Safe.to_string
             (`Assoc
                 ([ "ok", `Bool (st = Unix.WEXITED 0)
                  ; "op", `String op
                  ; "action", `String "clone"
                  ; "path", `String clone_path
                  ; "status", Keeper_alerting_path.process_status_to_json st
                  ; "output", `String out
                  ]
                 @ route_fields)))
  | "gh" ->
    let raw_cmd_str = Safe_ops.json_string ~default:"" "cmd" args in
    (* gh runs against remote network. Prior floors (1s, then 5s) kept
       firing gh_command_timed_out on plain read calls — 41 such
       rejections on 2026-04-17/18 (#8688), every single one at
       timeout_sec=5. GitHub API round-trip alone runs 1-8s even on
       small queries, and `gh` spends additional time on auth handshake
       and JSON encoding. Floor at 15s so the keeper LLM cannot request
       a sub-network-latency timeout; default remains the configured
       pr_create timeout (tool_policy.toml, default 30s). *)
    let gh_default_timeout = Keeper_tool_policy.pr_create_timeout_sec () in
    let timeout_sec =
      Keeper_shell_shared.clamp_shell_timeout ~min_sec:Keeper_shell_shared.gh_min_timeout_sec ~default:gh_default_timeout args
    in
    if String.trim raw_cmd_str = "" then
      error_json ~fields:[ "op", `String op ]
        "cmd is required for gh op. Good: cmd='pr list --state open'. Bad: cmd=''."
    else (
      match Keeper_gh_shared.parse_simple_gh_command raw_cmd_str with
      | Error parse_error ->
        let reason =
          match parse_error with
          | Keeper_gh_shared.Empty_command -> "empty_command"
          | Keeper_gh_shared.Unsupported_shell_construct tag -> tag
          | Keeper_gh_shared.Unsupported_command_shape tag -> tag
        in
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool false
              ; "op", `String op
              ; "error", `String "gh_command_shape_unsupported"
              ; "reason", `String reason
              ; "hint", `String
                 "keeper_shell op=gh only accepts one simple gh command. \
                   Avoid pipelines, redirects, env prefixes, and shell \
                   control syntax."
              ])
      | Ok parsed_cmd ->
        let allowed_orgs = Keeper_tool_policy.git_clone_allowed_orgs () in
        let canonical_cmd_str =
          Keeper_gh_shared.gh_simple_command_argv parsed_cmd
          |> String.concat " "
        in
        (* Reversibility gate (Thariq / Anthropic auto-mode principle):
           - R0 read / R1 reversible mutation: allowed; R1 is audit-logged.
           - R2 irreversible: rejected with a structured-tool hint so the
             LLM can self-recover toward an operator-approval path without
             a second round-trip. *)
        let reversibility =
          Worker_dev_tools.classify_gh_reversibility canonical_cmd_str
        in
        let rev_tag =
          Worker_dev_tools.string_of_gh_reversibility reversibility
        in
        let gh_cmd_display cmd =
          Printf.sprintf "gh %s"
            (Keeper_gh_shared.render_simple_gh_command cmd)
        in
        let gh_base ~ok ~cwd ~command extras =
          let docker_hard_mode_brokered =
            meta.sandbox_profile = Docker
            && Env_config_keeper.KeeperSandbox.hard_mode ()
          in
          let route_fields =
            if meta.sandbox_profile = Docker then
              [ "via", `String
                  (if docker_hard_mode_brokered then "brokered" else "docker") ]
            else
              []
          in
          Yojson.Safe.to_string
            (`Assoc
                ([ "ok", `Bool ok
                 ; "op", `String op
                 ; "cwd", `String cwd
                 ; "command", `String command
                 ; "reversibility", `String rev_tag
                 ] @ route_fields @ extras))
        in
        let run_gh_command ~display_command ~parsed_command ~cwd
            ~(ctx : Keeper_shell_gh_context.gh_repo_context option) =
          if reversibility = Worker_dev_tools.R1_Reversible then
            Log.Keeper.info
              "gh_audit: keeper=%s reversibility=R1 cwd=%s cmd=%s"
              meta.name cwd display_command;
          let gh_context_fields =
            match ctx with
            | Some ctx ->
              let repo_fields =
                match ctx.repo_slug with
                | Some repo_slug -> [ "repo", `String repo_slug ]
                | None -> []
              in
              [ "task_id", `String ctx.task_id
              ; "git_root", `String ctx.git_root
              ]
              @ repo_fields
            | None -> []
          in
          let gh_process =
            if meta.sandbox_profile = Docker
               && not (Env_config_keeper.KeeperSandbox.hard_mode ())
            then
              match
                Keeper_shell_shared.run_docker_shell_command_with_status ~config ~meta ~cwd
                  ~timeout_sec ~cmd:display_command
                  ~git_creds_enabled:true ~network_mode:Network_inherit
              with
              | Ok result -> Ok (result.status, result.output)
              | Error msg -> Error msg
            else
              (match Keeper_gh_env.keeper_process_env config ~keeper_name:meta.name with
               | Error err -> Error err
               | Ok env ->
                   let gh_argv =
                     "gh" :: Keeper_gh_shared.gh_simple_command_argv parsed_command
                   in
                   Ok (Process_eio.run_argv_with_status ?env ~cwd ~timeout_sec gh_argv))
          in
          match gh_process with
          | Error msg ->
            gh_base ~command:display_command ~ok:false ~cwd
              (gh_context_fields @ [ "error", `String msg ])
          | Ok (st, out) ->
            if Keeper_shell_shared.process_status_is_timeout st then
              gh_base ~command:display_command ~ok:false ~cwd
                (gh_context_fields @
                [ "error", `String "gh_command_timed_out"
                ; "timeout_sec", `Float timeout_sec
                ; "status", Keeper_alerting_path.process_status_to_json st
                ; "output", `String out
                ; "hint", `String
                    "gh network call exceeded timeout_sec. Retry \
                     with a larger value — gh round-trip plus auth \
                     handshake is usually 3-10s, so prefer \
                     timeout_sec=30 or timeout_sec=60 rather than \
                     the 15s floor. You may also narrow the query \
                     (--state, --limit, --json)."
                ])
            else
              let ok = st = Unix.WEXITED 0 in
              let base_fields =
                gh_context_fields @
                [ "status", Keeper_alerting_path.process_status_to_json st
                ; "output", `String out ]
              in
              let hinted_fields =
                if (not ok)
                   && String_util.contains_substring_ci out
                        "Could not resolve to a Repository"
                then
                  base_fields @
                  [ "error", `String "gh_repo_resolve_failed"
                  ; "hint", `String
                      "gh is bound to the active task worktree repo. \
                       Ensure the linked sandbox clone still has a valid \
                       origin remote and recreate the task worktree if needed." ]
                else base_fields
              in
              gh_base ~command:display_command ~ok ~cwd hinted_fields
        in
        (match reversibility with
         | Worker_dev_tools.R2_Irreversible ->
           let hint =
             Option.value
               (Worker_dev_tools.structured_tool_hint_for_r2 canonical_cmd_str)
               ~default:
                 "This gh command mutates state that gh itself cannot \
                  restore. Route through the appropriate structured \
                  keeper tool or post on the board for operator approval."
           in
           Log.Keeper.warn
             "keeper_shell op=gh R2 blocked: %s (keeper=%s)"
             canonical_cmd_str meta.name;
           gh_base ~ok:false ~cwd:"" ~command:(gh_cmd_display parsed_cmd)
             [ "error", `String "gh_irreversible_blocked"
             ; "hint", `String hint ]
         | R0_Read | R1_Reversible ->
           begin
             match
               Worker_dev_tools.validate_gh_command
                 ~allowed_orgs canonical_cmd_str
             with
             | Error reason ->
               Yojson.Safe.to_string
                 (`Assoc
                     [ "ok", `Bool false
                     ; "op", `String op
                     ; "error", `String "gh_command_blocked"
                     ; "reason", `String reason
                     ; "hint", `String
                         "Run `gh --help` shapes: pr/issue/repo/release/\
                         label/run/workflow/api/project/ruleset/search/\
                          status/cache/gist. auth/secret/ssh-key are blocked."
                     ])
             | Ok () ->
               (match Keeper_shell_shared.resolve_keeper_shell_write_cwd ~config ~meta ~args with
                | Error e -> error_json e
                  | Ok gh_cwd ->
                  (match Keeper_shell_gh_context.resolve_gh_repo_context ~config ~meta ~cwd:gh_cwd with
                   | Error err ->
                     Keeper_shell_gh_context.gh_repo_context_error_json
                       ~op
                       ~cmd_display:(gh_cmd_display parsed_cmd) err
                   | Ok ctx ->
                     let cmd_to_run =
                       match ctx.repo_slug with
                       | Some repo_slug ->
                           Keeper_gh_shared.gh_simple_command_with_repo_flag
                             ~repo_slug parsed_cmd
                       | None -> parsed_cmd
                     in
                     run_gh_command
                       ~display_command:(gh_cmd_display cmd_to_run)
                       ~parsed_command:cmd_to_run
                       ~cwd:ctx.worktree_cwd
                       ~ctx:(Some ctx)))
           end))
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
