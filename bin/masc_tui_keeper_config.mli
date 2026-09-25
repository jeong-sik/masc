val editable_snapshot : Yojson.Safe.t -> Yojson.Safe.t
val editor_stem : Yojson.Safe.t -> string

val expected_runtime_assignment_revision :
  Yojson.Safe.t -> (Yojson.Safe.t, string) result

val decode_unchanged_runtime_assignment_response :
  Yojson.Safe.t -> (Yojson.Safe.t, string) result

val config_write_status_message :
  keeper_name:string -> Yojson.Safe.t -> ((string * string), string) result

type edit_refusal =
  | Fix_in_editor of string
      (** The edited text cannot become a patch: not an object, an unknown
          key, or a value outside a closed set. The operator fixes it in the
          editor, so the caller reopens it with {!reopened_stem}. *)
  | Cannot_send of string
      (** The edit is fine but there is no revision to send it against. Not
          the operator's text to fix; the caller reports it. *)

val edit_refusal_to_string : edit_refusal -> string

val activation_values : string
(** [manual | on_demand | autonomous], from {!Masc.Keeper_activation_mode.all}. *)

val patch_of_edit :
  before:Yojson.Safe.t ->
  after:Yojson.Safe.t ->
  (Yojson.Safe.t, edit_refusal) result

val reopened_stem : reason:string -> string -> string
(** The operator's edited text with [// reason] on top, replacing any
    refusal line a previous round put there. It parses to the same JSON as
    the edited text. *)

val view_lines : sanitize:(string -> string) -> Yojson.Safe.t -> string list
(** The whole Settings pane, styled. Every row carries a glyph saying whether
    [e] reaches it, and the field count in the heading comes from
    [editable_snapshot] so it matches what the editor actually opens.

    [sanitize] is applied to every fetched value before it reaches the frame.
    It is mandatory so a new terminal caller cannot accidentally choose an
    unsafe identity default; projection tests pass [Fun.id] explicitly. *)
