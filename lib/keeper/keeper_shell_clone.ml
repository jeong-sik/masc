open Keeper_types
open Keeper_exec_shared

(* ── Shared helpers for git_clone/docker-or-host execution ───────── *)

let docker_result_pair = function
  | Ok (result : Keeper_shell_docker.docker_shell_result) ->
    result.status, result.output
  | Error msg -> Unix.WEXITED 127, msg

let clone_action_json ~op ~action ~path ~status ~output ~extra ~via_fields =
  Yojson.Safe.to_string
    (`Assoc
        ([ "ok", `Bool (status = Unix.WEXITED 0)
         ; "op", `String op
         ; "action", `String action
         ; "path", `String path
         ; "status", Keeper_alerting_path.process_status_to_json status
         ; "output", `String output
         ]
         @ extra
         @ via_fields))

let handle
      ~op
      ~(meta : keeper_meta)
      ~(config : Coord.config)
      ~(args : Yojson.Safe.t)
  =
  let url = Safe_ops.json_string ~default:"" "url" args |> String.trim in
  if url = "" then
    error_json_for_op ~op
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
       let clone_url = Tool_code_write.normalize_github_clone_url url in
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
       let via = sandbox_profile_via_fields meta in
       let normalize_existing_origin_to_https clone_path =
         match
           Masc_exec.Exec_gate.run_argv_with_status ~actor:`Coord_git
             ~raw_source:("git -C " ^ clone_path ^ " remote get-url origin")
             ~summary:"keeper git remote get-url"
             ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Git_meta ())
             [ "git"; "-C"; clone_path; "remote"; "get-url"; "origin" ]
         with
         | Unix.WEXITED 0, origin ->
           let origin = String.trim origin in
           let normalized = Tool_code_write.normalize_github_clone_url origin in
           if String.equal origin normalized then None
           else
             (match
                Masc_exec.Exec_gate.run_argv_with_status ~actor:`Coord_git
                  ~raw_source:("git -C " ^ clone_path ^ " remote set-url origin " ^ normalized)
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
                     ; "output", `String (Masc_domain.masc_error_to_string err)
                     ]
                    @ via))
          | Ok repair_note ->
              let origin_repair_note =
                normalize_existing_origin_to_https clone_path
              in
              (* Already cloned — pull latest instead *)
              let st, out =
                if meta.sandbox_profile = Docker then
                  Keeper_shell_docker.run_docker_shell_command_with_status ~config ~meta
                    ~cwd:repos_dir ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Shell ())
                    ~cmd:(Printf.sprintf "git -C %s pull --ff-only"
                            (Filename.quote repo_name))
                    ~git_creds_enabled:true ~network_mode:Network_inherit
                  |> docker_result_pair
                else
                  Masc_exec.Exec_gate.run_argv_with_status ~actor:`Coord_git
                    ~raw_source:("git -C " ^ clone_path ^ " pull --ff-only")
                    ~summary:"keeper git pull"
                    ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Shell ())
                    [ "git"; "-C"; clone_path; "pull"; "--ff-only" ]
              in
              if st = Unix.WEXITED 0 then
                Keeper_shell_shared.update_playground_repo_cache
                  ~playground_dir:playground ~repo_name ~repo_path:clone_path
                  ~action:"pull" ~shallow:false;
              let repair_fields =
                [ repair_note; origin_repair_note ]
                |> List.filter_map (fun note -> note)
                |> function
                | [] -> []
                | notes -> [ "repair_note", `String (String.concat "; " notes) ]
              in
              clone_action_json ~op ~action:"pull" ~path:clone_path ~status:st ~output:out
                ~extra:repair_fields ~via_fields:via)
       else
         let depth = Keeper_tool_policy.clone_depth () |> max 0 in
         let depth_args =
           if depth > 0 then ["--depth"; string_of_int depth] else []
         in
         let shallow = depth > 0 in
         let st, out =
           if meta.sandbox_profile = Docker then
             let clone_cmd =
               String.concat " "
                 (List.map Filename.quote
                    ("git" :: "clone" :: depth_args @ [ clone_url; repo_name ]))
             in
             Keeper_shell_docker.run_docker_shell_command_with_status ~config ~meta ~cwd:repos_dir
               ~timeout_sec:(Keeper_tool_policy.clone_timeout_sec ())
               ~cmd:clone_cmd
               ~git_creds_enabled:true ~network_mode:Network_inherit
             |> docker_result_pair
           else
             Masc_exec.Exec_gate.run_argv_with_status ~actor:`Coord_git
               ~raw_source:("git clone " ^ String.concat " " depth_args ^ " " ^ clone_url ^ " " ^ clone_path)
               ~summary:"keeper git clone"
               ~timeout_sec:(Keeper_tool_policy.clone_timeout_sec ())
               ("git" :: "clone" :: depth_args @ [ clone_url; clone_path ])
         in
         if st = Unix.WEXITED 0 then
           Keeper_shell_shared.update_playground_repo_cache
             ~playground_dir:playground ~repo_name ~repo_path:clone_path
             ~action:"clone" ~shallow;
         clone_action_json ~op ~action:"clone" ~path:clone_path ~status:st ~output:out
           ~extra:[] ~via_fields:via)
