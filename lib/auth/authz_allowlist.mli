(* HIGH-RISK-UNREVIEWED: an Admin writes the allowlist here. An entry lets its
   identity join the installation as a Member at its first sign-in. *)

(** What an Admin does to the allowlist with the writer zone (plan C2d):
    register an identity, or remove an entry. The routes of plan C3 call these
    for the screen of plan C6; nothing here reads a request.

    The zone checks each record with {!Authz_state.apply} inside its lock and
    refuses it with the reason of the state ([Commit_failed (Refused _)]), so
    who may write and what may be written are decided there: the author is an
    Admin that acts, a registered identity has no open entry and is bound to no
    principal, and a removed entry is open. The removal is a [Revoke] intent of the entry, which
    the zone writes to the external store before the record (design 8.2).

    A registration id is drawn here, and drawn again while the snapshot names
    it, at most {!attempts} times. *)

type registered =
  { registration_id : Authz_types.Registration_id.t
  ; previously_deleted : bool
        (** A deleted principal was bound to this identity (design 5.1-6). The
            entry is written all the same, and the person joins as a new
            principal. *)
  }

type error =
  | Id_not_drawn of Authz_id.error  (** [draw] gave a value that is not an id. *)
  | Body_not_built of Authz_body.error
  | Commit_failed of Authz_zone.error
      (** The zone says what it wrote. [Refused] is the reason of the state,
          and nothing was written. *)

val error_to_string : error -> string

(** Three. *)
val attempts : int

(** [register zone ~admin ~draw identity] writes an entry for [identity] as the
    human principal [admin]. [draw ()] gives 32 random lowercase hex characters
    for the id ({!Random_id.hex} in the server). *)
val register
  :  Authz_zone.t
  -> admin:Authz_types.User_id.t
  -> draw:(unit -> string)
  -> Authz_external_identity.t
  -> (registered, error) result

(** [remove zone ~admin registration_id] removes an open entry as the human
    principal [admin]. *)
val remove
  :  Authz_zone.t
  -> admin:Authz_types.User_id.t
  -> Authz_types.Registration_id.t
  -> (unit, error) result
