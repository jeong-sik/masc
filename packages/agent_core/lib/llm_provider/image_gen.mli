(** Standalone image generation over typed provider image-API dialects.

    Covers dedicated non-chat image generation endpoints ([/images/generations],
    Gemini/Vertex Imagen [:predict]) without routing them through chat
    completion codecs. Request building and response decoding are pure and
    exhaustively matched on {!Capabilities.images_api_dialect}. *)

type request =
  { prompt : string
  ; aspect_ratio : string option
  ; size : string option
  ; quality : string option
  ; count : int option
  ; output_format : string option
    (** Optional format hint such as ["png"], ["jpeg"], or ["webp"]. *)
  ; negative_prompt : string option
    (** Optional negative prompt for dialects that support it (e.g. Imagen). *)
  }
[@@deriving show, eq]

val make_request
  :  ?aspect_ratio:string
  -> ?size:string
  -> ?quality:string
  -> ?count:int
  -> ?output_format:string
  -> ?negative_prompt:string
  -> string
  -> request

(** Default maximum HTTP response body size (64 MiB) for standalone image
    generation endpoints carrying multi-image base64 JSON payloads. *)
val max_response_bytes : int

type generated_image =
  { mime_type : string option
    (** Explicitly declared provider MIME type (from [mime_type], [mimeType],
        or [output_format] fields), or [None] when undeclared so downstream
        storage can sniff magic bytes without false mismatch errors. *)
  ; data_bytes : string option
    (** Raw decoded binary bytes when the provider returned base64 payload. *)
  ; remote_url : string option
    (** Provider-hosted URL when the provider returned a URL instead of inline bytes. *)
  ; revised_prompt : string option
  }
[@@deriving show, eq]

type generation_result =
  { images : generated_image list
  ; ignored_options : string list
    (** Request option names supplied by the caller that this dialect has no
        wire field for (for example ["aspect_ratio"] on [Openai_images_v1],
        ["quality"] on [Gemini_imagen_predict]). *)
  }
[@@deriving show, eq]

(** List the non-empty option names in [request] that [dialect] has no wire
    representation for (["aspect_ratio"], ["size"], ["quality"], ["count"],
    ["output_format"], ["negative_prompt"]). Pure and exhaustive on
    {!Capabilities.images_api_dialect}. *)
val unsupported_options
  :  dialect:Capabilities.images_api_dialect
  -> request
  -> string list

(** List the non-empty option names in [request] that [contract] has no wire
    representation for. Covers both standalone {!Capabilities.Endpoint_images_api}
    dialects and all in-turn {!Capabilities.image_output_contract} modes. *)
val unsupported_options_for_contract
  :  contract:Capabilities.image_output_contract
  -> request
  -> string list

(** Resolve the standalone {!Capabilities.images_api_dialect} declared by
    [config]'s resolved model capabilities ([Endpoint_images_api dialect]).
    Returns [Error] for chat/in-turn contracts or [No_image_output]. *)
val dialect_of_config : Provider_config.t -> (Capabilities.images_api_dialect, string) result

(** Construct the full HTTP endpoint URL for [dialect] and [config]:
    - Explicit non-blank [config.request_path] always wins (leading ['/']
      normalized) for [Openai_images_v1] / [Zai_images_v4].
    - When [config.request_path] is blank:
      - [Openai_images_v1] appends ["/images/generations"] if [base_url]
        already ends with ["/v1"], otherwise ["/v1/images/generations"].
      - [Zai_images_v4] appends ["/images/generations"] if [base_url] already
        ends with ["/api/paas/v4"] or ["/v4"], otherwise
        ["/api/paas/v4/images/generations"].
    - [Gemini_imagen_predict]: [<base_url>/models/<model_id>:predict] via
      {!Complete_sampling.gemini_predict_url}. *)
val request_url
  :  dialect:Capabilities.images_api_dialect
  -> config:Provider_config.t
  -> string

(** Pure JSON request body serializer. Fails closed with [Error] on blank
    prompts, non-positive counts, unrecognized [output_format], or a non-blank
    [negative_prompt] targeting a dialect that cannot honor negative prompts
    ([Openai_images_v1], [Zai_images_v4]). *)
val build_request_body
  :  dialect:Capabilities.images_api_dialect
  -> config:Provider_config.t
  -> request
  -> (string, string) result

(** Pure JSON response decoder. Decodes base64 payloads into raw binary
    [data_bytes], extracts [remote_url] / [revised_prompt], and records
    [mime_type = Some m] only when explicitly declared by the provider ([None]
    when undeclared). Fails closed on error envelopes, malformed base64, or
    empty image lists. *)
val parse_response
  :  dialect:Capabilities.images_api_dialect
  -> string
  -> (generated_image list, string) result

(** Execute a standalone image generation HTTP POST using [config]'s resolved
    auth headers, custom headers, and endpoint URL. Uses [max_response_bytes]
    (default {!max_response_bytes}, 64 MiB) instead of the 10 MiB text cap, and
    returns {!generation_result} with any [ignored_options] surfaced explicitly.
    Supports single-shot 401 credential refresh when [config] carries an
    invalidatable credential source (e.g. Vertex ADC OAuth). *)
val generate
  :  ?cache:Http_client.cache
  -> ?timeout_s:float
  -> ?max_response_bytes:int
  -> sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> clock:_ Eio.Time.clock
  -> config:Provider_config.t
  -> dialect:Capabilities.images_api_dialect
  -> request
  -> (generation_result, Http_client.http_error) result
