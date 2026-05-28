(** Tool_shard_types_schemas_git_pr — keeper_git_* and keeper_pr_* tool schemas.

    RFC-0202: Dedicated Git/PR tool surfaces for keepers.
    Replaces shell passthrough via [tool_execute] with typed, governed tools. *)

let git_pr_tools : Masc_domain.tool_schema list =
  [ { name = "tool_git_clone"
    ; description =
        "Clone a repository into the keeper's playground workspace. Uses \
         injected credentials — the keeper never sees tokens. Returns the \
         cloned path and checked-out branch."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repository"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description"
                      , `String
                          "Repository URL or owner/repo shorthand (e.g., \
                           'jeong-sik/masc-mcp')"
                      ] )
                ; ( "branch"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description"
                      , `String
                          "Branch to checkout after clone (default: repository \
                           default branch)"
                      ] )
                ; ( "depth"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description"
                      , `String "Clone depth (default: 1 for shallow clone)"
                      ] )
                ] )
          ; "required", `List [ `String "repository" ]
          ]
    }
  ; { name = "tool_git_commit"
    ; description =
        "Stage and commit changes in the current workspace. Use \
         Conventional Commits format for messages. Returns the new commit SHA."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "message"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description"
                      , `String
                          "Commit message (Conventional Commits format preferred)"
                      ] )
                ; ( "files"
                  , `Assoc
                      [ "type", `String "array"
                      ; "items", `Assoc [ "type", `String "string" ]
                      ; "description"
                      , `String
                          "Specific files to stage (default: all changed files)"
                      ] )
                ; ( "allow_empty"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; "description"
                      , `String "Allow empty commit (default: false)"
                      ] )
                ] )
          ; "required", `List [ `String "message" ]
          ]
    }
  ; { name = "tool_git_push"
    ; description =
        "Push committed changes to a remote repository. Uses injected \
         credentials for authentication. Force push requires approval gate."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "remote"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description"
                      , `String "Remote name (default: 'origin')"
                      ] )
                ; ( "branch"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description"
                      , `String "Branch to push (default: current branch)"
                      ] )
                ; ( "force"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; "description"
                      , `String
                          "Force push (default: false, requires approval gate)"
                      ] )
                ; ( "set_upstream"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; "description"
                      , `String
                          "Set upstream tracking (default: true for new branches)"
                      ] )
                ] )
          ]
    }
  ; { name = "tool_pr_create"
    ; description =
        "Create a draft pull request on GitHub. Uses injected credentials. \
         Always creates as draft by default — use masc_transition or approval \
         workflow to mark ready."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "title"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "PR title"
                      ] )
                ; ( "body"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "PR body (markdown)"
                      ] )
                ; ( "base"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description"
                      , `String "Base branch (default: repository default)"
                      ] )
                ; ( "draft"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; "description"
                      , `String "Create as draft (default: true)"
                      ] )
                ; ( "reviewers"
                  , `Assoc
                      [ "type", `String "array"
                      ; "items", `Assoc [ "type", `String "string" ]
                      ; "description", `String "Reviewer usernames"
                      ] )
                ] )
          ; "required", `List [ `String "title" ]
          ]
    }
  ; { name = "tool_pr_review"
    ; description =
        "Submit a review on a GitHub pull request. Supports APPROVE, \
         REQUEST_CHANGES, and COMMENT events. Inline comments can target \
         specific file lines."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "pr_number"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "PR number to review"
                      ] )
                ; ( "event"
                  , `Assoc
                      [ "type", `String "string"
                      ; "enum"
                      , `List
                          [ `String "APPROVE"
                          ; `String "REQUEST_CHANGES"
                          ; `String "COMMENT"
                          ]
                      ; "description", `String "Review event type"
                      ] )
                ; ( "body"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Review comment body"
                      ] )
                ; ( "comments"
                  , `Assoc
                      [ "type", `String "array"
                      ; "items"
                      , `Assoc
                          [ "type", `String "object"
                          ; ( "properties"
                            , `Assoc
                                [ "path"
                                , `Assoc [ "type", `String "string" ]
                                ; "line"
                                , `Assoc [ "type", `String "integer" ]
                                ; "body"
                                , `Assoc [ "type", `String "string" ]
                                ] )
                          ; "required"
                          , `List
                              [ `String "path"
                              ; `String "line"
                              ; `String "body"
                              ]
                          ]
                      ; "description", `String "Inline review comments"
                      ] )
                ] )
          ; "required", `List [ `String "pr_number"; `String "event" ]
          ]
    }
  ]
;;
