(** Typed tool_execute schema fragments and aggregate schema. *)

val tool_execute_timeout_sec_field : string * Yojson.Safe.t
(** Timeout field schema kept public for the widening regression test. *)

val tool_execute_schema : Masc_domain.tool_schema
val typed_execute_tools : Masc_domain.tool_schema list
