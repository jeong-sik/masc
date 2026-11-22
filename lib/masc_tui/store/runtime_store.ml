open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_map = Map.Make (String)

type fusion_draft = {
  keeper : string option;
  prompt : string;
  preset : string option;
  topology : Wire_runtime.fusion_topology option;
  web_tools : bool;
  submitting : bool;
}

type partitioned_accounts = {
  exhausted_and_credits : Wire_runtime.account_usage list;
  active_subscriptions : Wire_runtime.account_usage list;
  unreported : Wire_runtime.account_usage list;
}

type velocity_series_kind =
  | Velocity_tokens of (float * float * float) list
  | Velocity_calls_and_spend of (float * float * float) list
  | Velocity_tool_calls_and_p95 of (float * float * float) list
  | Velocity_empty

type keeper_spend_row = {
  keeper : string;
  company : string;
  calls : int;
  turns : int;
  input_tokens : int;
  output_tokens : int;
  cache_hit_pct : float Observed.t;
  cost_usd : float;
  cost_per_turn_usd : float option;
}

type company_spend_row = {
  company : string;
  keeper_count : int;
  calls : int;
  turns : int;
  cost_usd : float;
}

type company_spend_group = {
  company : string;
  total_cost_usd : float;
  members : keeper_spend_row list;
}

type t = {
  active_tab : Nav.runtime_tab;
  usage_windows : Wire_runtime.provider_usage_windows Observed.t;
  usage_history : Wire_runtime.provider_usage_history Observed.t;
  keeper_costs : Wire_runtime.keeper_costs_window Observed.t;
  efficiency : Wire_runtime.efficiency_month Observed.t;
  models_metrics : Wire_runtime.models_metrics_snapshot Observed.t;
  runtime_metrics : Wire_runtime.runtime_metrics_snapshot Observed.t;
  runtime_resolved : Wire_runtime.runtime_resolved_snapshot Observed.t;
  runtime_config_raw : Wire_runtime.runtime_config_raw_meta Observed.t;
  setup_inventory : Wire_runtime.setup_inventory Observed.t;
  setup_login_receipt : Wire_runtime.setup_login_receipt option;
  runtime_probe : Wire_runtime.runtime_probe_snapshot Observed.t;
  exact_lane_runs : Wire_runtime.exact_lane_run list Observed.t;
  fusion_runs : Wire_runtime.fusion_run list Observed.t;
  fusion_launch_draft : fusion_draft;
  tool_series : Wire_runtime.tool_series Observed.t;
  tools_catalog : Wire_runtime.tool_summary list Observed.t;
  connectors : Wire_runtime.connector_row list Observed.t;
  browser_lane : Wire_runtime.browser_lane_status Observed.t;
  mcp_clients : Wire_runtime.mcp_client_row list Observed.t;
  keeper_companies : string String_map.t;
  show_outside_lane_probes : bool;
  show_unreported_accounts : bool;
  selected_index : int;
  scroll_offset : int;
  quota_scroll_offset : int;
  connector_selected_index : int;
  connector_scroll_offset : int;
  detail_scroll_offset : int;
  filter_query : string;
}

let empty_fusion_draft =
  {
    keeper = None;
    prompt = "";
    preset = None;
    topology = None;
    web_tools = false;
    submitting = false;
  }

let empty =
  {
    active_tab = Nav.Runtime_quotas_credits;
    usage_windows = Observed.unreported;
    usage_history = Observed.unreported;
    keeper_costs = Observed.unreported;
    efficiency = Observed.unreported;
    models_metrics = Observed.unreported;
    runtime_metrics = Observed.unreported;
    runtime_resolved = Observed.unreported;
    runtime_config_raw = Observed.unreported;
    setup_inventory = Observed.unreported;
    setup_login_receipt = None;
    runtime_probe = Observed.unreported;
    exact_lane_runs = Observed.unreported;
    fusion_runs = Observed.unreported;
    fusion_launch_draft = empty_fusion_draft;
    tool_series = Observed.unreported;
    tools_catalog = Observed.unreported;
    connectors = Observed.unreported;
    browser_lane = Observed.unreported;
    mcp_clients = Observed.unreported;
    keeper_companies = String_map.empty;
    show_outside_lane_probes = false;
    show_unreported_accounts = false;
    selected_index = 0;
    scroll_offset = 0;
    quota_scroll_offset = 0;
    connector_selected_index = 0;
    connector_scroll_offset = 0;
    detail_scroll_offset = 0;
    filter_query = "";
  }

let contains_ci = Store_scroll.contains_ci
let adjust_grouped_scroll = Store_scroll.adjust_grouped_scroll
let clamp_index = Store_scroll.clamp_index

let set_tab active_tab t =
  {
    t with
    active_tab;
    selected_index = 0;
    scroll_offset = 0;
    quota_scroll_offset = 0;
    connector_selected_index = 0;
    connector_scroll_offset = 0;
    detail_scroll_offset = 0;
  }

let cycle_tab dir t =
  let next_tab =
    match dir with
    | Keymap.Next -> Nav.next_runtime_tab t.active_tab
    | Keymap.Prev -> Nav.prev_runtime_tab t.active_tab
  in
  set_tab next_tab t

let best_cache_hit_pct_of ~models_metrics ~runtime_metrics ~efficiency =
  let first_val xs =
    List.find_opt Observed.is_value xs
    |> Option.value ~default:Observed.unreported
  in
  let rt_pct =
    match Observed.to_option runtime_metrics with
    | Some (r : Wire_runtime.runtime_metrics_snapshot) -> r.fleet_cache_hit_pct
    | None -> Observed.unreported
  in
  let mdl_pct =
    match Observed.to_option models_metrics with
    | Some (m : Wire_runtime.models_metrics_snapshot) -> m.fleet_cache_hit_pct
    | None -> Observed.unreported
  in
  let eff_pct =
    match Observed.to_option efficiency with
    | Some (e : Wire_runtime.efficiency_month) -> e.fleet.fleet_cache_hit_pct
    | None -> Observed.unreported
  in
  first_val [ rt_pct; mdl_pct; eff_pct ]

let sync_efficiency_cache_pct t =
  let best =
    best_cache_hit_pct_of ~models_metrics:t.models_metrics
      ~runtime_metrics:t.runtime_metrics ~efficiency:t.efficiency
  in
  if not (Observed.is_value best) then t
  else
    let efficiency =
      Observed.map
        (fun (eff : Wire_runtime.efficiency_month) ->
          if Observed.is_value eff.fleet.fleet_cache_hit_pct then eff
          else
            {
              eff with
              fleet = { eff.fleet with fleet_cache_hit_pct = best };
            })
        t.efficiency
    in
    { t with efficiency }

let apply_usage_windows ~observed_at usage_windows t =
  { t with usage_windows = Observed.value ~observed_at usage_windows }

let apply_usage_history ~observed_at usage_history t =
  { t with usage_history = Observed.value ~observed_at usage_history }

let apply_keeper_costs ~observed_at keeper_costs t =
  { t with keeper_costs = Observed.value ~observed_at keeper_costs }

let apply_efficiency ~observed_at efficiency t =
  { t with efficiency = Observed.value ~observed_at efficiency }
  |> sync_efficiency_cache_pct

let apply_models_metrics ~observed_at models_metrics t =
  { t with models_metrics = Observed.value ~observed_at models_metrics }
  |> sync_efficiency_cache_pct

let apply_runtime_metrics ~observed_at runtime_metrics t =
  { t with runtime_metrics = Observed.value ~observed_at runtime_metrics }
  |> sync_efficiency_cache_pct

let apply_runtime_resolved ~observed_at (snap : Wire_runtime.runtime_resolved_snapshot) t =
  let usage_windows =
    match snap.usage_windows with
    | Some uw -> Observed.value ~observed_at uw
    | None -> t.usage_windows
  in
  {
    t with
    runtime_resolved = Observed.value ~observed_at snap;
    usage_windows;
  }

let apply_runtime_config_raw ~observed_at meta t =
  { t with runtime_config_raw = Observed.value ~observed_at meta }

let apply_setup_inventory ~observed_at inv t =
  { t with setup_inventory = Observed.value ~observed_at inv }

let apply_setup_login_receipt receipt t =
  { t with setup_login_receipt = Some receipt }

let apply_runtime_probe ~observed_at probe t =
  { t with runtime_probe = Observed.value ~observed_at probe }

let apply_exact_lane_runs ~observed_at runs t =
  { t with exact_lane_runs = Observed.value ~observed_at runs }

let apply_fusion_runs ~observed_at runs t =
  { t with fusion_runs = Observed.value ~observed_at runs }

let apply_tool_series ~observed_at series t =
  { t with tool_series = Observed.value ~observed_at series }

let apply_tools_catalog ~observed_at catalog t =
  { t with tools_catalog = Observed.value ~observed_at catalog }

let apply_connectors ~observed_at connectors t =
  { t with connectors = Observed.value ~observed_at connectors }

let apply_browser_lane ~observed_at lane t =
  { t with browser_lane = Observed.value ~observed_at lane }

let apply_mcp_clients ~observed_at clients t =
  { t with mcp_clients = Observed.value ~observed_at clients }

let active_and_outside_probes t =
  match
    Observed.to_option t.runtime_resolved, Observed.to_option t.runtime_probe
  with
  | Some resolved, Some probe ->
      Wire_runtime.partition_probe_by_active_lanes ~lanes:resolved.lanes probe
  | None, Some probe -> ([], probe.providers)
  | Some _, None | None, None -> ([], [])

let toggle_outside_lane_probes t =
  { t with show_outside_lane_probes = not t.show_outside_lane_probes }

let runtime_options t =
  match Observed.to_option t.runtime_resolved with
  | Some snap -> snap.runtimes
  | None -> []

let all_accounts t =
  match Observed.to_option t.usage_windows with
  | Some uw -> uw.accounts
  | None -> []

let account_display_name ?(lang = Say.Lang_ko) t acc =
  Wire_runtime.human_provider_label ~lang ~runtimes:(runtime_options t)
    ~all_accounts:(all_accounts t) acc

let max_subscription_pct (acc : Wire_runtime.account_usage) =
  match acc.state with
  | Wire_runtime.Account_reported windows ->
      List.fold_left
        (fun best (w : Wire_runtime.usage_window) ->
          let pct =
            match w.utilization with
            | Wire_runtime.Util_fraction f -> f *. 100.0
            | Wire_runtime.Util_percent p -> Float.of_int p
            | Wire_runtime.Util_credit_unlimited -> 0.0
            | Wire_runtime.Util_usd _
            | Wire_runtime.Util_credit_balance _
            | Wire_runtime.Util_credit_retracted ->
                -1.0
          in
          Float.max best pct)
        0.0 windows
  | Wire_runtime.Account_not_reported_since_start
  | Wire_runtime.Account_reported_no_windows _ ->
      0.0

let credit_remaining_ratio (acc : Wire_runtime.account_usage) =
  match acc.state with
  | Wire_runtime.Account_reported windows ->
      List.find_map
        (fun (w : Wire_runtime.usage_window) ->
          match w.utilization with
          | Wire_runtime.Util_credit_balance { total = Some tot; remaining; _ }
            when tot > 0.0 ->
              Some (remaining /. tot)
          | Wire_runtime.Util_credit_balance { total = None; remaining; _ } ->
              Some (if remaining <= 0.0 then 0.0 else 1.0)
          | Wire_runtime.Util_credit_balance { total = Some _; remaining; _ } ->
              Some (if remaining <= 0.0 then 0.0 else 1.0)
          | Wire_runtime.Util_usd { used; limit = Some lim } when lim > 0.0 ->
              Some (Float.max 0.0 ((lim -. used) /. lim))
          | Wire_runtime.Util_usd _
          | Wire_runtime.Util_fraction _
          | Wire_runtime.Util_percent _
          | Wire_runtime.Util_credit_unlimited
          | Wire_runtime.Util_credit_retracted ->
              None)
        windows
      |> Option.value ~default:1.0
  | Wire_runtime.Account_not_reported_since_start
  | Wire_runtime.Account_reported_no_windows _ ->
      1.0

let filtered_accounts t =
  let all = all_accounts t in
  let q = String.trim t.filter_query in
  if String.equal q "" then all
  else
    List.filter
      (fun (acc : Wire_runtime.account_usage) ->
        List.exists
          (fun (p : Wire_runtime.usage_provider_ref) ->
            contains_ci ~needle:q p.id || contains_ci ~needle:q p.display_name)
          acc.providers
        || contains_ci ~needle:q acc.scope
        || contains_ci ~needle:q acc.scope_id
        || contains_ci ~needle:q (account_display_name t acc))
      all

let partition_accounts t =
  let accounts = filtered_accounts t in
  let credits = ref [] in
  let subs = ref [] in
  let unreported = ref [] in
  List.iter
    (fun (acc : Wire_runtime.account_usage) ->
      match acc.cost_state with
      | Format_val.Exhausted_zero | Format_val.Amount _ ->
          credits := acc :: !credits
      | Format_val.Subscription_zero -> subs := acc :: !subs
      | Format_val.Unreported -> unreported := acc :: !unreported)
    accounts;
  let sort_credits =
    List.stable_sort
      (fun (a : Wire_runtime.account_usage) (b : Wire_runtime.account_usage) ->
        let rank (x : Wire_runtime.account_usage) =
          match x.cost_state with
          | Format_val.Exhausted_zero -> 0
          | Format_val.Amount _ -> 1
          | Format_val.Subscription_zero -> 2
          | Format_val.Unreported -> 3
        in
        let r = Int.compare (rank a) (rank b) in
        if r <> 0 then r
        else
          let cr =
            Float.compare (credit_remaining_ratio a) (credit_remaining_ratio b)
          in
          if cr <> 0 then cr
          else
            let amount_of = function
              | Format_val.Amount v -> Some v
              | Format_val.Exhausted_zero | Format_val.Subscription_zero
              | Format_val.Unreported ->
                  None
            in
            match (amount_of a.cost_state, amount_of b.cost_state) with
            | Some va, Some vb -> Float.compare va vb
            | Some _, None | None, Some _ | None, None ->
                String.compare a.scope b.scope)
      (List.rev !credits)
  in
  let sort_subs =
    List.stable_sort
      (fun (a : Wire_runtime.account_usage) (b : Wire_runtime.account_usage) ->
        let c =
          Float.compare (max_subscription_pct b) (max_subscription_pct a)
        in
        if c <> 0 then c else String.compare a.scope b.scope)
      (List.rev !subs)
  in
  let sort_unrep =
    List.stable_sort
      (fun (a : Wire_runtime.account_usage) (b : Wire_runtime.account_usage) ->
        String.compare (account_display_name t a) (account_display_name t b))
      (List.rev !unreported)
  in
  {
    exhausted_and_credits = sort_credits;
    active_subscriptions = sort_subs;
    unreported = sort_unrep;
  }

let visible_credit_accounts t =
  let p = partition_accounts t in
  if t.show_unreported_accounts then
    p.exhausted_and_credits @ p.active_subscriptions @ p.unreported
  else p.exhausted_and_credits @ p.active_subscriptions

let is_unreported_toggle_row_selected t =
  let p = partition_accounts t in
  p.unreported <> []
  &&
  let header_idx =
    List.length p.exhausted_and_credits + List.length p.active_subscriptions
  in
  Int.equal t.selected_index header_idx

let effective_cache_hit_pct t =
  best_cache_hit_pct_of ~models_metrics:t.models_metrics
    ~runtime_metrics:t.runtime_metrics ~efficiency:t.efficiency

type spend_24h_source =
  | Spend_provider_24h
  | Spend_keeper_turns_24h
  | Spend_unreported

type spend_24h_breakdown = {
  source : spend_24h_source;
  total_usd : float Observed.t;
  provider_usd : float Observed.t;
  keeper_attributed_usd : float Observed.t;
  system_unattributed_usd : float option;
}

type spend_table_window =
  | Spend_window_mtd of { month : string; days_covered : int }
  | Spend_window_month_complete of { month : string; days_covered : int }
  | Spend_window_24h of { window_minutes : int }
  | Spend_window_none

let provider_spend_24h_usd t =
  match Observed.to_option t.models_metrics with
  | Some m when Observed.is_value m.fleet_cost_usd -> m.fleet_cost_usd
  | Some _ | None -> (
      match Observed.to_option t.runtime_metrics with
      | Some r when Observed.is_value r.fleet_cost_usd -> r.fleet_cost_usd
      | Some _ | None -> Observed.unreported)

let keeper_attributed_spend_24h_usd t =
  match t.keeper_costs with
  | Observed.Value { data; observed_at; _ } ->
      let sum, seen =
        List.fold_left
          (fun (acc, any) (row : Wire_runtime.keeper_cost_row) ->
            match Observed.to_option row.total_cost_usd with
            | Some c when Float.is_finite c -> (acc +. c, true)
            | Some _ | None -> (acc, any))
          (0.0, false) data.rows
      in
      if seen then Observed.value ~observed_at sum else Observed.unreported
  | Observed.Loading _ | Observed.Absent | Observed.Unreported
  | Observed.Failed _ ->
      Observed.unreported

let effective_spend_24h_usd t =
  let prov = provider_spend_24h_usd t in
  if Observed.is_value prov then prov else keeper_attributed_spend_24h_usd t

let spend_24h_breakdown t =
  let provider_usd = provider_spend_24h_usd t in
  let keeper_attributed_usd = keeper_attributed_spend_24h_usd t in
  let source, total_usd =
    if Observed.is_value provider_usd then (Spend_provider_24h, provider_usd)
    else if Observed.is_value keeper_attributed_usd then
      (Spend_keeper_turns_24h, keeper_attributed_usd)
    else (Spend_unreported, Observed.unreported)
  in
  let system_unattributed_usd =
    match
      (Observed.to_option provider_usd, Observed.to_option keeper_attributed_usd)
    with
    | Some p, Some k when Float.is_finite p && Float.is_finite k && p > k +. 0.005
      ->
        Some (p -. k)
    | _ -> None
  in
  {
    source;
    total_usd;
    provider_usd;
    keeper_attributed_usd;
    system_unattributed_usd;
  }

let keeper_spend_table_window t =
  match Observed.to_option t.efficiency with
  | Some eff when eff.keepers <> [] -> (
      match eff.window_kind with
      | Some Wire_runtime.Efficiency_month_complete ->
          Spend_window_month_complete
            { month = eff.month; days_covered = eff.days_covered }
      | Some Wire_runtime.Efficiency_month_mtd | None ->
          Spend_window_mtd
            { month = eff.month; days_covered = eff.days_covered })
  | Some _ | None -> (
      match Observed.to_option t.keeper_costs with
      | Some kc when kc.rows <> [] ->
          Spend_window_24h { window_minutes = kc.window_minutes }
      | Some _ | None -> Spend_window_none)

let tool_series_totals t =
  match Observed.to_option t.tool_series with
  | None -> None
  | Some ts ->
      let calls, fails, latest_p95 =
        List.fold_left
          (fun (c, f, p95) (b : Wire_runtime.tool_series_bucket) ->
            match b.activity with
            | Wire_runtime.Series_idle -> (c, f, p95)
            | Wire_runtime.Series_active { calls = bc; failures = bf; p95_ms; _ } ->
                (c + bc, f + bf, Some p95_ms))
          (0, 0, None) ts.buckets
      in
      Some (calls, fails, latest_p95)

let cache_hit_series_24h t =
  let from_buckets (buckets : Wire_runtime.aggregated_metrics_bucket list) =
    List.map
      (fun (b : Wire_runtime.aggregated_metrics_bucket) ->
        (b.ts_start, b.cache_hit_pct))
      buckets
  in
  match Observed.to_option t.models_metrics with
  | Some m when m.hourly_buckets <> [] -> from_buckets m.hourly_buckets
  | Some _ | None -> (
      match Observed.to_option t.runtime_metrics with
      | Some r when r.hourly_buckets <> [] -> from_buckets r.hourly_buckets
      | Some _ | None -> [])

let velocity_series_24h t =
  let token_pts_of_eff (eff : Wire_runtime.efficiency_month) =
    List.filter_map
      (fun (s : Wire_runtime.token_velocity_sample) ->
        match
          ( Observed.to_option s.input_tok_per_min
          , Observed.to_option s.output_tok_per_min )
        with
        | Some inp, Some outp ->
            let cr = Option.value ~default:0.0 (Observed.to_option s.cache_read_tok_per_min) in
            Some (s.at_unix, Float.max inp cr, outp)
        | _ -> None)
      eff.velocity
  in
  let from_eff =
    match Observed.to_option t.efficiency with
    | Some eff -> token_pts_of_eff eff
    | None -> []
  in
  if from_eff <> [] then Velocity_tokens from_eff
  else
    let buckets =
      match Observed.to_option t.models_metrics with
      | Some m when m.hourly_buckets <> [] -> m.hourly_buckets
      | Some _ | None -> (
          match Observed.to_option t.runtime_metrics with
          | Some r -> r.hourly_buckets
          | None -> [])
    in
    let token_pts_of_buckets =
      List.filter_map
        (fun (b : Wire_runtime.aggregated_metrics_bucket) ->
          match (b.input_tokens, b.output_tokens) with
          | Some inp, Some outp ->
              Some (b.ts_start, Float.of_int inp, Float.of_int outp)
          | _ -> None)
        buckets
    in
    if token_pts_of_buckets <> [] then Velocity_tokens token_pts_of_buckets
    else if buckets <> [] then
      Velocity_calls_and_spend
        (List.map
           (fun (b : Wire_runtime.aggregated_metrics_bucket) ->
             (b.ts_start, Float.of_int b.entry_count, b.total_cost_usd))
           buckets)
    else
      match Observed.to_option t.tool_series with
      | Some ts when ts.buckets <> [] ->
          Velocity_tool_calls_and_p95
            (List.map
               (fun (b : Wire_runtime.tool_series_bucket) ->
                 match b.activity with
                 | Wire_runtime.Series_idle -> (b.start_unix, 0.0, 0.0)
                 | Wire_runtime.Series_active { calls; p95_ms; _ } ->
                     (b.start_unix, Float.of_int calls, p95_ms))
               ts.buckets)
      | Some _ | None -> Velocity_empty

let sync_keeper_companies (ks : Wire_fleet.keeper_summary list) t =
  let grouped = Wire_fleet.group_by_company ks in
  let resolved = Hashtbl.create (max 16 (List.length ks)) in
  List.iter
    (fun (g : Wire_fleet.company_group) ->
      List.iter
        (fun (k : Wire_fleet.keeper_summary) ->
          Hashtbl.replace resolved k.name g.company)
        g.keepers)
    grouped;
  let keeper_companies =
    List.fold_left
      (fun acc (k : Wire_fleet.keeper_summary) ->
        let from_group = Hashtbl.find_opt resolved k.name in
        let raw_c = String.trim k.company in
        let has_explicit_company =
          (not (String.equal raw_c ""))
          && (not (String.equal (String.lowercase_ascii raw_c) "ungrouped"))
          && not (String.equal raw_c "Other")
        in
        let comp =
          match from_group with
          | Some g when not (String.equal g "Other") -> g
          | Some _ | None ->
              if has_explicit_company then raw_c else "Other"
        in
        String_map.add k.name comp acc)
      String_map.empty ks
  in
  { t with keeper_companies }

let keeper_costs_24h_assoc t =
  match Observed.to_option t.keeper_costs with
  | None -> []
  | Some kc ->
      List.filter_map
        (fun (r : Wire_runtime.keeper_cost_row) ->
          match Observed.to_option r.total_cost_usd with
          | Some c -> Some (r.keeper_name, c)
          | None -> None)
        kc.rows

let compare_keeper_spend (a : keeper_spend_row) (b : keeper_spend_row) =
  let c = Float.compare b.cost_usd a.cost_usd in
  if c <> 0 then c
  else
    let cc = Int.compare b.calls a.calls in
    if cc <> 0 then cc else String.compare a.keeper b.keeper

let keeper_spend_rows t : keeper_spend_row list =
  let company_of name =
    match String_map.find_opt name t.keeper_companies with
    | Some c -> c
    | None ->
        Option.value ~default:"Other"
          (Wire_fleet.classify_company_single ~group:None name)
  in
  let raw =
    match Observed.to_option t.efficiency with
    | Some eff when eff.keepers <> [] ->
        List.map
          (fun (k : Wire_runtime.keeper_efficiency_row) : keeper_spend_row ->
            {
              keeper = k.keeper;
              company = company_of k.keeper;
              calls = k.calls;
              turns = k.turns;
              input_tokens = k.input_tokens;
              output_tokens = k.output_tokens;
              cache_hit_pct = k.cache_hit_pct;
              cost_usd = k.cost_usd;
              cost_per_turn_usd =
                (if k.turns > 0 then Some (k.cost_usd /. Float.of_int k.turns)
                else None);
            })
          eff.keepers
        |> List.stable_sort compare_keeper_spend
    | Some _ | None -> (
        match Observed.to_option t.keeper_costs with
        | None -> []
        | Some kc ->
            List.map
              (fun (r : Wire_runtime.keeper_cost_row) : keeper_spend_row ->
                let cost_usd =
                  Option.value ~default:0.0 (Observed.to_option r.total_cost_usd)
                in
                let tok =
                  Option.value ~default:0 (Observed.to_option r.total_tokens)
                in
                {
                  keeper = r.keeper_name;
                  company = company_of r.keeper_name;
                  calls = r.sample_count;
                  turns = r.sample_count;
                  input_tokens = tok;
                  output_tokens = 0;
                  cache_hit_pct = Observed.unreported;
                  cost_usd;
                  cost_per_turn_usd =
                    (if r.sample_count > 0 then
                       Some (cost_usd /. Float.of_int r.sample_count)
                    else None);
                })
              kc.rows
            |> List.stable_sort compare_keeper_spend)
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then raw
  else
    List.filter
      (fun (r : keeper_spend_row) ->
        contains_ci ~needle:q r.keeper || contains_ci ~needle:q r.company)
      raw

let grouped_keeper_spend_rows t : company_spend_group list =
  let rows = keeper_spend_rows t in
  let comp_tbl : (string, keeper_spend_row list) Hashtbl.t = Hashtbl.create 8 in
  List.iter
    (fun (r : keeper_spend_row) ->
      let prev =
        match Hashtbl.find_opt comp_tbl r.company with Some xs -> xs | None -> []
      in
      Hashtbl.replace comp_tbl r.company (r :: prev))
    rows;
  Hashtbl.fold
    (fun company rev_members acc ->
      let members = List.stable_sort compare_keeper_spend (List.rev rev_members) in
      let total_cost_usd =
        List.fold_left
          (fun s (m : keeper_spend_row) -> s +. m.cost_usd)
          0.0 members
      in
      { company; total_cost_usd; members } :: acc)
    comp_tbl []
  |> List.sort (fun (a : company_spend_group) (b : company_spend_group) ->
         let c = Float.compare b.total_cost_usd a.total_cost_usd in
         if c <> 0 then c else String.compare a.company b.company)

let keeper_spend_display_rows t : keeper_spend_row list =
  List.concat_map
    (fun (g : company_spend_group) -> g.members)
    (grouped_keeper_spend_rows t)

let selected_keeper_spend_row t =
  let rows = keeper_spend_display_rows t in
  List.nth_opt rows (clamp_index (List.length rows) t.selected_index)

let company_spend_rollups t =
  let rows = keeper_spend_rows t in
  let tbl : (string, int * int * int * float) Hashtbl.t = Hashtbl.create 8 in
  List.iter
    (fun (r : keeper_spend_row) ->
      let kc, calls, turns, cost =
        match Hashtbl.find_opt tbl r.company with
        | Some v -> v
        | None -> (0, 0, 0, 0.0)
      in
      Hashtbl.replace tbl r.company
        (kc + 1, calls + r.calls, turns + r.turns, cost +. r.cost_usd))
    rows;
  Hashtbl.fold
    (fun company (keeper_count, calls, turns, cost_usd) acc ->
      { company; keeper_count; calls; turns; cost_usd } :: acc)
    tbl []
  |> List.sort (fun a b ->
         let c = Float.compare b.cost_usd a.cost_usd in
         if c <> 0 then c else String.compare a.company b.company)

let set_fusion_prompt prompt t =
  { t with fusion_launch_draft = { t.fusion_launch_draft with prompt } }

let set_fusion_keeper keeper t =
  { t with fusion_launch_draft = { t.fusion_launch_draft with keeper } }

let set_fusion_preset preset t =
  { t with fusion_launch_draft = { t.fusion_launch_draft with preset } }

let set_fusion_topology topology t =
  { t with fusion_launch_draft = { t.fusion_launch_draft with topology } }

let toggle_fusion_web_tools t =
  {
    t with
    fusion_launch_draft =
      { t.fusion_launch_draft with web_tools = not t.fusion_launch_draft.web_tools };
  }

let set_fusion_submitting submitting t =
  { t with fusion_launch_draft = { t.fusion_launch_draft with submitting } }

let clear_fusion_draft t = { t with fusion_launch_draft = empty_fusion_draft }

let to_fusion_launch_request t =
  let d = t.fusion_launch_draft in
  let prompt = String.trim d.prompt in
  if String.equal prompt "" then Error "Fusion prompt must not be empty"
  else
    match d.keeper with
    | None -> Error "Select a target keeper before launching a Fusion run"
    | Some k when String.equal (String.trim k) "" ->
        Error "Select a target keeper before launching a Fusion run"
    | Some keeper ->
        Ok
          ( keeper
          , {
              Wire_runtime.prompt;
              preset = d.preset;
              topology = d.topology;
              web_tools = d.web_tools;
            } )

let filtered_lanes t =
  let lanes =
    match Observed.to_option t.runtime_resolved with
    | Some snap -> snap.lanes
    | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then lanes
  else
    List.filter
      (fun (l : Wire_runtime.failover_lane) ->
        contains_ci ~needle:q l.id
        || List.exists (fun rid -> contains_ci ~needle:q rid) l.runtime_ids)
      lanes

let filtered_tools t =
  let tools =
    match Observed.to_option t.tools_catalog with
    | Some xs -> xs
    | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then tools
  else
    List.filter
      (fun (tool : Wire_runtime.tool_summary) ->
        contains_ci ~needle:q tool.name
        ||
        match tool.description with
        | Some d -> contains_ci ~needle:q d
        | None -> false)
      tools

let filtered_connectors t =
  let cs =
    match Observed.to_option t.connectors with
    | Some xs -> xs
    | None -> []
  in
  let q = String.trim t.filter_query in
  if String.equal q "" then cs
  else
    List.filter
      (fun (c : Wire_runtime.connector_row) ->
        contains_ci ~needle:q c.connector_id
        || contains_ci ~needle:q c.display_name
        || (match c.channel with
            | Some ch -> contains_ci ~needle:q ch
            | None -> false)
        ||
        match c.error with
        | Some err -> contains_ci ~needle:q err
        | None -> false)
      cs

let selected_lane t =
  let lanes = filtered_lanes t in
  List.nth_opt lanes (clamp_index (List.length lanes) t.selected_index)

let selected_connector t =
  let cs = filtered_connectors t in
  List.nth_opt cs (clamp_index (List.length cs) t.connector_selected_index)

let subscription_window_count t =
  List.fold_left
    (fun acc (acc_row : Wire_runtime.account_usage) ->
      match acc_row.state with
      | Wire_runtime.Account_reported ws ->
          let sub_n =
            List.fold_left
              (fun n (w : Wire_runtime.usage_window) ->
                match w.utilization with
                | Wire_runtime.Util_fraction _
                | Wire_runtime.Util_percent _
                | Wire_runtime.Util_credit_unlimited ->
                    n + 1
                | Wire_runtime.Util_usd _
                | Wire_runtime.Util_credit_balance _
                | Wire_runtime.Util_credit_retracted ->
                    n)
              0 ws
          in
          acc + sub_n
      | Wire_runtime.Account_not_reported_since_start
      | Wire_runtime.Account_reported_no_windows _ ->
          acc)
    0 (filtered_accounts t)

let credits_list_len t =
  let p = partition_accounts t in
  let base =
    List.length p.exhausted_and_credits + List.length p.active_subscriptions
  in
  let extra =
    match p.unreported with
    | [] -> 0
    | xs -> if t.show_unreported_accounts then 1 + List.length xs else 1
  in
  base + extra

let visual_row_for_selection t ~selected_index =
  match t.active_tab with
  | Nav.Runtime_efficiency_spend ->
      let groups = grouped_keeper_spend_rows t in
      let rec walk vis_row item_idx = function
        | [] -> (selected_index, selected_index)
        | (g : company_spend_group) :: rest ->
            let n = List.length g.members in
            if selected_index < item_idx + n then
              let offset = selected_index - item_idx in
              let row = vis_row + 1 + offset in
              ((if offset = 0 then vis_row else row), row)
            else walk (vis_row + 1 + n) (item_idx + n) rest
      in
      walk 0 0 groups
  | Nav.Runtime_failover_lanes ->
      let lanes = filtered_lanes t in
      let rec walk vis_row idx = function
        | [] -> (vis_row, vis_row)
        | (lane : Wire_runtime.failover_lane) :: rest ->
            if idx >= selected_index then (vis_row, vis_row)
            else
              walk
                (vis_row + 1 + List.length lane.runtime_ids)
                (idx + 1) rest
      in
      walk 0 0 lanes
  | Nav.Runtime_quotas_credits | Nav.Runtime_tools_connectors ->
      (selected_index, selected_index)

let reset_detail_scroll t = { t with detail_scroll_offset = 0 }

let move_selection ?(pane_index = 0) ?viewport_rows ~delta t =
  match t.active_tab with
  | Nav.Runtime_quotas_credits ->
      if pane_index = 0 then
        let total = subscription_window_count t in
        let max_scroll = max 0 (total - 1) in
        let quota_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll (t.quota_scroll_offset + delta)
        in
        { t with quota_scroll_offset }
      else
        let len = credits_list_len t in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let scroll_offset =
          Store_scroll.adjust_scroll ?viewport_rows ~scroll:t.scroll_offset
            selected_index
        in
        { t with selected_index; scroll_offset }
  | Nav.Runtime_efficiency_spend ->
      let len = List.length (keeper_spend_display_rows t) in
      let selected_index = clamp_index len (t.selected_index + delta) in
      let header_row, vis_row = visual_row_for_selection t ~selected_index in
      let scroll_offset =
        adjust_grouped_scroll ?viewport_rows ~scroll:t.scroll_offset ~header_row
          vis_row
      in
      { t with selected_index; scroll_offset }
  | Nav.Runtime_failover_lanes ->
      if pane_index = 1 then
        let detail_scroll_offset =
          Store_scroll.clamp_scroll ~max_scroll:64
            (t.detail_scroll_offset + delta)
        in
        { t with detail_scroll_offset }
      else
        let len = List.length (filtered_lanes t) in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let header_row, vis_row = visual_row_for_selection t ~selected_index in
        let scroll_offset =
          adjust_grouped_scroll ?viewport_rows ~scroll:t.scroll_offset
            ~header_row vis_row
        in
        let detail_scroll_offset =
          if Int.equal selected_index t.selected_index then
            t.detail_scroll_offset
          else 0
        in
        { t with selected_index; scroll_offset; detail_scroll_offset }
  | Nav.Runtime_tools_connectors ->
      if pane_index = 1 then
        let len = List.length (filtered_connectors t) in
        let connector_selected_index =
          clamp_index len (t.connector_selected_index + delta)
        in
        let connector_scroll_offset =
          Store_scroll.adjust_scroll ?viewport_rows
            ~scroll:t.connector_scroll_offset connector_selected_index
        in
        { t with connector_selected_index; connector_scroll_offset }
      else
        let len = List.length (filtered_tools t) in
        let selected_index = clamp_index len (t.selected_index + delta) in
        let scroll_offset =
          Store_scroll.adjust_scroll ?viewport_rows ~scroll:t.scroll_offset
            selected_index
        in
        { t with selected_index; scroll_offset }

let set_show_unreported_accounts show_unreported_accounts t =
  let next = { t with show_unreported_accounts } in
  let len = credits_list_len next in
  let selected_index = clamp_index len next.selected_index in
  let scroll_offset =
    if selected_index < next.scroll_offset then selected_index
    else next.scroll_offset
  in
  { next with selected_index; scroll_offset }

let toggle_unreported_accounts t =
  set_show_unreported_accounts (not t.show_unreported_accounts) t

let set_filter filter_query t =
  {
    t with
    filter_query;
    selected_index = 0;
    scroll_offset = 0;
    quota_scroll_offset = 0;
    connector_selected_index = 0;
    connector_scroll_offset = 0;
    detail_scroll_offset = 0;
  }

let mark_stale_all t =
  {
    t with
    usage_windows = Observed.mark_stale t.usage_windows;
    usage_history = Observed.mark_stale t.usage_history;
    keeper_costs = Observed.mark_stale t.keeper_costs;
    efficiency = Observed.mark_stale t.efficiency;
    models_metrics = Observed.mark_stale t.models_metrics;
    runtime_metrics = Observed.mark_stale t.runtime_metrics;
    runtime_resolved = Observed.mark_stale t.runtime_resolved;
    runtime_config_raw = Observed.mark_stale t.runtime_config_raw;
    setup_inventory = Observed.mark_stale t.setup_inventory;
    runtime_probe = Observed.mark_stale t.runtime_probe;
    exact_lane_runs = Observed.mark_stale t.exact_lane_runs;
    fusion_runs = Observed.mark_stale t.fusion_runs;
    tool_series = Observed.mark_stale t.tool_series;
    tools_catalog = Observed.mark_stale t.tools_catalog;
    connectors = Observed.mark_stale t.connectors;
    browser_lane = Observed.mark_stale t.browser_lane;
    mcp_clients = Observed.mark_stale t.mcp_clients;
  }
