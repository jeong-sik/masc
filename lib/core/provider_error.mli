(** Closed provider error contract for cascade / telemetry handoff.

    This module is additive: callers can emit it beside existing string
    error labels while later sweeps remove stringly-typed decisions. *)

type capacity_scope = [ `Model | `Provider ]

type provider_error =
  | RateLimit of {
      retry_after : float option;
      provider : string;
    }
  | CapacityExhausted of {
      scope : capacity_scope;
      affected : string list;
    }
  | AuthError of {
      provider : string;
    }
  | ServerError of {
      code : int;
      transient : bool;
    }
  | InvalidRequest of {
      provider : string;
      reason : string;
    }

type t = provider_error

val scope_to_string : capacity_scope -> string
val to_error_kind : t -> string
val to_yojson : t -> Yojson.Safe.t
val affected_providers : t -> string list
val is_capacity_exhausted : t -> bool
