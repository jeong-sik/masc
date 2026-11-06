(** Keeper_chat_store — JSONL-based persistence for keeper direct messages.

    Each keeper gets a file: [<base_dir>/.masc/keeper_chat/<name>.jsonl]
    Lines are append-only with timestamps.

    Line format:
    {v {"id":"msg-...","role":"user","content":"hello","ts":1774000000.0} v}

    Tool-call lines (persisted between the user and assistant lines of a
    turn) carry the executed tool name and accumulated arguments:
    {v {"id":"msg-...","role":"tool","content":"{\"path\":\"x\"}","ts":...,
        "tool_call_id":"toolu_1","tool_call_name":"Read",
        "surface":{"kind":"dashboard"}} v}

    Connector rows may additionally carry opaque route coordinates:
    [conversation_id] for channel/thread grouping and [external_message_id]
    for the inbound platform message. The store does not interpret these
    values.

    The code lives in the [Keeper_chat_store_*] modules included below.
    Each include uses only the ones above it, and [keeper_chat_store.mli]
    is the interface callers see.

    @since 2.145.0 *)

include Keeper_chat_types
include Keeper_chat_store_paths
include Keeper_chat_store_redaction
include Keeper_chat_store_row_codec
include Keeper_chat_store_delivery_rules
include Keeper_chat_store_provenance_index
include Keeper_chat_store_append_primitives
include Keeper_chat_store_turn_append
include Keeper_chat_store_append_once
include Keeper_chat_store_message_append
include Keeper_chat_store_line_decode
include Keeper_chat_store_history_window
include Keeper_chat_store_transcript_rows
include Keeper_chat_store_transcript_load
include Keeper_chat_store_approval_lifecycle
include Keeper_chat_store_audio_clip
include Keeper_chat_store_turn_transcript

