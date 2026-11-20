(** The content of one unit of a Keeper's turn log, read as items
    (RFC librarian-call-only-proposes §5.1, §5.3, §5.5, §5.6).

    {!Librarian_unread} names what a unit holds in each store. This reads it:
    the rows of the chat file and the external store that lie in its ranges,
    and the conversation from the record each segment names
    ({!Librarian_unread.record}): the Agent-Core messages its slices name
    with the internal file's replies beside them, the rows of the
    official-client files in its ranges, or all of these for a stretch that
    can hold several turns.

    To avoid repeating identical user/assistant/tool lines across overlapping
    stores in one unit, exact-witness chat deduplication omits:
    - [Role.Assistant] and [Role.Tool] chat mirror rows only when the unit's
      conversation witness holds a matching assistant message or tool block
      (keeping the chat row if the transcript witness is absent);
    - [Role.User] chat rows matching an [External_row] in the same unit (by
      connector event id or [(conversation_id, external_message_id)]);
    - [turn_ref]-stamped [Role.User] chat rows only when the unit's
      conversation carries a conversation user message.
    Corrupt rows, [Role.System], [Role.Request_failure], and unlinked
    [Operation*] accepted-user rows (whose operation id is absent from
    [Opened]) always stay, so deduplication never leaves a previously readable
    unit empty. Witnesses are derived from the unit's full non-chat ranges so
    item selection and coordinates are invariant across {!First_items} slices
    and [span.resume]. Each kept item is the value its store holds, in the order
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

(** How much of a unit to read. *)
type take =
  | Rest_of_unit
  | First_items of Librarian_width.count
  (** The first this many items. Missing parts do not count. *)

type read =
  { unit : Librarian_read_unit.t
  ; ends : Librarian_log.within
  (** [Whole]: the unit was read to its end, missing parts after its last
      item included. [Item _]: an item follows this one, and the next read
      starts after it. *)
  }

(** Reads the items of [span] from where its [resume] says: after that item,
    or from the first. Each item carries its {!Librarian_unit.item_name}. A
    bundle that is not stored is [Bundle] of the part of the slice that was
    to be read. Bytes or rows a file does not hold are the range of them
    that it lacks. A row that does not decode is its offset, or its row
    number in the external store; a chat row is an item with what the chat
    reader made of it.

    A byte file is read from the resumed row's offset. The row there is not
    decoded again: the next row starts after the line break that ends it.
    [First_items k] reads until it finds the item after the k-th, and keeps
    only the k. *)
val read : stores -> Librarian_unread.span -> take:take -> (read, read_error) result
