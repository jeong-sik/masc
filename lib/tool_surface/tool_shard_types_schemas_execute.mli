(** Typed execute tool schema. *)

val tool_execute_exec_stage_schema : Yojson.Safe.t
val tool_execute_executable_field : string * Yojson.Safe.t
val tool_execute_argv_field : string * Yojson.Safe.t
val tool_execute_pipeline_field : string * Yojson.Safe.t
val tool_execute_env_field : string * Yojson.Safe.t
val tool_execute_cwd_field : string * Yojson.Safe.t
val tool_execute_timeout_sec_field : string * Yojson.Safe.t
val redirect_target_properties : (string * Yojson.Safe.t) list
val redirect_target_one_of : Yojson.Safe.t
val redirect_field : name:string -> description:string -> string * Yojson.Safe.t
val tool_execute_stdin_field : string * Yojson.Safe.t
val tool_execute_stdout_field : string * Yojson.Safe.t
val tool_execute_stderr_field : string * Yojson.Safe.t
val tool_execute_description : string
val tool_execute_schema : Masc_domain.tool_schema
val typed_execute_tools : Masc_domain.tool_schema list
