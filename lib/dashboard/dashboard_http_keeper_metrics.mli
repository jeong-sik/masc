(** Dashboard_http_keeper_metrics — counters for the keeper metrics window.

    {!Dashboard_http_keeper_detail} includes this module and counts work kinds
    and tool names with it. *)

module Count_map : Map.S with type key = string

val count_map_incr :
  int Count_map.t -> string -> int Count_map.t

val top_counts_map_json :
  ?limit:int ->
  name_key:string ->
  int Count_map.t ->
  Yojson.Safe.t list
