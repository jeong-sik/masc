(** Closed control-plane instructions accepted by a Keeper lane.

    Transport encodings are intentionally owned by their transport modules;
    Keeper business logic receives only this typed representation. *)

type t =
  | Pause
  | Resume
  | Wakeup
  | Assign_task of Keeper_id.Task_id.t
