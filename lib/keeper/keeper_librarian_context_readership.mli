(** What the server-bound Keeper may be shown of its working context now.

    A working context keeps queue events as sources, and a Board event may be
    shown only while the Keeper still reads its parent post. The Librarian
    capture and the Keeper recall both put stored context in front of a model,
    so both ask here and one rule decides for both. *)

type reader
(** One Keeper for the length of one read. Its effective meta is read at most
    once, the first time a Board source asks for it. *)

val reader : base_path:string -> keeper_name:string -> reader

val can_project : reader -> Keeper_event_queue.stimulus -> bool
(** Whether a queue event may enter a prompt. A Board row whose routing is not
    resolved never may. A Board signal or attention row may while
    {!Keeper_board_audience.can_project_queued_stimulus} holds for the Keeper;
    when the Keeper's meta cannot be read it may not. Every other event may. *)

type withheld =
  | Board_source_unreadable
  | Event_source_undecodable
(** Why a stored source is not shown. *)

val shown :
  reader ->
  Keeper_librarian_context.snapshot ->
  Keeper_librarian_context.snapshot * withheld list
(** The snapshot without the event sources that may not be shown and without
    every pocket that names one of them. A pocket is one merged text and can
    hold any of its sources, so it is shown whole or not at all. The stored
    snapshot is not changed. The list has one entry for each withheld source,
    in stored order. *)
