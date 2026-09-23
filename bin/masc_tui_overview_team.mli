(** The Overview Team block: one row per Keeper, answering who is doing what
    and who is stuck (RFC-0464 §2).

    Pure. The render reads [project]'s result and draws it; nothing here
    touches the terminal, the network or the clock. *)

module Tui_decode = Masc.Tui_decode

(** Which band a Keeper's row sits in. The bands are drawn in this order and
    decided by the Keeper's phase and the tasks it holds -- not by a score. *)
type group =
  | Needs_you
      (** Not paused, and [Failing] or [Crashed], a phase this build cannot
          read, or no phase at all while a non-info attention item names the
          Keeper. *)
  | Working
      (** Alive ([Running], [Draining], [Restarting]) and holds a Claimed or
          InProgress task. *)
  | Idle  (** Alive with no such task. *)
  | Paused
      (** The brief says [paused: true] (whatever the phase and the attention
          list say), or the phase is [Paused]. Drawn as one line of names. *)
  | Stopped
      (** Not paused, and [Stopped], [Offline], or no phase and nothing
          asking for the operator. Drawn as one line of names. *)

type detail =
  | Blocker of {
      summary : string;
      item : Masc_tui_types.attention_item;
      held : int;
    }
      (** The first attention item above info severity that names this
          Keeper -- its blocker
          sentence when the item carries one, else its summary, verbatim --
          the item itself, and how many open tasks it holds while stuck. *)
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
  paused : (string * int) list;
      (** [Paused] Keeper names, by name, with the open tasks each still
          holds: work behind a paused Keeper is work nobody is doing. *)
  stopped : (string * int) list;
      (** [Stopped] Keeper names, by name, with the open tasks each still
          holds. *)
  other_holders : (string * int) list;
      (** Assignees that are not Keepers in the briefing (MCP clients, retired
          names) with how many open tasks each holds, most first. Work held
          outside the fleet is still work the team is waiting on; work a
          Keeper holds is counted on that Keeper's row or name entry. *)
}

val project :
  keepers:Masc_tui_types.overview_keeper list ->
  tasks:Tui_decode.task list ->
  attention:Masc_tui_types.attention_item list ->
  t

val drawn_rows : t -> int
(** Rows the block draws below its title: one per [rows] entry, one for the
    paused names and one for the stopped names when there are any, one for
    [other_holders] when there are any. The row budget asks for this many. *)

val count : t -> group -> int

val drawn_items : t -> rows:int -> Masc_tui_types.attention_item list
(** The attention items the block's first [rows] rows draw. The block draws
    its [Needs_you] rows first, and only a [Blocker] row draws an item --
    one item, even when several name the Keeper. A working or idle row, the
    paused and stopped lines and the holders line draw none. *)

val settle :
  t ->
  attention:Masc_tui_types.attention_item list ->
  allocate:(Masc_tui_types.attention_item list -> 'budget) ->
  team_rows:('budget -> int) ->
  Masc_tui_types.attention_item list * 'budget
(** The Attention panel's items beside this block and the budget they were
    allocated with: [attention] without the instances the drawn Team rows
    carry. Rows the budget cuts keep their items in the panel, and with no
    Team row drawn every item stays there, so an item is never on neither.
    [allocate] must not give fewer Team rows for fewer panel items. *)

val phase_word : Masc_tui_types.overview_keeper -> string
(** The phase as the row prints it: the lifecycle word, the unreadable wire
    word as it came, or ["no phase"] when the briefing wrote none. *)

(** {1 Quota windows} *)

(** One provider or credential quota window that is shut, as the runtime
    catalogue reports it. The catalogue carries the window on every runtime
    that shares it; this is the window once. *)
type shut_window = {
  sw_scope : string option;
      (** The catalogue's [quota_scope], e.g. ["provider:claude_code"]. [None]
          groups the runtimes that report a shut window with no scope. *)
  sw_runtimes : int;  (** Runtimes behind this window. *)
  sw_resets_at : float option;
      (** Epoch seconds the provider said the window reopens; [None] when it
          did not say. The latest of the runtimes' readings. *)
}

val shut_windows : Tui_decode.runtime_option list -> shut_window list
(** Every window with at least one exhausted runtime, soonest reopening first;
    windows with no reopening time last, by scope. Runtimes whose quota is
    open do not appear. *)
