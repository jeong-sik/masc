type image_action = Preview_image | No_image_action
val render : ?image_action:image_action -> width:int -> Masc_tui_artifact_html.t -> string list
(** Terminal reading of the inert HTML projection. Text is sanitized and stays
    literal; generated headings/lists/tables provide structure. No HTML executes.
    The default [Preview_image] names the Resources preview key. Readers without
    that action pass [No_image_action] and show only image provenance. *)
