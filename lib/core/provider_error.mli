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
  (* RFC-0057 Phase 0: CLI-specific error variants that were previously
     reconstructed through string matching in cascade_attempt_fsm.ml.
     These carry the structured information lost when the CLI adapter
     compressed them into InvalidRequest { message }. *)
  | CliWrappedHardQuota of {
      provider : string;
      detail : string;
    }
  | CliWrappedMaxTurns of {
      provider : string;
      detail : string;
    }
  | CliWrappedResumableSession of {
      provider : string;
      detail : string;
      exit_code : int option;
    }
  | PermissionDenied of {
      provider : string;
      resource : string option;
    }
  | ModelNotFound of {
      provider : string;
      model_name : string;
    }

type t = provider_error

val scope_to_string : capacity_scope -> string
val to_error_kind : t -> string
val to_yojson : t -> Yojson.Safe.t
val affected_providers : t -> string list
val is_capacity_exhausted : t -> bool
