(** Tool_shard_types_schemas_execute — [typed_execute_tools] tool_execute
    schema.

    The public descriptor exposes only the typed argv / pipeline forms:
    [executable]/[argv] for a single process and [pipeline] for
    explicit Shell IR pipelines. Raw [cmd] strings are intentionally absent
    from the schema. *)

let tool_execute_exec_stage_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ ( "executable"
            , `Assoc
                [ "type", `String "string"
                ; "minLength", `Float 1.
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
                       are data; use pipeline for multi-stage execution." )
                ] )
          ] )
    ; "required", `List [ `String "executable" ]
    ; "additionalProperties", `Bool false
    ]
;;

let tool_execute_executable_field =
  ( "executable"
  , `Assoc
      [ "type", `String "string"
      ; "minLength", `Float 1.
      ; ( "description"
        , `String
            "Typed argv form: allowlisted executable name. Provide argv separately; \
             do not combine shell syntax into this field. Mutually exclusive with \
             pipeline; if both are provided executable takes precedence." )
      ] )
;;

let tool_execute_argv_field =
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

let tool_execute_pipeline_field =
  ( "pipeline"
  , `Assoc
      [ "type", `String "array"
      ; "items", tool_execute_exec_stage_schema
      ; ( "description"
        , `String
            "Typed pipeline form: ordered exec stages. Use this instead of putting \
             '|' in argv. Mutually exclusive with executable." )
      ] )
;;

let tool_execute_env_field =
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

let tool_execute_cwd_field =
  ( "cwd"
  , `Assoc
      [ "type", `String "string"
      ; ( "description"
        , `String
            "Optional working directory for the command. Must stay within the keeper \
             sandbox or an explicit allowed path." )
      ] )
;;

let tool_execute_timeout_sec_field =
  ( "timeout_sec"
  , `Assoc
      [ "type", `String "number"
      ; ( "description"
        , `String
            "Timeout seconds for foreground typed execution (default: 30, max: 180)." )
      ] )
;;

let tool_execute_description =
  "Execute one command through the typed execution gates via typed argv. \
   Provide EITHER executable/argv OR pipeline, never both. If both are \
   provided, executable takes precedence. Use executable/argv for one process, \
   or pipeline for explicit Shell IR pipelines. IMPORTANT: there is no 'cmd' \
   or 'command' field. Those fields are not supported and will be rejected. \
   Always use 'executable' (string) and 'argv' (string array) instead. \
   Accepted fields: executable, argv, pipeline, env, cwd, timeout_sec. \
   Shell metacharacters in argv are \
   data, not syntax. Good: executable='git' argv=['status','--short'], \
   pipeline=[{executable='git',...}, {executable='head',...}]. Runs in the \
   keeper sandbox by default; use cwd to target an explicit allowed directory. \
   Paths resolve automatically — never include host storage prefixes such as \
   '.masc/playground/your-name/' in cwd. Use 'repos/X' instead. Sandbox root is \
   NOT a git repository: git/gh calls require cwd='repos/<REPO_NAME>' (or the \
   worktree path under it). 'not a git repository' or 'path_outside_sandbox' \
   from the sandbox root means you forgot the cwd. For read-only search/listing \
   use SearchFiles when visible; for file edits use EditFile. Long-running commands must \
   be split or run through a dedicated structured workflow; this tool no longer \
   exposes background task lifecycle tools. \
   COMMON REJECTIONS: 'executable' must be a non-empty allowlisted command name \
   (e.g. 'cat', 'ls', 'gh'); never the empty string ''. Never collapse the entire \
   command into a single string like \"'' -c 'ls -la'\" — that is shell-style and \
   will be rejected by the typed gate with Empty_executable. The validation gate \
   emits Empty_executable for any missing or empty 'executable' field; do not \
   retry the same empty payload — restructure to executable='X' argv=['arg1',...]."
;;

let tool_execute_schema : Masc_domain.tool_schema =
  let properties =
    [ tool_execute_executable_field
    ; tool_execute_argv_field
    ; tool_execute_pipeline_field
    ; tool_execute_env_field
    ; tool_execute_cwd_field
    ; tool_execute_timeout_sec_field
    ]
  in
  { name = "tool_execute"
  ; description = tool_execute_description
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; "properties", `Assoc properties
        ; "additionalProperties", `Bool false
        ; ( "oneOf"
          , `List
              [ `Assoc
                  [ "required", `List [ `String "executable" ]
                  ; ( "description"
                    , `String
                        "Single-process form: provide executable (and optional \
                         argv). Must not include pipeline." )
                  ]
              ; `Assoc
                  [ "required", `List [ `String "pipeline" ]
                  ; ( "description"
                    , `String
                        "Pipeline form: provide pipeline array of exec stages. \
                         Must not include executable." )
                  ]
              ] )
        ]
  }
;;

let typed_execute_tools : Masc_domain.tool_schema list =
  [ tool_execute_schema ]
;;
