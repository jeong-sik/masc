(** The provenance index of a transcript file, kept between appends.

    An append-once delivery asks the index of every row in the transcript
    whether its row is already there. [update_indexed_transcript] keeps that
    index for each transcript path together with the place its reading ended,
    and each update reads only the rows written after that place: the rows
    this process appended, and the rows any other writer appended.

    The index is rebuilt from the first row when the file at the path is not
    the file that was read (another device or inode), is shorter than what was
    read, or has no row starting at the place the reading ended. It is not
    kept at all by an update that met a row it could not read: while a
    transcript has one, each update reads the whole file, and so does the
    first update after its repair.

    A row is a line that ends with its newline. Bytes after the last newline
    are an append that stopped part way, whether or not they read as a row:
    the sender of that append got no answer, so its delivery is not in the
    index, and the update that appends a row cuts those bytes first, as a
    plain append does.

    It is not rebuilt when bytes before that place change while the device,
    the inode, at least the length and a row start at that place all stay. The
    writers of the chat store never make such a change: they append, take back
    an append that failed, and cut an incomplete last row before an append,
    all after that place. A transcript whose rows can all be read is
    therefore edited by hand only with the server stopped. That includes one
    that refuses a delivery key for rows that can be read (two rows of one
    provenance): the refusal stays with the kept index until the index is
    rebuilt for one of the reasons above, the transcript is purged, or the
    server restarts. *)

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
    that is already cancelled when it calls, or is cancelled while it waits
    for its turn, writes nothing and raises. An update that has its turn runs
    to its end whatever happens to its fiber, and the caller meets the
    cancellation at its next cancellation point.

    [decide] runs under the file lock in the blocking worker and must not
    perform Eio effects. It must not update or purge the same transcript
    either: that call would wait for the turn its caller holds. Called from
    an Eio fiber's update it never returns; called outside Eio it raises
    [Sys_error]. *)

val purge_indexed_transcript : string -> remove:(string -> 'a) -> 'a
(** [purge_indexed_transcript path ~remove] runs [remove path] while no
    [update_indexed_transcript] of [path] is in flight, and forgets the index
    of the file whatever [remove] answers or raises. A transcript removed any
    other way leaves an index that a new file at the same path can match by
    its inode number. *)
