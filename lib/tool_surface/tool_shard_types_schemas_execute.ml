(** Tool_shard_types_schemas_execute — [typed_execute_tools] tool_execute
    schema.

    The public descriptor exposes one command SSOT: a non-empty [argv] process
    vector for a single process, or [pipeline] containing stages for explicit
    Shell IR pipelines. Either form is a program of one or more stages, and a
    stage owns its own redirections. Raw [cmd] strings and the retired
    duplicate [executable] field are intentionally absent from the schema.

    Accepted fields: argv, pipeline, env, cwd, timeout_sec, stdin, stdout,
    stderr. This sentence is the contract line checked by
    scripts/check-execute-async-surface.sh — update both together. *)

(* A redirect is an optional object naming exactly one shape; absent keeps
   the inherited descriptor. Reading and writing admit different names, so
   each direction carries its own property set and a stream never accepts a
   name it cannot honour. *)
let discard_property = "discard", `Assoc [ "type", `String "boolean" ]

let path_property ~name ~description =
  ( name
  , `Assoc
      [ "type", `String "string"
      ; "minLength", `Float 1.
      ; "pattern", `String "^/"
      ; "description", `String description
      ] )
;;

let fd_property =
  ( "fd"
  , `Assoc
      [ "type", `String "integer"
      ; "enum", `List [ `Int 0; `Int 1; `Int 2 ]
      ; ( "description"
        , `String
            "Duplicate another standard descriptor of this same stage, the \
             typed form of '2>&1'. A stage owns only 0, 1 and 2." )
      ] )
;;

let input_source_properties =
  [ discard_property
  ; path_property
      ~name:"file"
      ~description:"Absolute path to read from, the typed form of '<'."
  ; fd_property
  ]
;;

let output_sink_properties =
  [ discard_property
  ; path_property
      ~name:"truncate"
      ~description:"Absolute path to replace, the typed form of '>'."
  ; path_property
      ~name:"append"
      ~description:"Absolute path to add to, the typed form of '>>'."
  ; fd_property
  ]
;;

(* Each branch requires one name and forbids the rest. Branches are selected
   by position so the generator never compares the names themselves. *)
let exactly_one_of names : Yojson.Safe.t =
  let indexed = List.mapi (fun index name -> index, name) names in
  let branch (index, chosen) =
    `Assoc
      [ "required", `List [ `String chosen ]
      ; ( "allOf"
        , `List
            (List.filter_map
               (fun (other_index, other) ->
                  if Int.equal index other_index
                  then None
                  else
                    Some
                      (`Assoc
                          [ "not", `Assoc [ "required", `List [ `String other ] ] ]))
               indexed) )
      ]
  in
  `List (List.map branch indexed)
;;

(* The object's own keys carry their meaning, so the wrapper adds no
   description of its own. [oneOf] is derived from the properties, which is
   why the two cannot drift apart. *)
let redirect_field ~name ~properties =
  ( name
  , `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc properties
      ; "additionalProperties", `Bool false
      ; "oneOf", exactly_one_of (List.map fst properties)
      ] )
;;

let stdin_field ~name = redirect_field ~name ~properties:input_source_properties
let stdout_field ~name = redirect_field ~name ~properties:output_sink_properties

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
          ; stdin_field ~name:"stdin"
          ; stdout_field ~name:"stdout"
          ; stdout_field ~name:"stderr"
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
             Filesystem arguments use the selected sandbox namespace; relative path \
             operands resolve against the typed cwd. Docker cannot access host \
             absolute paths. \
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
             '|' in argv. Each stage may carry its own stdin/stdout/stderr, so \
             piping and redirecting combine in one call. Stage argv uses the \
             selected sandbox namespace, and relative path operands resolve \
             against the typed cwd. Mutually exclusive with top-level argv." )
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
             sandbox or an explicit allowed path. Pass a relative cwd, typically '.'. \
             The Keeper-visible absolute root is informational, not a cwd input. \
             Docker host absolute paths are unavailable." )
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

let tool_execute_stdin_field = stdin_field ~name:"stdin"
let tool_execute_stdout_field = stdout_field ~name:"stdout"
let tool_execute_stderr_field = stdout_field ~name:"stderr"

let tool_execute_description =
  "Execute a typed process invocation inside the Keeper sandbox. Accepted fields: argv, pipeline, env, cwd, timeout_sec, stdin, stdout, stderr. Provide either \
   one non-empty argv process vector or an explicit pipeline of typed stages, \
   never both; this tool does not expose background task lifecycle tools. The \
   cmd and command string fields are rejected. Shell \
   metacharacters in argv are data, not syntax; use typed stdin/stdout/stderr \
   objects for redirection and the pipeline field for pipelines. Use Grep for \
   structured file-content search. cwd must resolve inside the Keeper path jail. \
   Pass a relative cwd (typically '.') and relative filesystem operands, which \
   resolve against cwd. The Keeper-visible absolute root is informational; Docker \
   host absolute paths are unavailable. \
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
