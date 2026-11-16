(** Pure, audience-aware projection of an attached service's MCP result.

    The SDK owns the content variants. Its permissive annotation decoder is
    preceded by strict shape checks so an invalid audience cannot become an
    unrestricted one. Unknown or malformed items return a diagnostic naming
    only their position and a fixed reason, never their payload.

    This module performs no storage or URI fetch. The caller must retain the
    original result independently, including when this projection fails, and
    must preserve the call's effect disposition. A projection failure does
    not establish that the service performed no effect. *)

val private_result_mime : string
(** Audit envelope containing the received content, including non-model
    audiences. Retention owners keep its reference; model status projections
    must not expose that reference as an indirect way to read the envelope. *)

type block =
  | Native_block of Llm_provider.Types.content_block
  | Binary_resource of
      { uri : string
      ; mime_type : string option
      ; bytes : string
      }
(** A valid embedded blob need not have a native model representation. Its
    decoded bytes remain a resource; the consumer publishes a readable byte
    artifact without guessing a document or fetching its URI. *)

type projection = private
  { content : string
    (** Text fallback, including descriptions of visible media and resource
        references. Never includes base64 payloads or user-only content. *)
  ; content_blocks : block list option
    (** The complete assistant-visible sequence, with native media and the
        separate structuredContent value. [None] means no visible blocks. *)
  }

val project : Mcp_client.tool_result -> (projection, string) result
(** Media uses canonical padded base64. Embedded resources must contain
    exactly one of text/blob. Recognized image, audio or PDF types use native
    blocks; other blobs, including absent MIME and empty files, use
    [Binary_resource]. Resource links remain text references
    and are never fetched. The original result is not mutated. *)
