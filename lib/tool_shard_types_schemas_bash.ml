(** Tool_shard_types_schemas_bash — [coding_keeper_bridge_tools] keeper_bash
    + keeper_bash_output + keeper_bash_kill schemas.

    [keeper_bash] exposes typed argv/pipeline input only. The old free-form
    command-string descriptor has been removed from the model-facing schema;
    reader-side rejection of [cmd] remains in [Keeper_tool_bash_input.of_json]
    for callers that bypass tool-schema validation. *)

let keeper_bash_exec_stage_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ ( "executable"
            , `Assoc
                [ "type", `String "string"
                ; ( "description"
                  , `String "Allowlisted executable name, e.g. rg, sed, sort, head." )
                ] )
          ; ( "argv"
            , `Assoc
                [ "type", `String "array"
                ; "items", `Assoc [ "type", `String "string" ]
                ; ( "description"
                  , `String
                      "Arguments passed verbatim to executable. Shell metacharacters \
                       are data; use pipeline/stages for pipes." )
                ] )
          ] )
    ; "required", `List [ `String "executable" ]
    ]
;;

(* --- Typed schema fragments. --- *)

let keeper_bash_executable_field =
  ( "executable"
  , `Assoc
      [ "type", `String "string"
      ; ( "description"
        , `String
            "Typed argv form: allowlisted executable name. Provide argv separately; \
             do not combine shell syntax into this field." )
      ] )
;;

let keeper_bash_argv_field =
  ( "argv"
  , `Assoc
      [ "type", `String "array"
      ; "items", `Assoc [ "type", `String "string" ]
      ; ( "description"
        , `String
            "Typed argv form: arguments passed verbatim to executable. A literal '|' \
             token is data, not a pipe." )
      ] )
;;

let keeper_bash_pipeline_field =
  ( "pipeline"
  , `Assoc
      [ "type", `String "array"
      ; "items", keeper_bash_exec_stage_schema
      ; ( "description"
        , `String
            "Typed pipeline form: ordered exec stages. Use this instead of putting \
             '|' in argv." )
      ] )
;;

let keeper_bash_stages_field =
  ( "stages"
  , `Assoc
      [ "type", `String "array"
      ; "items", keeper_bash_exec_stage_schema
      ; ( "description"
        , `String
            "Alias for pipeline. Each stage has executable and optional argv." )
      ] )
;;

let keeper_bash_env_field =
  ( "env"
  , `Assoc
      [ "type", `String "object"
      ; "additionalProperties", `Assoc [ "type", `String "string" ]
      ; ( "description"
        , `String
            "Optional typed environment bindings. Keys must be [A-Za-z0-9_]+ and \
             values are strings." )
      ] )
;;

let keeper_bash_cwd_field =
  ( "cwd"
  , `Assoc
      [ "type", `String "string"
      ; ( "description"
        , `String
            "Optional working directory for the command. Must stay within the keeper \
             sandbox or an explicit allowed path." )
      ] )
;;

let keeper_bash_timeout_sec_field =
  ( "timeout_sec"
  , `Assoc
      [ "type", `String "number"
      ; ( "description"
        , `String
            "Timeout seconds (default: 30, max: 180). For run_in_background=true, 0 \
             disables the timeout." )
      ] )
;;

let keeper_bash_run_in_background_field =
  ( "run_in_background"
  , `Assoc
      [ "type", `String "boolean"
      ; ( "description"
        , `String
            "Default false. When true, returns immediately with background_task_id; \
             poll output via keeper_bash_output, stop via keeper_bash_kill." )
      ] )
;;

let keeper_bash_description =
  "Execute one command through the keeper_bash safety gates via typed argv. Use \
   executable/argv for one process, or pipeline/stages for explicit Shell IR \
   pipelines. Shell metacharacters in argv are data, not syntax. Good: \
   executable='rg' argv=['pattern','lib/'], pipeline=[{executable='rg',...}, \
   {executable='head',...}]. Runs in the keeper sandbox by default; use cwd to \
   target an explicit allowed directory. Paths resolve automatically — never include \
   host storage prefixes such as '.masc/playground/your-name/' in cwd. Use 'repos/X' \
   instead. Sandbox root is NOT a git repository: git/gh calls require \
   cwd='repos/<REPO_NAME>' (or the worktree path under it). 'not a git repository' \
   or 'path_outside_sandbox' from the sandbox root means you forgot the cwd. For \
   read-only ops use keeper_shell, for file edits use keeper_fs_edit. Set \
   run_in_background=true for long-running tasks (returns background_task_id; poll \
   with keeper_bash_output, terminate with keeper_bash_kill)."
;;

let keeper_bash_schema : Masc_domain.tool_schema =
  let properties =
    [ keeper_bash_executable_field
    ; keeper_bash_argv_field
    ; keeper_bash_pipeline_field
    ; keeper_bash_stages_field
    ; keeper_bash_env_field
    ; keeper_bash_cwd_field
    ; keeper_bash_timeout_sec_field
    ; keeper_bash_run_in_background_field
    ]
  in
  let one_of_branches =
    [ `Assoc [ "required", `List [ `String "executable" ] ]
    ; `Assoc [ "required", `List [ `String "pipeline" ] ]
    ; `Assoc [ "required", `List [ `String "stages" ] ]
    ]
  in
  let input_schema =
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "additionalProperties", `Bool false
    ; "oneOf", `List one_of_branches
    ]
  in
  { name = "keeper_bash"
  ; description = keeper_bash_description
  ; input_schema = `Assoc input_schema
  }
;;

let keeper_bash_output_schema : Masc_domain.tool_schema =
  { name = "keeper_bash_output"
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
;;

let keeper_bash_kill_schema : Masc_domain.tool_schema =
  { name = "keeper_bash_kill"
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
;;

let coding_keeper_bridge_tools : Masc_domain.tool_schema list =
  [ keeper_bash_schema; keeper_bash_output_schema; keeper_bash_kill_schema ]
;;
