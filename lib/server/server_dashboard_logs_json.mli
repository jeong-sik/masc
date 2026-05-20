(** Dashboard [/logs] endpoint JSON builder. *)

val store_path : masc_root:string -> string

val build
  :  config:Coord.config
  -> limit:int
  -> level_filter:string
  -> min_level:int
  -> module_filter:string
  -> since_seq:int option
  -> Log.Ring.entry list
  -> Yojson.Safe.t
