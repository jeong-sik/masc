(** The end of what a Keeper's Memory writer has read, as a place in the
    history a request is cut from (RFC librarian-call-only-proposes §11.1,
    §11.2).

    The writer keeps one value in memory, its view. This module turns the
    view into the vocabulary a request's range uses: the atom the part of
    the history Memory does not hold starts at. Nothing here reads a file,
    and no digest is compared: a purge that rewrites a closed message keeps
    its number, so the place still resolves after one. *)

(** Why the view's end is not a place in the history in hand. *)
type unresolved =
  | Other_trace of { covered : string }
  (** The view ends on trace [covered], and the history is another trace's.
      A cleared history is this until the writer reads the unit of the
      clearing. *)
  | History_shorter of
      { closed_messages : int
      ; in_hand : int
      }
  (** The view counts [closed_messages] closed messages and the history
      holds [in_hand] messages. *)

type place =
  | Covered of { end_atom : int }
  (** Memory holds what is before atom [end_atom] of the history. *)
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
    after that message. *)
val of_view
  :  trace_id:string
  -> messages:Agent_core.Types.message list
  -> Librarian_writer.view
  -> t

(** [of_view] on the view of [keeper_name]'s writer in this workspace. It
    does not wait for the writer. An [Error] is not "nothing was read yet":
    there is no view, so the request has no read end and carries no working
    state (§11.1).

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
