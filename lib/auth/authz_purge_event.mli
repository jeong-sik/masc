(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   starts or ends the purge of what a person owns. A purge that reads as ended
   while what it names is still on disk tells the person a deletion happened
   that did not. *)

(** The body of a purge record (design 8.5, plan S1b-3c): the start of the
    purge of one target, and its end.

    {b Target.} A conversation of a person with one of their Keepers, named by
    its owner and its id. The purge deletes the folder of the conversation, and
    asks the vendor CLI to drop the copy it keeps of the conversation.

    {b Events.} [Purge_pending] starts the purge. From it on, the target is not
    read (design 8.5-2). [Purged] says that the folder is gone, and
    [Purge_failed] that it is not, at the stage that failed. Both say what
    became of the vendor copy.

    {b Body.} An object whose first member is [event]:
    [{"event":"pending","target":T}],
    [{"event":"purged","target":T,"vendor_copy":V}], or
    [{"event":"failed","target":T,"failed_stage":S,"vendor_copy":V}], with the
    members in this order. [T] is
    [{"type":"keeper_conversation","owner":...,"conversation_id":...}], the
    shape that {!Authz_external_store} writes for the same subject. [V] is
    [removed], [none], or [may_remain], and [S] is [folder_not_removed]. The
    labels are on disk, and renaming one orphans every record written with
    it. A body with other members, the same members in another order, or a
    member of another type is refused.

    This module does not know who may write the record ({!Authz_record.admits}
    and {!Authz_purge_state} decide that), nor in which order the events may
    come. *)

type target =
  | Keeper_conversation of
      { owner : Authz_types.User_id.t
      ; conversation_id : Authz_types.Conversation_id.t
      }

val target_equal : target -> target -> bool
val target_compare : target -> target -> int

(** The subject that the start of a purge of the target is an intent on
    (design 8.2). *)
val subject : target -> Authz_records.Subject.t

(** What became of the copy that the vendor CLI keeps of the conversation. *)
type vendor_copy =
  | Removed  (** The CLI was asked to drop it and exited 0. *)
  | No_copy
      (** No turn of the conversation reached the CLI, so it holds none and
          was not asked. *)
  | May_remain
      (** A turn reached the CLI, and the CLI was too old to be asked or did
          not exit 0. *)

type failed_stage = Folder_not_removed  (** The folder of the target is still there. *)

type t =
  | Purge_pending of { target : target }
  | Purged of
      { target : target
      ; vendor_copy : vendor_copy
      }
  | Purge_failed of
      { target : target
      ; failed_stage : failed_stage
      ; vendor_copy : vendor_copy
      }

val target : t -> target
val equal : t -> t -> bool

(** The body of the record. The error cannot come from a value of {!t}. It is
    returned because {!Authz_body.t} can only be made through functions that
    check. *)
val to_body : t -> (Authz_body.t, Authz_body.error) result

(** Why a body is not the body of a purge record. *)
type error =
  | Not_an_object
  | Unknown_event of string  (** The first member is [event], but not a label of it. *)
  | Wrong_members
      (** An object, but not exactly the members of one event, in their order,
          with [target] an object of [type], [owner], and [conversation_id],
          and every other member a string. *)
  | Unknown_target of string  (** The [type] of the target is not a label of one. *)
  | Invalid_owner of Authz_id.error
  | Invalid_conversation_id of Authz_id.error
  | Unknown_failed_stage of string
  | Unknown_vendor_copy of string

val error_to_string : error -> string

(** Reads a body. The first check that fails is the result: it is an object,
    its first member names an event, its members are those of that event, the
    target is one, and then the stage and the vendor copy are ones. *)
val of_body : Authz_body.t -> (t, error) result
