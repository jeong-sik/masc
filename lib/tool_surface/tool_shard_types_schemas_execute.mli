(** Typed Execute tool schemas. *)

val tool_execute_timeout_sec_field : string * Yojson.Safe.t
val tool_execute_schema : Masc_domain.tool_schema
val typed_execute_tools : Masc_domain.tool_schema list
