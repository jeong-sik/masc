(** Shared helpers, constants, and content-block serialization.

    @stability Internal
    @since 0.93.1 *)

val default_base_url : string
val api_version : string
val max_response_body : int
val max_stdio_buffer : int

(** Allocate an opaque, process-unique tool-use identity.

    Use this only when the provider does not supply an identity.  The result is
    independent of model-generated tool names and arguments and is safe to
    allocate concurrently from multiple OCaml 5 domains. *)
val fresh_tool_use_id : unit -> string

val string_is_blank : string -> bool
val text_blocks_to_string : Types.content_block list -> string
val json_of_string_or_raw : string -> Yojson.Safe.t

(** Raise [Invalid_argument] for a media source carrier unsupported by a backend.
    Backends should use this helper instead of silently reinterpreting [data] as
    another carrier. *)
val unsupported_media_source
  :  backend:string
  -> block:string
  -> Types.media_source_kind
  -> 'a

(** Convert a base64 media block into a data URL. Non-base64 carriers fail
    closed with {!unsupported_media_source}. *)
val base64_media_data_url
  :  backend:string
  -> block:string
  -> media_type:string
  -> data:string
  -> Types.media_source_kind
  -> string

(** Return the raw base64 payload for backends whose wire format separates the
    media type from the base64 data. Non-base64 carriers fail closed. *)
val base64_media_payload
  :  backend:string
  -> block:string
  -> data:string
  -> Types.media_source_kind
  -> string

(** {2 Document admission}

    A [Document] block must never be emitted as some other modality (oas#2744:
    the OpenAI-compatible Chat Completions serializer used to relabel it
    [image_url], so the model saw a picture where the caller sent a file, and
    nothing reported it). Two typed facts decide whether a document may go out:
    which native part the wire has ({!document_wire_form}) and whether the
    resolved model row accepts documents
    ([Capabilities.supports_document_input]). {!admit_document_blocks} checks
    both before serialization, so every serializer's [Document] arm has exactly
    one native form and no fallback. *)

(** Native document representation of a request wire. No wildcard arm: a wire
    with no document part declares {!Document_unrepresentable}. *)
type document_wire_form =
  | Document_source_block (** Anthropic [{"type":"document","source":{…}}]. *)
  | Document_inline_data (** Gemini [inlineData] with the document MIME. *)
  | Document_input_file_part (** OpenAI Responses [input_file] + [file_data]. *)
  | Document_chat_file_part
  (** OpenAI Chat Completions [{"type":"file","file":{"file_data":…}}]. *)
  | Document_unrepresentable
  (** Ollama native [/api/chat]: scalar [content] plus an [images] array
          only. *)

val document_wire_form_to_string : document_wire_form -> string

type document_admission_error =
  | Document_wire_has_no_representation of
      { wire_form : document_wire_form
      ; media_type : string
      }
  | Document_input_not_declared of
      { model_id : string
      ; media_type : string
      }

val document_admission_error_to_string : document_admission_error -> string

(** [admit_document_blocks ~wire_form ~model_id ~supports_document_input blocks]
    is [Ok ()] when every [Document] in [blocks] may be placed on a wire whose
    native form is [wire_form], and [Error] naming the first one that may not.
    Only [Document] blocks are inspected: image and audio admission is
    unchanged, so this cannot alter what a working provider emits for them. *)
val admit_document_blocks
  :  wire_form:document_wire_form
  -> model_id:string
  -> supports_document_input:bool
  -> Types.content_block list
  -> (unit, document_admission_error) result

(** {!admit_document_blocks} over a whole history, reporting the first
    inadmissible document. Retained for callers that want a hard admission
    verdict; the request/serialize paths degrade instead (see
    {!degrade_document_messages}). *)
val admit_document_messages
  :  wire_form:document_wire_form
  -> model_id:string
  -> supports_document_input:bool
  -> Types.message list
  -> (unit, document_admission_error) result

(** The visible text block an unrepresentable document is replaced with. Names
    the media type so the omission is legible to the model and, through it, the
    user — the degrade is not silent. *)
val document_omitted_placeholder : media_type:string -> Types.content_block

(** [degrade_document_messages ~wire_form ~supports_document_input messages]
    rewrites every [Document] that cannot be placed on a wire whose native form
    is [wire_form] into {!document_omitted_placeholder}, leaving representable
    documents and every other block untouched. Returns the rewritten history and
    the number of documents degraded.

    This is the request/serialize-path remedy for oas#2744: a document is never
    relabelled as another modality (the original defect) and never rejects the
    turn (which retroactively broke conversations already holding a document in
    history against a model without the capability) — it degrades to a named
    placeholder, uniformly across the whole history, statelessly. *)
val degrade_document_messages
  :  wire_form:document_wire_form
  -> supports_document_input:bool
  -> Types.message list
  -> Types.message list * int

(** {2 Content block JSON conversion} *)

val content_block_to_json : Types.content_block -> Yojson.Safe.t

type content_block_decode_error =
  | Missing_content_block_type
  | Unsupported_content_block_type of string
  | Missing_content_block_field of
      { block_type : string
      ; field : string
      }
  | Unsupported_media_source_kind of
      { block_type : string
      ; source_type : string
      }

val content_block_decode_error_to_string : content_block_decode_error -> string

val content_block_of_json_result
  :  Yojson.Safe.t
  -> (Types.content_block, content_block_decode_error) result

val content_block_of_json : Yojson.Safe.t -> Types.content_block option

(* Internal metadata is retained while projecting an immediate ToolResult plus
   plain User follow-up into one provider user turn; metadata is not wire
   content. *)
val merge_tool_result_followup_user_messages : Types.message list -> Types.message list
val message_to_json : Types.message -> Yojson.Safe.t
val kimi_message_to_json : Types.message -> Yojson.Safe.t

(** {2 TLS} *)

type https_init_error =
  | Ca_certs_unavailable of string
  | Tls_config_unavailable of string

val https_init_error_to_string : https_init_error -> string

(** Process-wide cached TLS client configuration.

    [Ca_certs.authenticator ()] loads the system trust store on every
    call: on macOS it spawns one [security find-certificate] subprocess
    per keychain and parses the resulting multi-hundred-KB PEM dump
    (X509 decode + fingerprints for the whole anchor set); on Linux it
    scans the certificate directories. The first successful result is
    cached for the process lifetime and reused by every subsequent
    connection. Certificate validity is still checked against the
    current time at each handshake (the authenticator captures a clock
    closure, not a timestamp). Errors are not cached: a failed load is
    retried on the next call. *)
val tls_client_config : unit -> (Tls.Config.client, https_init_error) result

val make_https_result
  :  unit
  -> ( Uri.t -> [> `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t -> Tls_eio.t
       , https_init_error )
       result

val make_https
  :  unit
  -> (Uri.t -> [> `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t -> Tls_eio.t)
       option
