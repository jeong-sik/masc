open Keeper_approval_queue_rules_types

(** Exact remembered-approval identity within one workspace's rule store. *)
type application =
  { approval_id : string
  ; keeper_name : string
  ; tool_name : string
  ; request_fingerprint : string
  ; expires_at : float option
  ; actor : string option
  }

type receipt =
  { application : application
  ; rule_id : string
  }

(** Rules and application receipts share one atomic persisted value. Receipts
    survive rule deletion so a retained delivery cannot recreate permission. *)
type t =
  { rules : approval_rule list
  ; applications : receipt list
  }

val empty : t
val rule_identity_matches : approval_rule -> approval_rule -> bool
val same_application : application -> application -> bool
val validate_application : application -> (unit, string) result
val find_application : t -> approval_id:string -> receipt option

(** The only legacy decode boundary. An old bare rule list is explicitly
    migrated by seeding each creation approval's exact application receipt.
    Unknown versions, duplicate identities and conflicting receipts fail. *)
val decode_current_or_migrate_legacy : Yojson.Safe.t -> (t, string) result

(** Always emits the canonical versioned envelope, never the legacy list. *)
val to_yojson : t -> Yojson.Safe.t
