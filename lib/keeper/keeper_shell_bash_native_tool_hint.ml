(* gh-pr native-tool routing hints for keeper_bash.

   When a [gh pr <list|status|diff|review>] command would be accepted
   by keeper_bash, surface the corresponding keeper_pr_* native tool
   suggestion so the PR action keeps its native-tool receipt path
   (audit/approval/retry).

   Extracted from [Keeper_shell_bash] (godfile decomp). Pure mapping
   over [Keeper_shell_bash_words.cmd_gh_pr_native_subcommand]. *)

open Keeper_shell_bash_words

type native_tool_hint =
  { rule_id : string
  ; tool_suggestion : string
  ; rewrite : string
  ; hint : string
  ; alternatives : string list
  }

let gh_pr_native_tool_hint cmd =
  let make ~rule_id ~tool_suggestion ~rewrite ~hint ~alternatives =
    Some { rule_id; tool_suggestion; rewrite; hint; alternatives }
  in
  match cmd_gh_pr_native_subcommand cmd with
  | Some Gh_pr_list ->
    make
      ~rule_id:"gh_pr_list_requires_keeper_pr_list"
      ~tool_suggestion:"keeper_pr_list"
      ~rewrite:"Use keeper_pr_list with the same repo/state/search intent."
      ~hint:
        "Do not call gh pr list through raw Bash. Use keeper_pr_list so PR \
         reads are routed through the native PR tool surface."
      ~alternatives:
        [ "keeper_pr_list repo=OWNER/REPO state=open"
        ; "keeper_pr_list repo=OWNER/REPO search=term"
        ]
  | Some Gh_pr_status ->
    make
      ~rule_id:"gh_pr_status_requires_keeper_pr_status"
      ~tool_suggestion:"keeper_pr_status"
      ~rewrite:"Use keeper_pr_status for PR state, checks, draft state, and mergeability."
      ~hint:
        "Do not call gh pr view/status/checks through raw Bash. Use \
         keeper_pr_status so PR status reads are captured by the native PR \
         receipt path."
      ~alternatives:
        [ "keeper_pr_status pr=NUMBER repo=OWNER/REPO"
        ; "keeper_pr_status head=BRANCH repo=OWNER/REPO"
        ]
  | Some Gh_pr_diff ->
    make
      ~rule_id:"gh_pr_diff_requires_keeper_pr_review_read"
      ~tool_suggestion:"keeper_pr_review_read"
      ~rewrite:"Use keeper_pr_review_read for PR diff/review context reads."
      ~hint:
        "Do not call gh pr diff through raw Bash. Use \
         keeper_pr_review_read so review context is read through the PR review \
         tool surface."
      ~alternatives:
        [ "keeper_pr_review_read pr=NUMBER repo=OWNER/REPO"
        ; "keeper_pr_status pr=NUMBER repo=OWNER/REPO"
        ]
  | Some Gh_pr_review ->
    make
      ~rule_id:"gh_pr_review_requires_keeper_pr_review_comment"
      ~tool_suggestion:"keeper_pr_review_comment"
      ~rewrite:"Use keeper_pr_review_comment for PR review comments or review actions."
      ~hint:
        "Do not call gh pr review/comment through raw Bash. Use \
         keeper_pr_review_comment so review actions keep approval and audit \
         receipts."
      ~alternatives:
        [ "keeper_pr_review_comment pr=NUMBER repo=OWNER/REPO body=..."
        ; "keeper_pr_review_read pr=NUMBER repo=OWNER/REPO"
        ]
  | None -> None
;;

let native_tool_diagnosis hint =
  { Exec_core.rule_id = hint.rule_id
  ; explanation =
      "Raw GitHub PR commands are blocked in Bash; the native PR tool \
       surface preserves routing, audit, and retry receipts."
  ; rewrite = Some hint.rewrite
  ; tool_suggestion = Some hint.tool_suggestion
  }
;;
