open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_set = Set.Make (String)

type decision_kind =
  | Decision_ask_answered
  | Decision_tool_approved
  | Decision_tool_denied
  | Decision_gate_approved
  | Decision_gate_rejected
  | Decision_goal_confirmed
  | Decision_verification_approved
  | Decision_verification_rejected

type decision_audit_entry = {
  at_unix : float;
  kind : decision_kind;
  target_id : string;
  keeper : string option;
  summary : string;
}

type t = {
  active_tab : Nav.work_tab;
  planning : Wire_work.planning_snapshot Observed.t;
  backlog_counts : Wire_work.task_backlog_counts option;
  verifications : Wire_work.verification_request list Observed.t;
  schedules : (Wire_work.schedule_row list * string option) Observed.t;
  asks : Wire_work.ask_row list Observed.t;
  tool_approvals : Wire_work.held_tool_approval list Observed.t;
  gate_pending : Wire_work.gate_pending list Observed.t;
  recent_decisions_24h : decision_audit_entry list;
  candle_ledger : Wire_work.candle_ledger Observed.t;
  candle_fallback_404 : bool;
  selected_index : int;
  scroll_offset : int;
  schedules_scroll_offset : int;
  filter_query : string;
  verification_view : [ `Pending | `All ];
  expanded_ids : String_set.t;
}

let max_recent_decisions = 100

let empty =
  {
    active_tab = Nav.Work_pipeline;
    planning = Observed.unreported;
    backlog_counts = None;
    verifications = Observed.unreported;
    schedules = Observed.unreported;
    asks = Observed.unreported;
    tool_approvals = Observed.unreported;
    gate_pending = Observed.unreported;
    recent_decisions_24h = [];
    candle_ledger = Observed.unreported;
    candle_fallback_404 = false;
    selected_index = 0;
    scroll_offset = 0;
    schedules_scroll_offset = 0;
    filter_query = "";
    verification_view = `Pending;
    expanded_ids = String_set.empty;
  }

let contains_ci ~needle haystack =
  let n_len = String.length needle in
  if n_len = 0 then true
  else
    let h_len = String.length haystack in
    if n_len > h_len then false
    else
      let n_low = String.lowercase_ascii needle in
      let h_low = String.lowercase_ascii haystack in
      let limit = h_len - n_len in
      let rec scan i =
        if i > limit then false
        else if String.equal (String.sub h_low i n_len) n_low then true
        else scan (i + 1)
      in
      scan 0

let clamp_index len idx =
  if len <= 0 then 0
  else if idx < 0 then 0
  else if idx >= len then len - 1
  else idx

let set_tab active_tab t =
  {
    t with
    active_tab;
    selected_index = 0;
    scroll_offset = 0;
    schedules_scroll_offset = 0;
  }

let cycle_tab dir t =
  let next_tab =
    match dir with
    | Keymap.Next -> Nav.next_work_tab t.active_tab
    | Keymap.Prev -> Nav.prev_work_tab t.active_tab
  in
  set_tab next_tab t

let apply_planning ~observed_at planning t =
  { t with planning = Observed.value ~observed_at planning }

let apply_backlog_counts counts t =
  { t with backlog_counts = Some counts }

let apply_verifications ~observed_at verifications t =
  { t with verifications = Observed.value ~observed_at verifications }

let apply_schedules ~observed_at schedules t =
  { t with schedules = Observed.value ~observed_at schedules }

let apply_asks ~observed_at asks t =
  { t with asks = Observed.value ~observed_at asks }

let apply_tool_approvals ~observed_at tool_approvals t =
  { t with tool_approvals = Observed.value ~observed_at tool_approvals }

let apply_gate_pending ~observed_at gate_pending t =
  { t with gate_pending = Observed.value ~observed_at gate_pending }

let apply_candle_ledger ~observed_at candle_ledger t =
  {
    t with
    candle_ledger = Observed.value ~observed_at candle_ledger;
    candle_fallback_404 = false;
  }

let apply_candle_ledger_fallback ~observed_at
    ~(summary : Wire_fleet.candle_summary_fallback option) ~balances t =
  let issued_milli, burned_milli, circulating_milli =
    match summary with
    | Some s -> (s.issued_milli, s.burned_milli, s.circulating_milli)
    | None -> ("0", "0", "0")
  in
  let balance_rows : Wire_work.candle_balance_row list =
    List.map
      (fun (keeper, balance_milli) ->
        {
          Wire_work.keeper;
          balance_milli;
          decayed_milli = "0";
          last_event_unix = None;
          owned_items = [];
        })
      balances
    |> List.sort (fun (a : Wire_work.candle_balance_row) b ->
           let c = Int.compare b.balance_milli a.balance_milli in
           if c <> 0 then c else String.compare a.keeper b.keeper)
  in
  let active_keepers =
    List.fold_left
      (fun n (r : Wire_work.candle_balance_row) ->
        if r.balance_milli > 0 then n + 1 else n)
      0 balance_rows
  in
  let ledger : Wire_work.candle_ledger =
    {
      ledger_state =
        (if Option.is_some summary || balance_rows <> [] then
           Wire_work.Ledger_present
        else Wire_work.Ledger_missing);
      total_events = 0;
      balance_error = None;
      policy_configuration = "fallback";
      pricing_mode = "fixed";
      disabled_reason = None;
      half_life_sec = None;
      issued_milli;
      burned_milli;
      circulating_milli;
      total_supply_milli = circulating_milli;
      active_keepers;
      diagnostics =
        {
          unattributed_count = 0;
          backlog_fenced_count = 0;
          zero_linked_tasks_goals = 0;
          held_windows_count = 0;
        };
      balances = balance_rows;
      recent_events = [];
    }
  in
  {
    t with
    candle_ledger = Observed.value ~observed_at ledger;
    candle_fallback_404 = true;
  }

let effective_task_counts t =
  match t.backlog_counts with
  | Some _ as c -> c
  | None -> (
      match Observed.to_option t.planning with
      | None -> None
      | Some p when p.tasks = [] -> None
      | Some p ->
          let todo = ref 0 in
          let claimed = ref 0 in
          let in_progress = ref 0 in
          let awaiting_verification = ref 0 in
          let done_total = ref 0 in
          let cancelled = ref 0 in
          List.iter
            (fun (task : Wire_work.task) ->
              match task.status with
              | Wire_work.Todo -> incr todo
              | Wire_work.Claimed _ -> incr claimed
              | Wire_work.InProgress _ -> incr in_progress
              | Wire_work.AwaitingVerification _ -> incr awaiting_verification
              | Wire_work.Done _ -> incr done_total
              | Wire_work.Cancelled _ -> incr cancelled)
            p.tasks;
          Some
            {
              Wire_work.todo = !todo;
              claimed = !claimed;
              in_progress = !in_progress;
              awaiting_verification = !awaiting_verification;
              done_total = !done_total;
              cancelled = !cancelled;
            })

let verification_pass_summary t =
  match Observed.to_option t.verifications with
  | None -> (0, 0, 0)
  | Some vs ->
      List.fold_left
        (fun (passed, rejected, awaiting) (v : Wire_work.verification_request) ->
          match v.review_observation with
          | Some { state = Wire_work.Review_approved; _ } ->
              (passed + 1, rejected, awaiting)
          | Some
              {
                state =
                  ( Wire_work.Review_rejected
                  | Wire_work.Review_failed
                  | Wire_work.Review_commit_failed );
                _;
              } ->
              (passed, rejected + 1, awaiting)
          | Some
              {
                state =
                  ( Wire_work.Review_unobserved
                  | Wire_work.Review_running
                  | Wire_work.Review_unavailable
                  | Wire_work.Review_not_reviewed
                  | Wire_work.Review_execution_pending
                  | Wire_work.Review_execution_repair_required
                  | Wire_work.Review_cancelled
                  | Wire_work.Review_superseded );
                _;
              }
          | None ->
              (passed, rejected, awaiting + 1))
        (0, 0, 0) vs

let record_decision ~at_unix ~kind ~target_id ~keeper ~summary t =
  let entry = { at_unix; kind; target_id; keeper; summary } in
  let recent_decisions_24h =
    List.take max_recent_decisions (entry :: t.recent_decisions_24h)
  in
  { t with recent_decisions_24h }

let goals t =
  match Observed.to_option t.planning with Some p -> p.goals | None -> []

let tasks t =
  match Observed.to_option t.planning with Some p -> p.tasks | None -> []

let verifications_list t =
  match Observed.to_option t.verifications with Some xs -> xs | None -> []

let schedules_list t =
  match Observed.to_option t.schedules with Some (rows, _) -> rows | None -> []

let asks_list t =
  match Observed.to_option t.asks with Some xs -> xs | None -> []

let open_asks t =
  List.filter
    (fun (a : Wire_work.ask_row) ->
      match a.resolution with
      | Wire_work.Ask_open -> true
      | Wire_work.Ask_answered _ | Wire_work.Ask_withdrawn _ -> false)
    (asks_list t)

let tool_approvals_list t =
  match Observed.to_option t.tool_approvals with Some xs -> xs | None -> []

let gate_pending_list t =
  match Observed.to_option t.gate_pending with Some xs -> xs | None -> []

let unlinked_task_count t =
  List.fold_left
    (fun acc (task : Wire_work.task) ->
      match task.goal_link with
      | Wire_work.Unlinked -> acc + 1
      | Wire_work.Linked _ -> acc)
    0 (tasks t)

let awaiting_confirmation_goals t =
  List.filter
    (fun (g : Wire_work.goal) ->
      match g.phase with
      | Wire_work.Awaiting_confirmation -> true
      | Wire_work.Executing
      | Wire_work.Verifying
      | Wire_work.Completed
      | Wire_work.Dropped
      | Wire_work.Paused _
      | Wire_work.Blocked _ ->
          false)
    (goals t)

let default_viewport_rows = 15

let adjust_scroll ?(viewport_rows = default_viewport_rows) ~scroll selected =
  let vr = max 1 viewport_rows in
  if selected < scroll then selected
  else if selected >= scroll + vr then max 0 (selected - vr + 1)
  else scroll

let task_is_active = function
  | Wire_work.Claimed _ | Wire_work.InProgress _
  | Wire_work.AwaitingVerification _ ->
      true
  | Wire_work.Todo | Wire_work.Done _ | Wire_work.Cancelled _ -> false

let task_is_done = function
  | Wire_work.Done _ -> true
  | Wire_work.Todo
  | Wire_work.Claimed _
  | Wire_work.InProgress _
  | Wire_work.AwaitingVerification _
  | Wire_work.Cancelled _ ->
      false

let task_is_awaiting_verification = function
  | Wire_work.AwaitingVerification _ -> true
  | Wire_work.Todo
  | Wire_work.Claimed _
  | Wire_work.InProgress _
  | Wire_work.Done _
  | Wire_work.Cancelled _ ->
      false

let filtered_goals t =
  let q = String.trim t.filter_query in
  if String.equal q "" then goals t
  else
    List.filter
      (fun (g : Wire_work.goal) ->
        contains_ci ~needle:q g.title
        || contains_ci ~needle:q g.id
        || contains_ci ~needle:q g.measure)
      (goals t)

let filtered_tasks t =
  let q_low = String.lowercase_ascii (String.trim t.filter_query) in
  let all = tasks t in
  if String.equal q_low "" then all
  else if String.equal q_low "schedules" || String.equal q_low "sched" then []
  else if String.equal q_low "active" then
    List.filter (fun (tk : Wire_work.task) -> task_is_active tk.status) all
  else if String.equal q_low "verify" then
    List.filter
      (fun (tk : Wire_work.task) -> task_is_awaiting_verification tk.status)
      all
  else if String.equal q_low "todo" then
    List.filter
      (fun (tk : Wire_work.task) ->
        match tk.status with
        | Wire_work.Todo -> true
        | Wire_work.Claimed _
        | Wire_work.InProgress _
        | Wire_work.AwaitingVerification _
        | Wire_work.Done _
        | Wire_work.Cancelled _ ->
            false)
      all
  else if String.equal q_low "unlinked" then
    List.filter
      (fun (tk : Wire_work.task) ->
        match tk.goal_link with
        | Wire_work.Unlinked -> true
        | Wire_work.Linked _ -> false)
      all
  else if String.equal q_low "done" then
    List.filter (fun (tk : Wire_work.task) -> task_is_done tk.status) all
  else
    List.filter
      (fun (task : Wire_work.task) ->
        contains_ci ~needle:q_low task.title || contains_ci ~needle:q_low task.id)
      all

let active_list_len ?(pane_index = 0) t =
  match t.active_tab with
  | Nav.Work_pipeline ->
      if Int.equal (pane_index mod 2) 1 then List.length (verifications_list t)
      else List.length (filtered_goals t)
  | Nav.Work_tasks_schedules ->
      List.length (filtered_tasks t) + List.length (schedules_list t)
  | Nav.Work_inbox ->
      List.length (open_asks t)
      + List.length (tool_approvals_list t)
      + List.length (gate_pending_list t)
  | Nav.Work_candle_scorecard -> (
      match Observed.to_option t.candle_ledger with
      | Some l -> List.length l.balances
      | None -> 0)

let selected_goal t =
  let gs = filtered_goals t in
  if t.selected_index < 0 then None else List.nth_opt gs t.selected_index

let selected_task t =
  let ts = filtered_tasks t in
  if t.selected_index < 0 then None else List.nth_opt ts t.selected_index

let selected_verification t =
  let vs = verifications_list t in
  if t.selected_index < 0 then None else List.nth_opt vs t.selected_index

let selected_schedule t =
  let ss = schedules_list t in
  let offset =
    match t.active_tab with
    | Nav.Work_tasks_schedules -> t.selected_index - List.length (filtered_tasks t)
    | Nav.Work_pipeline | Nav.Work_inbox | Nav.Work_candle_scorecard ->
        t.selected_index
  in
  if offset < 0 then None else List.nth_opt ss offset

let selected_open_ask t =
  let xs = open_asks t in
  if t.selected_index < 0 then None else List.nth_opt xs t.selected_index

let move_selection ?pane_index ?viewport_rows ~delta t =
  let len = active_list_len ?pane_index t in
  let selected_index = clamp_index len (t.selected_index + delta) in
  match t.active_tab with
  | Nav.Work_tasks_schedules ->
      let n_tasks = List.length (filtered_tasks t) in
      if selected_index < n_tasks then
        let scroll_offset =
          adjust_scroll ?viewport_rows ~scroll:t.scroll_offset selected_index
        in
        { t with selected_index; scroll_offset }
      else
        let sched_idx = selected_index - n_tasks in
        let sched_vr =
          if n_tasks = 0 then
            Option.value ~default:default_viewport_rows viewport_rows
          else
            match viewport_rows with
            | Some vr -> min 7 (max 2 vr)
            | None -> 7
        in
        let schedules_scroll_offset =
          adjust_scroll ~viewport_rows:sched_vr
            ~scroll:t.schedules_scroll_offset sched_idx
        in
        { t with selected_index; schedules_scroll_offset }
  | Nav.Work_pipeline | Nav.Work_inbox | Nav.Work_candle_scorecard ->
      let scroll_offset =
        adjust_scroll ?viewport_rows ~scroll:t.scroll_offset selected_index
      in
      { t with selected_index; scroll_offset }

let set_filter filter_query t =
  {
    t with
    filter_query;
    selected_index = 0;
    scroll_offset = 0;
    schedules_scroll_offset = 0;
  }

let toggle_verification_view t =
  let verification_view =
    match t.verification_view with `Pending -> `All | `All -> `Pending
  in
  {
    t with
    verification_view;
    verifications = Observed.mark_stale t.verifications;
    selected_index = 0;
  }

let toggle_expanded id t =
  let expanded_ids =
    if String_set.mem id t.expanded_ids then String_set.remove id t.expanded_ids
    else String_set.add id t.expanded_ids
  in
  { t with expanded_ids }

let mark_stale_all t =
  {
    t with
    planning = Observed.mark_stale t.planning;
    verifications = Observed.mark_stale t.verifications;
    schedules = Observed.mark_stale t.schedules;
    asks = Observed.mark_stale t.asks;
    tool_approvals = Observed.mark_stale t.tool_approvals;
    gate_pending = Observed.mark_stale t.gate_pending;
    candle_ledger = Observed.mark_stale t.candle_ledger;
  }
