open Keeper_types
open Keeper_exec_shared

type run_command_with_status =
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  timeout_sec:float ->
  host:Keeper_sandbox_runner.host_command ->
  backend:Keeper_sandbox_runner.backend_command ->
  Keeper_sandbox_runner.routed_result

let repo_name_of_clone_url url =
  let stripped =
    let s = String.trim url in
    if String.ends_with ~suffix:"/" s
    then String.sub s 0 (String.length s - 1)
    else s
  in
  let base = Filename.basename stripped in
  let name =
    if String.ends_with ~suffix:".git" base
    then String.sub base 0 (String.length base - 4)
    else base
  in
  let safe =
    String.map
      (fun c ->
        if (c >= 'a' && c <= 'z')
           || (c >= 'A' && c <= 'Z')
           || (c >= '0' && c <= '9')
           || c = '-'
           || c = '_'
           || c = '.'
        then c
        else '_')
      name
  in
  if safe = "" || safe = "." || safe = ".." then "repo" else safe
;;

let normalize_existing_origin_to_https clone_path =
  match
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:`Coord_git
      ~raw_source:("git -C " ^ clone_path ^ " remote get-url origin")
      ~summary:"keeper git remote get-url"
      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Git_meta ())
      [ "git"; "-C"; clone_path; "remote"; "get-url"; "origin" ]
  with
  | Unix.WEXITED 0, origin ->
    let origin = String.trim origin in
    let normalized = Tool_code_write.normalize_github_clone_url origin in
    if String.equal origin normalized
    then None
    else (
      match
        Masc_exec.Exec_gate.run_argv_with_status
          ~actor:`Coord_git
          ~raw_source:
            ("git -C " ^ clone_path ^ " remote set-url origin " ^ normalized)
          ~summary:"keeper git remote set-url"
          ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Git_meta ())
          [ "git"; "-C"; clone_path; "remote"; "set-url"; "origin"; normalized ]
      with
      | Unix.WEXITED 0, _ -> Some "origin remote normalized to HTTPS"
      | _, out ->
        Some
          (Printf.sprintf
             "origin remote normalization failed: %s"
             (String.trim out)))
  | _ -> None
;;

let handle_git_clone
    ?(run_command_with_status =
      Keeper_sandbox_runner.run_command_with_status)
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(args : Yojson.Safe.t)
    () =
  let op = "git_clone" in
  let url = Safe_ops.json_string ~default:"" "url" args |> String.trim in
  if url = ""
  then
    error_json
      ~fields:[ "op", `String op ]
      "url is required for git_clone. Good: url='https://github.com/org/repo'. \
       Bad: url=''."
  else
    let base_path = config.base_path in
    match Tool_code_write.validate_clone_url ~base_path url with
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
      let clone_url = Tool_code_write.normalize_github_clone_url url in
      let _bundle_paths =
        Keeper_alerting_path.ensure_sandbox_bundle ~config ~meta
      in
      ignore (_bundle_paths : string list);
      let playground = keeper_playground_root ~config ~meta in
      let repos_dir = Filename.concat playground "repos" in
      Fs_compat.mkdir_p repos_dir;
      let repo_name = repo_name_of_clone_url url in
      let clone_path = Filename.concat repos_dir repo_name in
      let route_fields =
        if Keeper_sandbox_runner.uses_backend ~config ~meta ~cwd:repos_dir
        then [ "via", `String "docker" ]
        else []
      in
      if Fs_compat.file_exists clone_path
      then (
        match Coord_worktree.ensure_sandbox_clone_ready clone_path with
        | Error err ->
          Yojson.Safe.to_string
            (`Assoc
                ([ "ok", `Bool false
                 ; "op", `String op
                 ; "action", `String "repair_existing_clone"
                 ; "path", `String clone_path
                 ; "error", `String "sandbox_clone_not_ready"
                 ; ( "status",
                     Keeper_alerting_path.process_status_to_json
                       (Unix.WEXITED 1)
                   )
                 ; "output", `String (Masc_domain.masc_error_to_string err)
                 ]
                 @ route_fields))
        | Ok repair_note ->
          let origin_repair_note =
            normalize_existing_origin_to_https clone_path
          in
          let pull_timeout =
            Env_config_exec_timeout.timeout_sec ~caller:Shell ()
          in
          let pull_result =
            run_command_with_status
              ~config
              ~meta
              ~timeout_sec:pull_timeout
              ~host:
                { actor = `Coord_git
                ; raw_source = "git -C " ^ clone_path ^ " pull --ff-only"
                ; summary = "keeper git pull"
                ; env = None
                ; cwd = None
                ; argv = [ "git"; "-C"; clone_path; "pull"; "--ff-only" ]
                }
              ~backend:
                { route_cwd = repos_dir
                ; cwd = (fun () -> repos_dir)
                ; command_text =
                    Printf.sprintf
                      "git -C %s pull --ff-only"
                      (Filename.quote repo_name)
                ; git_creds_enabled = true
                ; network_mode = Network_inherit
                ; trust = Keeper_sandbox_runner.Trusted_tool
                }
          in
          let st, out = pull_result.status, pull_result.output in
          if st = Unix.WEXITED 0
          then
            Keeper_shell_shared.update_playground_repo_cache
              ~playground_dir:playground
              ~repo_name
              ~repo_path:clone_path
              ~action:"pull"
              ~shallow:false;
          let repair_fields =
            [ repair_note; origin_repair_note ]
            |> List.filter_map (fun note -> note)
            |> function
            | [] -> []
            | notes -> [ "repair_note", `String (String.concat "; " notes) ]
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
          if depth > 0 then [ "--depth"; string_of_int depth ] else []
        in
        let shallow = depth > 0 in
        let clone_cmd =
          String.concat
            " "
            (List.map
               Filename.quote
               ("git" :: "clone" :: depth_args @ [ clone_url; repo_name ]))
        in
        let clone_timeout = Keeper_tool_policy.clone_timeout_sec () in
        let clone_result =
          run_command_with_status
            ~config
            ~meta
            ~timeout_sec:clone_timeout
            ~host:
              { actor = `Coord_git
              ; raw_source =
                  "git clone "
                  ^ String.concat " " depth_args
                  ^ " "
                  ^ clone_url
                  ^ " "
                  ^ clone_path
              ; summary = "keeper git clone"
              ; env = None
              ; cwd = None
              ; argv = "git" :: "clone" :: depth_args @ [ clone_url; clone_path ]
              }
            ~backend:
              { route_cwd = repos_dir
              ; cwd = (fun () -> repos_dir)
              ; command_text = clone_cmd
              ; git_creds_enabled = true
              ; network_mode = Network_inherit
              ; trust = Keeper_sandbox_runner.Trusted_tool
              }
        in
        let st, out = clone_result.status, clone_result.output in
        if st = Unix.WEXITED 0
        then
          Keeper_shell_shared.update_playground_repo_cache
            ~playground_dir:playground
            ~repo_name
            ~repo_path:clone_path
            ~action:"clone"
            ~shallow;
        Yojson.Safe.to_string
          (`Assoc
              ([ "ok", `Bool (st = Unix.WEXITED 0)
               ; "op", `String op
               ; "action", `String "clone"
               ; "path", `String clone_path
               ; "status", Keeper_alerting_path.process_status_to_json st
               ; "output", `String out
               ]
               @ route_fields))
;;
