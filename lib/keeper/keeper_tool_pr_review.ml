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

(* Both "pr_number" and "number" are accepted for schema-drift compat. *)
let pr_number_of_args args =
  let from_pr = Safe_ops.json_int ~default:0 "pr_number" args in
  if from_pr <> 0 then from_pr
  else Safe_ops.json_int ~default:0 "number" args

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
  ignore meta;
  let pr_number = pr_number_of_args args in
  let repo = Safe_ops.json_string ~default:"" "repo" args |> String.trim in
  if pr_number = 0 then
    error_json "pr_number is required. Good: pr_number=123."
  else
    let root = Keeper_alerting_path.project_root_of_config config in
    let repo_flag = if repo <> "" then Printf.sprintf " -R %s" (Filename.quote repo) else "" in
    (* Get PR metadata *)
    let meta_cmd = Printf.sprintf
      "cd %s && gh pr view %d%s --json title,body,state,files,reviews,comments,additions,deletions 2>&1"
      (Filename.quote root) pr_number repo_flag in
    let st_meta, out_meta =
      Process_eio.run_argv_with_status
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Pr_review ())
        [ "/bin/zsh"; "-lc"; meta_cmd ] in
    (* Get PR diff (truncated) *)
    let diff_cmd = Printf.sprintf
      "cd %s && gh pr diff %d%s 2>&1 | head -c %d"
      (Filename.quote root) pr_number repo_flag Common.max_tool_output_bytes in
    let st_diff, out_diff =
      Process_eio.run_argv_with_status
        ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Pr_review ())
        [ "/bin/zsh"; "-lc"; diff_cmd ] in
    let diff_truncated = String.length out_diff >= Common.max_tool_output_bytes in
    let meta_ok = (st_meta = Unix.WEXITED 0) in
    if not meta_ok && (pr_not_found_in_output out_meta || pr_not_found_in_output out_diff) then
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool false
            ; "error", `String "pr_not_found"
            ; "pr_number", `Int pr_number
            ; "repo", `String repo
            ; "hint", `String "PR may have been closed/deleted or the number is wrong. Use keeper_pr_list (or `gh pr list`) to see open PRs before retrying."
            ])
    else
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool meta_ok
            ; "pr_number", `Int pr_number
            ; "metadata", `String out_meta
            ; "diff", `String out_diff
            ; "diff_truncated", `Bool diff_truncated
            ; "diff_status", `Bool (st_diff = Unix.WEXITED 0)
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
    (* Check preset: requires delivery/coding/full for mutations *)
    let preset_ok =
      match Keeper_types.tool_access_preset meta.tool_access with
      | Some (Delivery | Coding | Full) -> true
      | _ -> false
    in
    if not preset_ok then
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool false
          ; "error", `String "preset_insufficient"
          ; "reason", `String "keeper_pr_review_comment requires delivery, coding, or full preset"
          ])
    else
      let root = Keeper_alerting_path.project_root_of_config config in
      let repo_flag = if repo <> "" then Printf.sprintf " -R %s" (Filename.quote repo) else "" in
      (* Use gh pr review to create a review *)
      let cmd = Printf.sprintf
        "cd %s && gh pr review %d%s --body %s %s 2>&1"
        (Filename.quote root) pr_number repo_flag
        (Filename.quote body)
        (pr_review_event_to_gh_flag event) in
      let st, out =
        Process_eio.run_argv_with_status
          ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Pr_review_post ())
          [ "/bin/zsh"; "-lc"; cmd ] in
      Log.Keeper.info "pr_review_comment: pr=%d event=%s keeper=%s ok=%b"
        pr_number (pr_review_event_to_string event) meta.name (st = Unix.WEXITED 0);
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool (st = Unix.WEXITED 0)
            ; "pr_number", `Int pr_number
            ; "event", `String (pr_review_event_to_string event)
            ; "output", `String out
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
      match Keeper_types.tool_access_preset meta.tool_access with
      | Some (Delivery | Coding | Full) -> true
      | _ -> false
    in
    if not preset_ok then
      Yojson.Safe.to_string
        (`Assoc
          [ "ok", `Bool false
          ; "error", `String "preset_insufficient"
          ; "reason", `String "keeper_pr_review_reply requires delivery, coding, or full preset"
          ])
    else
      let root = Keeper_alerting_path.project_root_of_config config in
      (* Determine owner/repo *)
      let owner_repo =
        if repo <> "" then repo
        else
          (* Deviation from Env_config_exec_timeout.Pr_review (15s):
             one-off [nameWithOwner] lookup is read-only and tightly
             bounded.  See #10594 — a dedicated caller variant for a
             single site is over-engineering, so this stays
             hardcoded.  If a third site needs 5s budget,
             reconsider. *)
          let st, out =
            Process_eio.run_argv_with_status ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Gh_shared ())
              [ "/bin/zsh"; "-lc";
                Printf.sprintf "cd %s && gh repo view --json nameWithOwner -q .nameWithOwner 2>&1"
                  (Filename.quote root) ] in
          if st = Unix.WEXITED 0 then String.trim out else ""
      in
      if owner_repo = "" then
        error_json "Could not determine repository. Provide repo parameter."
      else
        let cmd = Printf.sprintf
          "cd %s && gh api repos/%s/pulls/comments/%d/replies -f body=%s 2>&1"
          (Filename.quote root)
          owner_repo comment_id
          (Filename.quote body) in
        let st, out =
          Process_eio.run_argv_with_status
            ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Pr_review ())
            [ "/bin/zsh"; "-lc"; cmd ] in
        Log.Keeper.info "pr_review_reply: pr=%d comment=%d keeper=%s ok=%b"
          pr_number comment_id meta.name (st = Unix.WEXITED 0);
        Yojson.Safe.to_string
          (`Assoc
              [ "ok", `Bool (st = Unix.WEXITED 0)
              ; "pr_number", `Int pr_number
              ; "comment_id", `Int comment_id
              ; "output", `String out
              ; "keeper", `String meta.name
              ])
;;
