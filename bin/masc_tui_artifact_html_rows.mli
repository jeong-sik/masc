val render : width:int -> Masc_tui_artifact_html.t -> string list
(** Terminal reading of the inert HTML projection. Text is sanitized and stays
    literal; generated headings/lists/tables provide structure. No HTML executes. *)
