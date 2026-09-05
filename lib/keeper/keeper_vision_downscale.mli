(** Downscales images exceeding maximum dimensions before sending to vision models.
    RFC-0414 follow-up / Issue #33075.

    The original artifact stored in {!Multimodal.Vision_artifact_store} is
    preserved at full resolution; only the provider request payload is scaled.
    If an image fits within the maximum dimension (default 1568px), or if header
    dimensions cannot be determined, or if external scaler tools fail, the
    function gracefully returns the original bytes without error. *)

val default_max_dimension : int
(** Default longest edge limit (1568px). *)

val max_dimension : unit -> int
(** Maximum dimension configured via [MASC_KEEPER_VISION_MAX_DIMENSION] or
    {!default_max_dimension}. Clamped to [256, 8192]. *)

type dimensions =
  { width : int
  ; height : int
  }

type scaler =
  | Sips
  | Magick
  | Convert

val scaler_to_string : scaler -> string

type failure_reason =
  | Scalers_exhausted
  | Scaler_exception of string

val failure_reason_to_string : failure_reason -> string

type downscale_status =
  | Unchanged_within_bounds of dimensions
  | Unchanged_unknown_dimensions
  | Downscaled of
      { original_dims : dimensions
      ; scaled_dims : dimensions option
      ; scaler : scaler
      }
  | Downscale_fallback_error of failure_reason

val detect_dimensions : string -> dimensions option
(** Identify pixel dimensions from leading image header bytes.
    Supports PNG, JPEG, GIF (via {!Keeper_image_dimensions}), and WebP
    (VP8 lossy, VP8L lossless, and VP8X extended). *)

val needs_downscale : ?max_dimension:int -> string -> bool
(** True iff detected dimensions exceed [max_dimension]. *)

val downscale_with_status
  :  ?max_dimension:int
  -> media_type:string
  -> bytes:string
  -> unit
  -> (string * string) * downscale_status
(** Attempt downscaling. Returns [((media_type, bytes), status)].
    Original [(media_type, bytes)] is preserved on any failure or when bounds are met. *)

val downscale_if_needed
  :  ?max_dimension:int
  -> media_type:string
  -> bytes:string
  -> unit
  -> string * string
(** Shorthand returning [(media_type, bytes)]. *)
