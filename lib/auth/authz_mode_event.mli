(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   changes the mode of the installation. The mode decides whether a boot runs
   with accounts or without them. *)

(** The body of a record of kind {!Authz_record.Kind.Mode_event} (design 5.1):
    what changed the mode of the installation, and the workspace it is about.

    {b Events.} [Fresh_bootstrap] sets the installation up (design 8.4),
    [Off] turns the accounts off, and [Reactivate] turns them on again (design
    10.5). Which mode an event makes is for the boot that reads the log to say
    (design 5.1). This module does not say it.

    {b Body.} An object with two members, in this order: [event], one of the
    labels below, and [workspace_id], the id of the workspace. The labels are
    on disk and renaming one orphans every record written with it. A body that
    has other members, the same members in another order, or a member of
    another type is refused. The text of the body is that of
    {!Authz_body.to_string}, so it is part of the bytes that the hash chain of
    the log covers.

    This module does not know who may write the record ({!Authz_record.admits}
    decides that) or in which order the events may come. *)

type event =
  | Fresh_bootstrap
  | Off
  | Reactivate

type t =
  { event : event
  ; workspace_id : Authz_types.Workspace_id.t
  }

val events : event list

(** The label on disk: [fresh_bootstrap], [off], or [reactivate]. *)
val event_label : event -> string

val event_of_label : string -> event option
val equal : t -> t -> bool

(** The body of the record. The error cannot come from a value of {!t}: the
    labels and the ids are ASCII, and {!Authz_body} refuses text that is not
    UTF-8. It is returned because {!Authz_body.t} can only be made through
    functions that check. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body is not the body of a mode event. *)
type error =
  | Not_an_object
  | Wrong_members
      (** An object, but not exactly the members [event] and [workspace_id], in
          this order, both strings. *)
  | Unknown_event of string  (** The label is not one of the three. *)
  | Invalid_workspace_id of Authz_id.error

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its members are those of the body, the event is one of the three, and the
    workspace id is one. *)
val of_body : Authz_body.t -> (t, error) result
