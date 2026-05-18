(** Tool_shard_types_schemas_github_pr — Dedicated GitHub PR workflow tool schemas (keeper_pr_list/status/create). *)

(** Dedicated GitHub PR workflow tools. *)
let keeper_github_pr_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_pr_list"
    ; description =
        "List GitHub pull requests with keeper-scoped credentials. Runs credential \
         preflight before gh, accepts repo owner/name or cwd, and returns gh JSON. \
         Read-only."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "GitHub repo (owner/name). Optional when cwd is a git repo." )
                      ] )
                ; ( "cwd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Optional keeper sandbox repo/worktree cwd." )
                      ] )
                ; ( "state"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            [ `String "open"
                            ; `String "closed"
                            ; `String "merged"
                            ; `String "all"
                            ] )
                      ; "description", `String "PR state filter. Default open."
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Max PRs to return, 1-100. Default 20."
                      ] )
                ] )
          ]
    }
  ; { name = "keeper_pr_status"
    ; description =
        "Read one GitHub PR status/details with keeper-scoped credentials. Runs \
         credential preflight before gh. Pass pr_number (preferred) or number."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "GitHub repo (owner/name). Optional when cwd is a git repo." )
                      ] )
                ; ( "cwd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Optional keeper sandbox repo/worktree cwd." )
                      ] )
                ; ( "pr_number"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "PR number (preferred field name)"
                      ] )
                ; ( "number"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "PR number (legacy alias for pr_number)"
                      ] )
                ] )
          ]
    }
  ; { name = "keeper_pr_create"
    ; description =
        "Create a draft GitHub pull request with keeper-scoped credentials. Draft-only \
         by policy: omit draft or set draft=true. Requires delivery, coding, or full \
         preset."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "GitHub repo (owner/name). Optional when cwd is a git repo." )
                      ] )
                ; ( "cwd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Keeper sandbox repo/worktree cwd. Required when repo cannot \
                             infer the branch context." )
                      ] )
                ; ( "title"
                  , `Assoc [ "type", `String "string"; "description", `String "PR title" ]
                  )
                ; ( "body"
                  , `Assoc [ "type", `String "string"; "description", `String "PR body" ]
                  )
                ; ( "base"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Optional base branch"
                      ] )
                ; ( "head"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Optional head branch"
                      ] )
                ; ( "draft"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; ( "description"
                        , `String
                            "Must be true if provided; ready PR creation is rejected." )
                      ] )
                ] )
          ; "required", `List [ `String "title"; `String "body" ]
          ]
    }
  ]
;;
