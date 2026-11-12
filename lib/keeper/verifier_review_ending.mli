(** How one recorded reviewer execution ended. [Owner_lost]: its writer is
    gone and left no terminal. *)
type t =
  | Succeeded
  | Failed
  | Cancelled
  | Owner_lost
