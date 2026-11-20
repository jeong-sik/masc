(** The end of what a Keeper's Memory writer has read, as a place in the
    history a request is cut from (RFC librarian-call-only-proposes §11.1,
    §11.2).

    The writer keeps one value in memory, its view. This module turns the
    view into the vocabulary a request's range uses: the atom the part of
    the history Memory does not hold starts at. No digest is compared: a
    purge that rewrites a closed message keeps its number, so the place still
    resolves after one.

    The view counts closed messages. A [Reset] line of the Keeper's turn log
    starts that count again, so a view taken before one names no place until
    the writer has read it (§11.2). The lines after the view's position are
    the only thing read from a file here. *)

(** What the turn log holds after the view's position. *)
type unread_lines =
  | No_reset  (** No [Reset] line. *)
  | Reset_at of { offset : int }
  (** A [Reset] line at byte [offset] that the writer has not read to its
      end. *)
  | Not_scanned of { detail : string }
  (** The lines could not be read, one of them does not decode, or the
      position is not a unit's line. *)

(** Why the view's end is not a place in the history in hand. *)
type unresolved =
  | Other_trace of { covered : string }
  (** The view ends on trace [covered], and the history is another trace's. *)
  | History_shorter of
      { closed_messages : int
      ; in_hand : int
      }
  (** The view counts [closed_messages] closed messages and the list in hand
      holds [in_hand] messages, open ones included. This only keeps the atom
      lookup inside the list: a head that fell below the read end and grew
      again is {!Reset_unread}. *)
  | Reset_unread of { offset : int }
  (** The turn log holds a [Reset] at byte [offset] after the view's
      position: the history was cleared, was found below the last mark, or
      lost what followed a break in a purge. What the view's count names now
      is not known until the writer reads that unit. *)
  | Turn_log_unread of { detail : string }
  (** Whether a [Reset] follows could not be read. *)

type place =
  | Covered of { end_atom : int }
  (** Memory holds what is before atom [end_atom] of the history. A count
      that ends inside an atom, on a tool result, gives that atom: the
      request then repeats the atom's first messages and leaves none out. *)
  | Nothing_read
  (** The writer has read no unit of the turn log, so there is no read end. *)
  | Front_unresolved of unresolved

type t =
  { place : place
  ; working_state : string option
  (** What the Keeper was doing, as the writer last committed it. *)
  }

(** The view's read end in [messages], the history of trace [trace_id] a
    request is about to be cut from. [covered.closed_messages] closed
    messages are before the end; the place is the atom that opens at or
    after that message. [unread_lines] is asked about the view's position
    only when the view has one, ends on this trace and counts no more
    messages than the list holds. *)
val of_view
  :  trace_id:string
  -> messages:Agent_core.Types.message list
  -> unread_lines:(line:int -> within:Librarian_log.within -> unread_lines)
  -> Librarian_writer.view
  -> t

(** The turn log at [turns_path] from the unit line at byte [line]. With
    [Whole] the unit at [line] is read and the lines after it are looked at;
    with [Item _] it is read in part, and a [Reset] there counts too. *)
val read_unread_lines
  :  turns_path:string
  -> line:int
  -> within:Librarian_log.within
  -> unread_lines

(** [of_view] on the view of [keeper_name]'s writer in this workspace, with
    {!read_unread_lines} over the Keeper's turn log. It does not wait for
    the writer. An [Error] is not "nothing was read yet": there is no view,
    so the request has no read end and carries no working state (§11.1).

    - [`Writers_not_started]: this process runs no Memory writers for the
      workspace.
    - The others are {!Librarian_writers.view}'s. *)
val read
  :  config:Workspace.config
  -> keeper_name:string
  -> trace_id:string
  -> messages:Agent_core.Types.message list
  -> ( t
       , [ `Writers_not_started | `Booting | `Stopped of Librarian_store.stop | `No_writer ] )
       result
