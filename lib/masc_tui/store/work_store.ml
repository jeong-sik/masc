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

type task_status_filter =
  | Status_all
  | Status_active
  | Status_awaiting_verification
  | Status_todo
  | Status_unlinked
  | Status_done
  | Status_schedules

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
  verif_selected_index : int;
  verif_scroll_offset : int;
  detail_scroll_offset : int;
  pulse_goal_index : int;
  schedules_scroll_offset : int;
  filter_query : string;
  task_status_filter : task_status_filter;
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
    verif_selected_index = 0;
    verif_scroll_offset = 0;
    detail_scroll_offset = 0;
    pulse_goal_index = 0;
    schedules_scroll_offset = 0;
    filter_query = "";
    task_status_filter = Status_all;
    verification_view = `Pending;
    expanded_ids = String_set.empty;
  }

let contains_ci = Store_scroll.contains_ci
let clamp_index = Store_scroll.clamp_index

let set_tab active_tab t =
  {
    t with
    active_tab;
    selected_index = 0;
    scroll_offset = 0;
    verif_selected_index = 0;
    verif_scroll_offset = 0;
    detail_scroll_offset = 0;
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

let default_viewport_rows = Store_scroll.default_viewport_rows
let adjust_scroll = Store_scroll.adjust_scroll

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

let task_matches_status filter (tk : Wire_work.task) =
  match filter with
  | Status_all -> true
  | Status_schedules -> false
  | Status_active -> task_is_active tk.status
  | Status_awaiting_verification -> task_is_awaiting_verification tk.status
  | Status_todo -> (
      match tk.status with
      | Wire_work.Todo -> true
      | Wire_work.Claimed _
      | Wire_work.InProgress _
      | Wire_work.AwaitingVerification _
      | Wire_work.Done _
      | Wire_work.Cancelled _ ->
          false)
  | Status_unlinked -> (
      match tk.goal_link with
      | Wire_work.Unlinked -> true
      | Wire_work.Linked _ -> false)
  | Status_done -> task_is_done tk.status

let filtered_tasks t =
  let q = String.trim t.filter_query in
  List.filter
    (fun (task : Wire_work.task) ->
      task_matches_status t.task_status_filter task
      && (String.equal q ""
         || contains_ci ~needle:q task.title
         || contains_ci ~needle:q task.id))
    (tasks t)

let filtered_verifications t =
  let q = String.trim t.filter_query in
  let all = verifications_list t in
  if String.equal q "" then all
  else
    List.filter
      (fun (v : Wire_work.verification_request) ->
        contains_ci ~needle:q v.task_title
        || contains_ci ~needle:q v.task_id
        || contains_ci ~needle:q v.request_id
        || contains_ci ~needle:q v.submitted_by)
      all

let filtered_schedules t =
  let q_low = String.lowercase_ascii (String.trim t.filter_query) in
  let all =
    match t.task_status_filter with
    | Status_all | Status_schedules -> schedules_list t
    | Status_active
    | Status_awaiting_verification
    | Status_todo
    | Status_unlinked
    | Status_done ->
        []
  in
  if String.equal q_low "" then all
  else
    List.filter
      (fun (s : Wire_work.schedule_row) ->
        contains_ci ~needle:q_low s.schedule_id
        || contains_ci ~needle:q_low s.source
        || contains_ci ~needle:q_low s.recurrence_summary
        || (match s.payload_keeper_name with
            | Some k -> contains_ci ~needle:q_low k
            | None -> false)
        || (match s.payload_target with
            | Some tg -> contains_ci ~needle:q_low tg
            | None -> false)
        ||
        match s.payload_summary with
        | Some sm -> contains_ci ~needle:q_low sm
        | None -> false)
      all

let filtered_candle_balances t =
  let all =
    match Observed.to_option t.candle_ledger with
    | Some l -> l.balances
    | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then all
  else
    List.filter
      (fun (b : Wire_work.candle_balance_row) ->
        contains_ci ~needle:q b.keeper
        || List.exists (fun item -> contains_ci ~needle:q item) b.owned_items)
      all

let pulse_active_goals t =
  goals t
  |> List.filter (fun (g : Wire_work.goal) ->
         match g.phase with
         | Wire_work.Awaiting_confirmation
         | Wire_work.Verifying
         | Wire_work.Executing ->
             true
         | Wire_work.Completed
         | Wire_work.Dropped
         | Wire_work.Paused _
         | Wire_work.Blocked _ ->
             false)
  |> List.sort (fun (a : Wire_work.goal) (b : Wire_work.goal) ->
         let rank = function
           | Wire_work.Awaiting_confirmation -> 0
           | Wire_work.Verifying -> 1
           | Wire_work.Executing -> 2
           | Wire_work.Blocked _ -> 3
           | Wire_work.Paused _ -> 4
           | Wire_work.Completed -> 5
           | Wire_work.Dropped -> 6
         in
         let c = Int.compare (rank a.phase) (rank b.phase) in
         if c <> 0 then c else Int.compare a.priority b.priority)

let selected_pulse_goal t =
  let gs = pulse_active_goals t in
  List.nth_opt gs (clamp_index (List.length gs) t.pulse_goal_index)

let move_pulse_goal ?viewport_rows:_ ~delta t =
  let len = List.length (pulse_active_goals t) in
  let pulse_goal_index = clamp_index len (t.pulse_goal_index + delta) in
  { t with pulse_goal_index }

let selected_goal t =
  let gs = filtered_goals t in
  if t.selected_index < 0 then None else List.nth_opt gs t.selected_index

let selected_task t =
  let ts = filtered_tasks t in
  if t.selected_index < 0 then None else List.nth_opt ts t.selected_index

let selected_verification t =
  let vs = filtered_verifications t in
  if t.verif_selected_index < 0 then None
  else List.nth_opt vs (clamp_index (List.length vs) t.verif_selected_index)

let selected_schedule t =
  let ss = filtered_schedules t in
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

let reset_detail_scroll t = { t with detail_scroll_offset = 0 }

let jump_tasks_schedules_pane ~pane_index t =
  if not (Nav.equal_work_tab t.active_tab Nav.Work_tasks_schedules) then t
  else
    let n_tasks = List.length (filtered_tasks t) in
    let n_scheds = List.length (filtered_schedules t) in
    if pane_index = 1 && n_scheds > 0 then
      let selected_index =
        if t.selected_index >= n_tasks && t.selected_index < n_tasks + n_scheds
        then t.selected_index
        else n_tasks
      in
      let sched_idx = selected_index - n_tasks in
      let schedules_scroll_offset =
        adjust_scroll ~viewport_rows:7 ~scroll:t.schedules_scroll_offset sched_idx
      in
      { t with selected_index; schedules_scroll_offset }
    else if pane_index = 0 && n_tasks > 0 then
      let selected_index =
        if t.selected_index < n_tasks then t.selected_index else 0
      in
      let scroll_offset =
        adjust_scroll ~scroll:t.scroll_offset selected_index
      in
      { t with selected_index; scroll_offset }
    else t

let move_selection ?(pane_index = 0) ?(has_linked_card = true) ?viewport_rows
    ~delta t =
  match t.active_tab with
  | Nav.Work_pipeline -> (
      match pane_index with
      | 1 when has_linked_card ->
          let len = List.length (filtered_verifications t) in
          let verif_selected_index =
            clamp_index len (t.verif_selected_index + delta)
          in
          let verif_scroll_offset =
            adjust_scroll ?viewport_rows ~scroll:t.verif_scroll_offset
              verif_selected_index
          in
          { t with verif_selected_index; verif_scroll_offset }
      | 1 | 2 ->
          let detail_scroll_offset =
            Store_scroll.clamp_scroll ~max_scroll:120
              (t.detail_scroll_offset + delta)
          in
          { t with detail_scroll_offset }
      | _ ->
          let len = List.length (filtered_goals t) in
          let selected_index = clamp_index len (t.selected_index + delta) in
          let scroll_offset =
            adjust_scroll ?viewport_rows ~scroll:t.scroll_offset selected_index
          in
          let detail_scroll_offset =
            if Int.equal selected_index t.selected_index then
              t.detail_scroll_offset
            else 0
          in
          { t with selected_index; scroll_offset; detail_scroll_offset })
  | Nav.Work_tasks_schedules ->
      let n_tasks = List.length (filtered_tasks t) in
      let len = n_tasks + List.length (filtered_schedules t) in
      let selected_index = clamp_index len (t.selected_index + delta) in
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
  | Nav.Work_inbox ->
      if pane_index = 1 then
        let detail_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll:120
            (t.detail_scroll_offset + delta)
        in
        { t with detail_scroll_offset }
      else
        let len =
          List.length (open_asks t)
          + List.length (tool_approvals_list t)
          + List.length (gate_pending_list t)
        in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let scroll_offset =
          adjust_scroll ?viewport_rows ~scroll:t.scroll_offset selected_index
        in
        let detail_scroll_offset =
          if Int.equal selected_index t.selected_index then
            t.detail_scroll_offset
          else 0
        in
        { t with selected_index; scroll_offset; detail_scroll_offset }
  | Nav.Work_candle_scorecard ->
      let len = List.length (filtered_candle_balances t) in
      let selected_index = clamp_index len (t.selected_index + delta) in
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
    verif_selected_index = 0;
    verif_scroll_offset = 0;
    detail_scroll_offset = 0;
    schedules_scroll_offset = 0;
  }

let equal_task_status_filter a b =
  match a, b with
  | Status_all, Status_all
  | Status_active, Status_active
  | Status_awaiting_verification, Status_awaiting_verification
  | Status_todo, Status_todo
  | Status_unlinked, Status_unlinked
  | Status_done, Status_done
  | Status_schedules, Status_schedules ->
      true
  | ( ( Status_all
      | Status_active
      | Status_awaiting_verification
      | Status_todo
      | Status_unlinked
      | Status_done
      | Status_schedules ),
      _ ) ->
      false

let all_task_status_filters =
  [
    Status_all;
    Status_active;
    Status_awaiting_verification;
    Status_todo;
    Status_unlinked;
    Status_done;
    Status_schedules;
  ]

let set_task_status_filter task_status_filter t =
  {
    t with
    task_status_filter;
    selected_index = 0;
    scroll_offset = 0;
    detail_scroll_offset = 0;
    schedules_scroll_offset = 0;
  }

let cycle_task_status_filter t =
  let next =
    match t.task_status_filter with
    | Status_all -> Status_active
    | Status_active -> Status_awaiting_verification
    | Status_awaiting_verification -> Status_todo
    | Status_todo -> Status_unlinked
    | Status_unlinked -> Status_done
    | Status_done -> Status_schedules
    | Status_schedules -> Status_all
  in
  set_task_status_filter next t

let toggle_verification_view t =
  let verification_view =
    match t.verification_view with `Pending -> `All | `All -> `Pending
  in
  {
    t with
    verification_view;
    verifications = Observed.mark_stale t.verifications;
    verif_selected_index = 0;
    verif_scroll_offset = 0;
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
