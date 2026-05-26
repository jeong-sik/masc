(** Tool_shard_types_schemas_github_pr — read-only GitHub PR tool schemas. *)

(** Read-only GitHub PR tools. PR creation is a GitHub/forge mutation and is
    intentionally not exposed as a keeper-native concept. *)
let keeper_github_pr_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_pr_list"
    ; description =
        "List GitHub pull requests with keeper-scoped credentials. Runs credential \
         preflight before gh, accepts repo owner/name or cwd, and returns gh JSON. \
         Read-only. NOTE: there is no keeper_pr_create tool — to create a PR, use \
         Execute with executable=\"gh\" argv=[\"pr\",\"create\",...]."
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
         credential preflight before gh. Pass pr_number. NOTE: there is no \
         keeper_pr_create tool — to create a PR, use Execute with \
         executable=\"gh\" argv=[\"pr\",\"create\",...]."
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
                      ; "description", `String "PR number"
                      ] )
                ] )
          ; "required", `List [ `String "pr_number" ]
          ]
    }
  ]
;;
