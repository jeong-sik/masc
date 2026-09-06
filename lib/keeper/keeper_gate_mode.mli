(** Persistent operating mode for the Keeper external-effect Gate.

    The three modes are independent choices: none is a stage on the way to
    another, and nothing promotes between them.

    They are ordered in exactly one place, {!resolve}, and only to answer
    which of two answers about the same call to keep. That order --
    [Always_allow], then [Auto_judge], then [Manual] -- is how much of a
    decision is asked of a person, and it exists so a keeper can be held to
    a higher bar than the workspace it runs in. It is not a lifecycle and
    nothing else reads it. *)

type t =
  | Manual
  | Auto_judge
  | Always_allow

type change =
  { previous : t option
  ; current : t
  ; actor : string
  ; changed_at : string
  ; replaced_read_error : string option
  }

val to_string : t -> string
val of_string : string -> t option
val parse_json : Yojson.Safe.t -> (t, string) result
val path : base_path:string -> string

(** A missing state file selects [default]. An existing unreadable or invalid
    file is an explicit error; callers must not silently coerce it. *)
val read : base_path:string -> (t, string) result

(** Dashboard projection. Invalid state exposes the read error and an explicit
    manual effective mode, so the Gate can defer to a human without hiding the
    configuration failure. *)
val status_json : base_path:string -> Yojson.Safe.t

val set :
  Workspace.config -> actor:string -> t -> (change, string) result

(** {1 Per-Keeper overrides}

    One keeper singled out for a higher bar than the rest of the workspace --
    a keeper attached to somebody else's Jira while the others are not.

    Only upward. An override that asks for less than the workspace is kept on
    disk and ignored on read, so turning the workspace stricter cannot be
    undone one keeper at a time by an older row nobody remembers writing.
    A keeper alone in [Auto_judge] above a looser workspace is a supported
    state: the drains and boot recovery admit owners by {!resolve}, so its
    queue is swept like any other. *)

type keeper_override = {
  keeper_name : string;
  mode : t;  (** what was asked for, before {!resolve} weighs it *)
  actor : string;
  changed_at : string;
}

type keeper_change = {
  keeper_previous : t option;
  keeper_current : t option;  (** [None] when the override was cleared *)
  keeper_actor : string;
  keeper_changed_at : string;
}

val keeper_overrides :
  base_path:string -> (keeper_override list, string) result
(** Every keeper an operator has singled out, in the order they were set.

    A file that cannot be read is an error, not an empty list: reading it as
    "nobody was singled out" answers with the workspace mode, which is the
    looser one, and an unreadable file must not be the quiet way back to
    it. *)

val keeper_override :
  base_path:string -> keeper_name:string -> (keeper_override option, string) result

val resolve : base_path:string -> keeper_name:string -> (t, string) result
(** The mode one keeper's call is decided under: the stricter of the
    workspace mode and this keeper's override.

    This is the one to ask about a call, and the one the drains ask per
    owner: an override can hold a single keeper in auto_judge above a
    looser workspace, and that owner's queue still needs sweeping. {!read}
    answers only what the workspace chose — the right question for "is the
    mode store readable", the wrong one for any keeper-scoped decision. *)

val set_for_keeper :
  Workspace.config ->
  actor:string ->
  keeper_name:string ->
  t option ->
  (keeper_change, string) result
(** [None] clears the override rather than storing a synonym for the
    workspace mode, so the file is also the list of keepers somebody
    actually singled out. *)

val keeper_change_json : keeper_change -> [ `Assoc of (string * Yojson.Safe.t) list ]

(** The external-services lane: calls that leave the workspace for an
    attached outside service (Jira, Slack, GitHub through a Keeper identity).

    A separate lane with a separate default because the two switches answer
    different questions. The workspace lane gets opened ([Always_allow]) for
    internal velocity — tool_execute, memory writes — and that gesture must
    not silently authorize writes into somebody else's service. An absent
    external state file selects {!default_external}, which is [Manual]:
    silence is not permission, in mode form. *)

val default_external : t
val read_external : base_path:string -> (t, string) result
val status_json_external : base_path:string -> Yojson.Safe.t

val set_external :
  Workspace.config -> actor:string -> t -> (change, string) result

val resolve_external :
  base_path:string -> keeper_name:string -> (t, string) result
(** {!resolve}'s twin for the external-services lane: the stricter of the
    lane mode and this keeper's override. An operator who singled a Keeper
    out for a higher bar meant it for everything that Keeper does, and
    outside writes are the last place to quietly exempt. *)

val change_json : change -> [ `Assoc of (string * Yojson.Safe.t) list ]
(** Closed object projection; callers can extend its fields without an
    impossible non-object branch. *)
