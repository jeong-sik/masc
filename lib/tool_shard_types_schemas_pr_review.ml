(** Tool_shard_types_schemas_pr_review — PR review tools (read, comment, reply) schemas. *)

open Tool_shard_types_enum_mirrors

(** PR review tools — read diffs, leave comments, approve/request changes. *)
let keeper_pr_review_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_pr_review_read"
    ; description =
        "Read PR metadata, diff, reviews, and comments. Returns title, body, changed \
         files, review threads, and truncated diff (max 64KB). Read-only. Pass the PR \
         number as `pr_number` (preferred) or `number` (legacy alias)."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "GitHub repo (owner/name)"
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
          ; (* No `required` for the number — the handler reads either
         pr_number or number and emits a clear error if both are
         missing. Schema-level required=[number] rejected callers
         that learned the historical pr_number key. *)
            "required", `List [ `String "repo" ]
          ]
    }
  ; { name = "keeper_pr_review_comment"
    ; description =
        "Submit a PR review with optional inline comments. Events: COMMENT, APPROVE, \
         REQUEST_CHANGES. Requires research, delivery, coding, or full preset. Use \
         REQUEST_CHANGES for actionable blockers; use APPROVE only when the draft proof \
         preflight permits it. Pass the PR number as `pr_number` (preferred) or `number` \
         (legacy alias)."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "GitHub repo (owner/name)"
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
                ; ( "body"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Review body text"
                      ] )
                ; (* Issue #8480: mirrors [Keeper_tool_pr_review.valid_pr_review_event_strings].
           Direct dependency would create a cycle (Tool_shard ->
           Keeper_tool_pr_review -> Keeper_alerting -> Tool_shard), so the
           sync regression test [test_types.ml :: pr_review_event_ssot]
           asserts these stay in lock-step. Same pattern as #8467
           (sandbox_profile / network_mode). *)
                  ( "event"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            (List.map (fun s -> `String s) pr_review_event_enum_strings) )
                      ; "description", `String "Review event type"
                      ] )
                ; ( "path"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "File path for inline comment (optional)"
                      ] )
                ; ( "line"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Line number for inline comment (optional)"
                      ] )
                ] )
          ; "required", `List [ `String "repo"; `String "body"; `String "event" ]
          ]
    }
  ; { name = "keeper_pr_review_reply"
    ; description =
        "Reply to a specific PR review comment. Requires research, delivery, coding, or \
         full preset. Pass the PR number as `pr_number` (preferred) or `number` (legacy \
         alias)."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "repo"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "GitHub repo (owner/name)"
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
                ; ( "comment_id"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Comment ID to reply to"
                      ] )
                ; ( "body"
                  , `Assoc
                      [ "type", `String "string"
                      ; "description", `String "Reply body text"
                      ] )
                ] )
          ; "required", `List [ `String "repo"; `String "comment_id"; `String "body" ]
          ]
    }
  ]
;;
