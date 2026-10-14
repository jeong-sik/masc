(** Private SQLite resource/statement mechanics shared by receiver journals.
    Schema, scope, sequence, admission and audit authority remain in each store. *)
val exec : error:(operation:string -> detail:string -> 'e) -> Sqlite3.db ->
  operation:string -> string -> (unit, 'e) result
type step = Row | Done | Failed of Sqlite3.Rc.t
(** One [Sqlite3.step]: a row is ready, the statement finished, or it failed with the given code. *)
val step : Sqlite3.stmt -> step
val failure : error:(operation:string -> detail:string -> 'e) -> Sqlite3.db ->
  operation:string -> Sqlite3.Rc.t -> 'e
(** The error [exec]/[bind]/[commit] build for a non-success code: ["<code>: <errmsg>"]. *)
val done_ : error:(operation:string -> detail:string -> 'e) -> Sqlite3.db ->
  Sqlite3.stmt -> operation:string -> (unit, 'e) result
(** Steps once; [Ok ()] only for DONE. A row or any other code is an [Error]. *)
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
val scalar : error:(operation:string -> detail:string -> 'e) ->
  on_cleanup:(operation:string -> detail:string -> unit) ->
  Sqlite3.db -> string -> (Sqlite3.Data.t, 'e) result
(** Runs a query that must return exactly one row; returns its first column. Zero rows, a second row or a failure is an [Error]. *)
