(** Keeper spawn/admission decision helpers. *)

type denial_reason =
  | Fd_pressure_active
  | Disk_pressure_active
  | Fd_admission_blocked
  | Disk_admission_blocked
  | Max_active_keepers of { running_count : int; max_keepers : int }

val denial_reason_to_label : denial_reason -> string
val denial_reason_to_detail : denial_reason -> string

val decision
  :  running_count:int
  -> ?base_path:string
  -> ?fd_admitted:bool
  -> ?disk_admitted:bool
  -> unit
  -> (unit, denial_reason) result

val available
  :  running_count:int
  -> ?base_path:string
  -> ?fd_admitted:bool
  -> ?disk_admitted:bool
  -> unit
  -> bool
