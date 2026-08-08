(** Completion-authority access to one producer's typed filesystem and command
    descriptors. Descriptor registry drift and unreadable producer state reject
    surface construction. Every dispatched call is validated and translated by
    the same descriptor that was advertised. *)

type t

val create :
  config:Workspace.config -> producer:string -> (t, string) result

val ownership_root : t -> string

val schemas : t -> Types_core.tool_schema list

val dispatch : t -> name:string -> args:Yojson.Safe.t -> (string, string) result
