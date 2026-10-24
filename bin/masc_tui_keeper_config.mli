val editable_snapshot : Yojson.Safe.t -> Yojson.Safe.t
val editor_stem : Yojson.Safe.t -> string

val expected_runtime_assignment_revision :
  Yojson.Safe.t -> (Yojson.Safe.t, string) result

type runtime_assignment_unchanged = {
  revision : Yojson.Safe.t;
  warnings : Masc_tui_runtime_config_receipt.lock_warning list;
  response : Yojson.Safe.t;
}
type runtime_assignment_write =
  | Assignment_committed of Masc_tui_runtime_config_receipt.t
  | Assignment_unchanged of runtime_assignment_unchanged
      (** Original unchanged reply, including revision and lock warnings. *)

type runtime_assignment_post_error =
  | Assignment_revision_conflict of Yojson.Safe.t
  | Assignment_auth_refused of { status : int; body : string }
  | Assignment_outcome_unconfirmed of string

val decode_runtime_assignment_answer : status:int -> body:string ->
  (runtime_assignment_write, runtime_assignment_post_error) result
(** Auth refusals happen before the route's write callback; the known 409 code
    is a revision conflict. Other errors, including 400 IO/atomic-replace failure
    and malformed success receipts, do not prove that nothing was written. *)

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

val reopen_edit_on_current : before:Yojson.Safe.t -> edited:string -> current:Yojson.Safe.t -> (string, edit_refusal) result
(** Explicit recovery after a new authoritative read: retain changed values,
    use current values for untouched fields, and leave the prior composite
    revision and context-shrink confirmation behind. The caller opens an editor
    for review; this does not authorize or dispatch a save. *)

val sandbox_patch : profile:Keeper_sandbox_config.sandbox_profile -> Yojson.Safe.t -> (Yojson.Safe.t option, string) result
(** Prepare the Sandbox selection using this snapshot's composite revision.
    SSH keeps an explicitly selected registered endpoint or selects the sole
    registered endpoint; an empty/ambiguous/unavailable registry is refused
    with directions to edit the endpoint. SSH selects inherited networking;
    other profiles clear the endpoint in the same CAS patch. [None] means the
    observed combination already matches. Invalid observations stay errors. *)

val view_lines : sanitize:(string -> string) -> Yojson.Safe.t -> string list
(** The whole Settings pane, styled. Every row carries a glyph saying whether
    [e] reaches it, and the field count in the heading comes from
    [editable_snapshot] so it matches what the editor actually opens.

    [sanitize] is applied to every fetched value before it reaches the frame.
    It is mandatory so a new terminal caller cannot accidentally choose an
    unsafe identity default; projection tests pass [Fun.id] explicitly. *)
