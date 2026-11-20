(** Why the file at a Keeper's snapshot path is not a snapshot the store
    opens (RFC librarian-call-only-proposes §7.1 step 2, §8.6).

    Every reader of that file names what it found with this type: the store
    at boot, before a direct commit and at an adoption, and an ask before it
    builds its question. The store and the writer stop for the same fault
    the same way ({!Librarian_store.stop_of_snapshot_fault}). *)
type t =
  | Absent (** No file at the path. *)
  | Not_a_snapshot_file
  (** Something other than a regular file, or bytes that do not decode as a
      snapshot. *)
  | Not_read
  (** The read failed. That says nothing about the file, so it is not taken
      as absent. *)
