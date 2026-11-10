(** The provenance index of a transcript file, kept between appends.

    An append-once delivery asks the index of every row in the transcript
    whether its row is already there. [update_indexed_transcript] keeps that
    index for each transcript path together with the place its reading ended,
    and each update reads only the rows written after that place: the rows
    this process appended, and the rows any other writer appended.

    The index is rebuilt from the first row when the file at the path is not
    the file that was read (another device or inode), is shorter than what was
    read, or has no row starting at the place the reading ended; and after an
    update that met a row it could not read, so a transcript that refuses
    deliveries is read whole each time, and whole once more after its repair.

    It is not rebuilt when bytes before that place change while the device,
    the inode, at least the length and a row start at that place all stay. The
    writers of the chat store never make such a change: they append, take back
    an append that failed, and cut an incomplete last row before a plain
    append, all after that place. A transcript that accepts deliveries is
    edited by hand only with the server stopped. *)

val update_indexed_transcript :
  string ->
  ((Keeper_chat_store_provenance_index.provenance_index, string) result ->
   string option * 'a) ->
  ('a, Fs_compat.durable_append_error) Fs_compat.private_file_transaction_outcome
(** [update_indexed_transcript path decide] is
    {!Fs_compat.update_private_file_durable_locked_result}, except that
    [decide] receives the index of every row in the file in place of its
    bytes: [Error] when a row cannot be read, with the line it is on. The rows
    [decide] appends are read by the next update.

    Updates of one path take turns in this process, as do its purges. A fiber
    cancelled while it waits for its turn writes nothing and raises; one
    cancelled before its file work starts does the same, as the Fs update
    does.

    [decide] runs under the file lock in the blocking worker and must not
    perform Eio effects. It must not update or purge the same transcript
    either: that call would wait for the turn its caller holds, and never
    return. *)

val purge_indexed_transcript : string -> remove:(string -> 'a) -> 'a
(** [purge_indexed_transcript path ~remove] runs [remove path] while no
    [update_indexed_transcript] of [path] is in flight, and forgets the index
    of the file whatever [remove] answers or raises. A transcript removed any
    other way leaves an index that a new file at the same path can match by
    its inode number. *)
