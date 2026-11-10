(** The index of the delivery provenance in a transcript.

    A row may carry [delivery_provenance], the address of the delivery that
    wrote it. [scan_transcript_rows] reads the lines of a transcript, or of a
    part of one, into [scanned_provenance] values: no provenance, a valid one
    with its row id, or a delivery key that the row poisons because its role or
    its execution id does not fit its transcript slot. A line that cannot be
    read at all is an [Error], and nothing is added to any index by the scan.

    A [provenance_index] holds the rows by provenance, by tool ordinal and by
    execution id, and the poisoned delivery keys. [add_scanned_provenance]
    adds one row. A provenance, a tool ordinal or an execution id that appears
    twice poisons its delivery key. Adding the rows of a transcript in file
    order gives the same index whether they are added in one read or in
    several, so an index of the rows read so far can take the rows a later
    append wrote.

    [find_indexed_provenance] answers from an index: [Ok (Some row_id)] when
    the delivery already has its row and [Ok None] when it has none. It is an
    [Error] when the delivery cannot be answered safely: its key is poisoned,
    its rows are duplicated, or its tool ordinal or execution id belongs to
    another delivery. An autonomous turn whose tool rows have no input binding
    row is poisoned for as long as that row is missing.
    [transcript_provenance_readable] asks only whether every line can be read.
    [Keeper_chat_store] includes this module. *)

type scanned_provenance

type scanned_rows =
  { scanned : scanned_provenance list (** The lines that are not empty, in order. *)
  ; newlines : int (** How many newlines the text holds. *)
  }

val scan_transcript_rows : first_line:int -> string -> (scanned_rows, string) result
(** [first_line] is the number of the text's first line in its transcript; an
    [Error] names the line it could not read by that numbering. *)

type provenance_index

val empty_provenance_index : unit -> provenance_index

val add_scanned_provenance : provenance_index -> scanned_provenance -> unit

val transcript_provenance_readable : string -> (unit, string) result

val validate_indexed_autonomous_inputs :
  provenance_index ->
  delivery_key:Keeper_chat_delivery_identity.delivery_key ->
  Keeper_chat_delivery_identity.approval_input_binding list ->
  (unit, string) result
(** Before any append, require the existing turn's exact ordered binding.
    An unseen turn can be bound once. Missing binding behind existing tools,
    duplicate bindings or another vector are conflicts, never repair inputs. *)

val find_indexed_provenance :
  provenance_index ->
  provenance:Keeper_chat_delivery_identity.delivery_provenance ->
  (string option, string) result
