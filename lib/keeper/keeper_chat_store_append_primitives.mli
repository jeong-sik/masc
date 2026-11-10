(** The primitives that every writer of a chat row uses.

    [append_line_once] appends a line to a transcript under the file lock
    unless [find_provenance] already finds the delivery in it, and says
    whether the line was appended or was already present. Autonomous turns
    require the binding-aware batch writer and are refused here.
    [append_chat_payload_durable] appends one payload durably and raises
    [Sys_error] when the write fails. [announce_appended] tells the open
    transcripts that a row was stored.
    A tool call is addressed in a transcript by its slot. [tool_transcript_slot]
    is a [Tool_call] slot when the call has an execution id and a
    [Tool_delivery] slot when it has none. [tool_transcript_bindings] pairs
    every call of a turn with its slot, and [tool_ownerships] lists the
    execution id and the ordinal of the calls that have an id.
    [normalize_tool_args] turns blank arguments into ["{}"] and
    [provider_tool_call_id] reads a blank provider call id as [None].
    [Keeper_chat_store] includes this module. *)
open Keeper_chat_types

val append_line_once :
  string ->
  provenance:Keeper_chat_delivery_identity.delivery_provenance ->
  row_id:string ->
  string -> (append_once_result, string) result

val append_chat_payload_durable : string -> string -> unit

val announce_appended :
  keeper_name:string ->
  ?surface:Surface_ref.t ->
  ?audio:audio_clip -> unit -> unit

val normalize_tool_args : string -> string

val provider_tool_call_id : string -> string option

val tool_transcript_slot :
  ordinal:int ->
  tool_call ->
  Keeper_chat_delivery_identity.transcript_slot

type tool_ownership =
  { execution_id : Ids.Execution_id.t
  ; ordinal : int
  }

val tool_ownerships : tool_call list -> tool_ownership list

val tool_transcript_bindings :
  tool_call list -> (tool_call * Keeper_chat_delivery_identity.transcript_slot) list
