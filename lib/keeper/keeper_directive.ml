type t =
  | Pause
  | Resume
  | Wakeup
  | Assign_task of Keeper_id.Task_id.t
