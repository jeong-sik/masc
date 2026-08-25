(** Evidence-backed token-serving boundaries for one resolved runtime target.

    A declaration or probe records only what it established: requests at or
    below [accepted_through] are known admitted, requests at or above
    [rejected_from] are known rejected, and any gap remains explicitly unknown.
    No provider, model, endpoint, or error prose is interpreted here. *)

type source_kind =
  | Declaration
  | Probe
[@@deriving show, eq]

type confidence =
  | Low
  | Medium
  | High
[@@deriving show, eq]

type evidence =
  { source_kind : source_kind
  ; source_ref : string
  ; checked_at_unix_s : int
  ; confidence : confidence
  ; expires_at_unix_s : int option
  }
[@@deriving show, eq]

type observation =
  { accepted_through : int
  ; rejected_from : int option
  }
[@@deriving show, eq]

type t =
  { observation : observation
  ; evidence : evidence
  }
[@@deriving show, eq]

type validation_error =
  | Invalid_source_ref
  | Invalid_checked_at of int
  | Missing_probe_expiry
  | Invalid_expiry of
      { checked_at_unix_s : int
      ; expires_at_unix_s : int
      }
  | Invalid_accepted_through of int
  | Invalid_rejected_from of
      { accepted_through : int
      ; rejected_from : int
      }
[@@deriving show, eq]

(** Probe evidence must carry an explicit expiry. The boundary never invents a
    default TTL; the catalog owner chooses the validity window. Declarations
    may omit expiry when their source contract is itself durable. *)
val make
  :  source_kind:source_kind
  -> source_ref:string
  -> checked_at_unix_s:int
  -> confidence:confidence
  -> ?expires_at_unix_s:int
  -> accepted_through:int
  -> ?rejected_from:int
  -> unit
  -> (t, validation_error) result

type admission_error =
  | Evidence_not_yet_valid of
      { now_unix_s : int
      ; checked_at_unix_s : int
      }
  | Evidence_expired of
      { now_unix_s : int
      ; expires_at_unix_s : int
      }
  | Boundary_unknown of
      { input_tokens : int
      ; accepted_through : int
      ; rejected_from : int option
      }
  | Input_rejected of
      { input_tokens : int
      ; accepted_through : int
      ; rejected_from : int
      }
[@@deriving show, eq]

(** Check whether the evidence is current without requiring a token
    measurement. This permits stale or future-dated evidence to fail before any
    provider request. *)
val check_evidence : now_unix_s:int -> t -> (unit, admission_error) result

(** Admit one exact provider-native input-token measurement. Evidence is
    current only in [[checked_at, expires_at)] when an expiry exists. *)
val admit : now_unix_s:int -> input_tokens:int -> t -> (unit, admission_error) result

val source_kind_of_string : string -> source_kind option
val source_kind_to_string : source_kind -> string
val confidence_of_string : string -> confidence option
val confidence_to_string : confidence -> string

(** Stable projection used by immutable catalog and ready-plan fingerprints.
    This deliberately includes the full evidence identity, not only the
    observed interval: refreshing [checked_at], [expires_at], [source_ref], or
    confidence creates a new ready-plan generation instead of mutating the
    meaning or validity window of an already-frozen plan. *)
val fingerprint_parts : t -> string list
