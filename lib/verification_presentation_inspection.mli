(** Inspect complete, already-contained PPTX bytes using the workspace's managed
    python-pptx interpreter and LibreOffice. No producer pathname is passed to
    either program. Every slide, including hidden slides, is rendered to PDF and
    inspected with Poppler. Static rendering does not inspect animation, embedded
    media playback, chart data, or accessibility. *)
type slide = { number : int; text : string; speaker_notes : string option }

type t =
  { source_bytes : int
  ; source_sha256 : string
  ; slides : slide list
  ; rendered_pdf : Verification_pdf_inspection.t
  ; diagnostics : string list
  }

type error =
  | Dependency_unavailable of string list
  | Command_failed of { program : string; status : Unix.process_status; detail : string }
  | Invalid_output of string
  | Policy_rejected of string
  | Storage_failed of string
  | Pdf_inspection_failed of Verification_pdf_inspection.error

val error_to_string : error -> string
val inspect : base_path:string -> max_image_bytes:int -> bytes:string -> (t, error) result
(** Missing dependencies are failures with setup guidance. External loading
    relationships and embedded active documents are rejected before rendering;
    ordinary hyperlinks are preserved without being followed. The private source
    snapshot is checked unchanged after parsing and rendering. *)
