(** Tool_shard_types_schemas_bash — [coding_keeper_bridge_tools] keeper_bash + keeper_bash_output + keeper_bash_kill schemas. *)

let coding_keeper_bridge_tools : Masc_domain.tool_schema list =
  [ { name = "keeper_bash"
    ; description =
        "Execute ONE shell command through the keeper_bash safety gates. No \
         chaining/control syntax (&&, ||, ;), command substitution, background \
         operators, or file redirects. Pipelines and fd-only redirects are accepted only \
         when the active preset validator allows every segment. Good: cmd='scripts/dune-local.sh build', \
         cmd='ls -la lib/'. Bad: cmd='cd x && dune build', cmd='echo hi > out.txt'. Runs \
         in the keeper sandbox by default; use cwd to target an explicit allowed \
         directory. Paths resolve automatically — never include host storage prefixes \
         such as '.masc/playground/your-name/' in cwd. Use 'repos/X' instead. Sandbox \
         root is NOT a git repository: git/gh calls require cwd='repos/<REPO_NAME>' (or \
         the worktree path under it). 'not a git repository' or 'path_outside_sandbox' \
         from the sandbox root means you forgot the cwd. For read-only ops use \
         keeper_shell, for file edits use keeper_fs_edit. Set run_in_background=true for \
         long-running tasks (returns background_task_id; poll with keeper_bash_output, \
         terminate with keeper_bash_kill)."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "cmd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Single command only. No chaining/control syntax or file \
                             redirects. Example: 'scripts/dune-local.sh build', 'rg pattern lib/'" )
                      ] )
                ; ( "cwd"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Optional working directory for the command. Must stay \
                             within the keeper sandbox or an explicit allowed path." )
                      ] )
                ; ( "timeout_sec"
                  , `Assoc
                      [ "type", `String "number"
                      ; ( "description"
                        , `String
                            "Timeout seconds (default: 30, max: 180). For \
                             run_in_background=true, 0 disables the timeout." )
                      ] )
                ; ( "run_in_background"
                  , `Assoc
                      [ "type", `String "boolean"
                      ; ( "description"
                        , `String
                            "Default false. When true, returns immediately with \
                             background_task_id; poll output via keeper_bash_output, \
                             stop via keeper_bash_kill." )
                      ] )
                ] )
          ; "required", `List [ `String "cmd" ]
          ]
    }
  ; { name = "keeper_bash_output"
    ; description =
        "Fetch incremental output from a background shell task spawned via keeper_bash \
         with run_in_background=true. Non-blocking: returns whatever stdout/stderr bytes \
         are currently buffered beyond the given offsets. Poll repeatedly until \
         closed=true. Mirrors claude-code BashOutput semantics."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "task_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "background_task_id returned by keeper_bash. Example: \
                             'bgt-1713600000-000001-12345'." )
                      ] )
                ; ( "since_stdout"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String
                            "Cumulative byte offset at which to start reading stdout. \
                             Use 0 for the first call, then the running length returned \
                             previously." )
                      ] )
                ; ( "since_stderr"
                  , `Assoc
                      [ "type", `String "integer"
                      ; ( "description"
                        , `String
                            "Same cursor for stderr. Note: in the current implementation \
                             keeper_bash redirects stderr into stdout so stderr_since is \
                             usually empty." )
                      ] )
                ] )
          ; "required", `List [ `String "task_id" ]
          ]
    }
  ; { name = "keeper_bash_kill"
    ; description =
        "Terminate a background shell task. Sends [signal] (default SIGTERM) to the \
         task's process group, waits up to grace_sec seconds, and escalates to SIGKILL \
         if any member survives. Idempotent — safe to call on already-exited tasks. \
         Mirrors claude-code KillShell semantics."
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; ( "properties"
            , `Assoc
                [ ( "task_id"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String "background_task_id returned by keeper_bash." )
                      ] )
                ; ( "signal"
                  , `Assoc
                      [ "type", `String "string"
                      ; ( "description"
                        , `String
                            "Signal name (TERM, KILL, INT, HUP, QUIT) or number. Default \
                             TERM." )
                      ] )
                ; ( "grace_sec"
                  , `Assoc
                      [ "type", `String "number"
                      ; ( "description"
                        , `String
                            "Seconds to wait for graceful exit before SIGKILL \
                             escalation. Default 2.0, max 30." )
                      ] )
                ] )
          ; "required", `List [ `String "task_id" ]
          ]
    }
  ]
;;
