(** Tool_shard_types_schemas_execute — [typed_execute_tools] tool_execute
    schema, decoded from [config/tools/tool_execute.toml].

    The public descriptor exposes one command SSOT: exactly one of a non-empty
    [argv] process vector, run without a shell with every token verbatim, or
    [script] — one command line handed as [-c] text to the shell named by
    [shell]. Pipes, redirections, [;]/[&&] sequencing and [FOO=1] prefixes are
    shell syntax inside [script]; the schema carries no object form for them.

    Accepted fields: argv, script, shell, cwd, timeout_sec. This sentence is
    the contract line checked by scripts/check-execute-async-surface.sh —
    update both together.

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
