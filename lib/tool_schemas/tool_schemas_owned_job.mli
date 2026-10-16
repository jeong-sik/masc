(** Restart-surviving isolated job tools. Input schemas and descriptions are
    decoded from the canonical [config/tools/keeper_job_*.toml] definitions. *)

type action = Start | Status | Cancel

type definition =
  { action : action
  ; id : string
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }
(** Every action is effectful and Serial. In particular, [Status] reconciles
    backend state and may persist terminal evidence. *)

val definitions : definition list
val schemas : Masc_domain.tool_schema list
val find_definition : string -> definition option
(** Resolve exact canonical names before dispatching on the closed action. *)
