(** Persistent operating mode for the Keeper external-effect Gate.

    The three modes are independent choices: none is a stage on the way to
    another, and nothing promotes between them. *)

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

val change_json : change -> [ `Assoc of (string * Yojson.Safe.t) list ]
(** Closed object projection; callers can extend its fields without an
    impossible non-object branch. *)
