include module type of Cp_io

type cleanup_result = {
  dead_units_removed : int;
  orphaned_units_removed : int;
  operations_archived : int;
  detachments_removed : int;
  intents_removed : int;
}

val empty_result : cleanup_result
val cleanup_result_to_json : cleanup_result -> Yojson.Safe.t

val cutoff_iso : days:int -> string
val find_dead_units : days:int -> unit_record list -> unit_record list
val find_orphaned_units : unit_record list -> unit_record list
val is_terminal_status : operation_status -> bool
val find_terminal_operations :
  days:int -> operation_record list -> operation_record list
val find_orphaned_detachments :
  operation_ids:string list -> detachment_record list -> detachment_record list
val find_dropped_intents : days:int -> intent_record list -> intent_record list

val archive_operations : Room.config -> operation_record list -> unit
val cleanup_dead_units :
  Room.config -> days:int -> unit_record list -> unit_record list * int
val cleanup_orphaned_units :
  Room.config -> unit_record list -> unit_record list * int
val archive_terminal_operations :
  Room.config -> days:int -> operation_record list -> operation_record list * int
val cleanup_orphaned_detachments :
  Room.config ->
  operation_ids:string list ->
  detachment_record list ->
  detachment_record list * int
val cleanup_dropped_intents :
  Room.config -> days:int -> intent_record list -> intent_record list * int
val cleanup_cp : Room.config -> cleanup_result
val cleanup_cp_summary : Room.config -> string
