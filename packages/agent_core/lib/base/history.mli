(** History-side content: the same blocks and messages as
    {!Llm_provider.Types}, with media held by reference (RFC-0476 §3.4, D5).

    A history media block has no base64 carrier. Raw media bytes live in a
    {!media_store}; the block keeps their {!stored} digest and length, or an
    external [Url]/[File_id] reference, which holds no bytes either. History
    and provider blocks meet only through {!of_wire_block}, which decodes and
    stores base64 payloads, and {!to_wire_block}, which reads them back and
    encodes them again. Every other constructor carries the provider payload
    unchanged. *)

(** {1 Stored media reference} *)

(** Raw media bytes held in a {!media_store}. [sha256] is the SHA-256 of the
    raw bytes (not of their base64 text) as 64 lowercase hex characters;
    [bytes] is their length. Built only by {!stored} and {!stored_of_raw}. *)
type stored = private
  { sha256 : string
  ; bytes : int
  }
[@@deriving show]

type stored_error =
  | Sha256_not_lowercase_hex of string
  (** Not exactly 64 characters of [0-9a-f]. *)
  | Negative_byte_count of int
[@@deriving show]

(** Checks the field forms. It reads no media, so it cannot tell whether
    [sha256] and [bytes] describe the same bytes; {!media_store.get} does. *)
val stored : sha256:string -> bytes:int -> (stored, stored_error) result

(** The reference of [raw]: its SHA-256 and its length. *)
val stored_of_raw : string -> stored

(** {1 Content} *)

type media_source =
  | Stored of stored
  | Url of string
  | File_id of string
[@@deriving show]

(** {!Llm_provider.Types.content_block} constructor for constructor. Only the
    media [source] type differs. *)
type content_block =
  | Text of string
  | Thinking of
      { content : string
      ; signature : string option
      }
  | ReasoningDetails of
      { reasoning_content : string option
      ; details : Llm_provider.Types.reasoning_detail list
      }
  | RedactedThinking of string
  | ToolUse of
      { id : string
      ; name : string
      ; input : Yojson.Safe.t
      }
  | ToolResult of
      { tool_use_id : string
      ; content : string
      ; outcome : Llm_provider.Types.tool_result_outcome
      ; json : Yojson.Safe.t option
      ; content_blocks : content_block list option
      }
  | Image of
      { media_type : string
      ; source : media_source
      }
  | Document of
      { media_type : string
      ; source : media_source
      }
  | Audio of
      { media_type : string
      ; source : media_source
      }
[@@deriving show]

(** {!Llm_provider.Types.message} with history content. *)
type message =
  { role : Llm_provider.Types.role
  ; origin : Llm_provider.Types.message_origin
  ; content : content_block list
  ; name : string option
  ; tool_call_id : string option
  ; metadata : Llm_provider.Types.metadata
  }
[@@deriving show]

(** {1 Media store} *)

type media_error =
  | Store_failed of { detail : string }
  (** The store could not write or read. *)
  | Missing_bytes of stored
  (** The store holds no bytes under this digest. *)
  | Invalid_base64 of
      { media_type : string
      ; detail : string
      }
  (** A provider payload that does not decode as padded standard base64. *)
  | Digest_mismatch of
      { expected : stored
      ; actual : stored
      }
  (** The bytes the store read back are not the bytes [expected] names;
      [actual] is the reference of what was read. *)
[@@deriving show]

(** The caller's media store. [put] keeps [raw] and returns
    [stored_of_raw raw]; writing the same bytes twice returns the same
    reference. [get] returns the raw bytes [stored] names and fails with
    [Digest_mismatch] instead of returning bytes whose digest or length
    differ. *)
type media_store =
  { put : media_type:string -> raw:string -> (stored, media_error) result
  ; get : stored -> (string, media_error) result
  }

(** {1 Provider conversions}

    Blocks are converted left to right, ToolResult [content_blocks]
    included, and the first error stops the conversion. Bytes already put
    before that error stay in the store. *)

(** [Base64] payloads are decoded and put; the block then holds [Stored].
    [Url] and [File_id] pass through without touching the store. *)
val of_wire_block
  :  media_store
  -> Llm_provider.Types.content_block
  -> (content_block, media_error) result

val of_wire_message
  :  media_store
  -> Llm_provider.Types.message
  -> (message, media_error) result

(** [Stored] is read with [get] and becomes a padded standard [Base64]
    payload. [Url] and [File_id] pass through without touching the store.
    [to_wire_block store b'] returns the original [b] when
    [of_wire_block store b = Ok b'] and every base64 payload in [b] is the
    canonical encoding of its bytes. *)
val to_wire_block
  :  media_store
  -> content_block
  -> (Llm_provider.Types.content_block, media_error) result

val to_wire_message
  :  media_store
  -> message
  -> (Llm_provider.Types.message, media_error) result

(** {1 Byte accounting} *)

(** Raw bytes for [Stored], payload length for [Url] and [File_id]. *)
val media_source_bytes : media_source -> int

(** Sum of {!media_source_bytes} over the media in a block, ToolResult
    [content_blocks] included; [0] for a block without media. *)
val media_bytes : content_block -> int

(** {1 JSON}

    A block without media encodes to the same bytes as the current
    checkpoint encoding of the provider block: {!Llm_provider.Api_common}
    for Text, Thinking, ReasoningDetails, RedactedThinking and ToolUse, and
    its ToolResult fields followed by [failure_kind], [error_class] and
    [text_content]. [Url] and [File_id] media keep the provider shape. A
    [Stored] source is
    [{"type":"stored","media_type":_,"sha256":_,"bytes":_}].

    The decoder accepts only these shapes: every object has its listed
    fields and no other, no field twice, and a [base64] source is refused.
    As in the current checkpoint, ToolResult [json] is not written and
    decodes as [None], and Text, unsigned Thinking, reasoning content and
    string tool output pass through UTF-8 sanitizing on encode. *)

type json_expectation =
  | Json_object
  | Json_array
  | Json_string
  | Json_string_or_array
  | Json_bool
  | Json_int
  | Json_non_blank_string
[@@deriving show]

type tool_result_problem =
  | Failure_without_kind
  | Error_class_without_kind
  | Success_with_provenance
  | Text_content_with_string_content
[@@deriving show]

(** [at] is the JSON path of the refused value, from [$] for the decoded
    root. *)
type decode_error =
  | Wrong_json_kind of
      { at : string
      ; expected : json_expectation
      }
  | Missing_field of
      { at : string
      ; field : string
      }
  | Unknown_field of
      { at : string
      ; field : string
      }
  | Duplicate_field of
      { at : string
      ; field : string
      }
  | Unknown_block_type of
      { at : string
      ; block_type : string
      }
  | Base64_source of { at : string }
  | Unknown_source_type of
      { at : string
      ; source_type : string
      }
  | Invalid_stored of
      { at : string
      ; error : stored_error
      }
  | Unknown_failure_kind of { at : string }
  | Unknown_error_class of { at : string }
  | Unknown_role of
      { at : string
      ; role : string
      }
  | Unknown_origin of
      { at : string
      ; origin : string
      }
  | Inconsistent_tool_result of
      { at : string
      ; problem : tool_result_problem
      }
  | Empty_metadata of { at : string }
  (** The encoder omits empty metadata, so a present one is not empty. *)
[@@deriving show]

val content_block_to_json : content_block -> Yojson.Safe.t
val content_block_of_json : Yojson.Safe.t -> (content_block, decode_error) result

(** Same fields and order as the current checkpoint message: [role],
    [origin], [content], then [name], [tool_call_id] and non-empty
    [metadata] when present. Role and content combinations are not checked
    here. *)
val message_to_json : message -> Yojson.Safe.t

val message_of_json : Yojson.Safe.t -> (message, decode_error) result

(** {1 In-memory store} *)

module Memory_store : sig
  (** A store in a hash table guarded by a mutex, for tests. [get] recomputes
      the digest of what it returns. *)
  val create : unit -> media_store
end
