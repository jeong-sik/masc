(* See [authz_records.mli] for the contract. *)

open Authz_types

module Principal_status = struct
  type t =
    | Active
    | Disabled
end

module Membership_status = struct
  type t =
    | Active
    | Disabled
end

module Auth_binding_status = struct
  type t =
    | Active
    | Revoked
end

module Resource_status = struct
  type t =
    | Active
    | Disabled
    | Blocked
    | Quarantined
    | Purged
end

module Grant_status = struct
  type t =
    | Active
    | Revoked
    | Purged
end

module Revocation_state = struct
  type t =
    | Not_pending
    | Pending
end

module Dependency_state = struct
  type t =
    | Cleared
    | Not_cleared
end

module Runtime_row = struct
  type t =
    { id : Runtime_id.t
    ; owner : Principal.t
    ; provider_account : Provider_account_id.t
    ; status : Resource_status.t
    }
end

module Runtime_grant = struct
  type kind =
    | Self
    | Delegated of { expires_at : float option }

  type t =
    { id : Grant_id.t
    ; runtime_id : Runtime_id.t
    ; grantee : Principal.t
    ; allowed_effects : Effect.Set.t
    ; status : Grant_status.t
    ; kind : kind
    }
end

module Subject = struct
  type t =
    | Grant of Grant_id.t
    | Credential of Provider_account_id.t
    | Principal of Principal.t
    | Runtime of Runtime_id.t

  let equal a b =
    match a, b with
    | Grant x, Grant y -> Grant_id.equal x y
    | Credential x, Credential y -> Provider_account_id.equal x y
    | Principal x, Principal y -> Principal.equal x y
    | Runtime x, Runtime y -> Runtime_id.equal x y
    | ( (Grant _ | Credential _ | Principal _ | Runtime _)
      , (Grant _ | Credential _ | Principal _ | Runtime _) ) -> false
  ;;

  let to_string = function
    | Grant id -> "grant:" ^ Grant_id.to_string id
    | Credential id -> "credential:" ^ Provider_account_id.to_string id
    | Principal principal -> "principal:" ^ Principal.to_string principal
    | Runtime id -> "runtime:" ^ Runtime_id.to_string id
  ;;
end

module Author = struct
  type t =
    | Authenticated of Principal.t
    | Local_operator
    | System_cron
    | System_maintenance
    | System_migration
end
