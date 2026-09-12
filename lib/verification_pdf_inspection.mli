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
  | Too_many_pages of { pages : int; limit : int }
      (** Raised from the page count, before any page is rendered. *)
  | Rendered_bytes_exceeded of { pages : int; bytes : int; limit : int }
      (** Raised part way through rendering; [bytes] is what had accumulated. *)
  | Storage_failed of string

val error_to_string : error -> string

val max_pages : int
(** Pages one inspection renders. A document with more is refused before any
    page is rendered. *)

val max_total_image_bytes : int
(** Rendered PNG bytes one inspection carries, counted across its pages. The
    per-page [max_image_bytes] limit does not bound this: every page can sit
    under it and the document still be too large to answer with. *)

val inspect :
  ?max_pages:int ->
  ?max_total_image_bytes:int ->
  base_path:string ->
  max_image_bytes:int ->
  bytes:string ->
  unit ->
  (t, error) result
(** Requires installed pdftotext and pdftoppm. Missing dependencies are explicit
    failures; bundled release archives do not currently provide Poppler.

    Each Poppler command runs under a fixed timeout, so a document that makes
    one of them hang comes back as [Command_failed] instead of holding the
    caller's verification slot. The budgets default to {!max_pages} and
    {!max_total_image_bytes}; they are arguments so a test can reach the
    refusal with a document small enough to write inline. *)
