(** Stored rows and statuses that the authorization decision reads (design 4.2,
    4.3, 4.5, 6.3).

    These are the fields the decision needs. Epochs, revisions, and the record
    envelope belong to the store that persists them. *)

open Authz_types

module Principal_status : sig
  type t =
    | Active
    | Disabled
end

module Membership_status : sig
  type t =
    | Active
    | Disabled
end

(** The session, PAT, or service credential that authenticated the request. *)
module Auth_binding_status : sig
  type t =
    | Active
    | Revoked
end

(** Status of a Runtime or a ProviderAccount. *)
module Resource_status : sig
  type t =
    | Active
    | Disabled
    | Blocked
    | Quarantined
    | Purged
end

module Grant_status : sig
  type t =
    | Active
    | Revoked
    | Purged
end

(** Whether a security revocation of a subject is unfinished. *)
module Revocation_state : sig
  type t =
    | Not_pending
    | Pending
end

(** Whether everything the request depends on has been cleared after a
    restore or mode change. *)
module Dependency_state : sig
  type t =
    | Cleared
    | Not_cleared
end

module Runtime_row : sig
  type t =
    { id : Runtime_id.t
    ; owner : Principal.t
    ; provider_account : Provider_account_id.t
    ; status : Resource_status.t
    }
end

module Runtime_grant : sig
  type kind =
    | Self
        (** Valid only while the grantee is the Runtime's owner. *)
    | Delegated of { expires_at : float option }
        (** Seconds since the epoch. The grant is expired when the clock is
            not before this instant. *)

  type t =
    { id : Grant_id.t
    ; runtime_id : Runtime_id.t
    ; grantee : Principal.t
    ; allowed_effects : Effect.Set.t
    ; status : Grant_status.t
    ; kind : kind
    }
end

(** What a revocation or intent is about (design 4.5). [Invite] is the token of
    an invitation, which lets its holder in until it expires or is revoked
    (design 5.1-4), so its revocation is an intent like that of a credential.
    [Registration] is an entry of the allowlist, which lets its identity in
    until it is removed or spent (plan C2d), so its removal is one too. The
    subject is the id of the entry, not the identity: the identity is only in
    the records of the log (design 4.1). [Session] is a browser session, which
    acts as its principal until it ends (design 5.2, plan C3), so its
    revocation is one too: a sign-out, or a new sign-in of the same browser
    that ends the session it held. [Pat] and [Service_credential] are the
    credentials of plan C4, which act as their principal until revoked, so
    their revocations are intents too. [Keeper_conversation] is a
    conversation of a person with one of their Keepers, named by its owner and
    its id (plan S1b-3c). The start of its purge takes it out of reads (design
    8.5-1 and 8.5-2), so that start is an intent too. *)
module Subject : sig
  type t =
    | Grant of Grant_id.t
    | Credential of Provider_account_id.t
    | Principal of Principal.t
    | Runtime of Runtime_id.t
    | Session of Session_id.t
    | Pat of Pat_id.t
    | Service_credential of Service_credential_id.t
    | Invite of Invite_id.t
    | Registration of Registration_id.t
    | Keeper_conversation of
        { owner : User_id.t
        ; conversation_id : Conversation_id.t
        }

  val equal : t -> t -> bool
  val to_string : t -> string
end

(** Who wrote a record (design 6.3). [Local_operator] is the host-local
    operator, not a principal. *)
module Author : sig
  type t =
    | Authenticated of Principal.t
    | Local_operator
    | System_cron
    | System_maintenance
    | System_migration

  (** The author as refusal messages name it: [the principal <id>],
      [the local operator], or [the system <cron|maintenance|migration>]. *)
  val label : t -> string
end
