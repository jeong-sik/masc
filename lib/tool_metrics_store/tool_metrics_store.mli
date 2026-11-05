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
val insert : masc_root:string -> row -> (unit, string) result
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
(** [read_series ~masc_root ~window ()] groups the stored calls inside
    [window] into its buckets. [tool_name] keeps only that tool's calls.
    A store that does not exist yet gives a series with no calls.

    It reads on a connection of its own, so it does not wait for the store
    lock or hold it, and an [insert] on another thread is not delayed by it.
    A window of a month over a busy store is about 800,000 rows and blocks the
    calling thread for about a second; run it off the Eio event loop. *)

val summary : masc_root:string -> (summary, string) result
val row_to_json : row -> Yojson.Safe.t
val reset_for_testing : unit -> unit
