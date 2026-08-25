(** Provider-reported input-token count contract.

    This module owns only the typed protocol vocabulary and response decoding.
    Endpoint selection, request construction, and transport execution remain
    outside this boundary.

    @stability Internal *)

type protocol =
  | Anthropic_messages_count_tokens
  | Openai_responses_input_tokens
  | Gemini_count_tokens
[@@deriving show, eq]

type count = private
  { input_tokens : int
  ; protocol : protocol
  ; model_id : string
  }
[@@deriving show, eq]

type error =
  | Unsupported of
      { protocol : protocol
      ; model_id : string
      }
  | Transport of Http_client.http_error
  | Invalid_response of
      { protocol : protocol
      ; model_id : string
      ; detail : string
      }

(** Decode one successful provider response.

    [model_id] is carried byte-for-byte as caller-owned identity. It is never
    inspected to select a protocol. All protocols accept zero and reject
    negative or non-integral token counts. *)
val decode_response
  :  protocol:protocol
  -> model_id:string
  -> string
  -> (count, error) result

(** Preserve an existing typed HTTP failure or decode the successful body. *)
val decode_transport_result
  :  protocol:protocol
  -> model_id:string
  -> (string, Http_client.http_error) result
  -> (count, error) result
