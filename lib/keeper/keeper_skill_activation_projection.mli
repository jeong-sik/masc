(** Live dashboard projection of one Keeper's durable Skill activation ledger. *)

type unavailable =
  { keeper_name : string
  ; reason : string
  ; detail : string
  }

type outcome =
  | Available of
      { keeper_name : string
      ; ledger : Keeper_skill_activation_ledger.t
      }
  | No_session of { keeper_name : string }
  | Unavailable of unavailable

type trace_outcome =
  | Trace_available of
      { trace_id : Keeper_id.Trace_id.t
      ; ledger : Keeper_skill_activation_ledger.t
      }
  | Trace_not_recorded of { trace_id : Keeper_id.Trace_id.t }
  | Trace_unavailable of
      { trace_id : Keeper_id.Trace_id.t
      ; reason : string
      ; detail : string
      }

val resolve : config:Workspace.config -> keeper_name:string -> outcome
val to_yojson : outcome -> Yojson.Safe.t

val resolve_trace :
  config:Workspace.config -> trace_id:Keeper_id.Trace_id.t -> trace_outcome
(** Read one exact historical session through the canonical typed ledger
    decoder. The trace id is already parsed before it can select a path. *)

val resolve_trace_string :
  config:Workspace.config -> string -> (trace_outcome, string) result
(** Parse an untrusted query value and resolve it without exporting the typed
    id across library boundaries. *)

val trace_to_yojson : trace_outcome -> Yojson.Safe.t
