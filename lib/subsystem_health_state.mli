(** Pure immutable lifecycle state for forked subsystems. *)

type health =
  | Alive
  | Dead of { crashed_at : float }

type event =
  | Registered of { name : string }
  | Crashed of
      { name : string
      ; crashed_at : float
      }

type t

val empty : t
val apply : t -> event -> t
val entries : t -> (string * health) list
(** Alphabetically ordered immutable view of the registry. *)
