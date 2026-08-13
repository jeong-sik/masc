(** Pure backend projection of the canonical execution-receipt
    [sandbox.routing] descriptor. *)

type failure_status =
  | Mismatch
  | Unobserved

type violation =
  | Effective_resolution_unavailable
  | Config_effective_mismatch
  | Receipt_evidence_unavailable
  | Effective_receipt_mismatch

type verification =
  | Verified of { containment : string }
  | Not_verified of
      { status : failure_status
      ; violation : violation
      ; detail : string
      }

type observation =
  | Absent
  | Observed of
      { descriptor : Yojson.Safe.t
      ; verification : verification
      }
  | Invalid_descriptor of
      { descriptor : Yojson.Safe.t
      ; detail : string
      }

type attention =
  { reason : string
  ; next_human_action : string
  }

val of_receipt : Yojson.Safe.t -> observation
(** Decode only [receipt.sandbox.routing]. Missing evidence remains [Absent];
    flat sandbox fields and the duplicate runtime-contract projection are not
    fallback evidence. *)

val descriptor_to_yojson : observation -> Yojson.Safe.t
(** [Absent] becomes JSON [null]. Present descriptors retain their exact
    receipt value, including malformed descriptors that require attention. *)

val attention : observation -> attention option
(** Verified evidence has no sandbox-routing attention. Mismatch, unobserved,
    and malformed evidence require operator inspection. *)

val attention_to_yojson : attention option -> Yojson.Safe.t
