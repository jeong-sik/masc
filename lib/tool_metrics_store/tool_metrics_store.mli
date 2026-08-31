type row = {
  record_id : string;
  ts : float;
  tool_name : string;
  disposition : string;
  duration_ms : float;
}

type summary = {
  path : string;
  exists : bool;
  entry_count : int;
  latest_ts : float option;
}

val database_path : base_path:string -> string
val insert : base_path:string -> row -> (unit, string) result
val prune : base_path:string -> retention_days:int -> (int, string) result

val iter_all :
  base_path:string ->
  f:(row -> (unit, string) result) ->
  (int, string) result

val read_recent :
  base_path:string ->
  ?since_ts:float ->
  ?until_ts:float ->
  n:int ->
  unit ->
  (row list, string) result

val summary : base_path:string -> (summary, string) result
val row_to_json : row -> Yojson.Safe.t
val reset_for_testing : unit -> unit
