(* HIGH-RISK-UNREVIEWED: this module writes the records that start and end the
   deletion of a person's conversation with their Keeper. A wrong record keeps
   a deleted conversation readable, or deletes one nobody asked to delete. *)

(** Writes the purge records of the authorization log (design 8.5, plan
    S1b-3c). The owner starts the purge of their conversation, and the system
    maintenance ends it when the folder of the conversation is gone or could
    not be removed. Each record is judged on the state of the zone first
    ({!Authz_purge_state.apply}), and the zone judges it again when it
    commits. *)

type error =
  | Body_not_built of Authz_body.error
  | Refused of Authz_purge_state.refusal
      (** The state of the zone, read just before the commit, refuses the
          record. Nothing was written. *)
  | Commit_failed of Authz_zone.error
      (** The zone did not write the record. A record that a later record
          made refusable between the read and the commit lands here too, as a
          [Refused] of the zone. *)

(** The reason in full. It can name paths of the server, so it is for the log
    of the server and not for an answer to a person. *)
val error_detail : error -> string

(** [user_id] starts the purge of [target], which they own: a
    [Purge_pending]. The zone writes its intent to the external store before
    the record (design 8.2). *)
val start
  :  Authz_zone.t
  -> user_id:Authz_types.User_id.t
  -> Authz_purge_event.target
  -> (unit, error) result

(** The system maintenance ends the purge of [target]: its folder is gone. *)
val purged
  :  Authz_zone.t
  -> Authz_purge_event.target
  -> vendor_copy:Authz_purge_event.vendor_copy
  -> (unit, error) result

(** The system maintenance ends the purge of [target]: its folder is still
    there. *)
val failed
  :  Authz_zone.t
  -> Authz_purge_event.target
  -> failed_stage:Authz_purge_event.failed_stage
  -> vendor_copy:Authz_purge_event.vendor_copy
  -> (unit, error) result
