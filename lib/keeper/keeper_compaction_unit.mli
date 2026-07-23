(** Pure structural partitioning for LLM compaction.

    Tool protocol cycles remain byte- and constructor-exact units. This module
    inspects only top-level content blocks; nested ToolResult payload blocks are
    never interpreted as protocol anchors. Presence in [closed_prefix] does not
    by itself authorize a unit for LLM summarization. *)

type closed_unit =
  | Ordinary_message of Agent_sdk.Types.message
  | Closed_tool_cycle of Agent_sdk.Types.message list

type structural_error =
  | Empty_tool_use_id of
      { message_index : int
      ; block_index : int
      ; tool_use_id : string
      }
  | Empty_tool_result_id of
      { message_index : int
      ; block_index : int
      ; tool_use_id : string
      }
  | Message_tool_call_id_mismatch of
      { message_index : int
      ; message_tool_call_id : string
      ; content_tool_use_ids : string list
      }
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
[@@deriving show]

type partition =
  { closed_prefix : closed_unit list
  ; protected_suffix : Agent_sdk.Types.message list
  }

type provider_transcript_error =
  | Invalid_transcript_structure of structural_error
  | Unresolved_tool_results of { tool_use_ids : string list }
[@@deriving show]

val partition
  :  ?quarantine:bool
  -> Agent_sdk.Types.message list
  -> (partition, structural_error) result
(** With [~quarantine:true] the first structural break freezes the valid
    [closed_prefix] and moves the open cycle plus the offending message and its
    successors into [protected_suffix] instead of returning [Error]. Compaction
    callers use this so a single broken tool cycle compacts the valid prefix
    rather than rejecting the whole history. [validate] and persistence callers
    keep the default [false] to reject broken structures. *)

(** Validate the same structural contract as {!partition} without exposing a
    partition to persistence callers that must preserve every message exactly. *)
val validate
  :  Agent_sdk.Types.message list
  -> (unit, structural_error) result

(** Provider dispatch requires a fully closed tool protocol. Unlike
    {!validate}, this rejects the open ToolUse suffix that checkpoint
    persistence deliberately preserves for crash recovery. *)
val validate_provider_transcript
  :  Agent_sdk.Types.message list
  -> (unit, provider_transcript_error) result
