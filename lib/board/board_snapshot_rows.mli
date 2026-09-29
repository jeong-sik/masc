(** The JSONL snapshot of a table of values that are replaced, never changed
    in place, such as the board's posts and comments.

    A snapshot has one row per value, in the table's iteration order, each
    ending in a newline. [rows] keeps, per key, the value the last snapshot
    wrote and its row. A row is rendered again only when the table holds a
    value that is not physically the one [rows] kept, so a snapshot after a
    small change renders only what changed. Rows of keys that left the
    table are dropped.

    [rows] belongs to one table. The caller serializes snapshots of that
    table and must not change a value in place. *)

val render :
  rows:(string, 'a * string) Hashtbl.t ->
  to_json:('a -> Yojson.Safe.t) ->
  (string, 'a) Hashtbl.t ->
  string
