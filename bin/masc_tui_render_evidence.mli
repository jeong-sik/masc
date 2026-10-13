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
  evidence:
    (string
    * ( Masc_tui_evidence_picture.evidence
      , Masc_tui_types.Verification_evidence_read.failure )
      result)
    option ->
  task_id:string ->
  width:int ->
  content_height:int ->
  display:Masc_tui_portrait_view.display ->
  (string * string) list
  * (Masc_tui_evidence_picture.slot * Masc_tui_evidence_picture.pixels) list
(** The section for [task_id], from the evidence read for that task; an
    answer that names another task is not drawn and the section reads
    "loading...". Each binary artifact is a caption row. On a terminal that
    draws pixels, a picture that fits ({!Masc_tui_evidence_picture.block}) is
    also a run of blank rows under its caption; its slot gives the index of the
    first blank row among the section's rows and the cells it takes. Each item
    is followed by the links it carries, one row each. *)
