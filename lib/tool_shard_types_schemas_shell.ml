(** Tool_shard_types_schemas_shell — [shell_tools] keeper_shell schema. *)

open Tool_shard_types_enum_mirrors

let shell_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_shell"
    ; description =
        "Run a structured project shell operation. ops: pwd, ls, cat, rg, git_status, \
         find, head, tail, wc, tree, git_log, git_diff, git_worktree, git_clone, gh. \
         Structured ops default to the keeper sandbox. IMPORTANT: paths resolve \
         automatically — use 'repos/X' or 'mind/X'. Never include host paths like \
         '.masc/playground/your-name/repos/X' in path or cwd. Use cwd to target an \
         explicit allowed directory or cloned repo. find REQUIRES pattern param (e.g. \
         pattern=\"*.ml\"). No generic bash execution: use Bash/keeper_bash for command \
         execution. git_clone: clone a repo into your sandbox repos/ lane (url \
         required). gh op: run a gh CLI subcommand with cmd=\"<subcommand>\" (e.g. \
         cmd=\"pr list --state open\"). Requires an active claimed task/current_task_id \
         because repo context is derived from the task worktree. Always run `gh pr list` \
         first before referencing a PR number to avoid hallucinations. Dangerous \
         commands (repo delete, auth logout, secret set/delete) are blocked. If path not \
         found, clone the repo first with op=git_clone. Use rg for pattern search, find \
         for path discovery, head/tail for line ranges, git_log/git_diff for repo \
         history, gh for GitHub PR/issue/CI."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ (* Issue #8524: derive from local mirror tracking
           [Keeper_exec_shell.valid_shell_op_strings].  Schema used to
           omit git_worktree even though the handler accepted it. *)
                  ( "op"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "enum"
                        , `List
                            (List.map (fun s -> `String s) keeper_shell_op_enum_strings) )
                      ; "description", `String "Structured operation to run"
                      ] )
                ; ( "cmd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "gh subcommand for op=gh, e.g. 'pr list --state open'. \
                             Requires an active claimed task/current_task_id. The active \
                             task worktree determines the repo; any --repo flag is \
                             normalized to that repo." )
                      ] )
                ; ( "path"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "Target path for ls/cat/rg/find/head/tail/wc/tree" )
                      ] )
                ; ( "cwd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Optional working directory for \
                             pwd/git_status/git_log/git_diff/git_worktree. Must stay \
                             within the keeper sandbox or an explicit allowed path." )
                      ] )
                ; ( "pattern"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Search pattern for rg, or name glob for find (REQUIRED for \
                             find, e.g. \"*.ml\")" )
                      ] )
                ; ( "limit"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String
                            "Result limit for ls/rg/find/tree, or line count for git_log"
                        )
                      ] )
                ; ( "lines"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String "Number of lines for head/tail (default 20, max 200)" )
                      ] )
                ; ( "max_bytes"
                  , `Assoc
                      [ "type", `String "integer"
                      ; "description", `String "Max bytes for cat"
                      ] )
                ; ( "url"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Git repo URL for git_clone op (e.g. \
                             'https://github.com/org/repo'). Clones into sandbox repos/."
                        )
                      ] )
                ] )
          ; "required", `List [ `String "op" ]
          ]
    }
  ]
;;
