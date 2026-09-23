(** The Overview Team block: one row per Keeper, answering who is doing what
    and who is stuck (RFC-0464 §2).

    Pure. The render reads [project]'s result and draws it; nothing here
    touches the terminal, the network or the clock. *)

module Tui_decode = Masc.Tui_decode

(** Which band a Keeper's row sits in. The bands are drawn in this order and
    decided by the Keeper's phase and the tasks it holds -- not by a score. *)
type group =
  | Needs_you
      (** [Failing] or [Crashed], a phase this build cannot read, or no phase
          at all while an attention item names the Keeper. *)
  | Working  (** [Running] and holds a Claimed or InProgress task. *)
  | Idle  (** Alive ([Running], [Draining], [Restarting]) with no such task. *)
  | Parked
      (** [Paused], [Stopped], [Offline], or no phase and nothing asking for
          the operator. Drawn as one line of names. *)

type detail =
  | Blocker of { summary : string; held : int }
      (** The first attention item that names this Keeper, verbatim, and how
          many open tasks it holds while stuck. *)
  | Phase_word of { word : string; held : int }
      (** A stuck Keeper no attention item explains: its own phase word. *)
  | Working_on of { task : Tui_decode.task; more : int; awaiting : int }
      (** The first held Claimed/InProgress task in backlog order, how many
          more it holds, and how many of its tasks wait on a verifier. *)
  | No_open_task of { awaiting : int }

type row = {
  keeper : Masc_tui_types.overview_keeper;
  group : group;
  detail : detail;
}

type t = {
  rows : row list;
      (** Needs_you, then Working, then Idle; by name inside a band. *)
  parked : (string * int) list;
      (** Parked Keeper names, by name, with the open tasks each still holds:
          work behind a stopped Keeper is work nobody is doing. *)
  other_holders : (string * int) list;
      (** Assignees that are not Keepers in the briefing (MCP clients, retired
          names) with how many open tasks each holds, most first. Work held
          outside the fleet is still work the team is waiting on; work a
          Keeper holds is counted on that Keeper's row or parked entry. *)
}

val project :
  keepers:Masc_tui_types.overview_keeper list ->
  tasks:Tui_decode.task list ->
  attention:Masc_tui_types.attention_item list ->
  t

val drawn_rows : t -> int
(** Rows the block draws below its title: one per [rows] entry, one for the
    parked names when there are any, one for [other_holders] when there are
    any. The row budget asks for this many. *)

val count : t -> group -> int

val phase_word : Masc_tui_types.overview_keeper -> string
(** The phase as the row prints it: the lifecycle word, the unreadable wire
    word as it came, or ["no phase"] when the briefing wrote none. *)
