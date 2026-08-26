(** Names for what a connector brings in -- the people and the places -- kept
    across restarts.

    The Slack gateway resolves [U…] ids through an in-memory TTL cache, so a
    restart loses every name it had learned and the same person arrives named
    on one message and id-shaped on the next.

    A live answer always wins. This says what to call someone when there is no
    live answer and there was one before: a name we have seen, not a name we
    are asserting. Someone who renames themselves keeps the old name until the
    next successful lookup -- a stale name still reads as a person, where a raw
    id reads as nothing.

    Keyed by connector, scope and id rather than by keeper: the same Slack user
    is the same person on every keeper's pane, and the same channel is the same
    room.

    People and channels share this rather than each getting a copy: they ask
    the same question -- what is this id called -- and two stores would be the
    same code twice, drifting on the next fix to either. {!scope} keeps their
    id spaces apart. *)

type scope =
  | Person
  | Channel

val remember :
  base_dir:string ->
  connector:string ->
  scope:scope ->
  id:string ->
  name:string ->
  unit ->
  unit
(** Record what this id was called. Blank ids and blank names are ignored --
    an empty name is the absence this store exists to answer, not an answer. *)

val recall :
  base_dir:string -> connector:string -> scope:scope -> id:string -> string option
(** The most recent name recorded for this id, or [None] where none was. *)
