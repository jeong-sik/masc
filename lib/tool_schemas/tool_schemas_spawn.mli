(** The four spawn actions with the schema each one runs.

    The description travels with the TOML declaration rather than being
    restated here: each schema is the whole [Masc_domain.tool_schema], and the
    file the model is handed is the one that should carry it. *)

type action =
  | Start
  | Read
  | Wait
  | Stop

type definition = {
  action : action;
  schema : Masc_domain.tool_schema;
  read_only : bool;
}

val definitions : definition list

(** [definitions], projected to just the schema each action runs. *)
val schemas : Masc_domain.tool_schema list

(** The definition whose schema is named [name], if any. *)
val find_definition : string -> definition option
