(** Pure structural partitioning for Keeper transcripts.

    Tool protocol cycles remain byte- and constructor-exact units. This module
    inspects only top-level content blocks; nested ToolResult payload blocks are
    never interpreted as protocol anchors. Presence in [closed_prefix] does not
    by itself authorize a unit for LLM summarization. *)

type closed_unit =
  | Ordinary_message of Agent_core.Types.message
  | Closed_tool_cycle of Agent_core.Types.message list

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
  ; protected_suffix : Agent_core.Types.message list
  }

type provider_transcript_error =
  | Invalid_transcript_structure of structural_error
  | Unresolved_tool_results of { tool_use_ids : string list }
[@@deriving show]

val messages_of_closed_unit : closed_unit -> Agent_core.Types.message list
(** Flatten a unit back to the messages it holds: the single message of
    [Ordinary_message], or the message list of [Closed_tool_cycle] in its
    original order. *)

val partition
  :  ?quarantine:bool
  -> Agent_core.Types.message list
  -> (partition, structural_error) result
(** With [~quarantine:true] the first structural break freezes the valid
    [closed_prefix] and moves the open cycle plus the offending message and its
    successors into [protected_suffix] instead of returning [Error]. Transcript recovery
    callers use this so a single broken tool cycle compacts the valid prefix
    rather than rejecting the whole history. [validate] and persistence callers
    keep the default [false] to reject broken structures. *)

(** Validate the same structural contract as {!partition} without exposing a
    partition to persistence callers that must preserve every message exactly. *)
val validate
  :  Agent_core.Types.message list
  -> (unit, structural_error) result

(** Provider dispatch requires a fully closed tool protocol. Unlike
    {!validate}, this rejects the open ToolUse suffix that checkpoint
    persistence deliberately preserves for crash recovery. *)
val validate_provider_transcript
  :  Agent_core.Types.message list
  -> (unit, provider_transcript_error) result

val interrupted_tool_result_content : string
(** SSOT for the body of a synthesized closer. States that the call was issued,
    that no result was recorded, and that whether it took effect is unknown —
    masc has no durable per-tool-call effect receipt to consult. *)

type tail_closure =
  { messages : Agent_core.Types.message list
  ; closed_tool_use_ids : string list
        (** Empty when the history was already dispatchable. *)
  }

val close_open_cycles
  :  Agent_core.Types.message list
  -> (tail_closure, structural_error) result
(** Close every open tool cycle where it sits, not only one at the tail.

    {!close_open_tail} repairs the shape an interruption leaves if nothing has
    been appended since. That is not the shape a keeper reaches: a turn dies
    mid-tool-call, the next turn appends its own request, and the unclosed
    cycle is now in the middle. {!partition} reports
    [Overlapping_tool_cycle] and rejects before any repair runs, so the keeper
    fails at the same fixed [message_index] on every turn forever (#31595).

    [Overlapping_tool_cycle] is the one member of [structural_error] that says
    "a result is missing" rather than "this history cannot be read", so it is
    the one a synthesized result can answer. Closers are inserted immediately
    before the request that exposed the open cycle. Nothing is trimmed and
    nothing is reset.

    Every other structural break still returns unchanged and must keep
    latching: there is no request for an orphaned result to attach to. On
    [Ok], {!validate_provider_transcript} of [messages] returns [Ok ()]. *)

val close_open_tail
  :  Agent_core.Types.message list
  -> (tail_closure, structural_error) result
(** Close the in-flight tool cycle that checkpoint persistence deliberately
    preserves, so a history interrupted by process death becomes dispatchable
    again instead of latching the lane. Appends one [ToolResult] per unresolved
    [ToolUse] id, carrying {!interrupted_tool_result_content} and an
    [Unattributed_tool_error] outcome.

    This is completion, not repair: the appended block records what recovery
    knows exactly (this id was issued, no result was recorded) rather than
    guessing at a corrupt artifact. A history that fails to parse returns its
    [structural_error] unchanged and must keep latching — only the open tail is
    recoverable. On [Ok], {!validate_provider_transcript} of [messages]
    returns [Ok ()]. *)

(** {1 The end of a history, read from its last message}

    Whether {!close_open_tail} appends anything can be told from the last
    messages of a history {!partition} accepts: once a cycle closes, no later
    verdict of {!partition} depends on the messages before it, and an open
    cycle admits no other request. *)

type tail_reading
(** What the last messages of a history, read from the last one backwards,
    leave for the message before them. *)

val tail_reading_start : tail_reading
(** Before the last message is read. *)

type tail_end =
  | Every_request_answered
      (** {!close_open_tail} appends nothing to a history that {!partition}
          accepts and that ends this way. *)
  | Request_awaits_results
      (** The last message that requests tool calls names an id that no
          message after it answers. *)

type tail_step =
  | Tail_end of tail_end
  | Reads_message_before of tail_reading
      (** The message requests nothing, so the one before it is read next.
          When the first message of a history is read this way, the history
          requests nothing at all and its end is [Every_request_answered]. *)

val read_tail_message : tail_reading -> Agent_core.Types.message -> tail_step
(** [read_tail_message reading message] reads [message], the one directly
    before the messages [reading] comes from.

    For a history {!partition} accepts, reading from the last message this way
    ends with [Request_awaits_results] exactly when {!close_open_tail} appends
    a result. For a history {!partition} refuses it can end either way: the
    reading does not judge the messages it reads (their roles, an id that
    repeats, a result nobody requested) and reads none before the last
    request. *)
