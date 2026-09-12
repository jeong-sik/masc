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
  | Page_budget_exceeded of
      { pages : int; page_limit : int; bytes : int; byte_limit : int }
      (** Every page can be under the per-page limit and the document still be
          too large: the pages are held together and base64-encoded into one
          response. [bytes] is zero when the page count alone refused it, before
          anything was rendered. *)
  | Storage_failed of string

val error_to_string : error -> string
val max_pages : int
val max_total_image_bytes : int
(** The defaults [inspect] applies. Submitted evidence is not trusted input, and
    every page under [max_image_bytes] still adds up: the pages are held together
    and base64-encoded into one response. *)

val inspect :
  ?max_pages:int ->
  ?max_total_image_bytes:int ->
  base_path:string ->
  max_image_bytes:int ->
  bytes:string ->
  unit ->
  (t, error) result
(** Requires installed pdftotext and pdftoppm. Missing dependencies are explicit
    failures; bundled release archives do not currently provide Poppler. *)
