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
  selected_id : string option;
  triage_index : int;
  triage_scroll_offset : int;
  auto_advance : bool;
  in_flight_ids : string list;
}

let empty =
  {
    items = [];
    selected_id = None;
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

let index_of_id id (xs : entry list) =
  let rec loop i = function
    | [] -> None
    | (e : entry) :: rest ->
        if String.equal e.id id then Some i else loop (i + 1) rest
  in
  loop 0 xs

let selected_index items t =
  match t.selected_id, items with
  | Some id, _ -> index_of_id id items
  | None, [] -> None
  | None, _ :: _ -> Some (clamp_index (List.length items) t.triage_index)

let position_selection ?viewport_rows t = function
  | None -> { t with triage_index = 0; triage_scroll_offset = 0 }
  | Some triage_index ->
      let triage_scroll_offset =
        adjust_scroll ?viewport_rows ~scroll:t.triage_scroll_offset triage_index
      in
      { t with triage_index; triage_scroll_offset }

let reanchor_unfiltered items t =
  position_selection { t with items } (selected_index items t)

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
  reanchor_unfiltered items { t with in_flight_ids }

let upsert_entry (e : entry) t =
  let filtered =
    List.filter (fun (x : entry) -> not (String.equal x.id e.id)) t.items
  in
  let items = sort_and_dedup (e :: filtered) in
  reanchor_unfiltered items t

let remove_by_id id t =
  let items =
    List.filter (fun (x : entry) -> not (String.equal x.id id)) t.items
  in
  let in_flight_ids =
    List.filter (fun x -> not (String.equal x id)) t.in_flight_ids
  in
  reanchor_unfiltered items { t with in_flight_ids }

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

let top_fast_path ?(query = "") t =
  List.find_opt
    (fun (e : entry) -> not (is_in_flight ~id:e.id t))
    (filtered_items ~query t)

let selected_index_in_filtered ~query t = selected_index (filtered_items ~query t) t

let current_filtered_item ~query t =
  let items = filtered_items ~query t in
  Option.bind (selected_index items t) (List.nth_opt items)

let current_triage_item t = current_filtered_item ~query:"" t

let sync_selection ~query t =
  position_selection t (selected_index_in_filtered ~query t)

let select_from_items ?viewport_rows idx items t =
  match List.nth_opt items idx with
  | None -> position_selection t None
  | Some entry ->
      position_selection ?viewport_rows { t with selected_id = Some entry.id }
        (Some idx)

let move_triage ?(query = "") ?viewport_rows ~delta t =
  let items = filtered_items ~query t in
  let index =
    match selected_index items t with
    | Some idx -> clamp_index (List.length items) (idx + delta)
    | None -> 0
  in
  select_from_items ?viewport_rows index items t

let select_triage_index ?(query = "") idx t =
  let items = filtered_items ~query t in
  select_from_items (clamp_index (List.length items) idx) items t

let set_auto_advance auto_advance t = { t with auto_advance }

let advance_past_in_flight ?(query = "") t =
  if not t.auto_advance then t
  else
    let xs = filtered_items ~query t in
    let len = List.length xs in
    match selected_index xs t with
    | None -> t
    | Some cur_idx -> (
        match List.nth_opt xs cur_idx with
        | Some cur when is_in_flight ~id:cur.id t -> (
            let rec find_next offset =
              if offset >= len then None
              else
                let idx = (cur_idx + offset) mod len in
                match List.nth_opt xs idx with
                | Some e when not (is_in_flight ~id:e.id t) -> Some idx
                | Some _ | None -> find_next (offset + 1)
            in
            match find_next 1 with
            | Some idx -> select_from_items idx xs t
            | None -> t)
        | Some _ | None -> t)

let advance_after_resolution ?(query = "") ~resolved_id t =
  let t =
    match current_filtered_item ~query t with
    | Some entry when String.equal entry.id resolved_id ->
        t |> mark_in_flight ~id:resolved_id |> advance_past_in_flight ~query
    | Some _ | None -> t
  in
  (* A matching action receipt can release the resolved selection even when
     an inventory refresh removed the row before its receipt arrived. *)
  let t =
    if t.auto_advance && Option.equal String.equal t.selected_id (Some resolved_id)
    then position_selection { t with selected_id = None } None
    else t
  in
  t |> remove_by_id resolved_id |> sync_selection ~query

let count t = List.length t.items
let is_empty t = match t.items with [] -> true | _ :: _ -> false

let has_actionable_fast_path t = Option.is_some (top_fast_path t)
