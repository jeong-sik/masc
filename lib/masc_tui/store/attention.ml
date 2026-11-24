open Masc_tui_core
open Masc_tui_protocol

type payload =
  | Payload_tool_approval of Wire_work.held_tool_approval
  | Payload_gate of Wire_work.gate_pending
  | Payload_ask of Wire_work.ask_row
  | Payload_goal_confirmation of Wire_work.goal

type entry = {
  id : string;
  kind : Health.attention_kind;
  payload : payload;
  title : string;
  summary : string;
  keeper : string option;
  created_at_unix : float option;
}

type t = {
  items : entry list;
  triage_index : int;
  triage_scroll_offset : int;
  auto_advance : bool;
  in_flight_ids : string list;
}

let empty =
  {
    items = [];
    triage_index = 0;
    triage_scroll_offset = 0;
    auto_advance = true;
    in_flight_ids = [];
  }

let urgency_rank = function
  | Health.Held_tool_approval _ -> 400
  | Health.Pending_ask _ -> 300
  | Health.Goal_confirmation _ -> 200

let compare_opt_float a b =
  match a, b with
  | Some x, Some y -> Float.compare x y
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0

let compare_entry (a : entry) (b : entry) =
  let c_rank = Int.compare (urgency_rank b.kind) (urgency_rank a.kind) in
  if c_rank <> 0 then c_rank
  else
    let c_time = compare_opt_float a.created_at_unix b.created_at_unix in
    if c_time <> 0 then c_time else String.compare a.id b.id

let adjust_scroll = Store_scroll.adjust_scroll
let clamp_index = Store_scroll.clamp_index

let sort_and_dedup entries =
  let sorted = List.stable_sort compare_entry entries in
  let rec dedup seen acc = function
    | [] -> List.rev acc
    | (e : entry) :: rest ->
        if List.exists (String.equal e.id) seen then dedup seen acc rest
        else dedup (e.id :: seen) (e :: acc) rest
  in
  dedup [] [] sorted

let entry_of_tool_approval (ta : Wire_work.held_tool_approval) : entry =
  {
    id = "tool:" ^ ta.approval_id;
    kind =
      Health.Held_tool_approval
        { request_id = ta.approval_id; keeper = ta.keeper; tool = ta.tool };
    payload = Payload_tool_approval ta;
    title = ta.keeper ^ " · " ^ ta.tool;
    summary =
      if String.equal (String.trim ta.question) "" then ta.args_preview
      else ta.question;
    keeper = Some ta.keeper;
    created_at_unix = Some ta.asked_at;
  }

let entry_of_gate (g : Wire_work.gate_pending) : entry =
  let summary =
    match g.input_preview with
    | Some p when not (String.equal (String.trim p) "") -> p
    | Some _ | None -> g.phase
  in
  {
    id = "gate:" ^ g.id;
    kind =
      Health.Held_tool_approval
        { request_id = g.id; keeper = g.keeper; tool = g.tool_name };
    payload = Payload_gate g;
    title = g.keeper ^ " · " ^ g.tool_name;
    summary;
    keeper = Some g.keeper;
    created_at_unix = None;
  }

let entry_of_ask (a : Wire_work.ask_row) : entry option =
  match a.resolution with
  | Wire_work.Ask_answered _ | Wire_work.Ask_withdrawn _ -> None
  | Wire_work.Ask_open ->
      let summary =
        match a.questions with
        | q :: _ -> q.prompt
        | [] -> (
            match a.context with
            | Some c -> c
            | None -> a.ask_id)
      in
      Some
        {
          id = "ask:" ^ a.ask_id;
          kind = Health.Pending_ask { ask_id = a.ask_id; keeper = a.keeper };
          payload = Payload_ask a;
          title = a.keeper ^ " · Ask";
          summary;
          keeper = Some a.keeper;
          created_at_unix = Some a.asked_at;
        }

let entry_of_goal (g : Wire_work.goal) : entry option =
  match g.phase with
  | Wire_work.Awaiting_confirmation ->
      Some
        {
          id = "goal:" ^ g.id;
          kind = Health.Goal_confirmation { goal_id = g.id };
          payload = Payload_goal_confirmation g;
          title = g.title;
          summary = g.measure;
          keeper = None;
          created_at_unix = None;
        }
  | Wire_work.Executing
  | Wire_work.Verifying
  | Wire_work.Completed
  | Wire_work.Dropped
  | Wire_work.Paused _
  | Wire_work.Blocked _ ->
      None

let rebuild ~asks ~tool_approvals ~gate_pending ~goals t =
  let raw =
    List.map entry_of_tool_approval tool_approvals
    @ List.map entry_of_gate gate_pending
    @ List.filter_map entry_of_ask asks
    @ List.filter_map entry_of_goal goals
  in
  let items = sort_and_dedup raw in
  let present_ids = List.map (fun (e : entry) -> e.id) items in
  let in_flight_ids =
    List.filter
      (fun id -> List.exists (String.equal id) present_ids)
      t.in_flight_ids
  in
  let triage_index = clamp_index (List.length items) t.triage_index in
  let triage_scroll_offset =
    if items = [] then 0
    else adjust_scroll ~scroll:t.triage_scroll_offset triage_index
  in
  { t with items; triage_index; triage_scroll_offset; in_flight_ids }

let upsert_entry (e : entry) t =
  let filtered =
    List.filter (fun (x : entry) -> not (String.equal x.id e.id)) t.items
  in
  let items = sort_and_dedup (e :: filtered) in
  let triage_index = clamp_index (List.length items) t.triage_index in
  let triage_scroll_offset =
    if items = [] then 0
    else adjust_scroll ~scroll:t.triage_scroll_offset triage_index
  in
  { t with items; triage_index; triage_scroll_offset }

let remove_by_id id t =
  let items =
    List.filter (fun (x : entry) -> not (String.equal x.id id)) t.items
  in
  let in_flight_ids =
    List.filter (fun x -> not (String.equal x id)) t.in_flight_ids
  in
  let triage_index = clamp_index (List.length items) t.triage_index in
  let triage_scroll_offset =
    if items = [] then 0
    else adjust_scroll ~scroll:t.triage_scroll_offset triage_index
  in
  { t with items; triage_index; triage_scroll_offset; in_flight_ids }

let is_in_flight ~id t = List.exists (String.equal id) t.in_flight_ids

let mark_in_flight ~id t =
  if is_in_flight ~id t then t
  else { t with in_flight_ids = id :: t.in_flight_ids }

let clear_in_flight ~id t =
  {
    t with
    in_flight_ids =
      List.filter (fun x -> not (String.equal x id)) t.in_flight_ids;
  }

let clear_all_in_flight t =
  match t.in_flight_ids with
  | [] -> t
  | _ :: _ -> { t with in_flight_ids = [] }

let top_fast_path t =
  List.find_opt (fun (e : entry) -> not (is_in_flight ~id:e.id t)) t.items

let filtered_items ~query t =
  let q = String.trim query in
  if String.equal q "" then t.items
  else
    List.filter
      (fun (e : entry) ->
        Store_scroll.contains_ci ~needle:q e.title
        || Store_scroll.contains_ci ~needle:q e.summary
        || Store_scroll.contains_ci ~needle:q e.id
        ||
        match e.keeper with
        | Some k -> Store_scroll.contains_ci ~needle:q k
        | None -> false)
      t.items

let current_filtered_item ~query t =
  let xs = filtered_items ~query t in
  List.nth_opt xs (clamp_index (List.length xs) t.triage_index)

let current_triage_item t = current_filtered_item ~query:"" t

let move_triage ?(query = "") ?viewport_rows ~delta t =
  let len = List.length (filtered_items ~query t) in
  if len <= 0 then { t with triage_index = 0; triage_scroll_offset = 0 }
  else
    let triage_index = clamp_index len (t.triage_index + delta) in
    let triage_scroll_offset =
      adjust_scroll ?viewport_rows ~scroll:t.triage_scroll_offset triage_index
    in
    { t with triage_index; triage_scroll_offset }

let select_triage_index idx t =
  let len = List.length t.items in
  if len <= 0 then { t with triage_index = 0; triage_scroll_offset = 0 }
  else
    let triage_index = clamp_index len idx in
    let triage_scroll_offset =
      adjust_scroll ~scroll:t.triage_scroll_offset triage_index
    in
    { t with triage_index; triage_scroll_offset }

let set_auto_advance auto_advance t = { t with auto_advance }

let advance_after_resolution ~resolved_id t =
  let t' = remove_by_id resolved_id t in
  if t'.auto_advance then
    let len = List.length t'.items in
    { t' with triage_index = clamp_index len t'.triage_index }
  else t'

let count t = List.length t.items
let is_empty t = match t.items with [] -> true | _ :: _ -> false

let has_actionable_fast_path t = Option.is_some (top_fast_path t)
