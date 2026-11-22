open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_protocol

module String_map = Map.Make (String)
module String_set = Set.Make (String)

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
  text : string;
  thinking : string;
  tools : active_tool_call list;
  active : bool;
  last_error : string option;
}

type t = {
  shell : Wire_fleet.dashboard_shell Observed.t;
  raw_shell_scorecard : Wire_fleet.daily_scorecard option;
  keepers : Wire_fleet.keeper_summary list Observed.t;
  turns : Wire_fleet.keeper_turn_row list Observed.t;
  sandbox_profiles : Wire_fleet.keeper_sandbox_profile String_map.t;
  candle_balances_milli : int String_map.t;
  candle_summary_fallback : Wire_fleet.candle_summary_fallback option;
  fleet_reading : Wire_fleet.fleet_stream_reading Observed.t;
  fleet_degradation : Wire_fleet.fleet_degradation option;
  fleet_mode : Nav.keepers_fleet_mode;
  selected_index : int;
  scroll_offset : int;
  filter_query : string;
  selected_keeper : string option;
  collapsed_companies : String_set.t;
  chat_histories : Wire_fleet.chat_history_page Observed.t String_map.t;
  chat_streams : chat_stream_buffer String_map.t;
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
    turns = Observed.unreported;
    sandbox_profiles = String_map.empty;
    candle_balances_milli = String_map.empty;
    candle_summary_fallback = None;
    fleet_reading = Observed.unreported;
    fleet_degradation = None;
    fleet_mode = Nav.Fleet_companies;
    selected_index = 0;
    scroll_offset = 0;
    filter_query = "";
    selected_keeper = None;
    collapsed_companies = String_set.empty;
    chat_histories = String_map.empty;
    chat_streams = String_map.empty;
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
  | Wire_fleet.Keeper_offline ->
      Health.Down { reason = Say.make ~ko:"오프라인" ~en:"Offline" }

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

let keepers_list t =
  match Observed.to_option t.keepers with Some ks -> ks | None -> []

let filtered_keepers t =
  let q = String.trim t.filter_query in
  let base = keepers_list t in
  let matched =
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
  in
  match t.fleet_mode with
  | Nav.Fleet_companies -> matched
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
    (filtered_keepers t)

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

let clamp_index len idx =
  if len <= 0 then 0
  else if idx < 0 then 0
  else if idx >= len then len - 1
  else idx

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

let turns_list t =
  match Observed.to_option t.turns with Some rows -> rows | None -> []

let chat_control_token_for ~keeper t =
  match
    List.find_opt
      (fun (r : Wire_fleet.keeper_turn_row) ->
        String.equal r.keeper_name keeper)
      (turns_list t)
  with
  | Some row -> row.chat_control_token
  | None -> None

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

let apply_keepers ~observed_at ks t =
  let next = { t with keepers = Observed.value ~observed_at ks } in
  let visible = filtered_keepers next in
  let selected_index = clamp_index (List.length visible) next.selected_index in
  let selected_keeper =
    match next.selected_keeper with
    | Some name
      when List.exists
             (fun (k : Wire_fleet.keeper_summary) -> String.equal k.name name)
             ks ->
        Some name
    | Some _ | None -> (
        match List.nth_opt visible selected_index with
        | Some k -> Some k.name
        | None -> None)
  in
  { next with selected_index; selected_keeper }

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
  { t with sandbox_profiles; candle_balances_milli; candle_summary_fallback }

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
               let context_ratio =
                 if Observed.is_value k.context_ratio then k.context_ratio
                 else
                   match e.context_ratio with
                   | Some cr -> Observed.value ~observed_at cr
                   | None -> k.context_ratio
               in
               let total_turns =
                 if Observed.is_value k.total_turns then k.total_turns
                 else
                   match e.total_turns with
                   | Some tt -> Observed.value ~observed_at tt
                   | None -> k.total_turns
               in
               { k with context_ratio; total_turns }))
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
  { t with turns = Observed.value ~observed_at rows; keepers }

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

let start_chat_stream ~keeper ~request_id t =
  let buf =
    {
      request_id;
      operation_id = None;
      text = "";
      thinking = "";
      tools = [];
      active = true;
      last_error = None;
    }
  in
  { t with chat_streams = String_map.add keeper buf t.chat_streams }

let apply_chat_stream_chunk ~keeper ~request_id chunk t =
  let prev =
    match String_map.find_opt keeper t.chat_streams with
    | Some b when String.equal b.request_id request_id -> b
    | Some _ | None ->
        {
          request_id;
          operation_id = None;
          text = "";
          thinking = "";
          tools = [];
          active = true;
          last_error = None;
        }
  in
  let updated =
    match chunk with
    | Wire_fleet.Chunk_accepted { operation_id; _ } ->
        { prev with operation_id = Some operation_id; active = true }
    | Wire_fleet.Chunk_text_delta { operation_id; delta } ->
        {
          prev with
          operation_id = Some operation_id;
          text = prev.text ^ delta;
          active = true;
        }
    | Wire_fleet.Chunk_thinking_delta { operation_id; delta } ->
        {
          prev with
          operation_id = Some operation_id;
          thinking = prev.thinking ^ delta;
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
        { prev with operation_id = Some operation_id; tools; active = true }
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
                  { c with completed = true; ok = Some ok; output_preview }
                else c)
              prev.tools
          else
            prev.tools
            @ [
                {
                  tool_use_id;
                  tool_name;
                  args_preview = None;
                  completed = true;
                  ok = Some ok;
                  output_preview;
                };
              ]
        in
        { prev with operation_id = Some operation_id; tools; active = true }
    | Wire_fleet.Chunk_turn_done { operation_id; reply; _ } ->
        let text =
          if String.equal (String.trim reply) "" then prev.text else reply
        in
        { prev with operation_id = Some operation_id; text; active = false }
    | Wire_fleet.Chunk_error { operation_id; message; _ } ->
        {
          prev with
          operation_id =
            (match operation_id with
            | Some _ as o -> o
            | None -> prev.operation_id);
          active = false;
          last_error = Some message;
        }
  in
  { t with chat_streams = String_map.add keeper updated t.chat_streams }

let finish_chat_stream ~keeper ~request_id ~error t =
  match String_map.find_opt keeper t.chat_streams with
  | Some b when String.equal b.request_id request_id ->
      let next =
        {
          b with
          active = false;
          last_error =
            (match error with Some _ as e -> e | None -> b.last_error);
        }
      in
      { t with chat_streams = String_map.add keeper next t.chat_streams }
  | Some _ | None -> t

let set_fleet_mode fleet_mode t =
  { t with fleet_mode; selected_index = 0; scroll_offset = 0 }

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
  let collapsed_companies =
    if String_set.mem company t.collapsed_companies then
      String_set.remove company t.collapsed_companies
    else String_set.add company t.collapsed_companies
  in
  { t with collapsed_companies }

let select_keeper name t =
  let ks = filtered_keepers t in
  let idx_opt =
    let rec find i = function
      | [] -> None
      | (k : Wire_fleet.keeper_summary) :: rest ->
          if String.equal k.name name then Some i else find (i + 1) rest
    in
    find 0 ks
  in
  match idx_opt with
  | Some idx -> { t with selected_keeper = Some name; selected_index = idx }
  | None -> { t with selected_keeper = Some name }

let move_selection ~delta t =
  let ks = filtered_keepers t in
  let len = List.length ks in
  let selected_index = clamp_index len (t.selected_index + delta) in
  let scroll_offset =
    if selected_index < t.scroll_offset then selected_index
    else t.scroll_offset
  in
  let selected_keeper =
    match List.nth_opt ks selected_index with
    | Some k -> Some k.name
    | None -> t.selected_keeper
  in
  { t with selected_index; scroll_offset; selected_keeper }

let move_chat_scroll ~delta t =
  { t with chat_scroll_offset = max 0 (t.chat_scroll_offset + delta) }

let reset_chat_scroll t = { t with chat_scroll_offset = 0 }

let set_filter filter_query t =
  let next = { t with filter_query; selected_index = 0; scroll_offset = 0 } in
  let ks = filtered_keepers next in
  let selected_keeper =
    match ks with k :: _ -> Some k.name | [] -> next.selected_keeper
  in
  { next with selected_keeper }

let mark_keepers_stale t =
  {
    t with
    keepers = Observed.mark_stale t.keepers;
    turns = Observed.mark_stale t.turns;
  }

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
    fleet_reading = Observed.mark_stale t.fleet_reading;
    chat_histories = String_map.map Observed.mark_stale t.chat_histories;
  }
