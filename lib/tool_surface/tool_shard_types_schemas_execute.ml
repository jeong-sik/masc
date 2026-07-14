(** Tool_shard_types_schemas_execute — [typed_execute_tools] tool_execute
    schema.

    The public descriptor exposes one command SSOT: a non-empty [argv] process
    vector for a single process, or [pipeline] containing non-empty [argv]
    vectors for explicit Shell IR pipelines. Raw [cmd] strings and the retired
    duplicate [executable] field are intentionally absent from the schema.

    Accepted fields: argv, pipeline, env, cwd, timeout_sec, stdin, stdout,
    stderr. This sentence is the contract line checked by
    scripts/check-execute-async-surface.sh — update both together. *)

let tool_execute_exec_stage_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ ( "argv"
            , `Assoc
                [ "type", `String "array"
                ; "items", `Assoc [ "type", `String "string" ]
                ; "minItems", `Int 1
                ; ( "description"
                  , `String
                      "Non-empty process vector: argv[0] is the executable and \
                       remaining tokens are arguments. Shell \
                       metacharacters are data; use pipeline for multi-stage \
                       execution. Wildcards (*, ?, [...]) are NOT expanded: argv \
                       reaches the process unchanged with no shell, so 'foo*.ml' \
                       matches a file literally named 'foo*.ml'. Pass exact paths, \
                       or discover exact paths before invoking the program." )
                ] )
          ] )
    ; "required", `List [ `String "argv" ]
    ; "additionalProperties", `Bool false
    ]
;;

let tool_execute_argv_field =
  ( "argv"
  , `Assoc
      [ "type", `String "array"
      ; "items", `Assoc [ "type", `String "string" ]
      ; "minItems", `Int 1
      ; ( "description"
        , `String
            "Typed single-process form: a non-empty process vector. argv[0] is \
             the executable and remaining tokens are arguments, all passed verbatim. \
             A literal '|' token is data, not a pipe. Wildcards (*, ?, [...]) are \
             NOT expanded either: there is no shell, so 'foo*.ml' is a literal \
             filename, not a glob. Use exact paths or list a directory first." )
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
             '|' in argv. Mutually exclusive with top-level argv." )
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
      ; "exclusiveMinimum", `Float 0.0
      ; ( "description"
        , `String
            "Optional explicit subprocess wall-clock timeout in seconds. \
             When absent, Execute is unbounded and remains cancellable." )
      ] )
;;

(* RFC-0198 Phase B: typed redirect fields.  Each is an optional
   object choosing exactly one of [{discard: true}] (equivalent to
   [/dev/null]) or [{file: "/abs/path"}].  Absent keeps the default
   [inherit] behaviour. *)
let redirect_target_properties =
  [ "discard", `Assoc [ "type", `String "boolean" ]
  ; ( "file"
    , `Assoc
        [ "type", `String "string"
        ; "minLength", `Float 1.
        ; ( "description"
          , `String
              "Absolute filesystem path for the redirect target. \
               Relative paths are rejected." )
        ] )
  ]
;;

let redirect_target_one_of : Yojson.Safe.t =
  `List
    [ `Assoc
        [ "required", `List [ `String "discard" ]
        ; "not", `Assoc [ "required", `List [ `String "file" ] ]
        ]
    ; `Assoc
        [ "required", `List [ `String "file" ]
        ; "not", `Assoc [ "required", `List [ `String "discard" ] ]
        ]
    ]
;;

let redirect_field ~name ~description =
  ( name
  , `Assoc
      [ "type", `String "object"
      ; "description", `String description
      ; "properties", `Assoc redirect_target_properties
      ; "additionalProperties", `Bool false
      ; "oneOf", redirect_target_one_of
      ] )
;;

let tool_execute_stdin_field =
  redirect_field
    ~name:"stdin"
    ~description:
      "Optional typed stdin redirect: {discard:true} feeds empty input, \
       {file:\"/abs/path\"} reads from an absolute path. Default \
       behaviour (field absent) inherits the parent's stdin."
;;

let tool_execute_stdout_field =
  redirect_field
    ~name:"stdout"
    ~description:
      "Optional typed stdout redirect: {discard:true} drops the output, \
       {file:\"/abs/path\"} writes to an absolute path. Use this instead \
       of putting shell syntax like '>/tmp/out' inside argv (which the \
       typed gate rejects per RFC-0198 Phase A)."
;;

let tool_execute_stderr_field =
  redirect_field
    ~name:"stderr"
    ~description:
      "Optional typed stderr redirect: {discard:true} drops stderr \
       (equivalent to '2>/dev/null'), {file:\"/abs/path\"} writes to an \
       absolute path. Use this instead of putting '2>/dev/null' or \
       similar into argv — the typed gate rejects redirection-shape \
       argv tokens per RFC-0198 Phase A and surfaces this field as the \
       alternative."
;;

let tool_execute_description =
  "Execute a typed process invocation inside the Keeper sandbox. Accepted fields: argv, pipeline, env, cwd, timeout_sec, stdin, stdout, stderr. Provide either \
   one non-empty argv process vector or an explicit pipeline of typed stages, \
   never both; this tool does not expose background task lifecycle tools. The \
   cmd and command string fields are rejected. Shell \
   metacharacters in argv are data, not syntax; use typed stdin/stdout/stderr \
   objects for redirection and the pipeline field for pipelines. Use Grep for \
   structured file-content search. cwd must resolve inside the Keeper path jail. \
   MASC does not interpret program or subcommand \
   meaning: after typed lowering, path containment, sandbox resolution, and the \
   external-effect Gate, the invoked program owns its syntax and exit result."
;;

let tool_execute_schema : Masc_domain.tool_schema =
  let properties =
    [ tool_execute_argv_field
    ; tool_execute_pipeline_field
    ; tool_execute_env_field
    ; tool_execute_cwd_field
    ; tool_execute_timeout_sec_field
    ; tool_execute_stdin_field
    ; tool_execute_stdout_field
    ; tool_execute_stderr_field
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
                  [ "required", `List [ `String "argv" ]
                  ; ( "not"
                    , `Assoc [ "required", `List [ `String "pipeline" ] ] )
                  ; ( "description"
                    , `String
                        "Single-process form: include one non-empty 'argv'. \
                         DO NOT also include 'pipeline' \
                         in the same call." )
                  ]
              ; `Assoc
                  [ "required", `List [ `String "pipeline" ]
                  ; ( "not"
                    , `Assoc
                        [ "required", `List [ `String "argv" ] ] )
                  ; ( "description"
                    , `String
                        "Pipeline form: include 'pipeline' array of exec \
                         stages.  DO NOT also include top-level 'argv' in the \
                         same call." )
                  ]
              ] )
        ]
  }
;;

let typed_execute_tools : Masc_domain.tool_schema list =
  [ tool_execute_schema ]
;;
