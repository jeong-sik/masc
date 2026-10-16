open Keeper_approval_queue_rules_types

(** Exact remembered-approval identity within one workspace's rule store. *)
type application =
  { approval_id : string
  ; resolution_sequence : int
  ; keeper_name : string
  ; tool_name : string
  ; request_fingerprint : string
  ; expires_at : float option
  ; actor : string option
  }

type application_effect = Rule_applied | Superseded

type receipt =
  { application : application
  ; rule_id : string
  ; settlement : application_effect
  }

(** Rules and application receipts share one atomic persisted value. Receipts
    survive rule deletion so a retained delivery cannot recreate permission.
    They are retained without compaction: the store has no authoritative
    proof that all delayed deliveries and restart replays have retired.
    Receipt retirement and whole-file growth remain follow-up work in #25483;
    individual receipts must not be removed as a maintenance shortcut. *)
type t =
  { rules : approval_rule list
  ; applications : receipt list
  }

val empty : t
val rule_identity_matches : approval_rule -> approval_rule -> bool
val same_application : application -> application -> bool
val validate_application : application -> (unit, string) result
val find_application : t -> approval_id:string -> receipt option
val latest_application : t -> application -> receipt option

(** Requires the canonical versioned store. Missing or unsupported formats,
    duplicate identities/orders and conflicting receipts fail. *)
val of_yojson : Yojson.Safe.t -> (t, string) result

(** Always emits the canonical versioned envelope, never the legacy list. *)
val to_yojson : t -> Yojson.Safe.t
