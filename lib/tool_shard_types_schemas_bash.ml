(** Tool_shard_types_schemas_bash — [coding_keeper_bridge_tools] keeper_bash
    + keeper_bash_output + keeper_bash_kill schemas.

    RFC-0091 PR-3 (2026-05-20): two descriptor variants live in this file:

    - [Legacy_v0] still advertises the legacy [cmd] string field alongside
      the typed [executable]/[argv]/[pipeline]/[stages] fields. This is the
      default during the staged rollout — fleet-wide behavior is unchanged
      until the operator flips the gate.
    - [Typed_v1] removes [cmd] from [input_schema.properties] and from the
      [oneOf] discriminator. LLMs see only the typed argv / pipeline forms,
      which prevents the cheaper [cmd] regression that re-introduces the
      [Worker_dev_tools] shell lexer ([Path syntax blocked] /
      [keeper_bash_command_shape_blocked] family — log audit 2026-05-20
      issues #8/9/10/14/17/18).

    Selection is single-knob (`MASC_KEEPER_BASH_DESCRIPTOR_VARIANT`,
    default `legacy_v0`). One emit path, one schema function — no
    parallel descriptor source-of-truth. Per-keeper TOML gating is the
    PR-3.1 follow-up; PR-3 ships the variant selector + descriptor only.

    Reader-side rejection of `cmd` already lives in
    [Keeper_tool_bash_input.of_json] (typed parser, PR-1). Even when the
    legacy descriptor is advertised, attempting to call through the typed
    boundary with `cmd` is a typed [Result.Error]. PR-2 will sweep the
    remaining callers/test fixtures so the [cmd] field can also be removed
    from the typed parser as a structural reject. *)

type descriptor_variant =
  | Legacy_v0
  | Typed_v1

let variant_of_env_string = function
  | "typed_v1" -> Some Typed_v1
  | "legacy_v0" -> Some Legacy_v0
  | _ -> None
;;

let resolve_descriptor_variant_from_env () =
  match Stdlib.Sys.getenv_opt "MASC_KEEPER_BASH_DESCRIPTOR_VARIANT" with
  | None -> Legacy_v0
  | Some raw ->
    (match variant_of_env_string (Stdlib.String.trim raw) with
     | Some v -> v
     | None -> Legacy_v0)
;;

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

(* --- Shared schema fragments used by both descriptor variants. --- *)

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
             '|' in argv or cmd." )
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

(* --- Legacy v0 only: the deprecated [cmd] string field. --- *)
let keeper_bash_cmd_field =
  ( "cmd"
  , `Assoc
      [ "type", `String "string"
      ; ( "description"
        , `String
            "Single command only. No chaining/control syntax or file redirects. \
             Example: 'scripts/dune-local.sh build', 'rg pattern lib/'" )
      ] )
;;

let legacy_v0_description =
  "Execute one command through the keeper_bash safety gates. Legacy cmd remains \
   accepted during the typed-argv migration; prefer executable/argv for one process \
   or pipeline/stages for explicit Shell IR pipelines. No chaining/control syntax \
   (&&, ||, ;), command substitution, background operators, or file redirects. Good: \
   cmd='scripts/dune-local.sh build', executable='rg' argv=['pattern','lib/'], \
   pipeline=[{executable='rg',...}, {executable='head',...}]. Bad: cmd='cd x && dune \
   build', cmd='echo hi > out.txt'. Runs in the keeper sandbox by default; use cwd \
   to target an explicit allowed directory. Paths resolve automatically — never \
   include host storage prefixes such as '.masc/playground/your-name/' in cwd. Use \
   'repos/X' instead. Sandbox root is NOT a git repository: git/gh calls require \
   cwd='repos/<REPO_NAME>' (or the worktree path under it). 'not a git repository' \
   or 'path_outside_sandbox' from the sandbox root means you forgot the cwd. For \
   read-only ops use keeper_shell, for file edits use keeper_fs_edit. Set \
   run_in_background=true for long-running tasks (returns background_task_id; poll \
   with keeper_bash_output, terminate with keeper_bash_kill)."
;;

let typed_v1_description =
  "Execute one command through the keeper_bash safety gates via typed argv. Use \
   executable/argv for one process, or pipeline/stages for explicit Shell IR \
   pipelines. The legacy 'cmd' string field is no longer accepted — shell \
   metacharacters in argv are data, not syntax. Good: executable='rg' \
   argv=['pattern','lib/'], pipeline=[{executable='rg',...}, \
   {executable='head',...}]. Runs in the keeper sandbox by default; use cwd to \
   target an explicit allowed directory. Paths resolve automatically — never \
   include host storage prefixes such as '.masc/playground/your-name/' in cwd. Use \
   'repos/X' instead. Sandbox root is NOT a git repository: git/gh calls require \
   cwd='repos/<REPO_NAME>' (or the worktree path under it). 'not a git repository' \
   or 'path_outside_sandbox' from the sandbox root means you forgot the cwd. For \
   read-only ops use keeper_shell, for file edits use keeper_fs_edit. Set \
   run_in_background=true for long-running tasks (returns background_task_id; poll \
   with keeper_bash_output, terminate with keeper_bash_kill)."
;;

let keeper_bash_schema ~(variant : descriptor_variant) : Masc_domain.tool_schema =
  let common_fields =
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
  let properties, one_of_branches, description, top_level_required =
    match variant with
    | Legacy_v0 ->
      ( keeper_bash_cmd_field :: common_fields
      , [ `Assoc [ "required", `List [ `String "cmd" ] ]
        ; `Assoc [ "required", `List [ `String "executable" ] ]
        ; `Assoc [ "required", `List [ `String "pipeline" ] ]
        ; `Assoc [ "required", `List [ `String "stages" ] ]
        ]
      , legacy_v0_description
      , None )
    | Typed_v1 ->
      ( common_fields
      , [ `Assoc [ "required", `List [ `String "executable" ] ]
        ; `Assoc [ "required", `List [ `String "pipeline" ] ]
        ; `Assoc [ "required", `List [ `String "stages" ] ]
        ]
      , typed_v1_description
      , Some (`List [ `String "executable" ]) )
  in
  let base_fields =
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "oneOf", `List one_of_branches
    ]
  in
  let input_schema_fields =
    match top_level_required with
    | None -> base_fields
    | Some required -> base_fields @ [ "required", required ]
  in
  { name = "keeper_bash"
  ; description
  ; input_schema = `Assoc input_schema_fields
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

let coding_keeper_bridge_tools_for_variant ~(variant : descriptor_variant)
  : Masc_domain.tool_schema list
  =
  [ keeper_bash_schema ~variant
  ; keeper_bash_output_schema
  ; keeper_bash_kill_schema
  ]
;;

let coding_keeper_bridge_tools : Masc_domain.tool_schema list =
  coding_keeper_bridge_tools_for_variant
    ~variant:(resolve_descriptor_variant_from_env ())
;;
