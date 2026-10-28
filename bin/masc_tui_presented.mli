(** Evidence belonging to one successfully presented frame. Values are
    immutable; the owner replaces the snapshot only after terminal output. *)
type barrier =
  | Open
  | Held of { rejected_input : bool; rejected_paste : bool }

type recovery = No_rejected_recovery | Rejected_recovery

type input_kind = Action | Paste | Protocol
type input_decision = Accept_input | Reject_action | Reject_paste
type panel_owner = Help | About | Context | Context_search | Agenda | Answering

type context_search_owner = {
  workspace : int;
  inspector : int;
  keeper : string;
}

val decide_unpresented_input :
  frame_presented:bool -> external_surface:bool -> input_kind -> input_decision
(** When a frame has not been presented, reject operator input unless an
    independently drawn image or machine surface owns it. Protocol replies
    remain observable. A presented compact frame counts as presented. *)

val decide_panel_input :
  external_surface:bool -> presented_owner:panel_owner option ->
  current_owner:panel_owner option ->
  input_kind -> input_decision
(** A panel owns input only while both the presented and current frame name
    it. Only Context_search accepts paste. Entering, leaving or replacing a
    panel rejects operator input until presentation; protocol replies and
    external surfaces retain their own admission rules. None denotes a frame
    outside these panels, whose existing input policy remains responsible. *)

type ('approval, 'presses, 'panes, 'reader) t = private {
  approval : 'approval;
  presses : 'presses;
  panes : 'panes;
  reader : 'reader;
  panel_owner : panel_owner option;
  context_search : context_search_owner option;
  barrier : barrier;
  recovery : recovery;
}

val begin_context_search :
  ('a, 'p, 'n, 'r) t -> context_search_owner -> ('a, 'p, 'n, 'r) t
(** Called only by the slash action of the presented Context panel. This
    permits its query typeahead, without claiming that an editor was painted. *)

val panel_owner_matches :
  ('a, 'p, 'n, 'r) t -> current_owner:panel_owner option ->
  context_search_owner:context_search_owner option -> bool

val decide_snapshot_input :
  ('a, 'p, 'n, 'r) t -> external_surface:bool ->
  current_owner:panel_owner option ->
  context_search_owner:context_search_owner option -> input_kind -> input_decision
(** An explicitly opened query accepts typeahead only in the same workspace,
    inspector generation and Keeper. Ending it requires a new frame before
    another action. Every successfully presented frame retires this grant. *)

val initial :
  approval:'a -> presses:'p -> panes:'n -> reader:'r ->
  panel_owner:panel_owner option -> ('a, 'p, 'n, 'r) t

val presented :
  ('a, 'p, 'n, 'r) t -> approval:'a -> presses:'p -> panes:'n -> reader:'r ->
  panel_owner:panel_owner option ->
  owner_changed:bool -> input_pending:bool -> ('a, 'p, 'n, 'r) t
(** Call only after successful output. A previous hold survives presentation;
    a changed owner starts one when input is already in flight. *)

val reject :
  ('a, 'p, 'n, 'r) t -> paste:bool -> ('a, 'p, 'n, 'r) t
(** Record a discarded operator event without retaining its contents. *)

val after_input :
  ('a, 'p, 'n, 'r) t -> input_pending:bool -> ('a, 'p, 'n, 'r) t
(** Release a hold only once all input sources have settled. The event read
    under that hold must already have been rejected by the caller. *)

val reject_recovery : ('a, 'p, 'n, 'r) t -> ('a, 'p, 'n, 'r) t
val clear_recovery : ('a, 'p, 'n, 'r) t -> ('a, 'p, 'n, 'r) t
(** A discarded recovered paste remains known until its tail ends or the
    operator unlocks it. No paste contents are kept in this snapshot. *)
