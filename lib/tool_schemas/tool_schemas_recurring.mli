(** MCP tool schemas for keeper recurring task management.
    RFC-0314 — Keeper Recurring Producer. *)

type action =
  | List_tasks
  | Remove_task

type definition = {
  action : action;
  id : string;
  name : string;
  schema : Masc_domain.tool_schema;
  read_only : bool;
}

val definitions : definition list
val all_definitions : definition list
val schemas : Masc_domain.tool_schema list
val find_definition : string -> definition option