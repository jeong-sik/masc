(** Pure core of the [analyze_image] delegation tool.
    RFC-keeper-vision-delegation-tool §2.2.

    Encodes the input/output contract of a vision sub-call independent of the
    provider transport (the mid-turn provider round-trip of §2.6 is the impure
    shell, deferred). The load-bearing guarantee: an empty or truncated vision
    reply is a typed error, never [Ok ""] — so delegation cannot reproduce the
    2026-06-25 empty-reply failure class one layer inward. *)

type request =
  { query : string
  ; image_media_type : string
  ; image_bytes : string
  }
(** A validated one-shot vision request: a [query] plus the image bytes loaded
    from {!Vision_artifact_store}. *)

val make_request
  :  query:string
  -> image_media_type:string
  -> image_bytes:string
  -> (request, string) result
(** Validate the inputs at the boundary (fail closed): [query] must be non-blank,
    [image_bytes] non-empty, [image_media_type] non-blank. [Error msg] otherwise. *)

type extraction_error =
  | Empty_extraction
      (** A normal stop with no usable text — the model produced nothing. *)
  | Truncated_extraction
      (** The reply was truncated (hit the token budget) before emitting usable
          text. The measured cause of the 2026-06-25 gemma4 empty reply (thinking
          consumed the whole budget). Retry with a larger budget or a runtime
          that is not thinking-token-starved. *)

val string_of_error : extraction_error -> string

val classify
  :  truncated:bool
  -> content:string
  -> (string, extraction_error) result
(** The analyze_image result contract:
    - trimmed-non-empty [content] -> [Ok trimmed] (usable even if [truncated]);
    - empty [content] with [truncated] -> [Error Truncated_extraction];
    - empty [content] otherwise -> [Error Empty_extraction].

    [truncated] is the provider's terminal-reason collapsed to a single bit. This
    module stays free of any provider/SDK type: the caller (keeper layer, which
    has the typed {!Agent_sdk.Types.stop_reason}) maps [MaxTokens -> true] and
    every other reason to [false] before calling. Keeping the typed [stop_reason]
    out of here avoids a string-classifier duplicate of an existing closed sum. *)
