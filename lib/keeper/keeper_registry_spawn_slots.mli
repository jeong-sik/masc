(** Spawn-slot admission decisions for keeper registry. *)

type denial_reason =
  | Fd_pressure_active
  | Disk_pressure_active
  | Fd_admission_blocked
  | Disk_admission_blocked
  | Max_active_keepers of { running_count : int; max_keepers : int }

val to_label : denial_reason -> string
val to_detail : denial_reason -> string

val decision
  :  ?base_path:string
  -> ?fd_admitted:bool
  -> ?disk_admitted:bool
  -> running_count:int
  -> unit
  -> (unit, denial_reason) result

val record_denied
  :  keeper_name:string
  -> surface:string
  -> denial_reason
  -> unit
