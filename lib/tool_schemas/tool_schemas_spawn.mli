(** What each spawn tool is, beside the schema that declares it. *)

type action =
  | Start
  | Read
  | Wait
  | Stop

type definition = {
  action : action;
  id : string;  (** the suffix of the descriptor id, [masc.spawn.<id>] *)
  schema : Masc_domain.tool_schema;
  read_only : bool;
}

val definitions : definition list
(** All four. The descriptor list maps over this, so a tool declared here and
    nowhere else still reaches a keeper. *)

val schemas : Masc_domain.tool_schema list

val find_definition : string -> definition option
(** By tool name, which is how a dispatch answers whether a call is one of
    these. *)
