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

type goal_phase_filter =
  | Goal_filter_all
  | Goal_filter_active
  | Goal_filter_verifying
  | Goal_filter_held
  | Goal_filter_closed

type goal_sort_mode =
  | Goal_sort_default
  | Goal_sort_phase
  | Goal_sort_progress
  | Goal_sort_recent

type verification_dive_tab =
  | Verif_tab_evidence
  | Verif_tab_summary
  | Verif_tab_specs
  | Verif_tab_tlc

type inbox_subview =
  | Inbox_queue
  | Inbox_rules
  | Inbox_history

type t = {
  active_tab : Nav.work_tab;
  inbox_subview : inbox_subview;
  planning : Wire_work.planning_snapshot Observed.t;
  backlog_counts : Wire_work.task_backlog_counts option;
  verifications : Wire_work.verification_request list Observed.t;
  harness_health : Wire_work.harness_health Observed.t;
  harness_selected_index : int;
  harness_scroll_offset : int;
  verification_evidence :
    (string * Wire_work.verification_evidence_bundle) Observed.t;
  verification_evidence_auth_denied : bool;
  verification_summary : Wire_work.verification_summary Observed.t;
  verification_specs : Wire_work.verification_specs Observed.t;
  verification_tlc_results : Wire_work.verification_tlc_results Observed.t;
  verification_dive_tab : verification_dive_tab;
  schedules : (Wire_work.schedule_row list * string option) Observed.t;
  asks : Wire_work.ask_row list Observed.t;
  tool_approvals : Wire_work.held_tool_approval list Observed.t;
  gate_pending : Wire_work.gate_pending list Observed.t;
  gate_snapshot : Wire_work.gate_snapshot Observed.t;
  tool_approval_modes : Wire_work.tool_approval_modes_snapshot Observed.t;
  tool_approval_modes_absent : bool;
  late_approval_attempts : Wire_work.late_approval_attempt list Observed.t;
  late_approval_absent : bool;
  late_approval_auth_denied : bool;
  recent_decisions_24h : decision_audit_entry list;
  candle_ledger : Wire_work.candle_ledger Observed.t;
  candle_fallback_404 : bool;
  selected_index : int;
  scroll_offset : int;
  rule_selected_index : int;
  rule_scroll_offset : int;
  history_selected_index : int;
  history_scroll_offset : int;
  verif_selected_index : int;
  verif_scroll_offset : int;
  detail_scroll_offset : int;
  ledger_scroll_offset : int;
  goal_dive_task_index : int;
  goal_dive_task_scroll : int;
  goal_dive_verif_index : int;
  goal_dive_verif_scroll : int;
  task_dive_desc_scroll : int;
  task_dive_verif_scroll : int;
  pulse_goal_index : int;
  schedules_scroll_offset : int;
  filter_query : string;
  goal_phase_filter : goal_phase_filter;
  goal_sort_mode : goal_sort_mode;
  task_status_filter : task_status_filter;
  verification_view : [ `Pending | `All ];
  expanded_ids : String_set.t;
}

let max_recent_decisions = 100

let empty =
  {
    active_tab = Nav.Work_pipeline;
    inbox_subview = Inbox_queue;
    planning = Observed.unreported;
    backlog_counts = None;
    verifications = Observed.unreported;
    harness_health = Observed.unreported;
    harness_selected_index = 0;
    harness_scroll_offset = 0;
    verification_evidence = Observed.unreported;
    verification_evidence_auth_denied = false;
    verification_summary = Observed.unreported;
    verification_specs = Observed.unreported;
    verification_tlc_results = Observed.unreported;
    verification_dive_tab = Verif_tab_evidence;
    schedules = Observed.unreported;
    asks = Observed.unreported;
    tool_approvals = Observed.unreported;
    gate_pending = Observed.unreported;
    gate_snapshot = Observed.unreported;
    tool_approval_modes = Observed.unreported;
    tool_approval_modes_absent = false;
    late_approval_attempts = Observed.unreported;
    late_approval_absent = false;
    late_approval_auth_denied = false;
    recent_decisions_24h = [];
    candle_ledger = Observed.unreported;
    candle_fallback_404 = false;
    selected_index = 0;
    scroll_offset = 0;
    rule_selected_index = 0;
    rule_scroll_offset = 0;
    history_selected_index = 0;
    history_scroll_offset = 0;
    verif_selected_index = 0;
    verif_scroll_offset = 0;
    detail_scroll_offset = 0;
    ledger_scroll_offset = 0;
    goal_dive_task_index = 0;
    goal_dive_task_scroll = 0;
    goal_dive_verif_index = 0;
    goal_dive_verif_scroll = 0;
    task_dive_desc_scroll = 0;
    task_dive_verif_scroll = 0;
    pulse_goal_index = 0;
    schedules_scroll_offset = 0;
    filter_query = "";
    goal_phase_filter = Goal_filter_all;
    goal_sort_mode = Goal_sort_default;
    task_status_filter = Status_all;
    verification_view = `All;
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
    rule_selected_index = 0;
    rule_scroll_offset = 0;
    history_selected_index = 0;
    history_scroll_offset = 0;
    verif_selected_index = 0;
    verif_scroll_offset = 0;
    detail_scroll_offset = 0;
    ledger_scroll_offset = 0;
    goal_dive_task_index = 0;
    goal_dive_task_scroll = 0;
    goal_dive_verif_index = 0;
    goal_dive_verif_scroll = 0;
    task_dive_desc_scroll = 0;
    task_dive_verif_scroll = 0;
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

(* Only a ready Candle carries a supply. An off Candle has no ledger, a
   disabled one failed to read its configuration, and no summary means the
   roster has not reported one yet; none of them becomes a 0/0/0 ledger. *)
let fallback_ledger ~(supply : Wire_fleet.candle_supply) ~balances :
    Wire_work.candle_ledger =
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
  {
    ledger_state = Wire_work.Ledger_present;
    total_events = 0;
    balance_error = None;
    policy_configuration = "fallback";
    pricing_mode = "fixed";
    disabled_reason = None;
    half_life_sec = None;
    issued_milli = supply.issued_milli;
    burned_milli = supply.burned_milli;
    circulating_milli = supply.circulating_milli;
    total_supply_milli = supply.circulating_milli;
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

let apply_candle_ledger_fallback ~observed_at
    ~(summary : Wire_fleet.candle_observation option) ~balances t =
  let candle_ledger =
    match summary with
    | Some (Wire_fleet.Candle_ready supply) ->
        Observed.value ~observed_at (fallback_ledger ~supply ~balances)
    | Some Wire_fleet.Candle_off -> Observed.absent
    | Some (Wire_fleet.Candle_disabled { reason }) ->
        Observed.failed
          ~reason:("Candle disabled: " ^ reason)
          ~retryable:false ~at:observed_at
    | None -> Observed.unreported
  in
  { t with candle_ledger; candle_fallback_404 = true }

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
          if Option.is_some v.evidence_projection_error then
            (passed, rejected + 1, awaiting)
          else
            match v.review_observation with
            | Some { state = Wire_work.Review_approved; _ } ->
                (passed + 1, rejected, awaiting)
            | Some
                {
                  state =
                    ( Wire_work.Review_rejected
                    | Wire_work.Review_failed
                    | Wire_work.Review_commit_failed
                    | Wire_work.Review_execution_repair_required );
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

let goal_matches_phase filter (g : Wire_work.goal) =
  match filter with
  | Goal_filter_all -> true
  | Goal_filter_active -> (
      match g.phase with
      | Wire_work.Executing -> true
      | Wire_work.Verifying
      | Wire_work.Awaiting_confirmation
      | Wire_work.Paused _
      | Wire_work.Blocked _
      | Wire_work.Completed
      | Wire_work.Dropped ->
          false)
  | Goal_filter_verifying -> (
      match g.phase with
      | Wire_work.Verifying | Wire_work.Awaiting_confirmation -> true
      | Wire_work.Executing
      | Wire_work.Paused _
      | Wire_work.Blocked _
      | Wire_work.Completed
      | Wire_work.Dropped ->
          false)
  | Goal_filter_held -> (
      match g.phase with
      | Wire_work.Paused _ | Wire_work.Blocked _ -> true
      | Wire_work.Executing
      | Wire_work.Verifying
      | Wire_work.Awaiting_confirmation
      | Wire_work.Completed
      | Wire_work.Dropped ->
          false)
  | Goal_filter_closed -> (
      match g.phase with
      | Wire_work.Completed | Wire_work.Dropped -> true
      | Wire_work.Executing
      | Wire_work.Verifying
      | Wire_work.Awaiting_confirmation
      | Wire_work.Paused _
      | Wire_work.Blocked _ ->
          false)

let goal_phase_rank = function
  | Wire_work.Awaiting_confirmation -> 0
  | Wire_work.Verifying -> 1
  | Wire_work.Executing -> 2
  | Wire_work.Blocked _ -> 3
  | Wire_work.Paused _ -> 4
  | Wire_work.Completed -> 5
  | Wire_work.Dropped -> 6

let goal_linked_tasks ~goal_id t =
  List.filter
    (fun (tk : Wire_work.task) ->
      match tk.goal_link with
      | Wire_work.Linked gid -> String.equal gid goal_id
      | Wire_work.Unlinked -> false)
    (tasks t)

let goal_linked_verifications ~goal_id t =
  let linked_ids =
    List.map (fun (tk : Wire_work.task) -> tk.id) (goal_linked_tasks ~goal_id t)
  in
  List.filter
    (fun (v : Wire_work.verification_request) ->
      List.exists (String.equal v.task_id) linked_ids)
    (verifications_list t)

let goal_progress_score t (g : Wire_work.goal) =
  let linked = goal_linked_tasks ~goal_id:g.id t in
  let total = List.length linked in
  if total > 0 then
    let done_n =
      List.fold_left
        (fun acc (tk : Wire_work.task) ->
          if task_is_done tk.status then acc + 1 else acc)
        0 linked
    in
    Float.of_int done_n /. Float.of_int total
  else
    match g.phase with
    | Wire_work.Completed -> 1.0
    | Wire_work.Awaiting_confirmation -> 0.85
    | Wire_work.Verifying -> 0.65
    | Wire_work.Executing -> 0.25
    | Wire_work.Paused _ | Wire_work.Blocked _ -> 0.1
    | Wire_work.Dropped -> 0.0

let goal_recency_key (g : Wire_work.goal) =
  match g.updated_at with
  | Some ts when not (String.equal (String.trim ts) "") -> ts
  | Some _ | None -> (
      match g.created_at with
      | Some ts when not (String.equal (String.trim ts) "") -> ts
      | Some _ | None -> "")

let filtered_goals t =
  let q = String.trim t.filter_query in
  let matched =
    List.filter
      (fun (g : Wire_work.goal) ->
        goal_matches_phase t.goal_phase_filter g
        && (String.equal q ""
           || contains_ci ~needle:q g.title
           || contains_ci ~needle:q g.id
           || contains_ci ~needle:q g.measure))
      (goals t)
  in
  match t.goal_sort_mode with
  | Goal_sort_default -> matched
  | Goal_sort_phase ->
      List.stable_sort
        (fun (a : Wire_work.goal) (b : Wire_work.goal) ->
          let c = Int.compare (goal_phase_rank a.phase) (goal_phase_rank b.phase) in
          if c <> 0 then c else Int.compare a.priority b.priority)
        matched
  | Goal_sort_progress ->
      List.stable_sort
        (fun (a : Wire_work.goal) (b : Wire_work.goal) ->
          let c = Float.compare (goal_progress_score t b) (goal_progress_score t a) in
          if c <> 0 then c else Int.compare a.priority b.priority)
        matched
  | Goal_sort_recent ->
      List.stable_sort
        (fun (a : Wire_work.goal) (b : Wire_work.goal) ->
          let c = String.compare (goal_recency_key b) (goal_recency_key a) in
          if c <> 0 then c else String.compare b.id a.id)
        matched

let task_matches_status filter (tk : Wire_work.task) =
  match filter with
  | Status_all -> true
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
  let all = schedules_list t in
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
  if t.selected_index < 0 then None else List.nth_opt ss t.selected_index

let selected_open_ask t =
  let xs = open_asks t in
  if t.selected_index < 0 then None else List.nth_opt xs t.selected_index

let reset_detail_scroll t = { t with detail_scroll_offset = 0 }

let move_selection ?(pane_index = 0) ?(has_linked_card = true) ?viewport_rows
    ?max_detail_scroll ~delta t =
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
          let max_scroll =
            match max_detail_scroll with
            | Some ms -> max 0 ms
            | None -> (
                match selected_goal t with
                | Some g ->
                    let vis =
                      max 1
                        (Option.value viewport_rows
                           ~default:default_viewport_rows)
                    in
                    let raw_lines =
                      List.length
                        (String.split_on_char '\n' (g.measure ^ "\n\n" ^ g.procedure))
                      + 6
                    in
                    max 0 (raw_lines - vis)
                | None -> 0)
          in
          let detail_scroll_offset =
            Store_scroll.clamp_scroll ~max_scroll
              (t.detail_scroll_offset + delta)
          in
          { t with detail_scroll_offset }
      | _ ->
          let len = List.length (filtered_goals t) in
          let selected_index = clamp_index len (t.selected_index + delta) in
          let scroll_offset =
            adjust_scroll ?viewport_rows ~scroll:t.scroll_offset selected_index
          in
          let changed = not (Int.equal selected_index t.selected_index) in
          let detail_scroll_offset =
            if changed then 0 else t.detail_scroll_offset
          in
          let base = { t with selected_index; scroll_offset; detail_scroll_offset } in
          if changed then
            {
              base with
              goal_dive_task_index = 0;
              goal_dive_task_scroll = 0;
              goal_dive_verif_index = 0;
              goal_dive_verif_scroll = 0;
            }
          else base)
  | Nav.Work_tasks ->
      if pane_index = 1 then
        let max_scroll =
          match max_detail_scroll with Some ms -> max 0 ms | None -> 0
        in
        let detail_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll (t.detail_scroll_offset + delta)
        in
        { t with detail_scroll_offset }
      else
        let len = List.length (filtered_tasks t) in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let scroll_offset =
          adjust_scroll ?viewport_rows ~scroll:t.scroll_offset selected_index
        in
        let changed = not (Int.equal selected_index t.selected_index) in
        let detail_scroll_offset =
          if changed then 0 else t.detail_scroll_offset
        in
        let base = { t with selected_index; scroll_offset; detail_scroll_offset } in
        if changed then
          { base with task_dive_desc_scroll = 0; task_dive_verif_scroll = 0 }
        else base
  | Nav.Work_schedules ->
      if pane_index = 1 then
        let max_scroll =
          match max_detail_scroll with Some ms -> max 0 ms | None -> 0
        in
        let detail_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll (t.detail_scroll_offset + delta)
        in
        { t with detail_scroll_offset }
      else
        let len = List.length (filtered_schedules t) in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let schedules_scroll_offset =
          adjust_scroll ?viewport_rows ~scroll:t.schedules_scroll_offset
            selected_index
        in
        let detail_scroll_offset =
          if Int.equal selected_index t.selected_index then
            t.detail_scroll_offset
          else 0
        in
        { t with selected_index; schedules_scroll_offset; detail_scroll_offset }
  | Nav.Work_inbox -> (
      if pane_index = 1 then
        let max_scroll =
          match max_detail_scroll with Some ms -> max 0 ms | None -> 0
        in
        let detail_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll
            (t.detail_scroll_offset + delta)
        in
        { t with detail_scroll_offset }
      else
        match t.inbox_subview with
        | Inbox_queue ->
            let len =
              List.length (open_asks t)
              + List.length (tool_approvals_list t)
              + List.length (gate_pending_list t)
            in
            let selected_index = clamp_index len (t.selected_index + delta) in
            let scroll_offset =
              adjust_scroll ?viewport_rows ~scroll:t.scroll_offset
                selected_index
            in
            let detail_scroll_offset =
              if Int.equal selected_index t.selected_index then
                t.detail_scroll_offset
              else 0
            in
            { t with selected_index; scroll_offset; detail_scroll_offset }
        | Inbox_rules ->
            let rules =
              match Observed.to_option t.gate_snapshot with
              | None -> []
              | Some snap ->
                  let q = String.trim t.filter_query in
                  if String.equal q "" then snap.rules
                  else
                    List.filter
                      (fun (r : Wire_work.gate_rule) ->
                        contains_ci ~needle:q r.id
                        || contains_ci ~needle:q r.keeper_name
                        || contains_ci ~needle:q r.tool_name
                        || contains_ci ~needle:q r.request_fingerprint)
                      snap.rules
            in
            let len = List.length rules in
            let rule_selected_index =
              clamp_index len (t.rule_selected_index + delta)
            in
            let rule_scroll_offset =
              adjust_scroll ?viewport_rows ~scroll:t.rule_scroll_offset
                rule_selected_index
            in
            {
              t with
              rule_selected_index;
              rule_scroll_offset;
              detail_scroll_offset = 0;
            }
        | Inbox_history ->
            let rows =
              match Observed.to_option t.gate_snapshot with
              | None -> []
              | Some snap ->
                  let q = String.trim t.filter_query in
                  if String.equal q "" then snap.recent_resolved
                  else
                    List.filter
                      (fun (r : Wire_work.gate_resolved_row) ->
                        contains_ci ~needle:q r.id
                        || contains_ci ~needle:q r.keeper
                        || contains_ci ~needle:q r.tool
                        || contains_ci ~needle:q r.decision)
                      snap.recent_resolved
            in
            let len = List.length rows in
            let history_selected_index =
              clamp_index len (t.history_selected_index + delta)
            in
            let history_scroll_offset =
              adjust_scroll ?viewport_rows ~scroll:t.history_scroll_offset
                history_selected_index
            in
            {
              t with
              history_selected_index;
              history_scroll_offset;
              detail_scroll_offset = 0;
            })
  | Nav.Work_candle_scorecard ->
      if pane_index = 1 then
        let max_scroll =
          match max_detail_scroll with Some ms -> max 0 ms | None -> 0
        in
        let ledger_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll (t.ledger_scroll_offset + delta)
        in
        { t with ledger_scroll_offset }
      else
        let len = List.length (filtered_candle_balances t) in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let scroll_offset =
          adjust_scroll ?viewport_rows ~scroll:t.scroll_offset selected_index
        in
        { t with selected_index; scroll_offset }
  | Nav.Work_harness ->
      if pane_index = 1 then
        let max_scroll =
          match max_detail_scroll with Some ms -> max 0 ms | None -> 0
        in
        let detail_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll
            (t.detail_scroll_offset + delta)
        in
        { t with detail_scroll_offset }
      else
        let verdicts =
          match Observed.to_option t.harness_health with
          | None -> []
          | Some hh ->
              let q = String.trim t.filter_query in
              if String.equal q "" then hh.recent_verdicts
              else
                List.filter
                  (fun (v : Wire_work.harness_verdict_row) ->
                    contains_ci ~needle:q v.task_id
                    || contains_ci ~needle:q v.task_title
                    || contains_ci ~needle:q v.agent_name
                    || contains_ci ~needle:q v.verdict
                    || contains_ci ~needle:q v.gate)
                  hh.recent_verdicts
        in
        let len = List.length verdicts in
        let harness_selected_index =
          clamp_index len (t.harness_selected_index + delta)
        in
        let harness_scroll_offset =
          adjust_scroll ?viewport_rows ~scroll:t.harness_scroll_offset
            harness_selected_index
        in
        let detail_scroll_offset =
          if Int.equal harness_selected_index t.harness_selected_index then
            t.detail_scroll_offset
          else 0
        in
        {
          t with
          harness_selected_index;
          harness_scroll_offset;
          detail_scroll_offset;
        }

let set_filter filter_query t =
  {
    t with
    filter_query;
    selected_index = 0;
    scroll_offset = 0;
    rule_selected_index = 0;
    rule_scroll_offset = 0;
    history_selected_index = 0;
    history_scroll_offset = 0;
    verif_selected_index = 0;
    verif_scroll_offset = 0;
    detail_scroll_offset = 0;
    ledger_scroll_offset = 0;
    schedules_scroll_offset = 0;
  }

let equal_task_status_filter a b =
  match a, b with
  | Status_all, Status_all
  | Status_active, Status_active
  | Status_awaiting_verification, Status_awaiting_verification
  | Status_todo, Status_todo
  | Status_unlinked, Status_unlinked
  | Status_done, Status_done ->
      true
  | ( ( Status_all
      | Status_active
      | Status_awaiting_verification
      | Status_todo
      | Status_unlinked
      | Status_done ),
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
  ]

let set_task_status_filter task_status_filter t =
  {
    t with
    task_status_filter;
    selected_index = 0;
    scroll_offset = 0;
    detail_scroll_offset = 0;
    ledger_scroll_offset = 0;
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
    | Status_done -> Status_all
  in
  set_task_status_filter next t

let equal_goal_phase_filter a b =
  match a, b with
  | Goal_filter_all, Goal_filter_all
  | Goal_filter_active, Goal_filter_active
  | Goal_filter_verifying, Goal_filter_verifying
  | Goal_filter_held, Goal_filter_held
  | Goal_filter_closed, Goal_filter_closed ->
      true
  | ( ( Goal_filter_all
      | Goal_filter_active
      | Goal_filter_verifying
      | Goal_filter_held
      | Goal_filter_closed ),
      _ ) ->
      false

let all_goal_phase_filters =
  [
    Goal_filter_all;
    Goal_filter_active;
    Goal_filter_verifying;
    Goal_filter_held;
    Goal_filter_closed;
  ]

let set_goal_phase_filter goal_phase_filter t =
  {
    t with
    goal_phase_filter;
    selected_index = 0;
    scroll_offset = 0;
    detail_scroll_offset = 0;
  }

let cycle_goal_phase_filter t =
  let next =
    match t.goal_phase_filter with
    | Goal_filter_all -> Goal_filter_active
    | Goal_filter_active -> Goal_filter_verifying
    | Goal_filter_verifying -> Goal_filter_held
    | Goal_filter_held -> Goal_filter_closed
    | Goal_filter_closed -> Goal_filter_all
  in
  set_goal_phase_filter next t

let equal_goal_sort_mode a b =
  match a, b with
  | Goal_sort_default, Goal_sort_default
  | Goal_sort_phase, Goal_sort_phase
  | Goal_sort_progress, Goal_sort_progress
  | Goal_sort_recent, Goal_sort_recent ->
      true
  | (Goal_sort_default | Goal_sort_phase | Goal_sort_progress | Goal_sort_recent), _ ->
      false

let set_goal_sort_mode goal_sort_mode t =
  { t with goal_sort_mode; selected_index = 0; scroll_offset = 0; detail_scroll_offset = 0 }

let cycle_goal_sort_mode t =
  let next =
    match t.goal_sort_mode with
    | Goal_sort_default -> Goal_sort_phase
    | Goal_sort_phase -> Goal_sort_progress
    | Goal_sort_progress -> Goal_sort_recent
    | Goal_sort_recent -> Goal_sort_default
  in
  set_goal_sort_mode next t

let selected_goal_dive_task ~goal_id t =
  let xs = goal_linked_tasks ~goal_id t in
  List.nth_opt xs (clamp_index (List.length xs) t.goal_dive_task_index)

let selected_goal_dive_verification ~goal_id t =
  let xs = goal_linked_verifications ~goal_id t in
  List.nth_opt xs (clamp_index (List.length xs) t.goal_dive_verif_index)

let reset_goal_dive_state t =
  {
    t with
    goal_dive_task_index = 0;
    goal_dive_task_scroll = 0;
    goal_dive_verif_index = 0;
    goal_dive_verif_scroll = 0;
  }

let select_goal_by_id ~goal_id t =
  let base0 = set_tab Nav.Work_pipeline t in
  let find_idx gs =
    let rec loop i = function
      | [] -> None
      | (g : Wire_work.goal) :: rest ->
          if String.equal g.id goal_id then Some i else loop (i + 1) rest
    in
    loop 0 gs
  in
  (* Filters are cleared only as far as needed to list the goal; a goal no
     view lists leaves the store untouched. *)
  let cleared = { base0 with filter_query = "" } in
  let candidates =
    [ base0; cleared; { cleared with goal_phase_filter = Goal_filter_all } ]
  in
  match
    List.find_map
      (fun b -> Option.map (fun idx -> (b, idx)) (find_idx (filtered_goals b)))
      candidates
  with
  | None -> Error `Not_listed
  | Some (base1, selected_index) ->
      let scroll_offset = adjust_scroll ~scroll:0 selected_index in
      Ok
        ({ base1 with selected_index; scroll_offset; detail_scroll_offset = 0 }
        |> reset_goal_dive_state)

let select_task_by_id ~task_id t =
  let base0 = set_tab Nav.Work_tasks t in
  let find_idx ts =
    let rec loop i = function
      | [] -> None
      | (tk : Wire_work.task) :: rest ->
          if String.equal tk.id task_id then Some i else loop (i + 1) rest
    in
    loop 0 ts
  in
  let cleared = { base0 with filter_query = "" } in
  let candidates =
    [ base0; cleared; { cleared with task_status_filter = Status_all } ]
  in
  match
    List.find_map
      (fun b -> Option.map (fun idx -> (b, idx)) (find_idx (filtered_tasks b)))
      candidates
  with
  | None -> Error `Not_listed
  | Some (base1, selected_index) ->
      let scroll_offset = adjust_scroll ~scroll:0 selected_index in
      Ok
        {
          base1 with
          selected_index;
          scroll_offset;
          detail_scroll_offset = 0;
          task_dive_desc_scroll = 0;
          task_dive_verif_scroll = 0;
        }

let move_goal_dive_task ~goal_id ?viewport_rows ~delta t =
  let len = List.length (goal_linked_tasks ~goal_id t) in
  if len <= 0 then
    { t with goal_dive_task_index = 0; goal_dive_task_scroll = 0 }
  else
    let goal_dive_task_index = clamp_index len (t.goal_dive_task_index + delta) in
    let goal_dive_task_scroll =
      adjust_scroll ?viewport_rows ~scroll:t.goal_dive_task_scroll
        goal_dive_task_index
    in
    { t with goal_dive_task_index; goal_dive_task_scroll }

let move_goal_dive_verif ~goal_id ?viewport_rows ~delta t =
  let len = List.length (goal_linked_verifications ~goal_id t) in
  if len <= 0 then
    { t with goal_dive_verif_index = 0; goal_dive_verif_scroll = 0 }
  else
    let goal_dive_verif_index = clamp_index len (t.goal_dive_verif_index + delta) in
    let goal_dive_verif_scroll =
      adjust_scroll ?viewport_rows ~scroll:t.goal_dive_verif_scroll
        goal_dive_verif_index
    in
    { t with goal_dive_verif_index; goal_dive_verif_scroll }

let verification_for_task ~task_id t =
  List.find_opt
    (fun (v : Wire_work.verification_request) -> String.equal v.task_id task_id)
    (verifications_list t)

let reset_task_dive_scroll t =
  { t with task_dive_desc_scroll = 0; task_dive_verif_scroll = 0 }

let scroll_task_dive_desc ~max_scroll ~delta t =
  let task_dive_desc_scroll =
    Store_scroll.clamp_scroll ~max_scroll (t.task_dive_desc_scroll + delta)
  in
  { t with task_dive_desc_scroll }

let scroll_task_dive_verif ~max_scroll ~delta t =
  let task_dive_verif_scroll =
    Store_scroll.clamp_scroll ~max_scroll (t.task_dive_verif_scroll + delta)
  in
  { t with task_dive_verif_scroll }

let harness_verdicts_list t =
  match Observed.to_option t.harness_health with
  | None -> []
  | Some hh -> hh.recent_verdicts

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
    harness_health = Observed.mark_stale t.harness_health;
    verification_evidence = Observed.mark_stale t.verification_evidence;
    verification_evidence_auth_denied = false;
    verification_summary = Observed.mark_stale t.verification_summary;
    verification_specs = Observed.mark_stale t.verification_specs;
    verification_tlc_results = Observed.mark_stale t.verification_tlc_results;
    schedules = Observed.mark_stale t.schedules;
    asks = Observed.mark_stale t.asks;
    tool_approvals = Observed.mark_stale t.tool_approvals;
    gate_pending = Observed.mark_stale t.gate_pending;
    gate_snapshot = Observed.mark_stale t.gate_snapshot;
    tool_approval_modes = Observed.mark_stale t.tool_approval_modes;
    tool_approval_modes_absent = false;
    late_approval_attempts = Observed.mark_stale t.late_approval_attempts;
    late_approval_absent = false;
    late_approval_auth_denied = false;
    candle_ledger = Observed.mark_stale t.candle_ledger;
  }

let verification_dive_tab_rank = function
  | Verif_tab_evidence -> 0
  | Verif_tab_summary -> 1
  | Verif_tab_specs -> 2
  | Verif_tab_tlc -> 3

let equal_verification_dive_tab a b =
  Int.equal (verification_dive_tab_rank a) (verification_dive_tab_rank b)

let set_verification_dive_tab verification_dive_tab t =
  { t with verification_dive_tab }

let cycle_verification_dive_tab t =
  let next =
    match t.verification_dive_tab with
    | Verif_tab_evidence -> Verif_tab_summary
    | Verif_tab_summary -> Verif_tab_specs
    | Verif_tab_specs -> Verif_tab_tlc
    | Verif_tab_tlc -> Verif_tab_evidence
  in
  set_verification_dive_tab next t

let apply_harness_health ~observed_at hh t =
  let len = List.length hh.Wire_work.recent_verdicts in
  {
    t with
    harness_health = Observed.value ~observed_at hh;
    harness_selected_index = clamp_index len t.harness_selected_index;
  }

let filtered_harness_verdicts t =
  match Observed.to_option t.harness_health with
  | None -> []
  | Some hh ->
      let q = String.trim t.filter_query in
      if String.equal q "" then hh.recent_verdicts
      else
        List.filter
          (fun (v : Wire_work.harness_verdict_row) ->
            contains_ci ~needle:q v.task_id
            || contains_ci ~needle:q v.task_title
            || contains_ci ~needle:q v.agent_name
            || contains_ci ~needle:q v.verdict
            || contains_ci ~needle:q v.gate)
          hh.recent_verdicts

let selected_harness_verdict t =
  let xs = filtered_harness_verdicts t in
  List.nth_opt xs (clamp_index (List.length xs) t.harness_selected_index)

let apply_verification_evidence ~observed_at ~verification_id bundle t =
  {
    t with
    verification_evidence = Observed.value ~observed_at (verification_id, bundle);
    verification_evidence_auth_denied = false;
  }

let mark_verification_evidence_denied ~at ~reason t =
  {
    t with
    verification_evidence = Observed.failed ~reason ~retryable:false ~at;
    verification_evidence_auth_denied = true;
  }

let verification_evidence_for ~verification_id t =
  match Observed.to_option t.verification_evidence with
  | Some (vid, bundle) when String.equal vid verification_id -> Some bundle
  | Some _ | None -> None

let apply_verification_summary ~observed_at summary t =
  { t with verification_summary = Observed.value ~observed_at summary }

let apply_verification_specs ~observed_at specs t =
  { t with verification_specs = Observed.value ~observed_at specs }

let apply_verification_tlc_results ~observed_at tlc t =
  { t with verification_tlc_results = Observed.value ~observed_at tlc }

let equal_inbox_subview a b =
  match (a, b) with
  | Inbox_queue, Inbox_queue
  | Inbox_rules, Inbox_rules
  | Inbox_history, Inbox_history ->
      true
  | Inbox_queue, (Inbox_rules | Inbox_history)
  | Inbox_rules, (Inbox_queue | Inbox_history)
  | Inbox_history, (Inbox_queue | Inbox_rules) ->
      false

let inbox_subview_rects (rect : Rect.t) =
  Rect.split_v rect ~top_h:(if rect.h >= 4 then 1 else 0)

let set_inbox_subview inbox_subview t =
  { t with inbox_subview; detail_scroll_offset = 0 }

let cycle_inbox_subview t =
  let next =
    match t.inbox_subview with
    | Inbox_queue -> Inbox_rules
    | Inbox_rules -> Inbox_history
    | Inbox_history -> Inbox_queue
  in
  set_inbox_subview next t

let apply_gate_snapshot ~observed_at (snap : Wire_work.gate_snapshot) t =
  let base =
    {
      t with
      gate_snapshot = Observed.value ~observed_at snap;
      gate_pending = Observed.value ~observed_at snap.pending;
    }
  in
  let q = String.trim base.filter_query in
  let filt_rules_len =
    if String.equal q "" then List.length snap.rules
    else
      List.length
        (List.filter
           (fun (r : Wire_work.gate_rule) ->
             contains_ci ~needle:q r.id
             || contains_ci ~needle:q r.keeper_name
             || contains_ci ~needle:q r.tool_name
             || contains_ci ~needle:q r.request_fingerprint)
           snap.rules)
  in
  let filt_hist_len =
    if String.equal q "" then List.length snap.recent_resolved
    else
      List.length
        (List.filter
           (fun (r : Wire_work.gate_resolved_row) ->
             contains_ci ~needle:q r.id
             || contains_ci ~needle:q r.keeper
             || contains_ci ~needle:q r.tool
             || contains_ci ~needle:q r.decision)
           snap.recent_resolved)
  in
  let rule_selected_index = clamp_index filt_rules_len base.rule_selected_index in
  let rule_scroll_offset =
    Int.min rule_selected_index (Int.max 0 base.rule_scroll_offset)
  in
  let history_selected_index =
    clamp_index filt_hist_len base.history_selected_index
  in
  let history_scroll_offset =
    Int.min history_selected_index (Int.max 0 base.history_scroll_offset)
  in
  {
    base with
    rule_selected_index;
    rule_scroll_offset;
    history_selected_index;
    history_scroll_offset;
  }

let apply_tool_approval_modes ~observed_at modes t =
  {
    t with
    tool_approval_modes = Observed.value ~observed_at modes;
    tool_approval_modes_absent = false;
  }

let apply_late_approval_attempts ~observed_at attempts t =
  {
    t with
    late_approval_attempts = Observed.value ~observed_at attempts;
    late_approval_absent = false;
    late_approval_auth_denied = false;
  }

let gate_rules_list t =
  match Observed.to_option t.gate_snapshot with
  | Some snap -> snap.rules
  | None -> []

let filtered_gate_rules t =
  let all = gate_rules_list t in
  let q = String.trim t.filter_query in
  if String.equal q "" then all
  else
    List.filter
      (fun (r : Wire_work.gate_rule) ->
        contains_ci ~needle:q r.id
        || contains_ci ~needle:q r.keeper_name
        || contains_ci ~needle:q r.tool_name
        || contains_ci ~needle:q r.request_fingerprint)
      all

let selected_gate_rule t =
  let xs = filtered_gate_rules t in
  List.nth_opt xs (clamp_index (List.length xs) t.rule_selected_index)

let gate_resolved_list t =
  match Observed.to_option t.gate_snapshot with
  | Some snap -> snap.recent_resolved
  | None -> []

let filtered_gate_resolved t =
  let all = gate_resolved_list t in
  let q = String.trim t.filter_query in
  if String.equal q "" then all
  else
    List.filter
      (fun (r : Wire_work.gate_resolved_row) ->
        contains_ci ~needle:q r.id
        || contains_ci ~needle:q r.keeper
        || contains_ci ~needle:q r.tool
        || contains_ci ~needle:q r.decision)
      all

let late_approval_attempts_list t =
  match Observed.to_option t.late_approval_attempts with
  | Some xs -> xs
  | None -> []

let retry_meta_for_id ~id t =
  match Observed.to_option t.gate_snapshot with
  | None -> None
  | Some snap ->
      List.find_opt
        (fun (m : Wire_work.gate_retry_meta) -> String.equal m.id id)
        snap.retry_meta

let hitl_status t =
  match Observed.to_option t.gate_snapshot with
  | Some snap -> snap.hitl
  | None -> None

let tool_approval_mode_for ~keeper t =
  match Observed.to_option t.tool_approval_modes with
  | None -> Wire_work.Approval_auto
  | Some snap -> (
      match List.assoc_opt keeper snap.overrides with
      | Some m -> m
      | None -> snap.default_mode)
