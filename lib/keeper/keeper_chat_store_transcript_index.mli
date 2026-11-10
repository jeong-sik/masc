(** The provenance index of a transcript file, kept between appends.

    An append-once delivery asks the index of every row in the transcript
    whether its row is already there. [update_indexed_transcript] keeps that
    index for each transcript path together with the place its reading ended,
    and each update reads only the rows written after that place: the rows
    this process appended, and the rows any other writer appended.

    The index is rebuilt from the first row when the file at the path is not
    the file that was read (another device or inode) or is shorter than what
    was read. It is not rebuilt when bytes before that place change while the
    device, the inode and at least the length stay: a transcript is appended
    to only while a server runs, and it is repaired with the server stopped. *)

val update_indexed_transcript :
  string ->
  ((Keeper_chat_store_provenance_index.provenance_index, string) result ->
   string option * 'a) ->
  ('a, Fs_compat.durable_append_error) Fs_compat.private_file_transaction_outcome
(** [update_indexed_transcript path decide] is
    {!Fs_compat.update_private_file_durable_locked_result}, except that
    [decide] receives the index of every row in the file in place of its
    bytes: [Error] when a row cannot be read, with the line it is on. The rows
    [decide] appends are read by the next update. [decide] runs under the file
    lock in the blocking worker and must not perform Eio effects or append to
    the same transcript. *)

val purge_indexed_transcript : string -> remove:(string -> 'a) -> 'a
(** [purge_indexed_transcript path ~remove] runs [remove path] while no
    [update_indexed_transcript] of [path] is in flight, and forgets the index
    of the file whatever [remove] answers or raises. A transcript removed any
    other way leaves an index that a new file at the same path can match by
    its inode number. *)
