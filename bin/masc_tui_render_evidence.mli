(** The "EVIDENCE CONTENT" section of the awaiting-verification task detail,
    as the rows the pane draws. Apart from the pane so the row model is tested
    without a terminal.

    A row is [(style, text)]. Rows are already wrapped to the pane's width, so
    the count of rows is the count of lines drawn, and a picture's reserved
    area is known by the index of its first row. *)

val wrap_rows : width:int -> (string * string) list -> (string * string) list
(** Rows wider than [width] are wrapped at word breaks; rows that fit are kept
    as they are, so field alignment survives. *)

val section :
  evidence:(Masc_tui_evidence_picture.evidence,
    Masc_tui_types.Verification_evidence_read.failure) Masc_tui_fetched.observation ->
  in_flight:bool ->
  workspace_confirmed:bool ->
  width:int ->
  content_height:int ->
  display:Masc_tui_portrait_view.display ->
  (string * string) list
  * (Masc_tui_evidence_picture.slot * Masc_tui_evidence_picture.pixels) list
(** The original detail's typed evidence observation. Never-asked, pending,
    previous-value refresh and typed failures remain distinct. The caller
    projects the exact verification-request/Task key; another key is absent. Each binary artifact is a caption row. On a terminal that
    draws pixels, a picture that fits ({!Masc_tui_evidence_picture.block}) is
    also a run of blank rows under its caption; its slot gives the index of the
    first blank row among the section's rows and the cells it takes. Each item
    is followed by the links it carries, one row each. *)

(** What one frame asks of the terminal for one picture. *)
type request =
  | Show of Masc_tui_portrait_view.png_placement
      (** the picture, cropped to the rows of its area inside the window *)
  | Hold of { image_id : int; key : string }
      (** no row of its area is inside the window *)

val requests :
  pictures:(Masc_tui_evidence_picture.slot * Masc_tui_evidence_picture.pixels) list ->
  evidence_first:int ->
  scroll:int ->
  content_height:int ->
  content_origin:int * int ->
  request list
(** [pictures] are as {!section} returned them, their rows counted from the
    section's first row. [evidence_first] is the section's first row among
    all the pane's rows, [scroll] the pane's first shown row, [content_origin]
    the frame (row, column) of the first content row's first cell. *)
