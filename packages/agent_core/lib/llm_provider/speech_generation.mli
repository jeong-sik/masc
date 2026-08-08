(** Typed text-to-speech round trips for catalog-declared speech models. *)

type output_format =
  | Mp3
  | Opus
  | Aac
  | Flac
  | Wav
  | Pcm

type voice =
  | Named of string
  | Custom_id of string

type source =
  | Raw_bytes of string
  | Inline_base64 of
      { media_type : string
      ; data : string
        (** Base64 payload exactly as the provider sent it — not decoded and
            not validated here; decoding is the caller's responsibility. *)
      }
  | Remote_url of string

type audio =
  { format : output_format
  ; source : source
  ; sample_rate : int option
  ; channels : int option
  }

type usage =
  { input_tokens : int option
  ; output_tokens : int option
  ; total_tokens : int option
  ; cached_tokens : int option
  ; thought_tokens : int option
  ; tool_use_tokens : int option
  }

type response =
  { provider_response_id : string option
  ; created_at_rfc3339 : string option
  ; audios : audio list
  ; usage : usage option
  }

(** Generate speech through an exact provider config.

    [OpenAI_compat] uses the OpenAI Speech API. [Gemini] uses a stateless
    Interactions request. Unsupported provider/format/voice combinations fail
    before I/O. Omission of [timeout_s] installs no OAS deadline. *)
val generate
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:_ Eio.Time.clock
  -> ?timeout_s:float
  -> ?connection_cache:Http_client.cache
  -> config:Provider_config.t
  -> text:string
  -> voice:voice
  -> format:output_format
  -> unit
  -> (response, Http_client.http_error) result
