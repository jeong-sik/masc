val editable_snapshot : Yojson.Safe.t -> Yojson.Safe.t
val editor_stem : Yojson.Safe.t -> string

val patch_of_edit :
  before:Yojson.Safe.t ->
  after:Yojson.Safe.t ->
  (Yojson.Safe.t, string) result

val view_lines : sanitize:(string -> string) -> Yojson.Safe.t -> string list
(** The whole Settings pane, styled. Every row carries a glyph saying whether
    [e] reaches it, and the field count in the heading comes from
    [editable_snapshot] so it matches what the editor actually opens.

    [sanitize] is applied to every fetched value before it reaches the frame.
    It is mandatory so a new terminal caller cannot accidentally choose an
    unsafe identity default; projection tests pass [Fun.id] explicitly. *)
