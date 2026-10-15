(** Pure terminal resource lifecycle, shared by the owner codec and public
    output contract. States alone do not grant effect or replay authority. *)
type t =
  | Resources_retained
  | Container_removal_requested
  | Container_removed
  | Data_removal_requested
  | Resources_removed
val to_string : t -> string
val of_string : string -> t option
val can_transition : t -> t -> bool
(** Keep the same state or advance to its immediate successor. *)
