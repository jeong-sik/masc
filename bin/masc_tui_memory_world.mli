(** The workspace memory world the Memory screen reads, and the one header line
    that draws it (RFC-0511 D2c).

    The world is the curator's ledger of shared claims and conflicts, and the
    briefing written from it. The server answers
    [GET /api/v1/dashboard/workspace-memory-inventory] from a 60 s cache and
    sends no change signal, so the screen asks on a clock: after each answer
    {!complete} sets the time before which {!start} gives out no read. The
    caller asks from its per-iteration launcher while the Memory overview or
    the Keepers memory/age views draw it, so there is no timer of its own.

    Nothing here does I/O. The state is a value; every transition returns a new
    one. *)

type inventory = Masc.Tui_decode_workspace_memory.inventory

type request = unit Masc_tui_fetched.request

(** Why the line has no fresh inventory. [Suspended] is the cause this module
    makes itself: {!suspend} retired the read. [Request_failed] holds the text
    of an answer that failed, as the shared read path built it. That path
    returns strings to every consumer, so the text is carried and drawn, and
    never read to tell one cause from another. *)
type failure =
  | Suspended
  | Request_failed of string

type t

val initial : t

val start : now:float -> t -> (t * request) option
(** The read to launch now. [None] while a read is in flight, and while [now] is
    before the time the last answer set. The value already held stays in view
    while the new read runs. *)

val complete : next_read_at:float -> t -> request -> (inventory, string) result -> t
(** An answer for a request this state has moved past is dropped whole. Any
    other answer, failed or not, keeps the next read from starting before
    [next_read_at]. A failure after a read keeps the last inventory and says
    the read failed; a failure with nothing read before it holds no inventory.
    The error text becomes [Request_failed]. *)

val suspend : t -> t
(** The workspace is no longer confirmed: retire the read in flight, whose
    answer can no longer settle anything. A first read becomes a failure and a
    refresh keeps the last inventory with its read marked failed, both with
    cause [Suspended]. A retry over a failure keeps that failure's cause, since
    the retired read never answered. A retired read sets no wait, so the first
    read after the workspace is confirmed again is not held back. *)

val clear : t -> t
(** Another workspace: nothing read and no wait. A reply to a request made
    before this still cannot settle the next one. *)

(** What the screen has to answer for. [Loaded] with a [refresh_failure] is the
    last inventory read while a later read failed; the line still draws it and
    says the read failed. *)
type reading =
  | Not_read
  | Reading
  | Loaded of { world : inventory; refresh_failure : failure option }
  | Read_failed of failure

val reading : t -> reading

val label : ko:bool -> string

val clauses : ko:bool -> room:int -> reading -> string list
(** The world line's clauses after its label. [Not_read], [Reading] and
    [Read_failed] draw the unknown mark and never a count. An inventory with no
    ledger, and an inventory whose counts are all zero, draw as values, which
    the unknown mark is not. [stale] appears only as the server's own briefing
    status.

    [room] is the cells a row of clauses may take, the [max_cells] the caller
    packs them with. A failed read ends with its cause as one more clause, put
    in what the last packed row has left, so the cause never adds a row. For
    [Suspended] it is a fixed word, drawn whole or not at all. For
    [Request_failed] it is the text on one printable line, cut with the cut
    mark, and left out when too few cells are left for a cut text to name
    anything, or when the text is blank. *)

val legend : (string * string) list
(** One row for each word the line can draw, keyed by that word, in the
    English the sheet is written in. The cause after [read failed] has no row
    of its own: [workspace unconfirmed] is wider than the sheet's key column, so
    the [read failed] row explains it. *)
