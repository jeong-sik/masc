(** Pure structural partitioning for LLM compaction.

    Tool protocol cycles remain byte- and constructor-exact units. This module
    inspects only top-level content blocks; nested ToolResult payload blocks are
    never interpreted as protocol anchors. *)

type compactable_unit =
  | Ordinary_message of Agent_sdk.Types.message
  | Closed_tool_cycle of Agent_sdk.Types.message list

type structural_error =
  | Orphan_tool_result of
      { message_index : int
      ; tool_use_id : string
      }
  | Duplicate_tool_result of
      { message_index : int
      ; tool_use_id : string
      }
  | Unknown_tool_result of
      { message_index : int
      ; tool_use_id : string
      }
  | Non_assistant_tool_use of
      { message_index : int
      ; tool_use_id : string
      }
  | Duplicate_tool_use_id of
      { message_index : int
      ; tool_use_id : string
      }
  | Overlapping_tool_cycle of
      { message_index : int
      ; tool_use_id : string
      }
  | Tool_request_contains_result of
      { message_index : int
      ; tool_use_id : string
      }
  | Non_result_tool_role of
      { message_index : int
      ; tool_use_id : string
      }

type partition =
  { compactable_prefix : compactable_unit list
  ; protected_suffix : Agent_sdk.Types.message list
  }

val partition
  :  Agent_sdk.Types.message list
  -> (partition, structural_error) result
