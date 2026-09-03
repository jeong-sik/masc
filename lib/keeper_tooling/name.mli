(** Typed vocabulary for Keeper task runtime adapters.

    Lives on the keeper side of the Tool/Keeper boundary: the tool dispatch
    substrate routes opaque tool names and the keeper subsystem owns the typed
    vocabulary of its own tools. Board names are owned by
    [Tool_name.Board_name]. Dependency direction is keeper -> tool, never the
    reverse. *)

type t =
  | Broadcast
  | Task_claim
  | Task_create
  | Task_done
  | Task_cancel
  | Task_release
  | Tasks_audit
  | Tasks_list

val to_string : t -> string
val of_string : string -> t option
val pp : Format.formatter -> t -> unit
