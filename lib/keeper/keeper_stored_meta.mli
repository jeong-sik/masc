(** The Keeper meta as its file holds it, taken from the Owner when the Owner
    stands for the file.

    The Owner writes the whole meta to the file on every commit and keeps the
    written value in memory. A reader that only wants what the file holds can
    ask the Owner instead of opening the file, as long as it reads the value
    back the way the file would give it: the snapshot encoding leaves the
    TOML-owned fields out, and a file read returns the decoder's placeholders
    for them. *)

val read
  :  Workspace.config
  -> string
  -> read_file:(unit -> (Keeper_meta_contract.keeper_meta option, string) result)
  -> (Keeper_meta_contract.keeper_meta option, string) result
(** [read config name ~read_file] answers what [read_file ()] answers when
    [read_file] reads the meta file of Keeper [name], and it opens no file
    when the Owner stands for that file
    ({!Keeper_owner_projection.meta_the_file_holds}). The Owner's meta is then
    passed through {!Keeper_meta_store.snapshot_read_back}; the result is
    remembered until the Owner publishes another meta.

    [read_file] runs in every other case: no Owner, an Owner without a meta,
    an Owner whose meta write ended without a known outcome, or an Owner meta
    whose snapshot does not decode. The last case is logged once per meta.

    Two differences from a file read remain. While the file is unreadable, a
    file read fails and this still answers from the Owner. And a meta file
    edited from outside the server is not seen until the Owner's next commit
    overwrites it.

    Lock-free; safe from a fiber and from a system thread. *)
