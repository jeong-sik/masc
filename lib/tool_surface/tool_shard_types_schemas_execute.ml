(** Tool_shard_types_schemas_execute — [typed_execute_tools] tool_execute
    schema, decoded from [config/tools/tool_execute.toml].

    The public descriptor exposes one command SSOT: a non-empty [argv] process
    vector for a single process, [pipeline] containing stages for explicit
    Shell IR pipelines, or [script] — one command line parsed by the bash
    subset into the same Shell IR, never handed to a shell. Every form is a
    program of one or more stages, and a stage owns its own redirections. Raw
    [cmd] strings and the retired duplicate [executable] field are
    intentionally absent from the schema.

    Accepted fields: argv, pipeline, script, env, cwd, timeout_sec, stdin,
    stdout, stderr. This sentence is the contract line checked by
    scripts/check-execute-async-surface.sh — update both together.

    The builders this file used to hold carried a [prose] type that decided,
    per call site, whether a nested repeat restates its description. A file
    states each description once where it appears, so the type had nothing
    left to enforce and went with them. *)

let tool_execute_schema : Masc_domain.tool_schema =
  Tool_shard_types_schemas_execute_toml.tool_execute
;;

let typed_execute_tools : Masc_domain.tool_schema list =
  [ tool_execute_schema ]
;;
