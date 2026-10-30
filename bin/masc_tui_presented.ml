type barrier =
  | Open
  | Held of { rejected_input : bool; rejected_paste : bool }

type recovery = No_rejected_recovery | Rejected_recovery

type input_kind = Action | Paste | Protocol
type input_decision = Accept_input | Reject_action | Reject_paste
type panel_owner = Help | About | Context | Context_search | Agenda | Answering

type context_search_owner = { workspace : int; inspector : int; keeper : string }

let decide_unpresented_input ~frame_presented ~external_surface input =
  if frame_presented || external_surface then Accept_input
  else match input with
    | Action -> Reject_action
    | Paste -> Reject_paste
    | Protocol -> Accept_input

let decide_panel_input ~external_surface ~presented_owner ~current_owner input =
  if external_surface then Accept_input
  else if Option.equal ( = ) presented_owner current_owner then
    match presented_owner, input with
    | Some Context_search, Paste -> Accept_input
    | Some (Help | About | Context | Agenda | Answering), Paste -> Reject_paste
    | Some _, (Action | Protocol) | None, (Action | Paste | Protocol) -> Accept_input
  else match input with
    | Action -> Reject_action
    | Paste -> Reject_paste
    | Protocol -> Accept_input

type ('approval, 'presses, 'panes, 'reader) t = {
  approval : 'approval;
  presses : 'presses;
  panes : 'panes;
  reader : 'reader;
  panel_owner : panel_owner option;
  context_search : context_search_owner option;
  barrier : barrier;
  recovery : recovery;
}

let begin_context_search snapshot owner =
  match snapshot.panel_owner, snapshot.barrier with
  | Some Context, Open -> { snapshot with context_search = Some owner }
  | Some (Help | About | Context_search | Agenda | Answering), (Open | Held _)
  | None, (Open | Held _) | Some Context, Held _ -> snapshot

let panel_owner_matches snapshot ~current_owner ~context_search_owner =
  match snapshot.context_search with
  | Some owner -> current_owner = Some Context_search
      && context_search_owner = Some owner
  | None -> snapshot.panel_owner = current_owner

let panel_presentation_changed snapshot ~current_owner =
  snapshot.panel_owner <> current_owner || Option.is_some snapshot.context_search

let decide_snapshot_input snapshot ~external_surface ~current_owner
    ~context_search_owner input =
  if external_surface then Accept_input
  else if panel_owner_matches snapshot ~current_owner ~context_search_owner then
    decide_panel_input ~external_surface:false ~presented_owner:current_owner
      ~current_owner input
  else match input with
    | Action -> Reject_action
    | Paste -> Reject_paste
    | Protocol -> Accept_input

let initial ~approval ~presses ~panes ~reader ~panel_owner =
  { approval; presses; panes; reader; panel_owner; context_search = None;
    barrier = Open; recovery = No_rejected_recovery }

let presented previous ~approval ~presses ~panes ~reader ~panel_owner ~owner_changed ~input_pending =
  let barrier = match previous.barrier with
    | Held _ as held -> held
    | Open when owner_changed && input_pending ->
        Held { rejected_input = false; rejected_paste = false }
    | Open -> Open
  in
  { approval; presses; panes; reader; panel_owner; context_search = None;
    barrier; recovery = previous.recovery }

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
