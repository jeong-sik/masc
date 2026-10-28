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

(** What a revocation or intent is about (design 4.5). *)
module Subject : sig
  type t =
    | Grant of Grant_id.t
    | Credential of Provider_account_id.t
    | Principal of Principal.t
    | Runtime of Runtime_id.t

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
end
