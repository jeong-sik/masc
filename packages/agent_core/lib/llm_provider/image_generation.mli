(** Typed image-generation round trips for catalog-declared image models.

    The selected model must declare [task = "image_generation"] in the model
    catalog (or in an explicit capability override). OAS never infers the task
    from a model id, endpoint, or provider label. *)

type source =
  | Remote_url of string
  | Inline_base64 of
      { media_type : string option
        (** Populated only when the response declares its format (the
            OpenAI-style top-level [output_format] field). [None] means the
            wire did not state a type; callers must not assume one. *)
      ; data : string
      }

type image = { source : source }

type usage =
  { input_tokens : int option
  ; output_tokens : int option
  ; total_tokens : int option
  ; cached_tokens : int option
  ; thought_tokens : int option
  ; tool_use_tokens : int option
  }

type filter_role =
  | User
  | Assistant
  | History
  | Other of string

type content_filter =
  { role : filter_role option
  ; level : int
  }

type response =
  { created_at : int option
  ; created_at_rfc3339 : string option
  ; provider_response_id : string option
  ; images : image list
  ; usage : usage option
  ; content_filter : content_filter list
  }

(** Generate images through an exact provider config.

    [Glm] uses the Z.AI image-generation wire. [OpenAI_compat] uses the OpenAI
    Image API wire. [Gemini] uses the current Interactions API and requests an
    image-only PNG response. Other provider kinds are rejected before I/O. The
    caller owns any [timeout_s]; omission installs no OAS deadline. *)
val generate
  :  sw:Eio.Switch.t
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:_ Eio.Time.clock
  -> ?timeout_s:float
  -> ?connection_cache:Http_client.cache
  -> config:Provider_config.t
  -> prompt:string
  -> unit
  -> (response, Http_client.http_error) result
