(** Keeper PR review tools — read, comment, reply handlers.

    Extracted from keeper_exec_github.ml (god file decomp Step 4). *)

open Keeper_types
open Keeper_exec_shared
let handle_keeper_pr_review_read
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  ignore meta;
  let pr_number =
  (* Schema-drift compatibility: tool_shard.ml advertises [number]
     (and most other PR tools also use [number]), but earlier
     versions of these handlers required [pr_number]. Live log
     2026-04-16 /loop iter 9 shows 14/3MB failures from keepers
     sending the schema-canonical key. Read both. *)
  let from_pr_number = Safe_ops.json_int ~default:0 "pr_number" args in
  if from_pr_number <> 0 then from_pr_number
  else Safe_ops.json_int ~default:0 "number" args
in
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
      Process_eio.run_argv_with_status ~timeout_sec:15.0
        [ "/bin/zsh"; "-lc"; meta_cmd ] in
    (* Get PR diff (truncated) *)
    let diff_cmd = Printf.sprintf
      "cd %s && gh pr diff %d%s 2>&1 | head -c %d"
      (Filename.quote root) pr_number repo_flag Common.max_tool_output_bytes in
    let st_diff, out_diff =
      Process_eio.run_argv_with_status ~timeout_sec:15.0
        [ "/bin/zsh"; "-lc"; diff_cmd ] in
    let diff_truncated = String.length out_diff >= Common.max_tool_output_bytes in
    Yojson.Safe.to_string
      (`Assoc
          [ "ok", `Bool (st_meta = Unix.WEXITED 0)
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
  let pr_number =
  (* Schema-drift compatibility: tool_shard.ml advertises [number]
     (and most other PR tools also use [number]), but earlier
     versions of these handlers required [pr_number]. Live log
     2026-04-16 /loop iter 9 shows 14/3MB failures from keepers
     sending the schema-canonical key. Read both. *)
  let from_pr_number = Safe_ops.json_int ~default:0 "pr_number" args in
  if from_pr_number <> 0 then from_pr_number
  else Safe_ops.json_int ~default:0 "number" args
in
  let body = Safe_ops.json_string ~default:"" "body" args |> String.trim in
  let event = Safe_ops.json_string ~default:"COMMENT" "event" args |> String.trim |> String.uppercase_ascii in
  let repo = Safe_ops.json_string ~default:"" "repo" args |> String.trim in
  if pr_number = 0 then
    error_json "pr_number is required."
  else if body = "" then
    error_json "body is required."
  else if not (List.mem event ["COMMENT"; "APPROVE"; "REQUEST_CHANGES"]) then
    error_json "event must be COMMENT, APPROVE, or REQUEST_CHANGES."
  else
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
        (match event with
         | "APPROVE" -> "--approve"
         | "REQUEST_CHANGES" -> "--request-changes"
         | _ -> "--comment") in
      let st, out =
        Process_eio.run_argv_with_status ~timeout_sec:30.0
          [ "/bin/zsh"; "-lc"; cmd ] in
      Log.Keeper.info "pr_review_comment: pr=%d event=%s keeper=%s ok=%b"
        pr_number event meta.name (st = Unix.WEXITED 0);
      Yojson.Safe.to_string
        (`Assoc
            [ "ok", `Bool (st = Unix.WEXITED 0)
            ; "pr_number", `Int pr_number
            ; "event", `String event
            ; "output", `String out
            ; "keeper", `String meta.name
            ])
;;

let handle_keeper_pr_review_reply
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  =
  let pr_number =
  (* Schema-drift compatibility: tool_shard.ml advertises [number]
     (and most other PR tools also use [number]), but earlier
     versions of these handlers required [pr_number]. Live log
     2026-04-16 /loop iter 9 shows 14/3MB failures from keepers
     sending the schema-canonical key. Read both. *)
  let from_pr_number = Safe_ops.json_int ~default:0 "pr_number" args in
  if from_pr_number <> 0 then from_pr_number
  else Safe_ops.json_int ~default:0 "number" args
in
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
          let st, out =
            Process_eio.run_argv_with_status ~timeout_sec:5.0
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
          Process_eio.run_argv_with_status ~timeout_sec:15.0
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
