open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_map = Map.Make (String)
module String_set = Set.Make (String)

module Operation_map = Map.Make (struct
  type t = string * string

  let compare (keeper_a, operation_a) (keeper_b, operation_b) =
    match String.compare keeper_a keeper_b with
    | 0 -> String.compare operation_a operation_b
    | order -> order
end)

type chat_display_origin =
  | Display_origin_bare
  | Display_origin_inline
  | Display_origin_row

type thinking_display =
  | Thinking_folded
  | Thinking_full
  | Thinking_hidden

type memory_display =
  | Memory_hidden
  | Memory_summary
  | Memory_full

type active_tool_call = {
  tool_use_id : string;
  tool_name : string;
  args_preview : string option;
  completed : bool;
  ok : bool option;
  output_preview : string option;
}

type chat_stream_buffer = {
  request_id : string;
  operation_id : string option;
  turn_ref : string option;
  run_started : bool;
  interrupting : bool;
  prior_msg_ids : String_set.t;
  text : string;
  text_ownership : Cut_reply.ownership;
  thinking : string;
  tools : active_tool_call list;
  active : bool;
  ended : bool;
  last_error : string option;
}

type t = {
  shell : Wire_fleet.dashboard_shell Observed.t;
  raw_shell_scorecard : Wire_fleet.daily_scorecard option;
  keepers : Wire_fleet.keeper_summary list Observed.t;
  unreadable_keepers : Wire_fleet.unreadable_keeper list;
  turns : Wire_fleet.keeper_turn_row list Observed.t;
  turn_records : Wire_fleet.keeper_turn_records Observed.t String_map.t;
  chat_control_tokens : string String_map.t;
  sandbox_profiles : Wire_fleet.keeper_sandbox_profile String_map.t;
  candle_balances_milli : int String_map.t;
  candle_summary_fallback : Wire_fleet.candle_observation option;
  turn_pulses : Wire_fleet.turn_pulse String_map.t;
  fleet_reading : Wire_fleet.fleet_stream_reading Observed.t;
  fleet_degradation : Wire_fleet.fleet_degradation option;
  fleet_mode : Nav.keepers_fleet_mode;
  selected_index : int;
  scroll_offset : int;
  pulse_scroll_offset : int;
  filter_query : string;
  selected_keeper : string option;
  collapsed_companies : String_set.t;
  chat_histories : Wire_fleet.chat_history_page Observed.t String_map.t;
  chat_streams : chat_stream_buffer String_map.t;
  cut_replies : Cut_reply.t Observed.t Operation_map.t;
  chat_origin_mode : chat_display_origin;
  chat_tools_mode : Slash.tools_mode;
  chat_thinking_mode : thinking_display;
  chat_memory_mode : memory_display;
  chat_turn_details_expanded : bool;
  chat_scroll_offset : int;
  keeper_dive_tab : Nav.keeper_tab;
}

let empty =
  {
    shell = Observed.loading ~since_ns:Clock.Mono.zero;
    raw_shell_scorecard = None;
    keepers = Observed.loading ~since_ns:Clock.Mono.zero;
    unreadable_keepers = [];
    turns = Observed.unreported;
    turn_records = String_map.empty;
    chat_control_tokens = String_map.empty;
    sandbox_profiles = String_map.empty;
    candle_balances_milli = String_map.empty;
    candle_summary_fallback = None;
    turn_pulses = String_map.empty;
    fleet_reading = Observed.unreported;
    fleet_degradation = None;
    fleet_mode = Nav.Fleet_companies;
    selected_index = 0;
    scroll_offset = 0;
    pulse_scroll_offset = 0;
    filter_query = "";
    selected_keeper = None;
    collapsed_companies = String_set.empty;
    chat_histories = String_map.empty;
    chat_streams = String_map.empty;
    cut_replies = Operation_map.empty;
    chat_origin_mode = Display_origin_bare;
    chat_tools_mode = Slash.Tools_compact;
    chat_thinking_mode = Thinking_folded;
    chat_memory_mode = Memory_hidden;
    chat_turn_details_expanded = false;
    chat_scroll_offset = 0;
    keeper_dive_tab = Nav.Keeper_chat;
  }

let equal_chat_display_origin a b =
  match a, b with
  | Display_origin_bare, Display_origin_bare
  | Display_origin_inline, Display_origin_inline
  | Display_origin_row, Display_origin_row ->
      true
  | Display_origin_bare, (Display_origin_inline | Display_origin_row)
  | Display_origin_inline, (Display_origin_bare | Display_origin_row)
  | Display_origin_row, (Display_origin_bare | Display_origin_inline) ->
      false

let equal_thinking_display a b =
  match a, b with
  | Thinking_folded, Thinking_folded
  | Thinking_full, Thinking_full
  | Thinking_hidden, Thinking_hidden ->
      true
  | Thinking_folded, (Thinking_full | Thinking_hidden)
  | Thinking_full, (Thinking_folded | Thinking_hidden)
  | Thinking_hidden, (Thinking_folded | Thinking_full) ->
      false

let equal_memory_display a b =
  match a, b with
  | Memory_hidden, Memory_hidden
  | Memory_summary, Memory_summary
  | Memory_full, Memory_full ->
      true
  | Memory_hidden, (Memory_summary | Memory_full)
  | Memory_summary, (Memory_hidden | Memory_full)
  | Memory_full, (Memory_hidden | Memory_summary) ->
      false

let keeper_live_state (k : Wire_fleet.keeper_summary) =
  match k.health with
  | Wire_fleet.Keeper_healthy -> Health.Healthy
  | Wire_fleet.Keeper_working ->
      let detail =
        match k.active_turn with
        | Some { tool_in_flight = Some tool; _ } ->
            Say.make ~ko:("도구 실행: " ^ tool) ~en:("Tool: " ^ tool)
        | Some { phase = Some phase; _ } -> Say.literal phase
        | Some _ | None -> Say.make ~ko:"턴 실행 중" ~en:"In turn"
      in
      Health.Working { detail }
  | Wire_fleet.Keeper_idle | Wire_fleet.Keeper_paused -> Health.Idle
  | Wire_fleet.Keeper_booting ->
      Health.Working { detail = Say.make ~ko:"시작 중" ~en:"Booting" }
  | Wire_fleet.Keeper_recovering ->
      Health.Degraded { reason = Say.make ~ko:"복구 중" ~en:"Recovering" }
  | Wire_fleet.Keeper_degraded ->
      Health.Degraded { reason = Say.make ~ko:"성능 저하" ~en:"Degraded" }
  | Wire_fleet.Keeper_failing ->
      Health.Down { reason = Say.make ~ko:"실행 실패" ~en:"Failing" }
  | Wire_fleet.Keeper_offline -> Health.Idle

type context_display =
  | Context_fill of { ratio : float; estimated : bool }
  | Context_tokens_only of int
  | Context_unavailable of Wire_fleet.context_unavailable_reason

let clamp_unit_ratio r = Float.max 0.0 (Float.min 1.0 r)

let context_display = function
  | Wire_fleet.Context_measured { ratio = Some r; _ } ->
      Context_fill { ratio = clamp_unit_ratio r; estimated = false }
  | Wire_fleet.Context_measured { ratio = None; tokens; _ } ->
      Context_tokens_only tokens
  | Wire_fleet.Context_not_measured { estimated_ratio = Some r; _ } ->
      Context_fill { ratio = clamp_unit_ratio r; estimated = true }
  | Wire_fleet.Context_not_measured { reason; estimated_ratio = None } ->
      Context_unavailable reason

let context_fill_label ~estimated ratio =
  let pct = ratio *. 100.0 in
  if estimated then Printf.sprintf "~%.0f%%" pct else Printf.sprintf "%.0f%%" pct

let context_unavailable_label = function
  | Wire_fleet.Context_measurement_missing ->
      Say.make ~ko:"기록 없음" ~en:"no record"
  | Wire_fleet.Context_record_undecodable ->
      Say.make ~ko:"기록 손상" ~en:"bad record"
  | Wire_fleet.Context_record_read_failed ->
      Say.make ~ko:"읽기 실패" ~en:"read failed"
  | Wire_fleet.Context_record_without_usage ->
      Say.make ~ko:"토큰 없음" ~en:"no usage"
  | Wire_fleet.Context_trace_mismatch -> Say.make ~ko:"새로 시작" ~en:"restarted"
  | Wire_fleet.Context_cumulative_usage ->
      Say.make ~ko:"대화 누적" ~en:"cumulative"
  | Wire_fleet.Context_turn_total_usage ->
      Say.make ~ko:"턴 합계" ~en:"turn total"
  | Wire_fleet.Context_usage_scope_unavailable ->
      Say.make ~ko:"범위 모름" ~en:"scope unknown"
  | Wire_fleet.Context_tokens_exceed_window ->
      Say.make ~ko:"창 초과" ~en:"over window"
  | Wire_fleet.Context_input_estimate ->
      Say.make ~ko:"입력 추정" ~en:"input estimated"
  | Wire_fleet.Context_input_provenance_unavailable ->
      Say.make ~ko:"출처 모름" ~en:"no provenance"

type fleet_health_counts = {
  total : int;
  active : int;
  working : int;
  healthy : int;
  degraded : int;
  failing : int;
  paused : int;
  offline : int;
}

let fleet_health_counts (ks : Wire_fleet.keeper_summary list) :
    fleet_health_counts =
  List.fold_left
    (fun acc (k : Wire_fleet.keeper_summary) ->
      let total = acc.total + 1 in
      match k.health with
      | Wire_fleet.Keeper_failing ->
          { acc with total; failing = acc.failing + 1 }
      | Wire_fleet.Keeper_offline ->
          { acc with total; offline = acc.offline + 1 }
      | Wire_fleet.Keeper_paused ->
          { acc with total; paused = acc.paused + 1 }
      | Wire_fleet.Keeper_healthy
      | Wire_fleet.Keeper_working
      | Wire_fleet.Keeper_booting
      | Wire_fleet.Keeper_idle
      | Wire_fleet.Keeper_degraded
      | Wire_fleet.Keeper_recovering
        when k.paused ->
          { acc with total; paused = acc.paused + 1 }
      | Wire_fleet.Keeper_working | Wire_fleet.Keeper_booting ->
          { acc with total; active = acc.active + 1; working = acc.working + 1 }
      | Wire_fleet.Keeper_degraded | Wire_fleet.Keeper_recovering ->
          { acc with total; active = acc.active + 1; degraded = acc.degraded + 1 }
      | Wire_fleet.Keeper_healthy ->
          { acc with total; active = acc.active + 1; healthy = acc.healthy + 1 }
      | Wire_fleet.Keeper_idle ->
          if k.keepalive_running then
            { acc with total; active = acc.active + 1; healthy = acc.healthy + 1 }
          else { acc with total; offline = acc.offline + 1 })
    {
      total = 0;
      active = 0;
      working = 0;
      healthy = 0;
      degraded = 0;
      failing = 0;
      paused = 0;
      offline = 0;
    }
    ks

let contains_ci = Store_scroll.contains_ci
let adjust_scroll = Store_scroll.adjust_scroll
let adjust_grouped_scroll = Store_scroll.adjust_grouped_scroll

let keepers_list t =
  match Observed.to_option t.keepers with Some ks -> ks | None -> []

let filter_matched_keepers t =
  let q = String.trim t.filter_query in
  let base = keepers_list t in
  if String.equal q "" then base
  else
    List.filter
      (fun (k : Wire_fleet.keeper_summary) ->
        contains_ci ~needle:q k.name
        || contains_ci ~needle:q k.company
        || contains_ci ~needle:q k.runtime_id
        ||
        match k.model_id with
        | Some m -> contains_ci ~needle:q m
        | None -> false)
      base

let filtered_keepers t =
  let matched = filter_matched_keepers t in
  match t.fleet_mode with
  | Nav.Fleet_companies ->
      let groups = Wire_fleet.group_by_company matched in
      let uncollapsed =
        List.concat_map
          (fun (g : Wire_fleet.company_group) ->
            if String_set.mem g.company t.collapsed_companies then []
            else g.keepers)
          groups
      in
      if uncollapsed <> [] then uncollapsed
      else List.concat_map (fun (g : Wire_fleet.company_group) -> g.keepers) groups
  | Nav.Fleet_attention ->
      List.stable_sort
        (fun a b ->
          let ra = Health.live_severity_rank (keeper_live_state a) in
          let rb = Health.live_severity_rank (keeper_live_state b) in
          let c = Int.compare rb ra in
          if c <> 0 then c else String.compare a.name b.name)
        matched
  | Nav.Fleet_pulse_wall ->
      List.stable_sort
        (fun (a : Wire_fleet.keeper_summary) (b : Wire_fleet.keeper_summary) ->
          let sum xs = List.fold_left ( +. ) 0.0 xs in
          let c =
            Float.compare
              (sum b.activity_sparkline_24h)
              (sum a.activity_sparkline_24h)
          in
          if c <> 0 then c else String.compare a.name b.name)
        matched

let company_groups_with_costs ?attention ~keeper_costs_24h t =
  let sandbox_profiles = String_map.bindings t.sandbox_profiles in
  Wire_fleet.group_by_company ?attention ~sandbox_profiles ~keeper_costs_24h
    (filter_matched_keepers t)

let company_groups ?attention t =
  company_groups_with_costs ?attention ~keeper_costs_24h:[] t

let sandbox_profile_of ~keeper t =
  String_map.find_opt keeper t.sandbox_profiles

let fleet_infra_counts t =
  String_map.fold
    (fun _ prof (vm, ssh, dock) ->
      match prof with
      | Wire_fleet.Profile_microvm -> (vm + 1, ssh, dock)
      | Wire_fleet.Profile_remote_ssh -> (vm, ssh + 1, dock)
      | Wire_fleet.Profile_docker -> (vm, ssh, dock + 1)
      | Wire_fleet.Profile_other _ -> (vm, ssh, dock))
    t.sandbox_profiles (0, 0, 0)

let total_turns_24h t =
  let ks = keepers_list t in
  let has_any =
    List.exists
      (fun (k : Wire_fleet.keeper_summary) -> k.activity_sparkline_24h <> [])
      ks
  in
  if not has_any then None
  else
    let sum =
      List.fold_left
        (fun acc (k : Wire_fleet.keeper_summary) ->
          acc
          +. List.fold_left ( +. ) 0.0 k.activity_sparkline_24h)
        0.0 ks
    in
    Some (Int.of_float (Float.round sum))

let find_keeper ~name t =
  List.find_opt
    (fun (k : Wire_fleet.keeper_summary) -> String.equal k.name name)
    (keepers_list t)

let clamp_index = Store_scroll.clamp_index

let selected_keeper_summary t =
  let ks = filtered_keepers t in
  match t.selected_keeper with
  | Some name -> (
      match
        List.find_opt
          (fun (k : Wire_fleet.keeper_summary) -> String.equal k.name name)
          ks
      with
      | Some k -> Some k
      | None -> List.nth_opt ks (clamp_index (List.length ks) t.selected_index))
  | None -> List.nth_opt ks (clamp_index (List.length ks) t.selected_index)

let selected_company_keeper t =
  let groups = company_groups t in
  let total = List.length groups in
  if total = 0 then None
  else
    let by_name =
      match t.selected_keeper with
      | None -> None
      | Some name ->
          List.find_map
            (fun (g : Wire_fleet.company_group) ->
              List.find_opt
                (fun (k : Wire_fleet.keeper_summary) ->
                  String.equal k.name name)
                g.keepers)
            groups
    in
    match by_name with
    | Some _ as k -> k
    | None -> (
        match List.nth_opt groups (clamp_index total t.selected_index) with
        | Some g -> (
            match g.keepers with lead :: _ -> Some lead | [] -> None)
        | None -> None)

let turns_list t =
  match Observed.to_option t.turns with Some rows -> rows | None -> []

let chat_control_token_for ~keeper t =
  match String_map.find_opt keeper t.chat_control_tokens with
  | Some _ as tok -> tok
  | None -> (
      match
        List.find_opt
          (fun (r : Wire_fleet.keeper_turn_row) ->
            String.equal r.keeper_name keeper)
          (turns_list t)
      with
      | Some row -> row.chat_control_token
      | None -> None)

let update_chat_control_token ~keeper ~token t =
  let trimmed = String.trim token in
  if String.equal trimmed "" then t
  else
    let chat_control_tokens =
      String_map.add keeper trimmed t.chat_control_tokens
    in
    let turns =
      Observed.map
        (List.map (fun (r : Wire_fleet.keeper_turn_row) ->
             if String.equal r.keeper_name keeper then
               { r with chat_control_token = Some trimmed }
             else r))
        t.turns
    in
    { t with chat_control_tokens; turns }

let has_active_chat_stream ~keeper t =
  match String_map.find_opt keeper t.chat_streams with
  | Some b -> b.active
  | None -> false

let active_turn_for ~keeper t =
  match
    List.find_opt
      (fun (r : Wire_fleet.keeper_turn_row) ->
        String.equal r.keeper_name keeper)
      (turns_list t)
  with
  | Some { state = Wire_fleet.Turn_active turn; _ } -> Some turn
  | Some { state = Wire_fleet.Turn_idle | Wire_fleet.Turn_unavailable _; _ }
  | None -> (
      match find_keeper ~name:keeper t with
      | Some k -> k.active_turn
      | None -> None)

let apply_shell ~observed_at shell t =
  {
    t with
    shell = Observed.value ~observed_at shell;
    raw_shell_scorecard = Some shell.scorecard_24h;
  }

let index_of_keeper_name name (ks : Wire_fleet.keeper_summary list) =
  let rec find i = function
    | [] -> None
    | (k : Wire_fleet.keeper_summary) :: rest ->
        if String.equal k.name name then Some i else find (i + 1) rest
  in
  find 0 ks

let resolve_current_index t (ks : Wire_fleet.keeper_summary list) =
  let len = List.length ks in
  match t.selected_keeper with
  | Some name -> (
      match index_of_keeper_name name ks with
      | Some idx -> idx
      | None -> clamp_index len t.selected_index)
  | None -> clamp_index len t.selected_index

let visual_row_for_selection t ~selected_index ~selected_keeper =
  match t.fleet_mode with
  | Nav.Fleet_attention | Nav.Fleet_pulse_wall ->
      (selected_index, selected_index)
  | Nav.Fleet_companies -> (
      let groups = Wire_fleet.group_by_company (filter_matched_keepers t) in
      match selected_keeper with
      | None -> (selected_index, selected_index)
      | Some want ->
          let rec walk_groups row = function
            | [] -> (selected_index, selected_index)
            | (g : Wire_fleet.company_group) :: rest ->
                let hdr_row = row in
                if String_set.mem g.company t.collapsed_companies then
                  if
                    List.exists
                      (fun (k : Wire_fleet.keeper_summary) ->
                        String.equal k.name want)
                      g.keepers
                  then (hdr_row, hdr_row)
                  else walk_groups (row + 1) rest
                else
                  let rec walk_members first r = function
                    | [] -> walk_groups r rest
                    | (k : Wire_fleet.keeper_summary) :: ks ->
                        if String.equal k.name want then
                          ((if first then hdr_row else r), r)
                        else walk_members false (r + 1) ks
                  in
                  walk_members true (row + 1) g.keepers
          in
          walk_groups 0 groups)

let sync_selection_after_change ~prev_index ~reset_scroll ~clear_if_empty next =
  let visible = filtered_keepers next in
  let len = List.length visible in
  let n_groups = List.length (company_groups next) in
  let pulse_scroll_offset =
    if reset_scroll || n_groups = 0 then 0
    else min next.pulse_scroll_offset (max 0 (n_groups - 1))
  in
  if len = 0 then
    let selected_keeper = if clear_if_empty then None else next.selected_keeper in
    {
      next with
      selected_index = 0;
      scroll_offset = 0;
      pulse_scroll_offset;
      selected_keeper;
    }
  else
    let selected_index, selected_keeper =
      match next.selected_keeper with
      | Some name -> (
          match index_of_keeper_name name visible with
          | Some idx -> (idx, Some name)
          | None ->
              let idx = clamp_index len prev_index in
              let kp =
                match List.nth_opt visible idx with
                | Some k -> Some k.name
                | None -> None
              in
              (idx, kp))
      | None ->
          let idx = clamp_index len prev_index in
          let kp =
            match List.nth_opt visible idx with
            | Some k -> Some k.name
            | None -> None
          in
          (idx, kp)
    in
    let header_row, vis_row =
      visual_row_for_selection next ~selected_index ~selected_keeper
    in
    let base_scroll = if reset_scroll then 0 else next.scroll_offset in
    let scroll_offset =
      adjust_grouped_scroll ~scroll:base_scroll ~header_row vis_row
    in
    {
      next with
      selected_index;
      scroll_offset;
      pulse_scroll_offset;
      selected_keeper;
    }

let apply_keepers ~observed_at ks t =
  let prev_index = resolve_current_index t (filtered_keepers t) in
  let next = { t with keepers = Observed.value ~observed_at ks } in
  sync_selection_after_change ~prev_index ~reset_scroll:false
    ~clear_if_empty:true next

let apply_roster ~observed_at (roster : Wire_fleet.keepers_roster) t =
  apply_keepers ~observed_at roster.keepers
    { t with unreadable_keepers = roster.unreadable }

let apply_roster_extras (extras : Wire_fleet.keeper_roster_extras) t =
  let sandbox_profiles =
    List.fold_left
      (fun acc (name, prof) -> String_map.add name prof acc)
      t.sandbox_profiles extras.sandbox_profiles
  in
  let candle_balances_milli =
    List.fold_left
      (fun acc (name, bal) -> String_map.add name bal acc)
      t.candle_balances_milli extras.candle_balances_milli
  in
  let candle_summary_fallback =
    match extras.candle_summary with
    | Some _ as cs -> cs
    | None -> t.candle_summary_fallback
  in
  (* The roster read carries every keeper's pulse, so it replaces the map: a
     keeper whose row no longer sends one has none. *)
  let turn_pulses =
    List.fold_left
      (fun acc (name, pulse) -> String_map.add name pulse acc)
      String_map.empty extras.turn_pulses
  in
  { t with sandbox_profiles; candle_balances_milli; candle_summary_fallback; turn_pulses }

let turn_pulse t name = String_map.find_opt name t.turn_pulses

let apply_execution_enrichments ~observed_at (enrichments, candle_opt) t =
  let by_name = Hashtbl.create (max 8 (List.length enrichments)) in
  let sandbox_profiles =
    List.fold_left
      (fun acc (e : Wire_fleet.execution_keeper_enrichment) ->
        Hashtbl.replace by_name e.keeper_name e;
        match e.sandbox_profile with
        | Some p -> String_map.add e.keeper_name p acc
        | None -> acc)
      t.sandbox_profiles enrichments
  in
  let keepers =
    Observed.map
      (List.map (fun (k : Wire_fleet.keeper_summary) ->
           match Hashtbl.find_opt by_name k.name with
           | None -> k
           | Some e ->
               let total_turns =
                 if Observed.is_value k.total_turns then k.total_turns
                 else
                   match e.total_turns with
                   | Some tt -> Observed.value ~observed_at tt
                   | None -> k.total_turns
               in
               { k with total_turns }))
      t.keepers
  in
  let candle_summary_fallback =
    match candle_opt with
    | Some _ as cs -> cs
    | None -> t.candle_summary_fallback
  in
  { t with keepers; sandbox_profiles; candle_summary_fallback }

let enrich_scorecard f t =
  let raw_shell_scorecard =
    match t.raw_shell_scorecard with
    | Some _ as r -> r
    | None ->
        Option.map
          (fun (sh : Wire_fleet.dashboard_shell) -> sh.scorecard_24h)
          (Observed.to_option t.shell)
  in
  let shell =
    Observed.map
      (fun (sh : Wire_fleet.dashboard_shell) ->
        let raw = Option.value ~default:sh.scorecard_24h raw_shell_scorecard in
        { sh with scorecard_24h = f raw })
      t.shell
  in
  { t with shell; raw_shell_scorecard }

let apply_turns ~observed_at rows t =
  let chat_control_tokens =
    List.fold_left
      (fun acc (r : Wire_fleet.keeper_turn_row) ->
        match r.chat_control_token with
        | Some tok when not (String.equal (String.trim tok) "") ->
            String_map.add r.keeper_name (String.trim tok) acc
        | Some _ | None -> acc)
      t.chat_control_tokens rows
  in
  let keepers =
    Observed.map
      (List.map (fun (k : Wire_fleet.keeper_summary) ->
           match
             List.find_opt
               (fun (r : Wire_fleet.keeper_turn_row) ->
                 String.equal r.keeper_name k.name)
               rows
           with
           | Some { state = Wire_fleet.Turn_active turn; _ } ->
               { k with active_turn = Some turn }
           | Some { state = Wire_fleet.Turn_idle; _ } ->
               { k with active_turn = None }
           | Some { state = Wire_fleet.Turn_unavailable _; _ } | None -> k))
      t.keepers
  in
  {
    t with
    turns = Observed.value ~observed_at rows;
    chat_control_tokens;
    keepers;
  }

let apply_fleet_stream_event ~observed_at ev t =
  match ev with
  | Wire_fleet.Fleet_snapshot { reading; degraded; _ } ->
      {
        t with
        fleet_reading = Observed.value ~observed_at reading;
        fleet_degradation = degraded;
      }
  | Wire_fleet.Fleet_changed { reading; _ } ->
      {
        t with
        fleet_reading = Observed.value ~observed_at reading;
        fleet_degradation = None;
      }
  | Wire_fleet.Fleet_unavailable_snapshot { degradation; _ }
  | Wire_fleet.Fleet_degraded { degradation; _ } ->
      { t with fleet_degradation = Some degradation }

let apply_heartbeat ~keeper ~phase ~in_turn ~at_unix t =
  let keepers =
    Observed.map
      (List.map (fun (k : Wire_fleet.keeper_summary) ->
           if not (String.equal k.name keeper) then k
           else
             let active_turn =
               match in_turn, k.active_turn with
               | Some false, _ -> None
               | Some true, Some turn ->
                   Some
                     {
                       turn with
                       phase =
                         (match phase with
                         | Some _ as p -> p
                         | None -> turn.phase);
                     }
               | Some true, None -> k.active_turn
               | None, cur -> cur
             in
             let last_turn_at_unix =
               match k.last_turn_at_unix with
               | Some prev when prev >= at_unix -> Some prev
               | Some _ | None -> Some at_unix
             in
             { k with active_turn; last_turn_at_unix }))
      t.keepers
  in
  { t with keepers }

let apply_chat_history ~observed_at ~keeper page t =
  let chat_histories =
    String_map.add keeper (Observed.value ~observed_at page) t.chat_histories
  in
  { t with chat_histories }

let snapshot_history_ids ~keeper t =
  match String_map.find_opt keeper t.chat_histories with
  | None -> String_set.empty
  | Some obs -> (
      match Observed.to_option obs with
      | None -> String_set.empty
      | Some page ->
          List.fold_left
            (fun acc (m : Wire_fleet.chat_message) -> String_set.add m.id acc)
            String_set.empty page.messages)

let fresh_stream_buffer ~keeper ~request_id t =
  {
    request_id;
    operation_id = None;
    turn_ref = None;
    run_started = false;
    interrupting = false;
    prior_msg_ids = snapshot_history_ids ~keeper t;
    text = "";
    text_ownership = Cut_reply.fresh_ownership;
    thinking = "";
    tools = [];
    active = true;
    ended = false;
    last_error = None;
  }

let start_chat_stream ~keeper ~request_id t =
  let buf = fresh_stream_buffer ~keeper ~request_id t in
  { t with chat_streams = String_map.add keeper buf t.chat_streams }

let merge_opt_op prev_op incoming_op =
  match incoming_op with Some _ as x -> x | None -> prev_op

let is_explicit_execution_start = function
  | Wire_fleet.Chunk_run_started _
  | Wire_fleet.Chunk_runtime_attempt_started _ ->
      true
  | Wire_fleet.Chunk_accepted { state = Wire_fleet.Accepted_running; _ } -> true
  | Wire_fleet.Chunk_accepted
      {
        state =
          ( Wire_fleet.Accepted_queued
          | Wire_fleet.Accepted_succeeded
          | Wire_fleet.Accepted_failed
          | Wire_fleet.Accepted_cancelled );
        _;
      }
  | Wire_fleet.Chunk_text_delta _
  | Wire_fleet.Chunk_thinking_delta _
  | Wire_fleet.Chunk_thinking_snapshot _
  | Wire_fleet.Chunk_tool_start _
  | Wire_fleet.Chunk_tool_args _
  | Wire_fleet.Chunk_tool_end _
  | Wire_fleet.Chunk_reply_details _
  | Wire_fleet.Chunk_turn_done _
  | Wire_fleet.Chunk_error _
  | Wire_fleet.Chunk_ignored ->
      false

let is_queued_acceptance = function
  | Wire_fleet.Chunk_accepted { state = Wire_fleet.Accepted_queued; _ } -> true
  | Wire_fleet.Chunk_accepted
      {
        state =
          ( Wire_fleet.Accepted_running
          | Wire_fleet.Accepted_succeeded
          | Wire_fleet.Accepted_failed
          | Wire_fleet.Accepted_cancelled );
        _;
      }
  | Wire_fleet.Chunk_run_started _
  | Wire_fleet.Chunk_runtime_attempt_started _
  | Wire_fleet.Chunk_text_delta _
  | Wire_fleet.Chunk_thinking_delta _
  | Wire_fleet.Chunk_thinking_snapshot _
  | Wire_fleet.Chunk_tool_start _
  | Wire_fleet.Chunk_tool_args _
  | Wire_fleet.Chunk_tool_end _
  | Wire_fleet.Chunk_reply_details _
  | Wire_fleet.Chunk_turn_done _
  | Wire_fleet.Chunk_error _
  | Wire_fleet.Chunk_ignored ->
      false

let apply_chat_stream_chunk ?(allow_takeover = false) ~keeper ~request_id chunk
    t =
  match chunk with
  | Wire_fleet.Chunk_ignored -> t
  | ( Wire_fleet.Chunk_accepted _
    | Wire_fleet.Chunk_run_started _
    | Wire_fleet.Chunk_runtime_attempt_started _
    | Wire_fleet.Chunk_text_delta _
    | Wire_fleet.Chunk_thinking_delta _
    | Wire_fleet.Chunk_thinking_snapshot _
    | Wire_fleet.Chunk_tool_start _
    | Wire_fleet.Chunk_tool_args _
    | Wire_fleet.Chunk_tool_end _
    | Wire_fleet.Chunk_reply_details _
    | Wire_fleet.Chunk_turn_done _
    | Wire_fleet.Chunk_error _ ) as chunk -> (
      let t =
        match chunk with
        | Wire_fleet.Chunk_accepted { control_token = Some tok; _ } ->
            update_chat_control_token ~keeper ~token:tok t
        | Wire_fleet.Chunk_accepted { control_token = None; _ }
        | Wire_fleet.Chunk_run_started _
        | Wire_fleet.Chunk_runtime_attempt_started _
        | Wire_fleet.Chunk_text_delta _
        | Wire_fleet.Chunk_thinking_delta _
        | Wire_fleet.Chunk_thinking_snapshot _
        | Wire_fleet.Chunk_tool_start _
        | Wire_fleet.Chunk_tool_args _
        | Wire_fleet.Chunk_tool_end _
        | Wire_fleet.Chunk_reply_details _
        | Wire_fleet.Chunk_turn_done _
        | Wire_fleet.Chunk_error _
        | Wire_fleet.Chunk_ignored ->
            t
      in
      let prev_opt =
        match String_map.find_opt keeper t.chat_streams with
        | Some b when String.equal b.request_id request_id -> Some b
        | Some b ->
            if
              allow_takeover
              && (not (is_queued_acceptance chunk))
              && ((not b.active) || is_explicit_execution_start chunk)
            then Some (fresh_stream_buffer ~keeper ~request_id t)
            else None
        | None ->
            if is_queued_acceptance chunk then None
            else Some (fresh_stream_buffer ~keeper ~request_id t)
      in
      match prev_opt with
      | None -> t
      | Some prev when prev.ended -> t
      | Some prev ->
          let updated =
            match chunk with
            | Wire_fleet.Chunk_accepted { operation_id; state; _ } ->
                let run_started =
                  prev.run_started
                  ||
                  match state with
                  | Wire_fleet.Accepted_running -> true
                  | Wire_fleet.Accepted_queued
                  | Wire_fleet.Accepted_succeeded
                  | Wire_fleet.Accepted_failed
                  | Wire_fleet.Accepted_cancelled ->
                      false
                in
                let active =
                  match state with
                  | Wire_fleet.Accepted_running -> true
                  | Wire_fleet.Accepted_queued -> prev.run_started
                  | Wire_fleet.Accepted_succeeded
                  | Wire_fleet.Accepted_failed
                  | Wire_fleet.Accepted_cancelled ->
                      false
                in
                let ended =
                  match state with
                  | Wire_fleet.Accepted_queued | Wire_fleet.Accepted_running ->
                      prev.ended
                  | Wire_fleet.Accepted_succeeded
                  | Wire_fleet.Accepted_failed
                  | Wire_fleet.Accepted_cancelled ->
                      true
                in
                {
                  prev with
                  operation_id = Some operation_id;
                  run_started;
                  active;
                  ended;
                }
            | Wire_fleet.Chunk_run_started { operation_id } ->
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  run_started = true;
                  text = "";
                  text_ownership = Cut_reply.fresh_ownership;
                  thinking = "";
                  active = true;
                }
            | Wire_fleet.Chunk_runtime_attempt_started { operation_id } ->
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  run_started = true;
                  text = "";
                  text_ownership = Cut_reply.retire_attempt prev.text_ownership;
                  thinking = "";
                  active = true;
                }
            | Wire_fleet.Chunk_text_delta { operation_id; delta; owner } -> (
                match Cut_reply.admit prev.text_ownership owner with
                | Cut_reply.Append text_ownership ->
                    {
                      prev with
                      operation_id = merge_opt_op prev.operation_id operation_id;
                      run_started = true;
                      text = prev.text ^ delta;
                      text_ownership;
                      active = true;
                    }
                | Cut_reply.Drop ->
                    {
                      prev with
                      operation_id = merge_opt_op prev.operation_id operation_id;
                      run_started = true;
                      active = true;
                    })
            | Wire_fleet.Chunk_thinking_delta { operation_id; delta } ->
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  run_started = true;
                  thinking = prev.thinking ^ delta;
                  active = true;
                }
            | Wire_fleet.Chunk_thinking_snapshot { operation_id; snapshot } ->
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  run_started = true;
                  thinking = snapshot;
                  active = true;
                }
            | Wire_fleet.Chunk_tool_start
                { operation_id; tool_use_id; tool_name; args_preview } ->
                let entry =
                  {
                    tool_use_id;
                    tool_name;
                    args_preview;
                    completed = false;
                    ok = None;
                    output_preview = None;
                  }
                in
                let tools =
                  List.filter
                    (fun (c : active_tool_call) ->
                      not (String.equal c.tool_use_id tool_use_id))
                    prev.tools
                  @ [ entry ]
                in
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  run_started = true;
                  tools;
                  active = true;
                }
            | Wire_fleet.Chunk_tool_args
                { operation_id; tool_use_id; delta; snapshot } ->
                let tools =
                  List.map
                    (fun (c : active_tool_call) ->
                      if String.equal c.tool_use_id tool_use_id then
                        let args_preview =
                          match snapshot, delta with
                          | Some s, _ -> Some s
                          | None, Some d ->
                              Some (Option.value c.args_preview ~default:"" ^ d)
                          | None, None -> c.args_preview
                        in
                        { c with args_preview }
                      else c)
                    prev.tools
                in
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  run_started = true;
                  tools;
                  active = true;
                }
            | Wire_fleet.Chunk_tool_end
                { operation_id; tool_use_id; tool_name; ok; output_preview } ->
                let found =
                  List.exists
                    (fun (c : active_tool_call) ->
                      String.equal c.tool_use_id tool_use_id)
                    prev.tools
                in
                let tools =
                  if found then
                    List.map
                      (fun (c : active_tool_call) ->
                        if String.equal c.tool_use_id tool_use_id then
                          {
                            c with
                            tool_name =
                              Option.value tool_name ~default:c.tool_name;
                            completed = true;
                            ok =
                              (match ok with Some _ as x -> x | None -> c.ok);
                            output_preview =
                              (match output_preview with
                              | Some _ as x -> x
                              | None -> c.output_preview);
                          }
                        else c)
                      prev.tools
                  else
                    prev.tools
                    @ [
                        {
                          tool_use_id;
                          tool_name = Option.value tool_name ~default:"tool";
                          args_preview = None;
                          completed = true;
                          ok;
                          output_preview;
                        };
                      ]
                in
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  run_started = true;
                  tools;
                  active = true;
                }
            | Wire_fleet.Chunk_reply_details
                { operation_id; reply; turn_ref; turn_outcome = _ } ->
                let text =
                  if String.equal (String.trim reply) "" then prev.text
                  else reply
                in
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  turn_ref =
                    (match turn_ref with
                    | Some _ as tr -> tr
                    | None -> prev.turn_ref);
                  run_started = true;
                  text;
                  active = true;
                }
            | Wire_fleet.Chunk_turn_done { operation_id; turn_ref; reply } ->
                let text =
                  match reply with
                  | Some r when not (String.equal (String.trim r) "") -> r
                  | Some _ | None -> prev.text
                in
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  turn_ref =
                    (match turn_ref with
                    | Some _ as tr -> tr
                    | None -> prev.turn_ref);
                  text;
                  active = false;
                  ended = true;
                  interrupting = false;
                }
            | Wire_fleet.Chunk_error { operation_id; message; code = _ } ->
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  active = false;
                  ended = true;
                  interrupting = false;
                  last_error = Some message;
                }
            | Wire_fleet.Chunk_ignored -> prev
          in
          { t with chat_streams = String_map.add keeper updated t.chat_streams })

let mark_chat_stream_interrupting ~keeper ~request_id ~interrupting t =
  match String_map.find_opt keeper t.chat_streams with
  | Some b when String.equal b.request_id request_id && b.active ->
      let next = { b with interrupting } in
      { t with chat_streams = String_map.add keeper next t.chat_streams }
  | Some _ | None -> t

let clear_inactive_chat_stream_error ~keeper t =
  match String_map.find_opt keeper t.chat_streams with
  | Some b when (not b.active) && Option.is_some b.last_error ->
      if
        String.equal (String.trim b.text) ""
        && String.equal (String.trim b.thinking) ""
        && b.tools = []
      then { t with chat_streams = String_map.remove keeper t.chat_streams }
      else
        let next = { b with last_error = None } in
        { t with chat_streams = String_map.add keeper next t.chat_streams }
  | Some _ | None -> t

let finish_chat_stream ~keeper ~request_id ~error t =
  match String_map.find_opt keeper t.chat_streams with
  | Some b when String.equal b.request_id request_id ->
      let next =
        {
          b with
          active = false;
          ended = true;
          interrupting = false;
          last_error =
            (match error with Some _ as e -> e | None -> b.last_error);
        }
      in
      { t with chat_streams = String_map.add keeper next t.chat_streams }
  | Some _ | None -> t

let detach_chat_streams t =
  {
    t with
    chat_streams =
      String_map.map
        (fun (b : chat_stream_buffer) ->
          if b.active then
            { b with active = false; ended = true; interrupting = false }
          else b)
        t.chat_streams;
  }

let set_fleet_mode fleet_mode t =
  let next = { t with fleet_mode } in
  sync_selection_after_change ~prev_index:0 ~reset_scroll:true
    ~clear_if_empty:false next

let prev_fleet_mode = function
  | Nav.Fleet_companies -> Nav.Fleet_pulse_wall
  | Nav.Fleet_attention -> Nav.Fleet_companies
  | Nav.Fleet_pulse_wall -> Nav.Fleet_attention

let cycle_fleet_mode dir t =
  let next_mode =
    match dir with
    | Keymap.Next -> Nav.next_keepers_fleet_mode t.fleet_mode
    | Keymap.Prev -> prev_fleet_mode t.fleet_mode
  in
  set_fleet_mode next_mode t

let set_keeper_dive_tab keeper_dive_tab t = { t with keeper_dive_tab }

let cycle_keeper_dive_tab dir t =
  let next_tab =
    match dir with
    | Keymap.Next -> Nav.next_keeper_tab t.keeper_dive_tab
    | Keymap.Prev -> Nav.prev_keeper_tab t.keeper_dive_tab
  in
  { t with keeper_dive_tab = next_tab }

let cycle_origin_mode t =
  let chat_origin_mode =
    match t.chat_origin_mode with
    | Display_origin_bare -> Display_origin_inline
    | Display_origin_inline -> Display_origin_row
    | Display_origin_row -> Display_origin_bare
  in
  { t with chat_origin_mode }

let set_tools_mode chat_tools_mode t = { t with chat_tools_mode }

let cycle_tools_mode t =
  let chat_tools_mode =
    match t.chat_tools_mode with
    | Slash.Tools_compact -> Slash.Tools_results
    | Slash.Tools_results -> Slash.Tools_full
    | Slash.Tools_full -> Slash.Tools_compact
  in
  { t with chat_tools_mode }

let cycle_thinking_mode t =
  let chat_thinking_mode =
    match t.chat_thinking_mode with
    | Thinking_folded -> Thinking_full
    | Thinking_full -> Thinking_hidden
    | Thinking_hidden -> Thinking_folded
  in
  { t with chat_thinking_mode }

let cycle_memory_mode t =
  let chat_memory_mode =
    match t.chat_memory_mode with
    | Memory_hidden -> Memory_summary
    | Memory_summary -> Memory_full
    | Memory_full -> Memory_hidden
  in
  { t with chat_memory_mode }

let toggle_turn_details t =
  { t with chat_turn_details_expanded = not t.chat_turn_details_expanded }

let toggle_company_collapsed company t =
  let prev_index = resolve_current_index t (filtered_keepers t) in
  let collapsed_companies =
    if String_set.mem company t.collapsed_companies then
      String_set.remove company t.collapsed_companies
    else String_set.add company t.collapsed_companies
  in
  let next = { t with collapsed_companies } in
  sync_selection_after_change ~prev_index ~reset_scroll:false
    ~clear_if_empty:false next

let select_keeper name t =
  let changed = not (Option.equal String.equal t.selected_keeper (Some name)) in
  let chat_scroll_offset = if changed then 0 else t.chat_scroll_offset in
  let ks = filtered_keepers t in
  match index_of_keeper_name name ks with
  | Some idx ->
      let selected_keeper = Some name in
      let header_row, vis_row =
        visual_row_for_selection t ~selected_index:idx ~selected_keeper
      in
      let scroll_offset =
        adjust_grouped_scroll ~scroll:t.scroll_offset ~header_row vis_row
      in
      {
        t with
        selected_keeper;
        selected_index = idx;
        scroll_offset;
        chat_scroll_offset;
      }
  | None -> { t with selected_keeper = Some name; chat_scroll_offset }

let move_selection ?viewport_rows ~delta t =
  let ks = filtered_keepers t in
  let len = List.length ks in
  let cur = resolve_current_index t ks in
  let selected_index = clamp_index len (cur + delta) in
  let selected_keeper =
    match List.nth_opt ks selected_index with
    | Some k -> Some k.name
    | None -> None
  in
  let changed = not (Option.equal String.equal t.selected_keeper selected_keeper) in
  let chat_scroll_offset = if changed then 0 else t.chat_scroll_offset in
  let header_row, vis_row =
    visual_row_for_selection t ~selected_index ~selected_keeper
  in
  let scroll_offset =
    if len = 0 then 0
    else
      adjust_grouped_scroll ?viewport_rows ~scroll:t.scroll_offset ~header_row
        vis_row
  in
  {
    t with
    selected_index;
    scroll_offset;
    selected_keeper;
    chat_scroll_offset;
  }

let move_company_selection ?viewport_rows ~delta t =
  let groups = company_groups t in
  let total = List.length groups in
  if total = 0 then { t with pulse_scroll_offset = 0 }
  else
    let current_group_idx =
      let sel_name =
        match t.selected_keeper with
        | Some _ as s -> s
        | None ->
            Option.map
              (fun (k : Wire_fleet.keeper_summary) -> k.name)
              (selected_company_keeper t)
      in
      let by_selected =
        match sel_name with
        | None -> None
        | Some name ->
            let rec find i = function
              | [] -> None
              | (g : Wire_fleet.company_group) :: rest ->
                  if
                    List.exists
                      (fun (k : Wire_fleet.keeper_summary) ->
                        String.equal k.name name)
                      g.keepers
                  then Some i
                  else find (i + 1) rest
            in
            find 0 groups
      in
      match by_selected with
      | Some idx -> idx
      | None -> clamp_index total t.selected_index
    in
    let target_idx = clamp_index total (current_group_idx + delta) in
    let vr =
      max 1 (Option.value ~default:Store_scroll.default_viewport_rows viewport_rows)
    in
    let max_pulse_scroll = max 0 (total - vr) in
    let pulse_scroll_offset =
      adjust_scroll ~viewport_rows:vr ~scroll:t.pulse_scroll_offset target_idx
      |> Store_scroll.clamp_scroll ~max_scroll:max_pulse_scroll
    in
    match List.nth_opt groups target_idx with
    | None -> { t with pulse_scroll_offset }
    | Some target_group -> (
        match target_group.keepers with
        | [] -> { t with pulse_scroll_offset }
        | lead :: _ ->
            let ks = filtered_keepers t in
            let selected_index =
              match index_of_keeper_name lead.name ks with
              | Some idx -> idx
              | None -> clamp_index (List.length ks) t.selected_index
            in
            let selected_keeper = Some lead.name in
            let changed =
              not (Option.equal String.equal t.selected_keeper selected_keeper)
            in
            let chat_scroll_offset =
              if changed then 0 else t.chat_scroll_offset
            in
            let header_row, vis_row =
              visual_row_for_selection t ~selected_index ~selected_keeper
            in
            let scroll_offset =
              adjust_grouped_scroll ~scroll:t.scroll_offset ~header_row vis_row
            in
            {
              t with
              selected_index;
              scroll_offset;
              pulse_scroll_offset;
              selected_keeper;
              chat_scroll_offset;
            })

let move_chat_scroll ?max_scroll ~delta t =
  let next =
    match max_scroll with
    | None -> max 0 (t.chat_scroll_offset + delta)
    | Some hi ->
        let hi = max 0 hi in
        let base = min hi t.chat_scroll_offset in
        max 0 (min hi (base + delta))
  in
  { t with chat_scroll_offset = next }

let reset_chat_scroll t = { t with chat_scroll_offset = 0 }

let set_filter filter_query t =
  let next = { t with filter_query } in
  sync_selection_after_change ~prev_index:0 ~reset_scroll:true
    ~clear_if_empty:false next

(* A roster change can mean a finished turn, so the turn records read for
   the Ctrl+T drawer go stale with the roster. *)
let mark_keepers_stale t =
  {
    t with
    keepers = Observed.mark_stale t.keepers;
    turns = Observed.mark_stale t.turns;
    turn_records = String_map.map Observed.mark_stale t.turn_records;
  }

let turn_records_for ~keeper t =
  match String_map.find_opt keeper t.turn_records with
  | Some obs -> obs
  | None -> Observed.unreported

let set_turn_records ~keeper obs t =
  { t with turn_records = String_map.add keeper obs t.turn_records }

let cut_reply_for ~keeper ~operation_id t =
  match Operation_map.find_opt (keeper, operation_id) t.cut_replies with
  | Some obs -> obs
  | None -> Observed.unreported

let set_cut_reply ~keeper ~operation_id obs t =
  {
    t with
    cut_replies = Operation_map.add (keeper, operation_id) obs t.cut_replies;
  }

(* A failure row stands for a cut reply when it is the first failure row of
   its operation and no assistant row of that operation is in the history.
   An assistant row with a delivery key sits only in the operation's
   Terminal_result slot (Keeper_chat_store_delivery_rules.validate_delivery_role),
   so it is the operation's delivered reply; a settled failure appended after
   it is a separate fact, not a cut (Keeper_chat_store
   .append_settled_failure_once). One operation can leave two failure rows,
   a Terminal_result one and a Settled_failure one; the reply is drawn once. *)
let cut_reply_rows ~keeper t =
  let messages =
    match String_map.find_opt keeper t.chat_histories with
    | None -> []
    | Some obs -> (
        match Observed.to_option obs with
        | Some (page : Wire_fleet.chat_history_page) -> page.messages
        | None -> [])
  in
  let replied =
    List.fold_left
      (fun acc (m : Wire_fleet.chat_message) ->
        match m.role, m.operation_id with
        | Wire_fleet.Role_assistant, Some op -> String_set.add op acc
        | ( ( Wire_fleet.Role_user
            | Wire_fleet.Role_peer _
            | Wire_fleet.Role_assistant
            | Wire_fleet.Role_system
            | Wire_fleet.Role_tool
            | Wire_fleet.Role_request_failure )
          , (Some _ | None) ) ->
            acc)
      String_set.empty messages
  in
  let _, rows =
    List.fold_left
      (fun (seen, rows) (m : Wire_fleet.chat_message) ->
        match m.role, m.operation_id with
        | Wire_fleet.Role_request_failure, Some op ->
            if String_set.mem op seen || String_set.mem op replied then
              (seen, rows)
            else (String_set.add op seen, (m.id, op) :: rows)
        | ( ( Wire_fleet.Role_user
            | Wire_fleet.Role_peer _
            | Wire_fleet.Role_assistant
            | Wire_fleet.Role_system
            | Wire_fleet.Role_tool
            | Wire_fleet.Role_request_failure )
          , (Some _ | None) ) ->
            (seen, rows))
      (String_set.empty, []) messages
  in
  List.rev rows

let cut_replies_by_row ~keeper t =
  List.fold_left
    (fun acc (row_id, operation_id) ->
      match
        Option.bind
          (Observed.to_option (cut_reply_for ~keeper ~operation_id t))
          Cut_reply.text
      with
      | Some text -> String_map.add row_id text acc
      | None -> acc)
    String_map.empty
    (cut_reply_rows ~keeper t)

let mark_chat_history_loading ~keeper t =
  match String_map.find_opt keeper t.chat_histories with
  | None ->
      {
        t with
        chat_histories =
          String_map.add keeper
            (Observed.loading ~since_ns:Clock.Mono.zero)
            t.chat_histories;
      }
  | Some _ -> t

let mark_chat_history_failed ~at ~keeper ~reason ~retryable t =
  match String_map.find_opt keeper t.chat_histories with
  | None
  | Some (Observed.Loading _ | Observed.Unreported | Observed.Failed _) ->
      {
        t with
        chat_histories =
          String_map.add keeper
            (Observed.failed ~at ~reason ~retryable)
            t.chat_histories;
      }
  | Some (Observed.Value _ | Observed.Absent) -> t

let mark_chat_history_stale ~keeper t =
  match String_map.find_opt keeper t.chat_histories with
  | None -> t
  | Some hist ->
      {
        t with
        chat_histories =
          String_map.add keeper (Observed.mark_stale hist) t.chat_histories;
      }

let mark_stale_all t =
  {
    t with
    shell = Observed.mark_stale t.shell;
    keepers = Observed.mark_stale t.keepers;
    turns = Observed.mark_stale t.turns;
    turn_records = String_map.map Observed.mark_stale t.turn_records;
    fleet_reading = Observed.mark_stale t.fleet_reading;
    chat_histories = String_map.map Observed.mark_stale t.chat_histories;
    cut_replies = Operation_map.map Observed.mark_stale t.cut_replies;
  }
