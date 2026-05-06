(** Dedicated GitHub PR keeper tools. *)

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
      ( "credential_scope",
        `String
          (Keeper_gh_env.credential_scope_to_string binding.credential_scope) );
      "git_identity_mode", `String binding.git_identity_mode;
      "credential_state", credential_state_json state;
    ]

let with_repo_arg repo argv =
  let repo = String.trim repo in
  if repo = "" then argv else argv @ [ "-R"; repo ]

let opt_flag flag = function
  | None -> []
  | Some value ->
      let value = String.trim value in
      if value = "" then [] else [ flag; value ]

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

let build_pr_view_recovery_argv ~repo ~head =
  let head = Option.map String.trim head |> Option.value ~default:"" in
  (if head = "" then [ "gh"; "pr"; "view" ] else [ "gh"; "pr"; "view"; head ])
  |> with_repo_arg repo
  |> fun argv -> argv @ [ "--json"; pr_json_fields ^ ",body" ]

let build_pr_create_argv ~repo ~title ~body ~base ~head =
  [ "gh"; "pr"; "create" ]
  |> with_repo_arg repo
  |> fun argv ->
  argv
  @ [ "--draft"; "--title"; title; "--body"; body ]
  @ opt_flag "--base" base
  @ opt_flag "--head" head

let draft_request_allowed args =
  match Safe_ops.json_bool_opt "draft" args with
  | Some false -> false
  | Some true | None -> (
      match Safe_ops.json_bool_opt "ready" args with
      | Some true -> false
      | Some false | None -> true)

(* Research is intentionally allowed here: [config/tool_policy.toml]'s
   [presets.research] grants the [github] group (which contains
   [keeper_pr_create]) per the "Step 9 bloodflow restoration plan"
   comment, so analyst/scholar/verifier-tier keepers can open draft
   PRs as part of their work. Without Research, the tool stays visible
   in the surface but fails at dispatch with [preset_insufficient] —
   the visible/callable contradiction surfaced when an analyst keeper
   tried a Docker PR-lifecycle proof. Mirrors
   [Keeper_tool_pr_review.pr_review_mutation_preset_ok], which already
   includes Research. *)
let mutation_preset_ok = function
  | Some (Research | Delivery | Coding | Full) -> true
  | _ -> false

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

let contains_substring haystack needle =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    if needle_len = 0 then true
    else if idx + needle_len > haystack_len then false
    else if String.sub haystack idx needle_len = needle then true
    else loop (idx + 1)
  in
  loop 0

let pr_create_failure_may_have_created_pr output =
  let output = String.lowercase_ascii output in
  List.exists
    (contains_substring output)
    [
      "http 504";
      "504 gateway timeout";
      "gateway timeout";
      "context deadline exceeded";
      "i/o timeout";
    ]

(* gh CLI verbatim prefix when a PR for the same head already exists:
   "a pull request for branch \"<owner:branch>\" into branch \"<base>\"
    already exists:\n<url>\n"
   Match the leading clause case-insensitively so future gh versions with
   minor wording shifts still classify correctly. *)
let pr_create_failure_already_exists output =
  let output = String.lowercase_ascii output in
  contains_substring output "a pull request for branch"
  && contains_substring output "already exists"

(* Recovery reason classifier — returned alongside the recovery result so
   observers can distinguish a transient retry-style recovery (504/timeout)
   from a deterministic idempotency hit (PR already exists). *)
let classify_pr_create_recovery output =
  if pr_create_failure_already_exists output then
    Some "pr_already_exists"
  else if pr_create_failure_may_have_created_pr output then
    Some "pr_create_transient_failure"
  else
    None

type gh_exec_result =
  { status : Unix.process_status
  ; output : string
  ; via : string
  }

let quote_argv argv =
  String.concat " " (List.map Filename.quote argv)

let run_gh_argv ~(config : Coord.config) ~(meta : keeper_meta) ~env ~cwd
    ~timeout_sec argv =
  if
    meta.sandbox_profile = Docker
    && Env_config_keeper.KeeperSandbox.hard_mode ()
  then
    let status, output =
      Process_eio.run_argv_with_status ~env ~cwd ~timeout_sec argv
    in
    { status; output; via = "brokered" }
  else if meta.sandbox_profile = Docker then
    match
      Keeper_shell_shared.run_docker_shell_command_with_status
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
      Process_eio.run_argv_with_status ~env ~cwd ~timeout_sec argv
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

let run_gh ?recover_pr_create ~tool ~operation ~config ~meta ~args ~write argv =
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
          let recovered =
            match recover_pr_create with
            | Some (repo, head) when not result_ok -> (
                match classify_pr_create_recovery result.output with
                | None -> None
                | Some reason ->
                    let recovery =
                      run_gh_argv ~config ~meta ~env ~cwd ~timeout_sec
                        (build_pr_view_recovery_argv ~repo ~head)
                    in
                    if status_ok recovery.status then Some (recovery, reason)
                    else None)
            | _ -> None
          in
          (match recovered with
           | Some (recovery, reason) ->
               output_json ~ok:true ~tool ~operation ~meta ~binding ~state
                 ~cwd ~via:recovery.via ~output:recovery.output
                 ~extra_fields:
                   [
                     "recovered_from_error", `String reason;
                     "original_ok", `Bool false;
                     "original_output", `String result.output;
                     "recovery_tool", `String "gh pr view";
                   ]
                 ()
           | None ->
               output_json ~ok:result_ok ~tool ~operation ~meta ~binding
                 ~state ~cwd ~via:result.via ~output:result.output ()))

let handle_keeper_pr_list ~(config : Coord.config) ~(meta : keeper_meta)
    ~(args : Yojson.Safe.t) =
  let repo = Safe_ops.json_string ~default:"" "repo" args in
  let limit = Safe_ops.json_int ~default:20 "limit" args |> clamp_limit in
  match Safe_ops.json_string ~default:"open" "state" args |> normalize_state with
  | Error reason -> error_json reason
  | Ok state ->
      run_gh ~tool:"keeper_pr_list" ~operation:"pr_list" ~config ~meta
        ~args ~write:false (build_pr_list_argv ~repo ~state ~limit)

let handle_keeper_pr_status ~(config : Coord.config) ~(meta : keeper_meta)
    ~(args : Yojson.Safe.t) =
  let repo = Safe_ops.json_string ~default:"" "repo" args in
  let pr_number = Keeper_tool_pr_review.pr_number_of_args args in
  if pr_number = 0 then
    error_json "pr_number is required. Good: pr_number=123."
  else
    run_gh ~tool:"keeper_pr_status" ~operation:"pr_status" ~config ~meta
      ~args ~write:false (build_pr_status_argv ~repo ~pr_number)

let handle_keeper_pr_create ~(config : Coord.config) ~(meta : keeper_meta)
    ~(args : Yojson.Safe.t) =
  let title = Safe_ops.json_string ~default:"" "title" args |> String.trim in
  let body = Safe_ops.json_string ~default:"" "body" args |> String.trim in
  let repo = Safe_ops.json_string ~default:"" "repo" args in
  let base = Safe_ops.json_string_opt "base" args in
  let head = Safe_ops.json_string_opt "head" args in
  if not (draft_request_allowed args) then
    error_json "keeper_pr_create is draft-only; omit draft or set draft=true."
  else if title = "" then
    error_json "title is required."
  else if body = "" then
    error_json "body is required."
  else if not (mutation_preset_ok (Keeper_types.tool_access_preset meta.tool_access)) then
    Yojson.Safe.to_string
      (`Assoc
        [
          "ok", `Bool false;
          "error", `String "preset_insufficient";
          "reason", `String "keeper_pr_create requires delivery, coding, or full preset";
        ])
  else
    run_gh ~tool:"keeper_pr_create" ~operation:"pr_create" ~config ~meta
      ~args ~write:true ~recover_pr_create:(repo, head)
      (build_pr_create_argv ~repo ~title ~body ~base ~head)

module For_testing = struct
  let build_pr_list_argv = build_pr_list_argv
  let build_pr_status_argv = build_pr_status_argv
  let build_pr_view_recovery_argv = build_pr_view_recovery_argv
  let build_pr_create_argv = build_pr_create_argv
  let draft_request_allowed = draft_request_allowed
  let pr_create_failure_may_have_created_pr =
    pr_create_failure_may_have_created_pr
  let pr_create_failure_already_exists = pr_create_failure_already_exists
  let classify_pr_create_recovery = classify_pr_create_recovery

  let quote_argv = quote_argv
  let mutation_preset_ok = mutation_preset_ok
end
