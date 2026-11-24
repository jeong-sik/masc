open Masc_tui_core
module Q = Board_quarantine
module Keeper_map = Map.Make (String)

type outcome = Accepted | Rejected of string | Unconfirmed of string
type command = Idle | Submitting of Q.inventory_item | Result of Q.inventory_item * outcome
type entry = {
  generation : int;
  inventory : Q.inventory Observed.t;
  selected : Q.inventory_item option;
  command : command;
}
type t = { view : string option; keepers : entry Keeper_map.t }
let empty = { view = None; keepers = Keeper_map.empty }
let shown ~keeper t = Option.equal String.equal (Some keeper) t.view
let open_view ~keeper t = { t with view = Some keeper }
let close t = { t with view = None }
let entry ~keeper t = Option.value (Keeper_map.find_opt keeper t.keepers)
    ~default:{ generation = 0; inventory = Observed.unreported; selected = None; command = Idle }
let set ~keeper row t = { t with keepers = Keeper_map.add keeper row t.keepers }

let read ~keeper ~now t =
  let previous = entry ~keeper t in
  let generation = previous.generation + 1 in
  let inventory = Observed.loading ~since_ns:now in
  let next = set ~keeper { previous with generation; inventory } t in
  next, generation

let observe ~keeper ~generation inventory t =
  let previous = entry ~keeper t in
  if previous.generation <> generation then t
  else
    let selected =
      match previous.selected, Observed.to_option inventory with
      | None, Some { Q.items = first :: _; _ } -> Some first
      | selected, _ -> selected
    in
    set ~keeper { previous with inventory; selected } t

let selection_index e =
  match e.selected, Observed.to_option e.inventory with
  | Some selected, Some inventory -> List.find_index (Q.same_candidate selected) inventory.items
  | _ -> None

let move ~keeper ~direction ~page_rows t =
  let e = entry ~keeper t in
  match Observed.to_option e.inventory with
  | Some { Q.items = (_ :: _ as rows); _ } ->
      let current = selection_index e and length = List.length rows in
      let relative delta =
        Option.value current ~default:(if delta < 0 then length else -1) + delta in
      let index =
        match direction with
        | Masc_tui_keymap.Keymap.Up -> relative (-1) | Down -> relative 1
        | Page_up -> relative (-page_rows) | Page_down -> relative page_rows
        | Home -> 0 | End -> length - 1
        | Left | Right -> Option.value current ~default:0
      in
      let index = Store_scroll.clamp_index length index in
      set ~keeper { e with selected = List.nth_opt rows index } t
  | Some { Q.items = []; _ } | None -> t

let actionable e =
  match e.command with
  | Submitting _ -> None
  | Idle | Result _ ->
      if Observed.is_stale e.inventory then None
      else match Observed.to_option e.inventory, e.selected with
        | Some { Q.items; errors = [] }, Some selected ->
            List.find_opt (fun item -> Q.same_candidate selected item && Q.recoverable item.phase) items
        | Some _, (Some _ | None) | None, (Some _ | None) -> None

let start ~keeper t =
  let e = entry ~keeper t in
  Option.map (fun item -> set ~keeper { e with command = Submitting item } t, item)
    (actionable e)

let finish (item : Q.inventory_item) outcome t =
  let e = entry ~keeper:item.keeper_name t in
  match e.command with
  | Submitting expected when Q.same_candidate item expected ->
      set ~keeper:item.keeper_name { e with command = Result (item, outcome) } t
  | Idle | Submitting _ | Result _ -> t

let invalidate t = { t with keepers = Keeper_map.empty }
