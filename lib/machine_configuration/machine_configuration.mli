(** Activity configuration for the workspace machines. Parsing does not create,
    move, eject or restore a machine. Omitted flags mean enabled. *)
type t = { msx_enabled : bool; dos_enabled : bool }
[@@deriving show, eq]

type activity = Enabled | Disabled | Unobserved

val default : t
val parse : Otoml.t -> (t, string) result
val activity_to_wire : activity -> string
