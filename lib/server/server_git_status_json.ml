let change_json (change : Repo_git.status_file) =
  `Assoc
    [ ("path", `String change.path)
    ; ("staged", `Bool change.staged)
    ; ("unstaged", `Bool change.unstaged)
    ; ("untracked", `Bool change.untracked)
    ; ("conflicted", `Bool change.conflicted)
    ]

let upstream_json (upstream : Repo_git.upstream_state) =
  match upstream with
  | Repo_git.No_upstream -> `Null
  | Repo_git.Upstream_gone upstream ->
      `Assoc [ ("name", `String upstream); ("ahead", `Null); ("behind", `Null) ]
  | Repo_git.Tracking { upstream; ahead; behind } ->
      `Assoc
        [ ("name", `String upstream)
        ; ("ahead", `Int ahead)
        ; ("behind", `Int behind)
        ]

let branch_json (branch : Repo_git.branch_status) =
  match branch with
  | Repo_git.Detached -> `Assoc [ ("head", `Null); ("upstream", `Null) ]
  | Repo_git.On_branch { name; upstream } ->
      `Assoc [ ("head", `String name); ("upstream", upstream_json upstream) ]

let snapshot ~scope ~branch ~changes =
  `Assoc
    [ ("scope", scope)
    ; ("branch", branch_json branch)
    ; ("changes", `List (List.map change_json changes))
    ; ("total", `Int (List.length changes))
    ]
