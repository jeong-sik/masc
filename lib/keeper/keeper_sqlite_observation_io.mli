(** Private SQLite resource/statement mechanics shared by receiver journals.
    Schema, scope, sequence, admission and audit authority remain in each store. *)
val exec : error:(operation:string -> detail:string -> 'e) -> Sqlite3.db ->
  operation:string -> string -> (unit, 'e) result
val statement : error:(operation:string -> detail:string -> 'e) ->
  on_cleanup:(operation:string -> detail:string -> unit) ->
  Sqlite3.db -> operation:string -> string ->
  (Sqlite3.stmt -> ('a, 'e) result) -> ('a, 'e) result
val bind : error:(operation:string -> detail:string -> 'e) ->
  Sqlite3.db -> Sqlite3.stmt -> Sqlite3.Data.t list -> (unit, 'e) result
val with_database : label:string -> before_open:(unit -> (unit, 'e) result) ->
  error:(operation:string -> detail:string -> 'e) ->
  on_cleanup:(operation:string -> detail:string -> unit) ->
  close:(Sqlite3.db -> bool) -> create:bool -> path:string ->
  (Sqlite3.db -> ('a, 'e) result) -> ('a, 'e) result
(** Runs blocking database work in a systhread, closes its exact handle, retains
    cleanup separately from the returned result and does not swallow cancellation.
    Caller supplies pre-open/path/scope validation, run inside the same systhread. No leaf-open continuity claim. *)
val commit : error:(operation:string -> detail:string -> 'e) ->
  unconfirmed:(string -> 'e) -> show_error:('e -> string) ->
  commit:(Sqlite3.db -> Sqlite3.Rc.t) -> Sqlite3.db -> (unit, 'e) result
