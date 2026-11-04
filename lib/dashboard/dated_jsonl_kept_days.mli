(** What the day files of a {!Dated_jsonl} store said, folded per file and
    kept between reads.

    A trailing-window answer read every day file its window touched on each
    request. Kept, a file is read whole the first time and afterwards only the
    bytes it gained ({!Dated_jsonl.fold_file_appended_entries_result}): a day
    file is append-only. A file whose cursor no longer holds (rotation moved
    the current file into a segment, or the file was rewritten) is read again
    from its start, and its old fold is dropped, so nothing is counted twice.

    The value is immutable: {!refresh} returns a new one and leaves the one it
    was given as it was, so a reader that fails or is cancelled keeps the
    last whole reading. *)

type day =
  { date : string  (** ["YYYY-MM-DD"], as the store names the day. *)
  ; starts_at : float  (** The UTC midnight that begins it. *)
  }

val seconds_per_day : float

val day_of : float -> day
(** The UTC day holding the time. *)

val days_between : since:float -> until:float -> day list
(** The UTC days from the one holding [since] to the one holding [until],
    oldest first; empty when [since] is after [until]. *)

type 'a t

val empty : 'a t

val refresh :
  Dated_jsonl.t ->
  days:day list ->
  init:'a ->
  f:('a -> Dated_jsonl.recent_entry -> 'a) ->
  'a t ->
  ('a t, Dated_jsonl.read_error) result
(** Fold what each day file of [days] gained since the given value read it,
    every row of a file it has not read, and drop the files of any other
    day. [f] sees every physical row of a file once, a malformed one as
    {!Dated_jsonl.Malformed_json}. A store that does not exist is empty. *)

val fold : 'a t -> init:'b -> f:('b -> day -> 'a -> 'b) -> 'b
(** Every kept file's fold with its day, oldest day first. *)
