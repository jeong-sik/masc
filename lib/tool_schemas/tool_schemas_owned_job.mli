(** Restart-surviving isolated job tools. Input schemas and descriptions are
    decoded from the canonical [config/tools/keeper_job_*.toml] definitions. *)

type action = Start | Status | Cancel | Read_result

type definition =
  { action : action
  ; id : string
  ; schema : Masc_domain.tool_schema
  ; read_only : bool
  }
(** [Read_result] only reads the original owner journal and is Concurrent.
    Other actions are effectful and Serial: [Status] reconciles backend state
    and may persist terminal evidence. *)

val definitions : definition list
val schemas : Masc_domain.tool_schema list
val find_definition : string -> definition option
(** Resolve exact canonical names before dispatching on the closed action. *)
