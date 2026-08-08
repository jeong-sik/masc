(** Modality ordering policy for multimodal user messages.

    Some models perform better when image / audio / document blocks
    precede text in the serialized request. Gemma 4 best practices state:

    {v
      Modality order: For optimal performance with multimodal inputs,
      place image and/or audio content before the text in your prompt.
    v}

    Other models (Anthropic, Openai, Glm) are not sensitive to this
    ordering, so the default is to preserve caller-supplied block order.

    @since 0.193.0 *)

(** Block ordering policy applied to a {!Types.message}'s content list
    just before serialization. Modeled as a sum type rather than a
    boolean so future policies (e.g. interleaved, audio-only-first) can
    be added without breaking existing call sites. *)
type priority =
  | Preserve_input_order (** Default. Caller's block order is kept verbatim. *)
  | Visual_first
  (** [Image], [Audio], and [Document] blocks are moved ahead of
        [Text] blocks. Other block kinds (tool calls, thinking) keep
        their relative position. Stable: within each group input order
        is preserved. Recommended for Gemma 4 family models. *)

(** [reorder priority blocks] applies [priority] to [blocks].

    Pure function — no I/O, no mutation, no allocation when [priority]
    is [Preserve_input_order]. Stable: relative order within each group
    is preserved.

    Block kinds classified as visual: [Image], [Audio], [Document].
    All others (Text, Thinking, RedactedThinking, ToolUse, ToolResult)
    are treated as non-visual. *)
val reorder : priority -> Types.content_block list -> Types.content_block list
