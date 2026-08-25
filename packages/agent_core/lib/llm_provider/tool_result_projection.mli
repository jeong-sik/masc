(** Immutable, occurrence-scoped ToolResult correlation.

    A canonical assistant ToolUse batch owns only the following Tool result
    batch. Provider IDs may therefore be reused by later turns without becoming
    a global history identity. The projection annotates each ToolResult with
    its exact ToolUse name for provider wires that require that name. *)

type t
type resolved_message

type error =
  | Duplicate_tool_use_id of
      { tool_use_id : string
      ; tool_name : string
      }
  | Conflicting_tool_use_id of
      { tool_use_id : string
      ; first_name : string
      ; conflicting_name : string
      }
  | Duplicate_tool_result_id of { tool_use_id : string }
  | Missing_tool_use_id of { tool_use_id : string }
  | Invalid_tool_use_role of
      { tool_use_id : string
      ; role : Types.role
      }
  | Invalid_tool_result_role of
      { tool_use_id : string
      ; role : Types.role
      }

(** [of_messages messages] resolves ToolResult names by canonical message
    occurrence. A duplicated ToolUse ID is rejected only within one active
    assistant batch; a later assistant batch may reuse that provider ID. *)
val of_messages : Types.message list -> (t, error) result

val messages : t -> resolved_message list
val original_message : resolved_message -> Types.message

(** Original content blocks in order. [Some tool_name] occurs exactly on a
    correlated {!Types.ToolResult}; every other block carries [None]. *)
val content : resolved_message -> (Types.content_block * string option) list

val error_to_string : error -> string
