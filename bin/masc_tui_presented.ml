type barrier =
  | Open
  | Held of { rejected_input : bool; rejected_paste : bool }

type recovery = No_rejected_recovery | Rejected_recovery

type input_kind = Action | Paste | Protocol
type input_decision = Accept_input | Reject_action | Reject_paste

let decide_unpresented_input ~frame_presented ~external_surface input =
  if frame_presented || external_surface then Accept_input
  else match input with
    | Action -> Reject_action
    | Paste -> Reject_paste
    | Protocol -> Accept_input

type ('approval, 'presses, 'panes, 'reader) t = {
  approval : 'approval;
  presses : 'presses;
  panes : 'panes;
  reader : 'reader;
  barrier : barrier;
  recovery : recovery;
}

let initial ~approval ~presses ~panes ~reader =
  { approval; presses; panes; reader; barrier = Open; recovery = No_rejected_recovery }

let presented previous ~approval ~presses ~panes ~reader ~owner_changed ~input_pending =
  let barrier = match previous.barrier with
    | Held _ as held -> held
    | Open when owner_changed && input_pending ->
        Held { rejected_input = false; rejected_paste = false }
    | Open -> Open
  in
  { approval; presses; panes; reader; barrier; recovery = previous.recovery }

let reject snapshot ~paste =
  match snapshot.barrier with
  | Open -> snapshot
  | Held { rejected_input = _; rejected_paste } ->
      { snapshot with barrier = Held {
          rejected_input = true;
          rejected_paste = rejected_paste || paste;
        } }

let after_input snapshot ~input_pending =
  if input_pending then snapshot else { snapshot with barrier = Open }

let reject_recovery snapshot = { snapshot with recovery = Rejected_recovery }
let clear_recovery snapshot = { snapshot with recovery = No_rejected_recovery }
