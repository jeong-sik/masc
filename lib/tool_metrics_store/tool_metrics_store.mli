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

val database_path : masc_root:string -> string
val insert : masc_root:string -> result_bytes:int -> row -> (unit, string) result
(** [insert ~masc_root ~result_bytes row] stores the call and the size of the
    result it returned in one transaction. A [record_id] already stored is left
    as it is, size included. It returns [Error] for a negative [result_bytes]. *)
val prune : masc_root:string -> retention_days:int -> (int, string) result

val iter_all :
  masc_root:string ->
  f:(row -> (unit, string) result) ->
  (int, string) result

val read_recent :
  masc_root:string ->
  ?since_ts:float ->
  ?until_ts:float ->
  n:int ->
  unit ->
  (row list, string) result

val read_series :
  masc_root:string ->
  window:Tool_metrics_series.window ->
  ?tool_name:string ->
  unit ->
  (Tool_metrics_series.t, string) result
(** Groups stored calls in [window], optionally filtered by tool. A missing
    database gives an empty series. A call stored without a size, as every
    call was before sizes were kept, is counted as a call and adds nothing to
    the byte totals. The sizes live in a table that opening the store through
    {!insert}, {!prune} or {!iter_all} creates, so a database file that this
    version has not opened yet cannot be read here. Uses a private read-only
    connection, without taking the writer lock. Month-long scans may take
    about a second on a busy store; run this off the Eio event loop. *)

type series_observation = {
  series : Tool_metrics_series.t;
  next_change_at : float;
}

val observe_series :
  masc_root:string -> window:Tool_metrics_series.window ->
  ?tool_name:string -> unit -> (series_observation, string) result
(** The series and its exact next row-admission/expiry or bucket-label
    deadline, read from one SQLite snapshot. A missing database yields an
    empty series with the next bucket deadline. This retains no connection
    or timer after returning; a mounted streaming caller owns the deadline.
    Like {!read_series}, run this off the Eio event loop. *)

val summary : masc_root:string -> (summary, string) result
val row_to_json : row -> Yojson.Safe.t
val reset_for_testing : unit -> unit

val database_filename : string
(** The database {!database_path} names below [<base>/.masc]. *)
