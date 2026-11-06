(** The redaction of a chat row before it is stored, and the stored reference
    that replaces an attachment payload.

    [redaction_for] takes the redaction snapshot of a keeper. It adds the
    GitHub CLI credential files to the secret sources, so a [gh] token cannot
    reach a chat row unmasked. [redact_message] applies a snapshot to the
    [content], the attachments, the blocks, the audio and the approval
    lifecycle of a message. The other [redact_] functions do the same for one
    kind of value: a string, an attachment, a tool call, the JSON of a trace,
    a table cell, a trace step and a block.
    [persisted_attachment] is not a redaction: it measures the dimensions of
    an image attachment and replaces the inline payload with a reference to
    the stored blob.
    [Keeper_chat_store] includes this module. *)
open Keeper_chat_types

val redaction_for :
  base_dir:string -> keeper_name:string -> Keeper_secret_redaction.t

val redact_attachment :
  Keeper_secret_redaction.t ->
  attachment -> attachment

val persisted_attachment :
  base_dir:string ->
  attachment -> attachment

val redact_tool_call :
  Keeper_secret_redaction.t ->
  tool_call -> tool_call

val redact_blocks :
  Keeper_secret_redaction.t ->
  chat_block list option ->
  chat_block list option

val redact_audio :
  Keeper_secret_redaction.t ->
  audio_clip -> audio_clip

val redact_approval_lifecycle :
  Keeper_secret_redaction.t ->
  approval_lifecycle ->
  approval_lifecycle

val redact_message :
  Keeper_secret_redaction.t ->
  chat_message -> chat_message
