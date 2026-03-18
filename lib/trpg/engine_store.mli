type snapshot = {
  last_seq : int;
  ts : string;
  state : Engine_types.room_state;
}

val room_dir : base_dir:string -> room_id:string -> (string, string) result
val events_path : base_dir:string -> room_id:string -> (string, string) result
val snapshot_path : base_dir:string -> room_id:string -> (string, string) result

val append_event :
  base_dir:string -> event:Engine_event.t -> (unit, string) result

val read_events :
  base_dir:string -> room_id:string -> (Engine_event.t list, string) result

val read_events_after :
  base_dir:string ->
  room_id:string ->
  after_seq:int ->
  (Engine_event.t list, string) result

val write_snapshot :
  base_dir:string ->
  room_id:string ->
  last_seq:int ->
  ts:string ->
  state:Engine_types.room_state ->
  (unit, string) result

val read_snapshot :
  base_dir:string -> room_id:string -> (snapshot option, string) result

val load_recovery :
  base_dir:string ->
  room_id:string ->
  ((snapshot option * Engine_event.t list), string) result
