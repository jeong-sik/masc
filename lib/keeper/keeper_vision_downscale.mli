(** Downscales images exceeding maximum dimensions before sending to vision models.
    RFC-0414 follow-up / Issue #33075.

    The original artifact stored in {!Multimodal.Vision_artifact_store} is
    preserved at full resolution; only the provider request payload is scaled.
    If an image fits within the maximum dimension (default 1568px), or if header
    dimensions cannot be determined, or if every external scaler fails, the
    function returns the original bytes and says so in the status. A media
    type this module cannot read is refused before any process is spawned. *)

type dimensions =
  { width : int
  ; height : int
  }

(** {1 Media types} *)

(** Exactly the formats {!detect_dimensions} reads. *)
type media_type =
  | Png
  | Jpeg
  | Gif
  | Webp

val all_media_types : media_type list
(** Every constructor of {!media_type}, in the order the vision tool lists
    them to a caller. *)

val media_type_to_string : media_type -> string
(** The IANA media type string, e.g. ["image/png"]. *)

val media_type_of_string : string -> media_type option
(** Inverse of {!media_type_to_string}; [None] for anything else. *)

(** {1 Scalers and attempts} *)

type scaler =
  | Sips
  | Magick
  | Convert

val scaler_to_string : scaler -> string
(** Also the program name the plan puts in argv[0]. *)

type scaler_plan =
  { scaler : scaler
  ; argv : string list
  ; output_media_type : media_type
      (** What the output file holds when the plan succeeds; sips turns WebP
          into PNG because it cannot write WebP. *)
  }

val scaler_plans
  :  max_dim:int
  -> in_file:string
  -> out_file:string
  -> media_type
  -> scaler_plan list
(** The chain tried in order: sips, then magick, then convert. Whether a
    program exists is not decided here; the spawner answers that per attempt. *)

type captured_output =
  { stdout : string
  ; stderr : string
  }

(** Every way one scaler run can fall short. Each carries what the process
    wrote so the boundary log can show it. *)
type attempt_failure =
  | Spawn_refused of Process_eio.spawn_refusal
      (** No process ran: argv[0] resolved to nothing on PATH, or the spawn
          itself was refused; the refusal says which. *)
  | Exited_nonzero of
      { code : int
      ; output : captured_output
      }
  | Timed_out of captured_output
      (** Killed at [scaler_timeout_sec]. *)
  | Signaled of
      { signal : int
      ; output : captured_output
      }
  | Stopped of
      { signal : int
      ; output : captured_output
      }
  | No_output_written of captured_output
      (** Exit 0 but the output file is missing or empty. *)
  | Output_dimensions_unknown of captured_output
      (** Exit 0, output written, but {!detect_dimensions} cannot read it. *)
  | Output_still_too_large of
      { dims : dimensions
      ; output : captured_output
      }
      (** Exit 0, output written, but its longest edge is over the bound. *)

type attempt =
  { attempted : scaler_plan
  ; failure : attempt_failure
  }

val attempt_to_string : attempt -> string

type failure_reason =
  | Unsupported_media_type of string
      (** The media type as the caller gave it; no process was spawned. *)
  | Scalers_exhausted of attempt list
      (** Every planned scaler, in the order tried, with why each fell short. *)
  | Scaler_exception of string

val failure_reason_to_string : failure_reason -> string
(** One line; for [Scalers_exhausted] it lists every attempt in order. *)

type downscale_status =
  | Unchanged_within_bounds of dimensions
  | Unchanged_unknown_dimensions
  | Downscaled of
      { original_dims : dimensions
      ; scaled_dims : dimensions
      ; scaler : scaler
      ; failed_before : attempt list
          (** Scalers earlier in the chain that fell short, in the order
              tried; empty when the first one succeeded. *)
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
  -> ?plans:(max_dim:int -> in_file:string -> out_file:string -> media_type -> scaler_plan list)
  -> media_type:string
  -> bytes:string
  -> unit
  -> (string * string) * downscale_status
(** Attempt downscaling. Returns [((media_type, bytes), status)].
    Original [(media_type, bytes)] is preserved on any failure or when bounds
    are met. [plans] defaults to {!scaler_plans}; a test passes its own to run
    scalers it controls. *)

val downscale_if_needed
  :  ?max_dimension:int
  -> media_type:string
  -> bytes:string
  -> unit
  -> string * string
(** Shorthand returning [(media_type, bytes)]. *)
