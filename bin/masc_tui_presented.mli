(** Evidence belonging to one successfully presented frame. Values are
    immutable; the owner replaces the snapshot only after terminal output. *)
type barrier =
  | Open
  | Held of { rejected_input : bool; rejected_paste : bool }

type recovery = No_rejected_recovery | Rejected_recovery

type input_kind = Action | Paste | Protocol
type input_decision = Accept_input | Reject_action | Reject_paste

val decide_unpresented_input :
  frame_presented:bool -> external_surface:bool -> input_kind -> input_decision
(** When a frame has not been presented, reject operator input unless an
    independently drawn image or machine surface owns it. Protocol replies
    remain observable. A presented compact frame counts as presented. *)

type ('approval, 'presses, 'panes, 'reader) t = private {
  approval : 'approval;
  presses : 'presses;
  panes : 'panes;
  reader : 'reader;
  barrier : barrier;
  recovery : recovery;
}

val initial :
  approval:'a -> presses:'p -> panes:'n -> reader:'r -> ('a, 'p, 'n, 'r) t

val presented :
  ('a, 'p, 'n, 'r) t -> approval:'a -> presses:'p -> panes:'n -> reader:'r ->
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
