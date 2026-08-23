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
(* Where a field sits decides whether it explains itself. A pipeline or [then]
   stage carries the same field names and the same shapes as the top level, so
   a second copy of the same sentence is bytes on every Keeper turn that say
   nothing the model has not already read in the same tool.

   This is an argument to the builders rather than a pass over the finished
   schema: stripping by key name would delete a property that happens to be
   called "description", and nothing would say so. Here every builder answers
   for both positions and the compiler asks. *)
type prose =
  | Stated (* the one occurrence that explains the field *)
  | Restated (* a nested repeat: shape, and prose only where it earns it *)

let describe prose text =
  match prose with
  | Stated -> [ "description", `String text ]
  | Restated -> []
;;

let discard_property = "discard", `Assoc [ "type", `String "boolean" ]

let path_property ~prose ~name ~description =
  ( name
  , `Assoc
      ([ "type", `String "string"; "minLength", `Float 1.; "pattern", `String "^/" ]
       @ describe prose description) )
;;

let fd_property ~prose =
  ( "fd"
  , `Assoc
      ([ "type", `String "integer"; "enum", `List [ `Int 1; `Int 2 ] ]
       @ describe
           prose
           "Send this stream into another of the stage's output descriptors, the \
            typed form of '2>&1'. The two streams are captured separately and \
            joined afterwards, so the merged text is grouped by stream, not \
            ordered by time.") )
;;

let input_source_properties ~prose =
  [ discard_property
  ; path_property
      ~prose
      ~name:"file"
      ~description:"Absolute path to read from, the typed form of '<'."
  ]
;;

let output_sink_properties ~prose =
  [ discard_property
  ; path_property
      ~prose
      ~name:"truncate"
      ~description:"Absolute path to replace, the typed form of '>'."
  ; path_property
      ~prose
      ~name:"append"
      ~description:"Absolute path to add to, the typed form of '>>'."
  ; fd_property ~prose
  ]
;;

(* The object's own keys carry their meaning, so the wrapper adds no
   description of its own. Exactly one key is present, said with the two
   counting keywords rather than a [oneOf] branch per property: with
   [additionalProperties] closed to the listed set, a count of one names the
   same objects. The branch form spelled out every pair of names, so it grew
   with the square of the property count and was written into stdin, stdout and
   stderr at the top level and again in every pipeline stage. *)
let redirect_field ~name ~properties =
  ( name
  , `Assoc
      [ "type", `String "object"
      ; "properties", `Assoc properties
      ; "additionalProperties", `Bool false
      ; "minProperties", `Float 1.
      ; "maxProperties", `Float 1.
      ] )
;;

let stdin_field ~prose ~name =
  redirect_field ~name ~properties:(input_source_properties ~prose)
;;

let stdout_field ~prose ~name =
  redirect_field ~name ~properties:(output_sink_properties ~prose)
;;

(* The full text is this tool's account of "there is no shell". A nested stage
   is exactly where a model reaches for '|', so that one sentence is worth
   restating there even though the rest is not — the only field whose repeat
   earns its bytes. *)
let tool_execute_argv_field ~prose =
  let description =
    match prose with
    | Stated ->
      "Non-empty process vector: argv[0] is the executable and remaining tokens \
       are arguments, all passed verbatim. There is no shell, so a literal '|', \
       '&&' or '>' token is data, not an operator, and wildcards (*, ?, [...]) \
       are not expanded: 'foo*.ml' names a file called 'foo*.ml'. Use pipeline, \
       then, and the redirect fields instead, and pass exact paths. Filesystem \
       arguments use the selected sandbox namespace; relative operands resolve \
       against the typed cwd, and Docker cannot reach host absolute paths."
    | Restated ->
      "Same shape as the top-level argv. Still no shell: '|', '&&' and '>' are \
       data, and wildcards are not expanded."
  in
  ( "argv"
  , `Assoc
      [ "type", `String "array"
      ; "items", `Assoc [ "type", `String "string" ]
      ; "minItems", `Int 1
      ; "description", `String description
      ] )
;;

(* A stage only ever sits inside [pipeline], so it is always the repeat. *)
let tool_execute_exec_stage_schema =
  let prose = Restated in
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ tool_execute_argv_field ~prose
          ; stdin_field ~prose ~name:"stdin"
          ; stdout_field ~prose ~name:"stdout"
          ; stdout_field ~prose ~name:"stderr"
          ] )
    ; "required", `List [ `String "argv" ]
    ; "additionalProperties", `Bool false
    ]
;;

let tool_execute_pipeline_field ~prose =
  ( "pipeline"
  , `Assoc
      ([ "type", `String "array"; "items", tool_execute_exec_stage_schema ]
       @ describe
           prose
           "Typed pipeline form: ordered exec stages. Use this instead of putting \
            '|' in argv. Each stage may carry its own stdin/stdout/stderr, so \
            piping and redirecting combine in one call. Stage argv uses the \
            selected sandbox namespace, and relative path operands resolve \
            against the typed cwd. Mutually exclusive with top-level argv.") )
;;

(* One continuation: the same program shape as the top level, plus the status
   it waits for. Written as a status rather than an operator name so the model
   states the condition instead of translating shell syntax. *)
let tool_execute_then_field =
  ( "then"
  , `Assoc
      [ "type", `String "array"
      ; ( "items"
        , `Assoc
            [ "type", `String "object"
            ; ( "properties"
              , `Assoc
                  [ ( "on"
                    , `Assoc
                        [ "type", `String "string"
                        ; "enum", `List [ `String "success"; `String "failure" ]
                        ] )
                  ; tool_execute_argv_field ~prose:Restated
                  ; tool_execute_pipeline_field ~prose:Restated
                  ; stdin_field ~prose:Restated ~name:"stdin"
                  ; stdout_field ~prose:Restated ~name:"stdout"
                  ; stdout_field ~prose:Restated ~name:"stderr"
                  ] )
            ; "required", `List [ `String "on" ]
            ; "additionalProperties", `Bool false
            ] )
      ; ( "description"
        , `String
            "Programs to run after this one, each guarded by how the one \
             before it ended, the typed form of '&&' and '||'. Use this \
             instead of putting those operators in argv, where nothing reads \
             them. Guards apply left to right." )
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
            "Working directory for the command, and the only way to set one: \
             there is no shell, so 'cd' runs as a program, changes the \
             directory of a child that exits, and reports success having done \
             nothing. Must stay within the keeper sandbox or an explicit \
             allowed path. Pass a relative cwd, typically '.'. The \
             Keeper-visible absolute root is informational, not a cwd input. \
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

(* The top level is where each field explains itself. *)
let tool_execute_stdin_field = stdin_field ~prose:Stated ~name:"stdin"
let tool_execute_stdout_field = stdout_field ~prose:Stated ~name:"stdout"
let tool_execute_stderr_field = stdout_field ~prose:Stated ~name:"stderr"

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
    [ tool_execute_argv_field ~prose:Stated
    ; tool_execute_pipeline_field ~prose:Stated
    ; tool_execute_then_field
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
