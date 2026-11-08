(** The workspace memory world the Memory screen reads, and the one header line
    that draws it (RFC-0511 D2c).

    The world is the curator's ledger of shared claims and conflicts, and the
    briefing written from it. The server answers
    [GET /api/v1/dashboard/workspace-memory-inventory] from a 60 s cache and
    sends no change signal, so the screen asks on a clock: after each answer
    {!complete} sets the time before which {!start} gives out no read. The
    caller asks from its per-iteration launcher while the Memory overview, the
    screen that draws the line, is open and nowhere else, so there is no timer
    of its own.

    Nothing here does I/O. The state is a value; every transition returns a new
    one. *)

type inventory = Masc.Tui_decode_workspace_memory.inventory

type request = unit Masc_tui_fetched.request

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
    the read failed; a failure with nothing read before it holds no inventory. *)

val suspend : t -> t
(** The workspace is no longer confirmed: retire the read in flight, whose
    answer can no longer settle anything. A first read becomes a failure and a
    refresh keeps the last inventory with its read marked failed. A retired read
    never answered, so it sets no wait and the first read after the workspace is
    confirmed again is not held back. *)

val clear : t -> t
(** Another workspace: nothing read and no wait. A reply to a request made
    before this still cannot settle the next one. *)

(** What the screen has to answer for. [Loaded] with [refresh_failed] is the
    last inventory read while a later read failed; the line still draws it and
    says the read failed. *)
type reading =
  | Not_read
  | Reading
  | Loaded of { world : inventory; refresh_failed : bool }
  | Read_failed

val reading : t -> reading

val label : ko:bool -> string

val clauses : ko:bool -> reading -> string list
(** The world line's clauses after its label. [Not_read], [Reading] and
    [Read_failed] draw the unknown mark and never a count. An inventory with no
    ledger, and an inventory whose counts are all zero, draw as values, which
    the unknown mark is not. [stale] appears only as the server's own briefing
    status. *)

val legend : (string * string) list
(** One row for each word the line can draw, keyed by that word, in the
    English the sheet is written in. *)
