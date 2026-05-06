(** Keeper PR review tools — read, comment, reply handlers.

    Extracted from keeper_exec_github.ml (god file decomp Step 4). *)

open Keeper_types
open Keeper_exec_shared

(* Issue #8480: Variant SSOT for PR review event. Adding a new
   constructor forces compilation in [pr_review_event_to_string],
   [pr_review_event_of_string_opt], and [pr_review_event_to_gh_flag],
   so the schema enum in [tool_shard.ml] (derived from
   [valid_pr_review_event_strings]) and the gh CLI dispatcher stay in
   lock-step. Strings are uppercase to match GitHub's review event
   vocabulary and the canonical [gh pr review] flag mapping. *)
type pr_review_event =
  | Comment
  | Approve
  | Request_changes

let pr_review_event_to_string = function
  | Comment -> "COMMENT"
  | Approve -> "APPROVE"
  | Request_changes -> "REQUEST_CHANGES"

let pr_review_event_of_string_opt raw =
  match String.uppercase_ascii (String.trim raw) with
  | "COMMENT" -> Some Comment
  | "APPROVE" -> Some Approve
  | "REQUEST_CHANGES" -> Some Request_changes
  | _ -> None

let pr_review_event_to_gh_flag = function
  | Comment -> "--comment"
  | Approve -> "--approve"
  | Request_changes -> "--request-changes"

let all_pr_review_events = [ Comment; Approve; Request_changes ]

let valid_pr_review_event_strings =
  List.map pr_review_event_to_string all_pr_review_events

let pr_review_mutation_preset_ok = function
  | Some (Research | Delivery | Coding | Full) -> true
  | _ -> false

let pr_review_mutation_preset_reason tool_name =
  Printf.sprintf "%s requires research, delivery, coding, or full preset" tool_name

(* Both "pr_number" and "number" are accepted for schema-drift compat. *)
let pr_number_of_args args =
  let from_pr = Safe_ops.json_int ~default:0 "pr_number" args in
  if from_pr <> 0 then from_pr
  else Safe_ops.json_int ~default:0 "number" args

type pr_review_exec_result =
  { status : Unix.process_status
  ; output : string
  ; via : string
  }

let status_ok = function
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let effective_repo_slug ~(config : Coord.config) ~(repo : string)
    : (string, string) result =
  let repo = String.trim repo in
  if repo <> "" then
    Keeper_gh_shared.validate_repo_slug repo
  else
    let root = Keeper_alerting_path.project_root_of_config config in
    match Keeper_gh_shared.repo_slug_of_git_root ~git_root:root with
    | Some slug -> Ok slug
    | None -> Error "Could not determine repository. Provide repo parameter."

let repo_flag repo_slug =
  Printf.sprintf " -R %s" (Filename.quote repo_slug)

let docker_pr_review_cwd ~(config : Coord.config) meta =
  let root = Keeper_sandbox.host_root_abs_of_meta ~config meta in
  let cwd = Filename.concat root ".gh-pr-review" in
  ignore (Keeper_fs.ensure_dir cwd);
  cwd

let run_pr_review_shell ~(config : Coord.config) ~(meta : keeper_meta)
    ~timeout_sec ~cmd =
  if meta.sandbox_profile = Docker then
    match
      Keeper_shell_shared.run_docker_shell_command_with_status
        ~config ~meta
        ~cwd:(docker_pr_review_cwd ~config meta)
        ~timeout_sec ~cmd
        ~git_creds_enabled:true
        ~network_mode:Network_inherit
    with
    | Ok result ->
        { status = result.Keeper_shell_docker.status
        ; output = result.output
        ; via = "docker"
        }
    | Error msg ->
        { status = Unix.WEXITED 1
        ; output = msg
        ; via = "docker"
        }
  else
    let root = Keeper_alerting_path.project_root_of_config config in
    let host_cmd =
      Printf.sprintf "cd %s && %s" (Filename.quote root) cmd
    in
    let status, output =
      Process_eio.run_argv_with_status
        ~timeout_sec
        [ "/bin/zsh"; "-lc"; host_cmd ]
    in
    { status; output; via = "host" }

(** Detect "PR not found" in [gh] CLI output. Strings stable across [gh]
    versions; covers both REST 404 and GraphQL "Could not resolve". When
    matched, the keeper sees a structured error and a redirect hint instead
    of having to parse a raw stderr blob, which avoids the "tool error
    messages teach LLM" retry loop documented in
    [memory/feedback_tool-error-messages-teach-llm.md]. *)
let pr_not_found_in_output (s : string) : bool =
  let needles = [
    "HTTP 404: Not Found";
    "no pull requests found";
    "could not resolve to a pullrequest";
    "could not resolve to a node";
  ] in
  let lower = String.lowercase_ascii s in
  List.exists (fun n ->
    let nl = String.lowercase_ascii n in
    let len_s = String.length lower and len_n = String.length nl in
    if len_n > len_s then false
    else
      let rec scan i =
        if i + len_n > len_s then false
        else if String.sub lower i len_n = nl then true
        else scan (i + 1)
      in
      scan 0) needles

let handle_keeper_pr_review_read
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let pr_number = pr_number_of_args args in
  let repo = Safe_ops.json_string ~default:"" "repo" args |> String.trim in
  if pr_number = 0 then
    error_json "pr_number is required. Good: pr_number=123."
  else
    match effective_repo_slug ~config ~repo with
    | Error msg -> error_json msg
    | Ok repo_slug ->
    let repo_flag_arg = repo_flag repo_slug in
    (* Get PR metadata *)
    let meta_cmd = Printf.sprintf
      "gh pr view %d%s --json title,body,state,files,reviews,comments,additions,deletions 2>&1"
      pr_number repo_flag_arg in
    let meta_result =
      run_pr_review_shell ~config ~meta
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Pr_review ())
        ~cmd:meta_cmd in
    (* Get PR diff (truncated) *)
    let diff_cmd = Printf.sprintf
      "gh pr diff %d%s 2>&1 | head -c %d"
      pr_number repo_flag_arg Common.max_tool_output_bytes in
    let diff_result =
      run_pr_review_shell ~config ~meta
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Pr_review ())
        ~cmd:diff_cmd in
    let diff_truncated = String.length diff_result.output >= Common.max_tool_output_bytes in
    let meta_ok = status_ok meta_result.status in
    if not meta_ok && (pr_not_found_in_output meta_result.output || pr_not_found_in_output diff_result.output) then
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool false
            ; "error", `String "pr_not_found"
            ; "pr_number", `Int pr_number
            ; "repo", `String repo_slug
            ; "via", `String meta_result.via
            ; "hint", `String "PR may have been closed/deleted or the number is wrong. Use keeper_pr_list (or `gh pr list`) to see open PRs before retrying."
            ])
    else
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool meta_ok
            ; "pr_number", `Int pr_number
            ; "repo", `String repo_slug
            ; "via", `String meta_result.via
            ; "metadata", `String meta_result.output
            ; "diff", `String diff_result.output
            ; "diff_truncated", `Bool diff_truncated
            ; "diff_status", `Bool (status_ok diff_result.status)
            ])
;;

let handle_keeper_pr_review_comment
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let pr_number = pr_number_of_args args in
  let body = Safe_ops.json_string ~default:"" "body" args |> String.trim in
  let event_raw = Safe_ops.json_string ~default:"COMMENT" "event" args in
  let event_opt = pr_review_event_of_string_opt event_raw in
  let repo = Safe_ops.json_string ~default:"" "repo" args |> String.trim in
  if pr_number = 0 then
    error_json "pr_number is required."
  else if body = "" then
    error_json "body is required."
  else match event_opt with
  | None ->
      error_json
        (Printf.sprintf "event must be one of [%s]; got %S"
           (String.concat ", " valid_pr_review_event_strings) event_raw)
  | Some event ->
    let preset_ok =
      pr_review_mutation_preset_ok
        (Keeper_types.tool_access_preset meta.tool_access)
    in
    if not preset_ok then
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool false
          ; "error", `String "preset_insufficient"
          ; "reason", `String
              (pr_review_mutation_preset_reason "keeper_pr_review_comment")
          ])
    else
      match effective_repo_slug ~config ~repo with
      | Error msg -> error_json msg
      | Ok repo_slug ->
      let repo_flag_arg = repo_flag repo_slug in
      (* Use gh pr review to create a review *)
      let cmd = Printf.sprintf
        "gh pr review %d%s --body %s %s 2>&1"
        pr_number repo_flag_arg
        (Filename.quote body)
        (pr_review_event_to_gh_flag event) in
      let result =
        run_pr_review_shell ~config ~meta
          ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Pr_review_post ())
          ~cmd in
      Log.Keeper.info "pr_review_comment: pr=%d event=%s keeper=%s ok=%b"
        pr_number (pr_review_event_to_string event) meta.name
        (status_ok result.status);
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool (status_ok result.status)
            ; "pr_number", `Int pr_number
            ; "repo", `String repo_slug
            ; "via", `String result.via
            ; "event", `String (pr_review_event_to_string event)
            ; "output", `String result.output
            ; "keeper", `String meta.name
            ])
;;

let handle_keeper_pr_review_reply
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let pr_number = pr_number_of_args args in
  let comment_id = Safe_ops.json_int ~default:0 "comment_id" args in
  let body = Safe_ops.json_string ~default:"" "body" args |> String.trim in
  let repo = Safe_ops.json_string ~default:"" "repo" args |> String.trim in
  if pr_number = 0 then
    error_json "pr_number is required."
  else if comment_id = 0 then
    error_json "comment_id is required."
  else if body = "" then
    error_json "body is required."
  else
    let preset_ok =
      pr_review_mutation_preset_ok
        (Keeper_types.tool_access_preset meta.tool_access)
    in
    if not preset_ok then
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool false
          ; "error", `String "preset_insufficient"
          ; "reason", `String
              (pr_review_mutation_preset_reason "keeper_pr_review_reply")
          ])
    else
      match effective_repo_slug ~config ~repo with
      | Error msg -> error_json msg
      | Ok owner_repo ->
        let cmd = Printf.sprintf
          "gh api repos/%s/pulls/comments/%d/replies -f body=%s 2>&1"
          owner_repo comment_id
          (Filename.quote body) in
        let result =
          run_pr_review_shell ~config ~meta
            ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Pr_review ())
            ~cmd in
        Log.Keeper.info "pr_review_reply: pr=%d comment=%d keeper=%s ok=%b"
          pr_number comment_id meta.name (status_ok result.status);
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool (status_ok result.status)
              ; "pr_number", `Int pr_number
              ; "repo", `String owner_repo
              ; "via", `String result.via
              ; "comment_id", `Int comment_id
              ; "output", `String result.output
              ; "keeper", `String meta.name
              ])
;;
