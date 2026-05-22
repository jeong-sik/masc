(** Read-only GitHub PR keeper tools. *)

open Keeper_types
open Keeper_exec_shared

let pr_json_fields =
  "number,title,state,isDraft,headRefName,baseRefName,mergeable,reviewDecision,url,updatedAt"

let credential_state_json = function
  | Repo_manager_types.Unmaterialized ->
      `Assoc [ "state", `String "unmaterialized" ]
  | Repo_manager_types.Materialized { last_verified_at } ->
      `Assoc
        [
          "state", `String "materialized";
          "last_verified_at", `Intlit (Int64.to_string last_verified_at);
        ]
  | Repo_manager_types.Stale { reason } ->
      `Assoc [ "state", `String "stale"; "reason", `String reason ]

let binding_json (binding : Keeper_gh_env.keeper_binding) ~state =
  `Assoc
    [
      "effective_github_identity", `String binding.effective_github_identity;
      ( "configured_github_identity",
        match binding.github_identity with
        | Some id -> `String id
        | None -> `Null );
      ( "credential_scope",
        `String
          (Keeper_gh_env.credential_scope_to_string binding.credential_scope) );
      "git_identity_mode", `String binding.git_identity_mode;
      "credential_state", credential_state_json state;
    ]

let with_repo_arg repo argv =
  let repo = String.trim repo in
  if repo = "" then argv else argv @ [ "-R"; repo ]

let repo_name_of_slug slug =
  match String.split_on_char '/' slug with
  | [ _owner; repo ] -> Some repo
  | _ -> None

let effective_repo_arg ~(config : Coord.config) repo =
  let repo = String.trim repo in
  if repo = "" then
    Ok ""
  else
    match Keeper_gh_shared.validate_repo_slug repo with
    | Ok slug -> Ok slug
    | Error reason when not (String.contains repo '/') -> (
        let root = Keeper_alerting_path.project_root_of_config config in
        match Keeper_gh_shared.repo_slug_of_git_root ~git_root:root with
        | Some slug when repo_name_of_slug slug = Some repo -> Ok slug
        | Some slug ->
            Error
              (Printf.sprintf
                 "repo must be owner/repo; got bare repo %S. Current \
                  project repository is %S."
                 repo slug)
        | None ->
            Error
              (Printf.sprintf
                 "repo must be owner/repo; got bare repo %S and current \
                  project repository could not be inferred."
                 repo))
    | Error reason -> Error reason

let clamp_limit n =
  Int.max 1 (Int.min 100 n)

let normalize_state raw =
  match String.lowercase_ascii (String.trim raw) with
  | "" | "open" -> Ok "open"
  | "closed" -> Ok "closed"
  | "merged" -> Ok "merged"
  | "all" -> Ok "all"
  | other ->
      Error
        (Printf.sprintf
           "state must be one of open, closed, merged, all; got %S" other)

let build_pr_list_argv ~repo ~state ~limit =
  [ "gh"; "pr"; "list" ]
  |> with_repo_arg repo
  |> fun argv ->
  argv
  @ [
      "--state";
      state;
      "--limit";
      string_of_int (clamp_limit limit);
      "--json";
      pr_json_fields;
    ]

let build_pr_status_argv ~repo ~pr_number =
  [ "gh"; "pr"; "view"; string_of_int pr_number ]
  |> with_repo_arg repo
  |> fun argv -> argv @ [ "--json"; pr_json_fields ^ ",body,files,reviews,comments" ]

let scoped_credential_or_error ~config ~meta =
  match Keeper_gh_env.keeper_binding config ~keeper_name:meta.name with
  | Error reason ->
      Error
        (`Assoc
          [
            "ok", `Bool false;
            "error", `String "credential_binding_failed";
            "reason", `String reason;
            "keeper", `String meta.name;
          ])
  | Ok binding -> (
      let state =
        Credential_materializer.verify_state
          ~gh_config_dir:binding.gh_config_dir
      in
      match state with
      | Repo_manager_types.Materialized _ ->
          let env =
            Keeper_gh_env.compose_base_with_gh_config
              ~dir:binding.gh_config_dir
          in
          Ok (binding, state, env)
      | Repo_manager_types.Unmaterialized | Repo_manager_types.Stale _ ->
          Error
            (`Assoc
              [
                "ok", `Bool false;
                "error", `String "credential_preflight_failed";
                "keeper", `String meta.name;
                "credential", binding_json binding ~state;
              ]))

let status_ok = function
  | Unix.WEXITED 0 -> true
  | _ -> false

type gh_exec_result =
  { status : Unix.process_status
  ; output : string
  ; via : string
  }

let quote_argv argv =
  String.concat " " (List.map Filename.quote argv)

let run_gh_argv ~(config : Coord.config) ~(meta : keeper_meta) ~env ~cwd
    ~timeout_sec argv =
  if meta.sandbox_profile = Docker then
    match
      Keeper_shell_docker.run_trusted_docker_shell_command_with_status
        ~config ~meta ~cwd ~timeout_sec ~cmd:(quote_argv argv)
        ~git_creds_enabled:true ~network_mode:Network_inherit
    with
    | Ok result ->
        { status = result.Keeper_shell_docker.status
        ; output = result.output
        ; via = "docker"
        }
    | Error msg ->
        { status = Unix.WEXITED 1; output = msg; via = "docker" }
  else
    let status, output =
      Masc_exec.Exec_gate.run_argv_with_status ~actor:`Coord_git
        ~raw_source:(quote_argv argv)
        ~summary:"keeper tool gh host"
        ~env ~cwd ~timeout_sec argv
    in
    { status; output; via = "host" }

let sandbox_profile_string (meta : keeper_meta) =
  match meta.sandbox_profile with
  | Docker -> "docker"
  | Local -> "local"

let output_json ?(extra_fields = []) ~ok ~tool ~operation ~meta ~binding
    ~state ~cwd ~via ~output () =
  Yojson.Safe.to_string
    (`Assoc
      ([
         "ok", `Bool ok;
         "tool", `String tool;
         "operation", `String operation;
         "keeper", `String meta.name;
         "sandbox_profile", `String (sandbox_profile_string meta);
         "via", `String via;
         "route_via", `String via;
         "credential", binding_json binding ~state;
         "cwd", `String cwd;
         "output", `String output;
       ]
       @ extra_fields))

let run_gh ~tool ~operation ~config ~meta ~args ~write argv =
  match scoped_credential_or_error ~config ~meta with
  | Error json -> Yojson.Safe.to_string json
  | Ok (binding, state, env) -> (
      let cwd_result =
        if write then
          Keeper_shell_shared.resolve_keeper_shell_write_cwd ~config ~meta ~args
        else
          Keeper_shell_shared.resolve_keeper_shell_read_cwd ~config ~meta ~args
      in
      match cwd_result with
      | Error reason ->
          Yojson.Safe.to_string
            (`Assoc
              [
                "ok", `Bool false;
                "tool", `String tool;
                "error", `String "cwd_resolution_failed";
                "reason", `String reason;
                "keeper", `String meta.name;
              ])
      | Ok cwd ->
          let timeout_sec =
            Env_config_exec_timeout.timeout_sec
              ~caller:(if write then Pr_review_post else Pr_review)
              ()
          in
          let result =
            run_gh_argv ~config ~meta ~env ~cwd ~timeout_sec argv
          in
          let result_ok = status_ok result.status in
          output_json ~ok:result_ok ~tool ~operation ~meta ~binding ~state
            ~cwd ~via:result.via ~output:result.output ())

let handle_keeper_pr_list ~(config : Coord.config) ~(meta : keeper_meta)
    ~(args : Yojson.Safe.t) =
  let repo = Safe_ops.json_string ~default:"" "repo" args in
  let limit = Safe_ops.json_int ~default:20 "limit" args |> clamp_limit in
  match
    ( effective_repo_arg ~config repo,
      Safe_ops.json_string ~default:"open" "state" args |> normalize_state )
  with
  | Error reason, _ | _, Error reason -> error_json reason
  | Ok repo, Ok state ->
      run_gh ~tool:"keeper_pr_list" ~operation:"pr_list" ~config ~meta ~args
        ~write:false (build_pr_list_argv ~repo ~state ~limit)

let handle_keeper_pr_status ~(config : Coord.config) ~(meta : keeper_meta)
    ~(args : Yojson.Safe.t) =
  let repo = Safe_ops.json_string ~default:"" "repo" args in
  let pr_number = Keeper_tool_pr_review.pr_number_of_args args in
  if pr_number = 0 then
    error_json "pr_number is required. Good: pr_number=123."
  else
    match effective_repo_arg ~config repo with
    | Error reason -> error_json reason
    | Ok repo ->
        run_gh ~tool:"keeper_pr_status" ~operation:"pr_status" ~config
          ~meta ~args ~write:false (build_pr_status_argv ~repo ~pr_number)

module For_testing = struct
  let build_pr_list_argv = build_pr_list_argv
  let build_pr_status_argv = build_pr_status_argv
  let effective_repo_arg = effective_repo_arg
  let quote_argv = quote_argv
end
