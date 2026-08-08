(** Redacted response-shape diagnostics for completed provider responses.

    This module is provider-agnostic: it counts normalized {!Types.content_block}
    variants after provider parsing. It does not interpret model-family-specific
    thinking semantics and it never exposes hidden thinking content. *)

type t =
  { text_chars : int
  ; text_blocks : int
  ; thinking_blocks : int
  ; thinking_chars : int
  ; redacted_thinking_blocks : int
  ; tool_use_count : int
  ; tool_result_count : int
  ; image_count : int
  ; document_count : int
  ; audio_count : int
  ; content_kinds : string list
  }

type content_shape =
  | Empty
  | Thinking_only
  | Blank_text_only
  | Tool_result_only
  | Media_only
  | Mixed_without_deliverable_content
  | Has_deliverable_content

(** [summarize_blocks blocks] computes the redacted shape counts over a bare
    content-block list, independent of any response envelope. This is the core
    of {!summarize}: [summarize r = summarize_blocks r.content]. Counts only
    (lengths/counts; never the underlying text/thinking/tool payloads). *)
val summarize_blocks : Types.content_block list -> t

val summarize : Types.api_response -> t
val content_shape : Types.api_response -> t -> content_shape
val content_shape_to_string : content_shape -> string

(** [true] when the response carries downstream-visible progress: non-blank
    text, a tool call, or an image/document/audio block. Hidden thinking and
    tool results are not deliverable progress by themselves. *)
val has_deliverable_content : t -> bool

(** [true] when the provider response ended normally without downstream-visible
    content. This is the generic OAS-side primitive that consumers can map to
    their own accept/retry policy. *)
val ended_without_deliverable_content : Types.api_response -> bool

(** Redacted, operator-facing counts only. The returned string does not include
    text, thinking text, tool inputs, tool results, or media payloads. *)
val diagnostic_summary : Types.api_response -> string
