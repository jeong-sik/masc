(** The content of one unit of a Keeper's turn log, read as items
    (RFC librarian-call-only-proposes §5.1, §5.3, §5.5, §5.6).

    {!Librarian_unread} names what a unit holds in each store. This reads it:
    the rows of the chat file and the external store that lie in its ranges,
    and the conversation from the one record each segment names: the
    Agent-Core messages its slices name, or the rows of the official-client
    files in its ranges. Each item is the value its store holds, in the order
    {!Librarian_unit} gives. Nothing is reduced here: the question reduces
    the items as §5.5 says when it writes them out.

    What a unit names and a store does not hold is named as missing, the way
    the unit's line names it, and the rest is still read. *)

(** Where a Keeper's stores are. *)
type stores =
  { session_dir : session:string -> string
  (** The directory of a session. A mark's [trace] names the session that
      keeps a unit's bundles, its [session] the session whose official-client
      files a unit's byte ranges count. *)
  ; base_path : string (** The chat file and the external store are under it. *)
  ; keeper_name : string
  }

type read_error =
  | Fault of Librarian_unit.input_fault
  (** [Content_unreadable]: a bundle the unit names is there and does not
      read: it cannot be read now, it does not match its digest or does not
      decode, or it holds fewer messages than a slice takes. *)
  | Unread of { detail : string }
  (** A byte file or the external store could not be read, or it changed
      while it was read. *)

(** Reads every item of [span]. A bundle that is not stored is [Bundle] of
    the slice that names it. Bytes or rows a file does not hold are the range
    of them that it lacks. A row that does not decode is its offset, or its
    row number in the external store; a chat row is an item with what the
    chat reader made of it. *)
val read : stores -> Librarian_unread.span -> (Librarian_read_unit.t, read_error) result
