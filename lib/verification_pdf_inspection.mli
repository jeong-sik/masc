(** Poppler inspection of already-contained complete PDF bytes. The immutable
    copy is parsed for page count, page geometry and text, then every page is
    rendered from that same copy. No producer path is passed to Poppler. *)
type page =
  { number : int
  ; width_points : float
  ; height_points : float
  ; text : string
  ; png : string
  }

type t =
  { source_bytes : int
  ; source_sha256 : string
  ; pages : page list
  ; diagnostics : string list
  }

type error =
  | Dependency_unavailable of string list
  | Command_failed of { program : string; status : Unix.process_status; detail : string }
  | Invalid_output of string
  | Image_policy_rejected of { page : int; bytes : int; limit : int }
  | Storage_failed of string

val error_to_string : error -> string
val inspect : base_path:string -> max_image_bytes:int -> bytes:string -> (t, error) result
(** Requires installed pdftotext and pdftoppm. Missing dependencies are explicit
    failures; bundled release archives do not currently provide Poppler. *)
