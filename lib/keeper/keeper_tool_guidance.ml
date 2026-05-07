(** Policy-derived keeper tool guidance.

    Prompts must not advertise tools outside the active keeper policy.  The
    model already receives the real schema set from OAS; this module renders
    short human-readable hints by filtering curated affordances through that
    same allowed-name set. *)

type hint =
  { name : string
  ; call : string
  ; description : string
  }

let hints =
  [ { name = "keeper_task_claim"
    ; call = "`keeper_task_claim` {}"
    ; description = "reserve the next eligible task"
    }
  ; { name = "keeper_tasks_list"
    ; call = "`keeper_tasks_list` {}"
    ; description = "inspect eligible task context"
    }
  ; { name = "keeper_task_create"
    ; call =
        "`keeper_task_create` { title: \"<verb + object>\", description: \
         \"<acceptance criteria>\" }"
    ; description = "create a new backlog task with keeper-native evidence"
    }
  ; { name = "keeper_board_get"
    ; call = "`keeper_board_get` { id: \"<post-id>\" }"
    ; description = "read a board post before replying"
    }
  ; { name = "keeper_board_comment"
    ; call = "`keeper_board_comment` { post_id: \"<post-id>\", content: \"<reply>\" }"
    ; description = "reply to a board post"
    }
  ; { name = "keeper_board_post"
    ; call = "`keeper_board_post` { content: \"<note>\" }"
    ; description = "coordinate via board"
    }
  ; { name = "keeper_broadcast"
    ; call = "`keeper_broadcast` { message: \"<note>\" }"
    ; description = "share broadly in the namespace"
    }
  ; { name = "keeper_fs_read"
    ; call = "`keeper_fs_read` { path: \"<path>\" }"
    ; description = "read a file before editing or reporting"
    }
  ; { name = "keeper_fs_edit"
    ; call =
        "`keeper_fs_edit` { path: \"<path>\", mode: \"patch\", old_string: \"...\", \
         new_string: \"...\" }"
    ; description = "edit files inside the keeper workspace"
    }
  ; { name = "keeper_shell"
    ; call = "`keeper_shell` { op: \"gh\", cmd: \"pr list --state open\" }"
    ; description = "inspect GitHub after a task/worktree is bound"
    }
  ; { name = "keeper_bash"
    ; call = "`keeper_bash` { cmd: \"<single shell command>\" }"
    ; description = "run one shell command in the keeper workspace"
    }
  ; { name = "masc_web_search"
    ; call = "`masc_web_search` { query: \"<current-info query>\", limit: 5 }"
    ; description = "look up current public context before time-sensitive claims"
    }
  ; { name = "masc_worktree_create"
    ; call = "`masc_worktree_create` { task_id: \"<task-id>\", repo_name: \"masc-mcp\" }"
    ; description = "create a repo worktree before code edits"
    }
  ; { name = "keeper_task_submit_for_verification"
    ; call =
        "`keeper_task_submit_for_verification` { notes: \"<evidence>\", pr_url: \
         \"<url>\" }"
    ; description = "submit PR/code work for verification"
    }
  ; { name = "keeper_task_done"
    ; call = "`keeper_task_done` { notes: \"<evidence>\" }"
    ; description = "close non-PR task work with evidence"
    }
  ; { name = "keeper_stay_silent"
    ; call = "`keeper_stay_silent` {}"
    ; description = "nothing genuinely actionable fits your role"
    }
  ]
;;

let allowed_lookup allowed_tool_names =
  let tbl = Hashtbl.create (List.length allowed_tool_names) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) allowed_tool_names;
  tbl
;;

let allowed_hints ~allowed_tool_names =
  let allowed = allowed_lookup allowed_tool_names in
  List.filter (fun hint -> Hashtbl.mem allowed hint.name) hints
;;

let line_of_hint hint = Printf.sprintf "  - %s - %s" hint.call hint.description

let render_preferred_tools ~allowed_tool_names =
  let lines = allowed_hints ~allowed_tool_names |> List.map line_of_hint in
  match lines with
  | [] ->
    "Preferred keeper tools: use only the tool schemas currently shown by the runtime."
  | _ ->
    "Preferred keeper tools currently allowed for you (copy the name and schema verbatim):\n"
    ^ String.concat "\n" lines
;;

let has allowed_tool_names name = List.mem name allowed_tool_names

let render_gh_workflow ~allowed_tool_names =
  let has_shell = has allowed_tool_names "keeper_shell" in
  let has_worktree = has allowed_tool_names "masc_worktree_create" in
  let has_bash = has allowed_tool_names "keeper_bash" in
  let has_verify = has allowed_tool_names "keeper_task_submit_for_verification" in
  let has_pr_create = has allowed_tool_names "keeper_pr_create" in
  match has_shell, has_worktree, has_bash, has_verify, has_pr_create with
  | true, true, true, true, true ->
    Some
      "GitHub/code workflow: if you do not already hold a task, call `keeper_task_claim` \
       first; `keeper_shell op=gh` derives repo context from the active task \
       worktree/current_task_id. Then inspect with `keeper_shell op=gh`; if code change \
       is needed, `masc_worktree_create` -> edit -> `keeper_bash` for `git add` / `git \
       commit` / `git push` -> `keeper_pr_create` with `draft=true` \
       -> `keeper_task_submit_for_verification` with notes and `pr_url`."
  | true, true, true, true, false ->
    Some
      "GitHub/code workflow: if you do not already hold a task, call `keeper_task_claim` \
       first; inspect with `keeper_shell op=gh`; if code change is needed, \
       `masc_worktree_create` -> edit -> `keeper_bash` for `git add` / `git commit` / \
       `git push`. Do not create PRs through `keeper_shell op=gh`; submit verification \
       notes with the pushed branch and request a dedicated draft-PR tool."
  | true, _, _, _, _ ->
    Some
      "GitHub workflow: use `keeper_shell op=gh` only for commands supported by your \
       active tool policy. `keeper_shell op=gh` derives repo context from the active \
       task worktree/current_task_id; claim a task first when repo context is required. \
       Do not create PRs through `keeper_shell op=gh`; use the dedicated draft-PR tool \
       when it is listed."
  | _ -> None
;;

let render_unknown_tool_guard () =
  "Do not call tool names that are absent from the active runtime schema list. Heartbeat \
   is server-managed; public lifecycle/status tools such as `masc_join`, `masc_who`, and \
   `masc_heartbeat` are not keeper action tools unless they are explicitly shown to you. \
   Copy active schema names exactly; do not substitute public `masc_*` aliases such as \
   `masc_board_list` for keeper-scoped tools."
;;
