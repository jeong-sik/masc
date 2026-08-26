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

val resolve : config:Workspace.config -> keeper_name:string -> outcome
val to_yojson : outcome -> Yojson.Safe.t
