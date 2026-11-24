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

type tool_call_state =
  | Tool_pending
  | Tool_result_pending of { model_output_after_close : bool }
  | Tool_settled
  | Tool_unfinished

type active_tool_call = {
  tool_use_id : string;
  stream_scope : int option;
  tool_name : string;
  args_preview : string option;
  tool_state : tool_call_state;
  ok : bool option;
  output_preview : string option;
}

type chat_queue = {
  operations : Wire_fleet.chat_operation list;
  read : unit Observed.t;
}

type model_activity =
  | Waiting_for_content
  | Receiving_delta of Wire_fleet.model_content_channel
  | Receiving_response of {
      owner : Wire_chat_journal.response_owner;
      blocks : Wire_fleet.model_content_activity list;
    }
  | Response_stopped of Wire_chat_journal.response_owner

type chat_stream_buffer = {
  request_id : string;
  operation_id : string option;
  turn_ref : string option;
  run_started : bool;
  interrupting : bool;
  text : string;
  text_ownership : Cut_reply.ownership;
  thinking : string;
  model_activity : model_activity;
  tools : active_tool_call list;
  active : bool;
  ended : bool;
  last_error : string option;
}

let empty_model_activity = Waiting_for_content

let current_model_content buf =
  match buf.model_activity with
  | Waiting_for_content | Response_stopped _ -> None
  | Receiving_delta channel -> Some channel
  | Receiving_response { blocks; _ } ->
      List.find_map
        (fun (block : Wire_fleet.model_content_activity) ->
          match block.content_state with
          | Content_observed -> Some block.channel
          | Content_ended -> None)
        blocks

let current_tool buf =
  let receiving_content = Option.is_some (current_model_content buf) in
  List.fold_left
    (fun pending tool ->
      match tool.tool_state with
      | Tool_result_pending { model_output_after_close = true } when receiving_content ->
          pending
      | Tool_pending | Tool_result_pending _ -> Some tool
      | Tool_settled | Tool_unfinished -> pending)
    None buf.tools

type t = {
  shell : Wire_fleet.dashboard_shell Observed.t;
  raw_shell_scorecard : Wire_fleet.daily_scorecard option;
  keepers : Wire_fleet.keeper_summary list Observed.t;
  unreadable_keepers : Wire_fleet.unreadable_keeper list;
  turns : Wire_fleet.keeper_turn_row list Observed.t;
  interrupting_turn_tokens : string String_map.t;
  turn_records : Wire_fleet.keeper_turn_records Observed.t String_map.t;
  chat_control_tokens : string String_map.t;
  sandbox_profiles : Wire_fleet.keeper_sandbox_profile String_map.t;
  candle_balances_milli : int String_map.t;
  candle_summary_fallback : Wire_fleet.candle_observation option;
  turn_pulses : Wire_fleet.turn_pulse String_map.t;
  wall_unix : float;
  fleet_reading : Wire_fleet.fleet_stream_reading Observed.t;
  fleet_degradation : Wire_fleet.fleet_degradation option;
  fleet_mode : Nav.keepers_fleet_mode;
  selected_index : int;
  scroll_offset : int;
  pulse_scroll_offset : int;
  filter_query : string;
  selected_keeper : string option;
  selected_collapsed_company : string option;
  collapsed_companies : String_set.t;
  chat_histories : Wire_fleet.chat_history_page Observed.t String_map.t;
  chat_queues : chat_queue String_map.t;
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
    interrupting_turn_tokens = String_map.empty;
    turn_records = String_map.empty;
    chat_control_tokens = String_map.empty;
    sandbox_profiles = String_map.empty;
    candle_balances_milli = String_map.empty;
    candle_summary_fallback = None;
    turn_pulses = String_map.empty;
    wall_unix = 0.0;
    fleet_reading = Observed.unreported;
    fleet_degradation = None;
    fleet_mode = Nav.Fleet_companies;
    selected_index = 0;
    scroll_offset = 0;
    pulse_scroll_offset = 0;
    filter_query = "";
    selected_keeper = None;
    selected_collapsed_company = None;
    collapsed_companies = String_set.empty;
    chat_histories = String_map.empty;
    chat_queues = String_map.empty;
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

let count_newlines s =
  let n = ref 0 in
  String.iter (fun c -> if Char.equal c '\n' then incr n) s;
  !n

let chat_scroll_delta_for_text ~prev_text ~next_text =
  let d = count_newlines next_text - count_newlines prev_text in
  if d > 0 then d else 0

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

let working_detail_of_active_turn (turn_opt : Wire_fleet.active_turn option) =
  match turn_opt with
  | None -> Say.make ~ko:"턴 실행 중" ~en:"In turn"
  | Some turn -> (
      match turn.tool_in_flight with
      | Some tool ->
          Say.make ~ko:("도구 실행: " ^ tool) ~en:("Tool: " ^ tool)
      | None -> (
          match turn.preview with
          | Some p -> (
              match p.preparation with
              | Some { state = Wire_fleet.Prep_active; _ } ->
                  Say.make ~ko:"턴 준비 중" ~en:"Preparing turn"
              | Some { state = Wire_fleet.Prep_prepared; _ } ->
                  Say.make ~ko:"준비 완료" ~en:"Prepared"
              | Some
                  {
                    state =
                      ( Wire_fleet.Prep_rejected
                      | Wire_fleet.Prep_raised
                      | Wire_fleet.Prep_cancelled );
                    _;
                  } ->
                  Say.make ~ko:"준비 중단" ~en:"Preparation halted"
              | None -> (
                  match p.activity with
                  | Wire_fleet.Preview_tool_observed -> (
                      match p.last_tool with
                      | Some tool ->
                          Say.make
                            ~ko:("도구 활동: " ^ tool)
                            ~en:("Tool activity: " ^ tool)
                      | None ->
                          Say.make ~ko:"도구 활동 중" ~en:"Tool activity")
                  | Wire_fleet.Preview_streaming ->
                      Say.make ~ko:"응답 생성 중…" ~en:"Streaming…"
                  | Wire_fleet.Preview_waiting ->
                      Say.make ~ko:"응답 대기 중" ~en:"Waiting for model"
                  | Wire_fleet.Preview_preparing ->
                      Say.make ~ko:"턴 준비 중" ~en:"Preparing turn"
                  | Wire_fleet.Preview_failed ->
                      Say.make ~ko:"시도 실패" ~en:"Attempt failed"))
          | None -> (
              match turn.phase with
              | Some phase -> Say.literal phase
              | None -> Say.make ~ko:"턴 실행 중" ~en:"In turn")))

let keeper_live_state (k : Wire_fleet.keeper_summary) =
  match k.health with
  | Wire_fleet.Keeper_healthy -> (
      match k.active_turn with
      | Some _ -> Health.Working { detail = working_detail_of_active_turn k.active_turn }
      | None -> Health.Healthy)
  | Wire_fleet.Keeper_working ->
      Health.Working { detail = working_detail_of_active_turn k.active_turn }
  | Wire_fleet.Keeper_idle -> (
      match k.active_turn with
      | Some _ -> Health.Working { detail = working_detail_of_active_turn k.active_turn }
      | None -> Health.Idle)
  | Wire_fleet.Keeper_paused -> Health.Idle
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
          if Option.is_some k.active_turn then
            { acc with total; active = acc.active + 1; working = acc.working + 1 }
          else
            { acc with total; active = acc.active + 1; healthy = acc.healthy + 1 }
      | Wire_fleet.Keeper_idle ->
          if Option.is_some k.active_turn then
            { acc with total; active = acc.active + 1; working = acc.working + 1 }
          else if k.keepalive_running then
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

type companies_nav_row =
  | Nav_company_collapsed of string
  | Nav_keeper of Wire_fleet.keeper_summary

let companies_nav_rows t =
  let groups = Wire_fleet.group_by_company (filter_matched_keepers t) in
  List.concat_map
    (fun (g : Wire_fleet.company_group) ->
      if String_set.mem g.company t.collapsed_companies then
        [ Nav_company_collapsed g.company ]
      else List.map (fun k -> Nav_keeper k) g.keepers)
    groups

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
          let turns name =
            match String_map.find_opt name t.turn_pulses with
            | Some pulse -> Wire_fleet.turns_24h_of_pulse ~now_unix:t.wall_unix pulse
            | None -> 0
          in
          let c = Int.compare (turns b.name) (turns a.name) in
          if c <> 0 then c else String.compare a.name b.name)
        matched

let company_groups_with_costs ?attention ?now_unix ~keeper_costs_24h t =
  let sandbox_profiles = String_map.bindings t.sandbox_profiles in
  let turn_pulses = String_map.bindings t.turn_pulses in
  let now_unix =
    match now_unix with
    | Some _ as n -> n
    | None -> if Float.is_finite t.wall_unix && t.wall_unix > 0.0 then Some t.wall_unix else None
  in
  Wire_fleet.group_by_company ?attention ~sandbox_profiles ~keeper_costs_24h
    ?now_unix ~turn_pulses
    (filter_matched_keepers t)

let company_groups ?attention ?now_unix t =
  company_groups_with_costs ?attention ?now_unix ~keeper_costs_24h:[] t

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

let set_wall_unix w t =
  if Float.is_finite w && w > t.wall_unix then { t with wall_unix = w } else t

let sparkline_24h ~now_unix ~keeper t =
  match String_map.find_opt keeper t.turn_pulses with
  | Some pulse -> Wire_fleet.sparkline_24h_of_pulse ~now_unix pulse
  | None -> []

let keeper_turns_24h ~now_unix ~keeper t =
  match String_map.find_opt keeper t.turn_pulses with
  | Some pulse -> Some (Wire_fleet.turns_24h_of_pulse ~now_unix pulse)
  | None -> None

let total_turns_24h ~now_unix t =
  let ks = keepers_list t in
  let has_any, sum =
    List.fold_left
      (fun (has_any, acc) (k : Wire_fleet.keeper_summary) ->
        match String_map.find_opt k.name t.turn_pulses with
        | Some pulse ->
            (true, acc + Wire_fleet.turns_24h_of_pulse ~now_unix pulse)
        | None -> (has_any, acc))
      (false, 0) ks
  in
  if has_any then Some sum else None

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
  (* A roster refresh can remove the company the cursor sits on while its
     collapsed flag stays set. Keep the header selection only while its row is
     still one of the navigable rows. *)
  let selected_collapsed_company =
    match next.selected_collapsed_company with
    | None -> None
    | Some company ->
        let still_navigable =
          List.exists
            (function
              | Nav_company_collapsed name -> String.equal name company
              | Nav_keeper _ -> false)
            (companies_nav_rows next)
        in
        if still_navigable then Some company else None
  in
  if len = 0 then
    let selected_keeper = if clear_if_empty then None else next.selected_keeper in
    {
      next with
      selected_index = 0;
      scroll_offset = 0;
      pulse_scroll_offset;
      selected_keeper;
      selected_collapsed_company;
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
      selected_collapsed_company;
    }

let overlay_turns_on_keepers (rows : Wire_fleet.keeper_turn_row list)
    (ks : Wire_fleet.keeper_summary list) =
  List.map
    (fun (k : Wire_fleet.keeper_summary) ->
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
      | Some { state = Wire_fleet.Turn_unavailable _; _ } | None -> k)
    ks

let apply_keepers ~observed_at ks t =
  let prev_index = resolve_current_index t (filtered_keepers t) in
  let ks_with_turns =
    match Observed.to_option t.turns with
    | Some rows -> overlay_turns_on_keepers rows ks
    | None -> ks
  in
  let next = { t with keepers = Observed.value ~observed_at ks_with_turns } in
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
  let interrupting_turn_tokens =
    String_map.filter
      (fun keeper tok ->
        match
          List.find_opt
            (fun (r : Wire_fleet.keeper_turn_row) ->
              String.equal r.keeper_name keeper)
            rows
        with
        | Some { state = Wire_fleet.Turn_active turn; _ } ->
            String.equal turn.interrupt_token tok
        | Some { state = Wire_fleet.Turn_idle; _ } -> false
        | Some { state = Wire_fleet.Turn_unavailable _; _ } | None -> true)
      t.interrupting_turn_tokens
  in
  let keepers = Observed.map (overlay_turns_on_keepers rows) t.keepers in
  {
    t with
    turns = Observed.value ~observed_at rows;
    interrupting_turn_tokens;
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

let chat_queue_for ~keeper t =
  Option.value (String_map.find_opt keeper t.chat_queues)
    ~default:{ operations = []; read = Observed.unreported }

let set_chat_queue ~keeper queue t =
  { t with chat_queues = String_map.add keeper queue t.chat_queues }

let note_model_content current (event : Wire_fleet.model_content_activity) =
  let compare = Wire_chat_journal.compare_response_owner in
  let start () = Some (Receiving_response { owner = event.owner; blocks = [ event ] }) in
  match current with
  | Waiting_for_content | Receiving_delta _ -> start ()
  | Response_stopped owner ->
      if compare event.owner owner > 0 then start () else None
  | Receiving_response { owner; blocks } ->
      let order = compare event.owner owner in
      if order < 0 then None
      else if order > 0 then start ()
      else
        let same_block (block : Wire_fleet.model_content_activity) =
          Int.equal block.block_index event.block_index
        in
        match blocks with
        | latest :: _ when same_block latest
                           && latest.content_state = event.content_state
                           && latest.channel = event.channel ->
            Some current
        | _ :: _ | [] -> (
            match List.find_opt same_block blocks with
            | Some block when block.content_state = Content_ended || block.channel <> event.channel ->
                None
            | Some _ | None ->
                Some (Receiving_response
                  { owner; blocks = event :: List.filter (fun block -> not (same_block block)) blocks }))

let stop_model_response current owner =
  match owner, current with
  | None, (Waiting_for_content | Receiving_delta _) -> Waiting_for_content
  | None, (Receiving_response _ | Response_stopped _) -> current
  | Some owner, Receiving_response { owner = prev; _ } ->
      if Wire_chat_journal.compare_response_owner owner prev = 0 then
        Response_stopped owner
      else current
  | Some _, Response_stopped _ -> current
  | Some owner, (Waiting_for_content | Receiving_delta _) ->
      Response_stopped owner

let retire_model_activity = function
  | Waiting_for_content | Receiving_delta _ -> Waiting_for_content
  | Receiving_response { owner; _ } | Response_stopped owner -> Response_stopped owner

let note_unscoped_delta current channel delta =
  match current with
  | Waiting_for_content | Receiving_delta _ ->
      if String.equal delta "" then current else Receiving_delta channel
  | Receiving_response _ | Response_stopped _ -> current

let retire_pending_tool tool =
  match tool.tool_state with
  | Tool_pending | Tool_result_pending _ -> { tool with tool_state = Tool_unfinished }
  | Tool_settled | Tool_unfinished -> tool

let retire_pending_tools tools = List.map retire_pending_tool tools

let close_tool_block tool =
  match tool.tool_state with
  | Tool_pending ->
      { tool with tool_state = Tool_result_pending { model_output_after_close = false } }
  | Tool_result_pending _ | Tool_settled | Tool_unfinished -> tool

(* A provider can emit text after a tool block closes, before the tool runs.
   That text takes display precedence while it is open. A later provider
   scope starts after the earlier tool batch has returned. *)
let note_tool_during_model_output ~stream_scope tool =
  if Option.exists (fun scope -> scope < stream_scope) tool.stream_scope then
    retire_pending_tool tool
  else
    match tool.tool_state with
    | Tool_result_pending { model_output_after_close = false } ->
        { tool with tool_state = Tool_result_pending { model_output_after_close = true } }
    | Tool_pending | Tool_result_pending _ | Tool_settled | Tool_unfinished -> tool

let rec note_tools_during_model_output ~stream_scope = function
  | [] -> []
  | tool :: rest as tools ->
      let next = note_tool_during_model_output ~stream_scope tool in
      let next_rest = note_tools_during_model_output ~stream_scope rest in
      if next == tool && next_rest == rest then tools else next :: next_rest

let fresh_stream_buffer ~request_id =
  {
    request_id;
    operation_id = None;
    turn_ref = None;
    run_started = false;
    interrupting = false;
    text = "";
    text_ownership = Cut_reply.fresh_ownership;
    thinking = "";
    model_activity = empty_model_activity;
    tools = [];
    active = true;
    ended = false;
    last_error = None;
  }

let start_chat_stream ~keeper ~request_id t =
  let buf = fresh_stream_buffer ~request_id in
  { t with chat_streams = String_map.add keeper buf t.chat_streams }

let merge_opt_op prev_op incoming_op =
  match incoming_op with Some _ as x -> x | None -> prev_op

let is_explicit_execution_start = function
  | Wire_fleet.Chunk_run_started _
  | Wire_fleet.Chunk_runtime_attempt_started _ ->
      true
  | Wire_fleet.Chunk_accepted { state = Keeper_chat_operation.State_name.Running; _ } -> true
  | Wire_fleet.Chunk_accepted
      {
        state =
          ( Keeper_chat_operation.State_name.Queued
          | Keeper_chat_operation.State_name.Succeeded
          | Keeper_chat_operation.State_name.Failed
          | Keeper_chat_operation.State_name.Cancelled );
        _;
      }
  | Wire_fleet.Chunk_text_delta _
  | Wire_fleet.Chunk_thinking_delta _
  | Wire_fleet.Chunk_thinking_snapshot _
  | Wire_fleet.Chunk_model_content _
  | Wire_fleet.Chunk_model_response_stop _
  | Wire_fleet.Chunk_tool_start _
  | Wire_fleet.Chunk_tool_args _
  | Wire_fleet.Chunk_tool_block_end _
  | Wire_fleet.Chunk_tool_end _
  | Wire_fleet.Chunk_tool_quarantined _
  | Wire_fleet.Chunk_reply_details _
  | Wire_fleet.Chunk_turn_done _
  | Wire_fleet.Chunk_error _
  | Wire_fleet.Chunk_ignored ->
      false

let is_queued_acceptance = function
  | Wire_fleet.Chunk_accepted { state = Keeper_chat_operation.State_name.Queued; _ } -> true
  | Wire_fleet.Chunk_accepted
      {
        state =
          ( Keeper_chat_operation.State_name.Running
          | Keeper_chat_operation.State_name.Succeeded
          | Keeper_chat_operation.State_name.Failed
          | Keeper_chat_operation.State_name.Cancelled );
        _;
      }
  | Wire_fleet.Chunk_run_started _
  | Wire_fleet.Chunk_runtime_attempt_started _
  | Wire_fleet.Chunk_text_delta _
  | Wire_fleet.Chunk_thinking_delta _
  | Wire_fleet.Chunk_thinking_snapshot _
  | Wire_fleet.Chunk_model_content _
  | Wire_fleet.Chunk_model_response_stop _
  | Wire_fleet.Chunk_tool_start _
  | Wire_fleet.Chunk_tool_args _
  | Wire_fleet.Chunk_tool_block_end _
  | Wire_fleet.Chunk_tool_end _
  | Wire_fleet.Chunk_tool_quarantined _
  | Wire_fleet.Chunk_reply_details _
  | Wire_fleet.Chunk_turn_done _
  | Wire_fleet.Chunk_error _
  | Wire_fleet.Chunk_ignored ->
      false

(* Activity frames annotate the matching live buffer. They cannot admit a
   request, replace another buffer, or reopen a settled stream. *)
let update_live_stream ~keeper ~request_id ~operation_id update t =
  match String_map.find_opt keeper t.chat_streams with
  | Some b when b.active && String.equal b.request_id request_id
                && Option.for_all
                     (fun id -> Option.for_all (String.equal id) b.operation_id)
                     operation_id ->
      let updated = update b in
      if updated == b then t
      else
        { t with chat_streams = String_map.add keeper updated t.chat_streams }
  | Some _ | None -> t

let update_model_activity ~keeper ~request_id ~operation_id update t =
  update_live_stream ~keeper ~request_id ~operation_id
    (fun b ->
      let model_activity = update b.model_activity in
      if model_activity == b.model_activity then b else { b with model_activity })
    t

let update_stream_tool ~keeper ~request_id ~operation_id ~tool_use_id update t =
  update_live_stream ~keeper ~request_id ~operation_id
    (fun b ->
      let tools =
        List.map
          (fun tool ->
            if String.equal tool.tool_use_id tool_use_id then update tool else tool)
          b.tools
      in
      { b with tools })
    t

let apply_chat_stream_chunk ?(allow_takeover = false) ~keeper ~request_id chunk
    t =
  match chunk with
  | Wire_fleet.Chunk_ignored -> t
  | Wire_fleet.Chunk_model_content { operation_id; activity } ->
      update_live_stream ~keeper ~request_id ~operation_id
        (fun b ->
          match note_model_content b.model_activity activity with
          | None -> b
          | Some model_activity ->
              let tools =
                match activity.content_state with
                | Content_observed ->
                    note_tools_during_model_output ~stream_scope:activity.owner.stream_scope
                      b.tools
                | Content_ended -> b.tools
              in
              if model_activity == b.model_activity && tools == b.tools then b
              else { b with model_activity; tools })
        t
  | Wire_fleet.Chunk_model_response_stop { operation_id; owner } ->
      update_model_activity ~keeper ~request_id ~operation_id
        (fun current -> stop_model_response current owner) t
  | Wire_fleet.Chunk_tool_quarantined { operation_id; tool_use_id } ->
      update_stream_tool ~keeper ~request_id ~operation_id ~tool_use_id
        retire_pending_tool t
  | Wire_fleet.Chunk_tool_block_end { operation_id; tool_use_id } ->
      update_stream_tool ~keeper ~request_id ~operation_id ~tool_use_id
        close_tool_block t
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
        | Wire_fleet.Chunk_model_content _
        | Wire_fleet.Chunk_model_response_stop _
        | Wire_fleet.Chunk_tool_start _
        | Wire_fleet.Chunk_tool_args _
        | Wire_fleet.Chunk_tool_block_end _
        | Wire_fleet.Chunk_tool_end _
        | Wire_fleet.Chunk_tool_quarantined _
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
            then Some (fresh_stream_buffer ~request_id)
            else None
        | None ->
            if is_queued_acceptance chunk then None
            else Some (fresh_stream_buffer ~request_id)
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
                  | Keeper_chat_operation.State_name.Running -> true
                  | Keeper_chat_operation.State_name.Queued
                  | Keeper_chat_operation.State_name.Succeeded
                  | Keeper_chat_operation.State_name.Failed
                  | Keeper_chat_operation.State_name.Cancelled ->
                      false
                in
                let active =
                  match state with
                  | Keeper_chat_operation.State_name.Running -> true
                  | Keeper_chat_operation.State_name.Queued -> prev.run_started
                  | Keeper_chat_operation.State_name.Succeeded
                  | Keeper_chat_operation.State_name.Failed
                  | Keeper_chat_operation.State_name.Cancelled ->
                      false
                in
                let ended =
                  match state with
                  | Keeper_chat_operation.State_name.Queued | Keeper_chat_operation.State_name.Running ->
                      prev.ended
                  | Keeper_chat_operation.State_name.Succeeded
                  | Keeper_chat_operation.State_name.Failed
                  | Keeper_chat_operation.State_name.Cancelled ->
                      true
                in
                {
                  prev with
                  operation_id = Some operation_id;
                  run_started;
                  active;
                  ended;
                  tools = if ended then retire_pending_tools prev.tools else prev.tools;
                }
            | Wire_fleet.Chunk_run_started { operation_id } ->
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  run_started = true;
                  text = "";
                  text_ownership = Cut_reply.fresh_ownership;
                  thinking = "";
                  model_activity = empty_model_activity;
                  tools = retire_pending_tools prev.tools;
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
                  model_activity = retire_model_activity prev.model_activity;
                  tools = retire_pending_tools prev.tools;
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
                      model_activity =
                        note_unscoped_delta prev.model_activity Content_text delta;
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
                  model_activity =
                    note_unscoped_delta prev.model_activity Content_thinking delta;
                  active = true;
                }
            | Wire_fleet.Chunk_thinking_snapshot { operation_id; snapshot } ->
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  run_started = true;
                  thinking = snapshot;
                  model_activity =
                    note_unscoped_delta prev.model_activity Content_thinking snapshot;
                  active = true;
                }
            | Wire_fleet.Chunk_tool_start
                { operation_id; tool_use_id; stream_scope; tool_name; args_preview } ->
                let entry =
                  {
                    tool_use_id;
                    stream_scope;
                    tool_name;
                    args_preview;
                    tool_state = Tool_pending;
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
                  model_activity = stop_model_response prev.model_activity None;
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
                            tool_state = Tool_settled;
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
                          stream_scope = None;
                          tool_name = Option.value tool_name ~default:"tool";
                          args_preview = None;
                          tool_state = Tool_settled;
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
                  model_activity = retire_model_activity prev.model_activity;
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
                  tools = retire_pending_tools prev.tools;
                }
            | Wire_fleet.Chunk_error { operation_id; message; code = _ } ->
                {
                  prev with
                  operation_id = merge_opt_op prev.operation_id operation_id;
                  active = false;
                  ended = true;
                  interrupting = false;
                  last_error = Some message;
                  tools = retire_pending_tools prev.tools;
                }
            | Wire_fleet.Chunk_model_content _
            | Wire_fleet.Chunk_model_response_stop _
            | Wire_fleet.Chunk_tool_quarantined _
            | Wire_fleet.Chunk_tool_block_end _
            | Wire_fleet.Chunk_ignored -> prev
          in
          let chat_scroll_offset =
            if
              t.chat_scroll_offset > 0
              && Option.equal String.equal t.selected_keeper (Some keeper)
            then
              t.chat_scroll_offset
              + chat_scroll_delta_for_text ~prev_text:prev.text
                  ~next_text:updated.text
            else t.chat_scroll_offset
          in
          {
            t with
            chat_streams = String_map.add keeper updated t.chat_streams;
            chat_scroll_offset;
          })

let active_stream_for_operation ~keeper ~operation_id t =
  match String_map.find_opt keeper t.chat_streams with
  | Some b as found
    when b.active
         && (String.equal b.request_id operation_id
            || Option.equal String.equal b.operation_id (Some operation_id)) ->
      found
  | Some _ | None -> None

let set_operation_interrupting ~keeper ~operation_id ~interrupting t =
  match active_stream_for_operation ~keeper ~operation_id t with
  | Some b ->
      let next = { b with interrupting } in
      { t with chat_streams = String_map.add keeper next t.chat_streams }
  | None -> t

let is_operation_interrupting ~keeper ~operation_id t =
  Option.exists (fun b -> b.interrupting)
    (active_stream_for_operation ~keeper ~operation_id t)

let mark_turn_interrupting ~keeper ~interrupt_token t =
  {
    t with
    interrupting_turn_tokens =
      String_map.add keeper interrupt_token t.interrupting_turn_tokens;
  }

let is_turn_interrupting ~keeper ~interrupt_token t =
  match String_map.find_opt keeper t.interrupting_turn_tokens with
  | Some tok -> String.equal tok interrupt_token
  | None -> false

let clear_turn_interrupting ~keeper ~interrupt_token t =
  if is_turn_interrupting ~keeper ~interrupt_token t then
    {
      t with
      interrupting_turn_tokens =
        String_map.remove keeper t.interrupting_turn_tokens;
    }
  else t

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
          tools = retire_pending_tools b.tools;
          last_error =
            (match error with Some _ as e -> e | None -> b.last_error);
        }
      in
      { t with chat_streams = String_map.add keeper next t.chat_streams }
  | Some _ | None -> t

let detach_chat_streams t =
  {
    t with
    chat_queues = String_map.empty;
    chat_streams =
      String_map.map
        (fun (b : chat_stream_buffer) ->
          if b.active then
            { b with active = false; ended = true; interrupting = false;
                     tools = retire_pending_tools b.tools }
          else b)
        t.chat_streams;
  }

let set_fleet_mode fleet_mode t =
  let next = { t with fleet_mode; selected_collapsed_company = None } in
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

let visual_row_for_collapsed_company t company =
  let groups = Wire_fleet.group_by_company (filter_matched_keepers t) in
  let rec walk row = function
    | [] -> (0, 0)
    | (g : Wire_fleet.company_group) :: rest ->
        if String.equal g.company company then (row, row)
        else
          let step =
            if String_set.mem g.company t.collapsed_companies then 1
            else 1 + List.length g.keepers
          in
          walk (row + step) rest
  in
  walk 0 groups

let toggle_company_collapsed company t =
  let prev_index = resolve_current_index t (filtered_keepers t) in
  let was_collapsed = String_set.mem company t.collapsed_companies in
  let collapsed_companies =
    if was_collapsed then String_set.remove company t.collapsed_companies
    else String_set.add company t.collapsed_companies
  in
  let next = { t with collapsed_companies } in
  if not was_collapsed then
    let selected_was_in_company =
      match t.selected_keeper with
      | None -> true
      | Some sn ->
          let groups = Wire_fleet.group_by_company (filter_matched_keepers t) in
          List.exists
            (fun (g : Wire_fleet.company_group) ->
              String.equal g.company company
              && List.exists
                   (fun (k : Wire_fleet.keeper_summary) ->
                     String.equal k.name sn)
                   g.keepers)
            groups
    in
    let synced =
      sync_selection_after_change ~prev_index ~reset_scroll:false
        ~clear_if_empty:false next
    in
    let all_collapsed = filtered_keepers next = [] in
    if selected_was_in_company || all_collapsed then
      (* Collapsing the active company (or the last open company) anchors cursor
         on the collapsed company header so the operator can immediately
         re-expand it with Space/Enter instead of getting trapped outside. *)
      let header_row, vis_row = visual_row_for_collapsed_company next company in
      let scroll_offset =
        adjust_grouped_scroll ~scroll:t.scroll_offset ~header_row vis_row
      in
      {
        synced with
        selected_collapsed_company = Some company;
        scroll_offset;
      }
    else
      { synced with selected_collapsed_company = t.selected_collapsed_company }
  else
    (* Expanding clears collapsed-header focus and selects the first keeper in
       this company so the newly revealed members are immediately focused. *)
    let first_keeper_opt =
      let groups = Wire_fleet.group_by_company (filter_matched_keepers next) in
      List.find_map
        (fun (g : Wire_fleet.company_group) ->
          if String.equal g.company company then
            match g.keepers with k :: _ -> Some k.name | [] -> None
          else None)
        groups
    in
    let next1 =
      {
        next with
        selected_collapsed_company = None;
        selected_keeper =
          (match first_keeper_opt with
          | Some _ as k -> k
          | None -> next.selected_keeper);
      }
    in
    sync_selection_after_change ~prev_index ~reset_scroll:false
      ~clear_if_empty:false next1

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
        selected_collapsed_company = None;
        selected_index = idx;
        scroll_offset;
        chat_scroll_offset;
      }
  | None ->
      {
        t with
        selected_keeper = Some name;
        selected_collapsed_company = None;
        chat_scroll_offset;
      }

let move_selection ?viewport_rows ~delta t =
  match t.fleet_mode with
  | Nav.Fleet_companies ->
      let nav_rows = companies_nav_rows t in
      let nav_len = List.length nav_rows in
      if nav_len = 0 then { t with selected_collapsed_company = None }
      else
        let cur_nav =
          match t.selected_collapsed_company with
          | Some c ->
              let rec find i = function
                | [] -> 0
                | Nav_company_collapsed name :: _ when String.equal name c -> i
                | (Nav_company_collapsed _ | Nav_keeper _) :: rest ->
                    find (i + 1) rest
              in
              find 0 nav_rows
          | None -> (
              match t.selected_keeper with
              | Some sn ->
                  let rec find i = function
                    | [] -> clamp_index nav_len t.selected_index
                    | Nav_keeper k :: _ when String.equal k.name sn -> i
                    | (Nav_company_collapsed _ | Nav_keeper _) :: rest ->
                        find (i + 1) rest
                  in
                  find 0 nav_rows
              | None -> clamp_index nav_len t.selected_index)
        in
        let next_nav = clamp_index nav_len (cur_nav + delta) in
        (match List.nth_opt nav_rows next_nav with
        | Some (Nav_company_collapsed company) ->
            let header_row, vis_row =
              visual_row_for_collapsed_company t company
            in
            let scroll_offset =
              adjust_grouped_scroll ?viewport_rows ~scroll:t.scroll_offset
                ~header_row vis_row
            in
            {
              t with
              selected_collapsed_company = Some company;
              scroll_offset;
            }
        | Some (Nav_keeper k) ->
            let ks = filtered_keepers t in
            let selected_index =
              match index_of_keeper_name k.name ks with
              | Some idx -> idx
              | None -> clamp_index (List.length ks) t.selected_index
            in
            let selected_keeper = Some k.name in
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
              adjust_grouped_scroll ?viewport_rows ~scroll:t.scroll_offset
                ~header_row vis_row
            in
            {
              t with
              selected_index;
              scroll_offset;
              selected_keeper;
              selected_collapsed_company = None;
              chat_scroll_offset;
            }
        | None -> t)
  | Nav.Fleet_attention | Nav.Fleet_pulse_wall ->
      let ks = filtered_keepers t in
      let len = List.length ks in
      let cur = resolve_current_index t ks in
      let selected_index = clamp_index len (cur + delta) in
      let selected_keeper =
        match List.nth_opt ks selected_index with
        | Some k -> Some k.name
        | None -> None
      in
      let changed =
        not (Option.equal String.equal t.selected_keeper selected_keeper)
      in
      let chat_scroll_offset = if changed then 0 else t.chat_scroll_offset in
      let header_row, vis_row =
        visual_row_for_selection t ~selected_index ~selected_keeper
      in
      let scroll_offset =
        if len = 0 then 0
        else
          adjust_grouped_scroll ?viewport_rows ~scroll:t.scroll_offset
            ~header_row vis_row
      in
      {
        t with
        selected_index;
        scroll_offset;
        selected_keeper;
        selected_collapsed_company = None;
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
  let next = { t with filter_query; selected_collapsed_company = None } in
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
        match m.role, Wire_fleet.terminal_operation m with
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
        match m.role, Wire_fleet.terminal_operation m with
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
    chat_queues = String_map.map (fun q -> { q with read = Observed.mark_stale q.read }) t.chat_queues;
    cut_replies = Operation_map.map Observed.mark_stale t.cut_replies;
  }
