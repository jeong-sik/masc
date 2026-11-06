(** Dashboard [/logs] endpoint JSON builder. *)

val build
  :  config:Workspace.config
  -> limit:int
  -> level_filter:string
  -> applied_level:Log.level
  -> min_level:int
  -> module_filter:string
  -> since_seq:int option
  -> before_seq:int option
  -> categories:Log.category_selector list option
  -> exclude_categories:Log.category_selector list option
  -> ring_bounds:Log.Ring.bounds
  -> Log.Ring.entry list
  -> Yojson.Safe.t
