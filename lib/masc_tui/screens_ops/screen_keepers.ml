open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let attention_items_for_grouping (attn : Attention.t) :
    Wire_fleet.attention_item list =
  List.map
    (fun (e : Attention.entry) ->
      let bucket =
        match e.kind with
        | Health.Pending_ask _ -> Wire_fleet.Bucket_asks
        | Health.Held_tool_approval _ -> Wire_fleet.Bucket_approvals
        | Health.Goal_confirmation _ -> Wire_fleet.Bucket_confirmations
      in
      {
        Wire_fleet.id = e.id;
        bucket;
        kind = e.kind;
        title = e.title;
        summary = e.summary;
        created_at_unix = e.created_at_unix;
        keeper = e.keeper;
      })
    attn.items

type fleet_counts = {
  attn : int;
  working : int;
  healthy : int;
  failing : int;
  paused_idle : int;
  offline : int;
}

let keeper_row_status ~has_attention (k : Wire_fleet.keeper_summary) =
  if has_attention then Ops_common.keeper_live_status ~has_attention k
  else
    match k.health with
    | Wire_fleet.Keeper_offline ->
        ( Glyph.Live_idle
        , Theme.Status_historical
        , Say.make ~ko:"오프라인" ~en:"Offline" )
    | Wire_fleet.Keeper_healthy
    | Wire_fleet.Keeper_working
    | Wire_fleet.Keeper_idle
    | Wire_fleet.Keeper_degraded
    | Wire_fleet.Keeper_recovering
    | Wire_fleet.Keeper_failing
    | Wire_fleet.Keeper_paused
    | Wire_fleet.Keeper_booting ->
        Ops_common.keeper_live_status ~has_attention:false k

let count_fleet ~(model : Model.t) (ks : Wire_fleet.keeper_summary list) =
  let attn_n, non_attn =
    List.fold_left
      (fun (a, rest) (k : Wire_fleet.keeper_summary) ->
        if Ops_common.keeper_has_attention model.attention k.name then
          (a + 1, rest)
        else (a, k :: rest))
      (0, []) ks
  in
  let hc = Fleet_store.fleet_health_counts non_attn in
  {
    attn = attn_n;
    working = hc.working + hc.degraded;
    healthy = hc.healthy;
    failing = hc.failing;
    paused_idle = hc.paused;
    offline = hc.offline;
  }

let company_groups_for_model ~(model : Model.t) =
  let attn_items = attention_items_for_grouping model.attention in
  let keeper_costs_24h = Runtime_store.keeper_costs_24h_assoc model.runtime in
  Fleet_store.company_groups_with_costs ~attention:attn_items
    ~now_unix:model.freshness.last_wall_unix ~keeper_costs_24h model.fleet

let context_cell ~lang (obs : Wire_fleet.context_reading Observed.t) :
    Table.cell_content =
  match obs with
  | Observed.Value { data; _ } -> (
      match Fleet_store.context_display data with
      | Fleet_store.Context_fill { ratio; estimated } ->
          let gradient =
            if ratio >= 0.80 then Chart.Gradient.Thermal
            else Chart.Gradient.Cool_flow
          in
          Table.Gauge
            {
              ratio;
              gradient;
              label = Some (Fleet_store.context_fill_label ~estimated ratio);
            }
      | Fleet_store.Context_tokens_only tokens ->
          Table.text_cell
            (Format_val.format_value Format_val.Tokens (Float.of_int tokens))
      | Fleet_store.Context_unavailable reason ->
          Table.text_cell
            (Say.resolve lang (Fleet_store.context_unavailable_label reason)))
  | Observed.Loading _ ->
      Table.text_cell (Glyph.to_utf8 Glyph.Transport_reconnecting)
  | Observed.Absent ->
      Table.text_cell (Glyph.to_utf8 Glyph.Missing_absent)
  | Observed.Unreported ->
      Table.text_cell (Glyph.to_utf8 Glyph.Missing_unreported)
  | Observed.Failed _ ->
      Table.Badge
        {
          glyph = Some Glyph.Live_failing;
          text = "";
          tone = Theme.Status_critical;
        }

(* Cells a keeper name needs. The keeper column reserves them as its minimum
   because [Table] shares the cells left after the minimums by weight: every
   column added to the roster would otherwise take cells from the name.
   "e-masc-the-leader" is the widest name test_screens_ops draws at 90x28. *)
let keeper_name_cells = 17

(* The Companies mode indents each keeper under its company header. *)
let company_indent = "  "

let keeper_table_row ~(model : Model.t) ~(theme : Theme.t) ~indent_name
    (k : Wire_fleet.keeper_summary) : Table.row =
  let has_attn = Ops_common.keeper_has_attention model.attention k.name in
  let glyph, tone, _ = keeper_row_status ~has_attention:has_attn k in
  let infra_txt, infra_tone = Ops_common.keeper_sandbox_tag ~model k.name in
  let trail_n = Ops_common.keeper_incident_count model.incidents k.name in
  let trail_cell =
    if trail_n > 0 then
      Table.Badge
        {
          glyph = Some Glyph.Recovered;
          text = Int.to_string trail_n;
          tone = Theme.Status_historical;
        }
    else
      Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
        (Glyph.to_utf8 Glyph.Separator_dot)
  in
  let name_display = if indent_name then company_indent ^ k.name else k.name in
  let task_str = Ops_common.keeper_turn_summary ~lang:model.lang k in
  let spark_samples =
    Ops_common.samples_of_floats
      (Fleet_store.sparkline_24h ~now_unix:model.freshness.last_wall_unix
         ~keeper:k.name model.fleet)
  in
  let turns_str =
    Format_val.format_observed Format_val.Count
      (Observed.map Float.of_int k.total_turns)
      ~lang:model.lang
  in
  let cost_obs = Runtime_store.keeper_cost_usd ~keeper:k.name model.runtime in
  let cost_str = Format_val.format_observed Format_val.Usd cost_obs ~lang:model.lang in
  let muted_cell glyph = Table.text_cell ~fg:(Color.of_rgb theme.text_muted) (Glyph.to_utf8 glyph) in
  let next_cell =
    match Observed.to_option model.work.schedules with
    | None -> muted_cell Glyph.Missing_unreported
    | Some (rows, next_cursor) -> (
        match
          Keeper_cadence.next_due ~now_unix:model.freshness.last_wall_unix
            ~more_pages:(Option.is_some next_cursor)
            (Keeper_cadence.keeper_schedules ~name:k.name rows)
        with
        | Keeper_cadence.No_schedule -> muted_cell Glyph.Separator_dot
        | Keeper_cadence.Due_unknown | Keeper_cadence.Past_page_read ->
            muted_cell Glyph.Missing_absent
        | Keeper_cadence.Due_in s ->
            Table.text_cell ~fg:(Color.of_rgb theme.text_secondary) (Format_val.format_duration_s s)
        | Keeper_cadence.Late_by s ->
            Table.Badge
              {
                glyph = Some Glyph.Warning_triangle;
                text = Format_val.format_duration_s s;
                tone = Theme.Status_attention;
              })
  in
  {
    Table.id = k.name;
    cells =
      [
        ("status", Table.Badge { glyph = Some glyph; text = ""; tone });
        ("keeper", Table.text_cell name_display);
        ("company", Table.text_cell ~fg:(Color.of_rgb theme.text_secondary) k.company);
        ("task", Table.text_cell ~fg:(Color.of_rgb theme.text_secondary) task_str);
        ("ctx", context_cell ~lang:model.lang k.context);
        ("infra", Table.Badge { glyph = None; text = infra_txt; tone = infra_tone });
        ( "spark"
        , Table.Sparkline
            { samples = spark_samples; gradient = Chart.Gradient.Cool_flow } );
        ("turns", Table.text_cell ~fg:(Color.of_rgb theme.text_secondary) turns_str);
        ("next", next_cell);
        ("cost", Table.text_cell ~fg:(Color.of_rgb theme.text_secondary) cost_str);
        ("trail", trail_cell);
      ];
  }

let standard_roster_columns : Table.column list =
  [
    {
      id = "status";
      header = Say.make ~ko:"상태" ~en:"St";
      priority = 0;
      min_width = 3;
      max_width = Some 4;
      weight = 1;
      align = Table.Center;
    };
    {
      id = "keeper";
      header = Say.make ~ko:"키퍼" ~en:"Keeper";
      priority = 0;
      min_width = keeper_name_cells + String.length company_indent;
      max_width = Some 24;
      weight = 3;
      align = Table.Left;
    };
    {
      id = "task";
      header = Say.make ~ko:"실시간 턴 · 작업" ~en:"Live Turn / Task";
      priority = 2;
      min_width = 14;
      max_width = Some 28;
      weight = 3;
      align = Table.Left;
    };
    {
      id = "ctx";
      header = Say.make ~ko:"컨텍스트" ~en:"Ctx %";
      priority = 1;
      min_width = 10;
      max_width = Some 16;
      weight = 2;
      align = Table.Right;
    };
    {
      id = "infra";
      header = Say.make ~ko:"격리" ~en:"Env";
      priority = 3;
      min_width = 5;
      max_width = Some 6;
      weight = 1;
      align = Table.Center;
    };
    {
      id = "spark";
      header = Say.make ~ko:"24h 활동" ~en:"24h Pulse";
      priority = 4;
      min_width = 8;
      max_width = Some 14;
      weight = 2;
      align = Table.Left;
    };
    {
      id = "next";
      header = Say.make ~ko:"다음 예약" ~en:"Next due";
      priority = 4;
      min_width = 6;
      max_width = Some 10;
      weight = 1;
      align = Table.Right;
    };
    {
      id = "trail";
      header = Say.make ~ko:"이력" ~en:"Trail";
      priority = 5;
      min_width = 4;
      max_width = Some 6;
      weight = 1;
      align = Table.Right;
    };
  ]

let pulse_wall_columns : Table.column list =
  [
    {
      id = "status";
      header = Say.make ~ko:"상태" ~en:"St";
      priority = 0;
      min_width = 3;
      max_width = Some 4;
      weight = 1;
      align = Table.Center;
    };
    {
      id = "keeper";
      header = Say.make ~ko:"키퍼" ~en:"Keeper";
      priority = 0;
      min_width = keeper_name_cells;
      max_width = Some 22;
      weight = 2;
      align = Table.Left;
    };
    {
      id = "spark";
      header = Say.make ~ko:"24h 활동 펄스" ~en:"24h Activity Wall";
      priority = 1;
      min_width = 12;
      max_width = Some 24;
      weight = 4;
      align = Table.Left;
    };
    {
      id = "turns";
      header = Say.make ~ko:"턴" ~en:"Turns";
      priority = 2;
      min_width = 6;
      max_width = Some 9;
      weight = 1;
      align = Table.Right;
    };
    {
      id = "next";
      header = Say.make ~ko:"다음 예약" ~en:"Next due";
      priority = 4;
      min_width = 6;
      max_width = Some 10;
      weight = 1;
      align = Table.Right;
    };
    {
      id = "ctx";
      header = Say.make ~ko:"컨텍스트" ~en:"Ctx %";
      priority = 3;
      min_width = 10;
      max_width = Some 14;
      weight = 2;
      align = Table.Right;
    };
    {
      id = "cost";
      header = Say.make ~ko:"24h 비용" ~en:"24h Spend";
      priority = 4;
      min_width = 8;
      max_width = Some 11;
      weight = 1;
      align = Table.Right;
    };
    {
      id = "trail";
      header = Say.make ~ko:"이력" ~en:"Trail";
      priority = 5;
      min_width = 4;
      max_width = Some 6;
      weight = 1;
      align = Table.Right;
    };
  ]

let format_fleet_counts (c : fleet_counts) =
  let buf = Buffer.create 32 in
  let add g n =
    if n > 0 then begin
      if Buffer.length buf > 0 then Buffer.add_char buf ' ';
      Buffer.add_string buf (Glyph.to_utf8 g);
      Buffer.add_string buf (Int.to_string n)
    end
  in
  add Glyph.Action_required c.attn;
  add Glyph.Live_failing c.failing;
  add Glyph.Live_working c.working;
  add Glyph.Live_healthy c.healthy;
  add Glyph.Live_paused c.paused_idle;
  add Glyph.Live_idle c.offline;
  Buffer.contents buf

let format_company_infra_mix (grp : Wire_fleet.company_group) =
  let parts = ref [] in
  if grp.docker_count > 0 then
    parts := Printf.sprintf "%ddkr" grp.docker_count :: !parts;
  if grp.ssh_count > 0 then
    parts := Printf.sprintf "%dssh" grp.ssh_count :: !parts;
  if grp.microvm_count > 0 then
    parts := Printf.sprintf "%dvm" grp.microvm_count :: !parts;
  String.concat " " !parts

let company_group_header_row ~(model : Model.t) ~(theme : Theme.t) ~collapsed
    (grp : Wire_fleet.company_group) : Table.row =
  let arrow =
    if collapsed then Glyph.to_utf8 Glyph.Expand_closed
    else Glyph.to_utf8 Glyph.Expand_open
  in
  let counts = format_fleet_counts (count_fleet ~model grp.keepers) in
  let infra_mix = format_company_infra_mix grp in
  let cost_s =
    if grp.cost_24h_usd > 0.005 then Printf.sprintf "$%.2f" grp.cost_24h_usd
    else ""
  in
  let turns_s =
    if grp.turns_24h > 0 then Printf.sprintf "%dt" grp.turns_24h else ""
  in
  let summary_parts =
    List.filter
      (fun s -> String.length s > 0)
      [ counts; infra_mix; turns_s; cost_s ]
  in
  {
    Table.id = "company:" ^ grp.company;
    cells =
      [
        ("status", Table.text_cell ~fg:(Color.of_rgb theme.accent) ~attrs:Attr.bold arrow);
        ( "keeper"
        , Table.text_cell ~fg:(Color.of_rgb theme.text_bright) ~attrs:Attr.bold
            (Printf.sprintf "%s (%d)" grp.company (List.length grp.keepers)) );
        ( "task"
        , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
            (String.concat " · " summary_parts) );
        ( "spark"
        , Table.Sparkline
            {
              samples = Ops_common.samples_of_floats grp.sparkline_24h;
              gradient = Chart.Gradient.Cool_flow;
            } );
      ];
  }

let draw_semantic_fleet_counts grid ~clip ~x ~y ~(theme : Theme.t) ~bg
    (c : fleet_counts) =
  let items =
    [
      (Glyph.Action_required, c.attn, Theme.Status_attention);
      (Glyph.Live_failing, c.failing, Theme.Status_critical);
      (Glyph.Live_working, c.working, Theme.Status_active);
      (Glyph.Live_healthy, c.healthy, Theme.Status_ok);
      (Glyph.Live_paused, c.paused_idle, Theme.Status_historical);
      (Glyph.Live_idle, c.offline, Theme.Status_historical);
    ]
    |> List.filter (fun (_, n, _) -> n > 0)
  in
  let cx = ref x in
  List.iteri
    (fun idx (g, n, tok) ->
      if !cx < Rect.right clip then begin
        if idx > 0 then incr cx;
        let s = Printf.sprintf "%s%d" (Glyph.to_utf8 g) n in
        let adv =
          Ops_common.put_line ~clip grid ~x:!cx ~y
            ~max_w:(Int.max 0 (Rect.right clip - !cx))
            ~style:(Typography.status ~bg ~bold:true theme tok)
            s
        in
        cx := !cx + adv
      end)
    items;
  !cx - x

(* Left Company/Group Fleet Tree rail (~36% width) used in Wide/Standard split *)
let render_narrow_company_rail grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  let selected_name =
    match Fleet_store.selected_keeper_summary model.fleet with
    | Some k -> Some k.name
    | None -> None
  in
  let groups = company_groups_for_model ~model in
  let flat_rows =
    match model.fleet.fleet_mode with
    | Nav.Fleet_companies ->
        List.concat_map
          (fun (g : Wire_fleet.company_group) ->
            let collapsed =
              Fleet_store.String_set.mem g.company
                model.fleet.collapsed_companies
            in
            let hdr = `Company (g, collapsed) in
            if collapsed then [ hdr ]
            else hdr :: List.map (fun k -> `Keeper k) g.keepers)
          groups
    | Nav.Fleet_attention | Nav.Fleet_pulse_wall ->
        List.map (fun k -> `Keeper k) (Fleet_store.filtered_keepers model.fleet)
  in
  let total = List.length flat_rows in
  if total = 0 then
    Ops_common.draw_observed_empty grid ~rect ~theme ~lang:model.lang
      model.fleet.keepers
      ~empty_msg:(Say.make ~ko:"표시할 키퍼가 없습니다" ~en:"No keepers match filter")
  else
    let has_any_spark =
      List.exists
        (function
          | `Keeper (k : Wire_fleet.keeper_summary) ->
              Option.is_some (Fleet_store.turn_pulse model.fleet k.name)
          | `Company _ -> false)
        flat_rows
    in
    let rail_context_fill (k : Wire_fleet.keeper_summary) =
      match Observed.to_option k.context with
      | Some reading -> (
          match Fleet_store.context_display reading with
          | Fleet_store.Context_fill { ratio; estimated } -> Some (ratio, estimated)
          | Fleet_store.Context_tokens_only _ | Fleet_store.Context_unavailable _
            ->
              None)
      | None -> None
    in
    let has_any_ctx =
      List.exists
        (function
          | `Keeper (k : Wire_fleet.keeper_summary) ->
              Option.is_some (rail_context_fill k)
          | `Company _ -> false)
        flat_rows
    in
    let has_any_infra =
      Observed.is_value model.infra.sandboxes
      || not (Fleet_store.String_map.is_empty model.fleet.sandbox_profiles)
    in
    let trail_col_w =
      List.fold_left
        (fun acc row ->
          match row with
          | `Keeper (k : Wire_fleet.keeper_summary) ->
              let n = Ops_common.keeper_incident_count model.incidents k.name in
              if n > 0 then
                let s =
                  Printf.sprintf "%s%d" (Glyph.to_utf8 Glyph.Recovered) n
                in
                Int.max acc (Grapheme.display_width s)
              else acc
          | `Company _ -> acc)
        0 flat_rows
    in
    let spark_w = if has_any_spark && rect.w >= 40 then 5 else 0 in
    let ctx_w = if has_any_ctx && rect.w >= 34 then 8 else 0 in
    let infra_w = if has_any_infra && rect.w >= 26 then 4 else 0 in
    let header_h = if rect.h >= 4 then 2 else if rect.h >= 3 then 1 else 0 in
    if header_h >= 1 then begin
      let bg = Color.of_rgb theme.surface_2 in
      let h_st = Typography.structure ~bg ~bold:true theme in
      let hdr_rect = Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:1 in
      Cell_grid.fill_rect ~clip:rect grid ~rect:hdr_rect ~style:h_st ();
      ignore
        (Ops_common.put_line ~clip:hdr_rect grid ~x:(rect.x + 4) ~y:rect.y
           ~max_w:(Int.max 6 (rect.w - 4))
           ~style:h_st
           (Ops_common.say model ~ko:"조직 · 키퍼" ~en:"Company / Keeper"));
      let hx = ref (Rect.right hdr_rect - 1) in
      if trail_col_w > 0 then begin
        hx := !hx - trail_col_w;
        ignore
          (Ops_common.put_line ~clip:hdr_rect grid ~x:!hx ~y:rect.y
             ~max_w:trail_col_w ~style:h_st (Glyph.to_utf8 Glyph.Recovered));
        hx := !hx - 1
      end;
      if spark_w > 0 then begin
        hx := !hx - spark_w;
        ignore
          (Ops_common.put_line ~clip:hdr_rect grid ~x:!hx ~y:rect.y
             ~max_w:spark_w ~style:h_st "24h");
        hx := !hx - 1
      end;
      if ctx_w > 0 then begin
        hx := !hx - ctx_w;
        ignore
          (Ops_common.put_line ~clip:hdr_rect grid ~x:!hx ~y:rect.y
             ~max_w:ctx_w ~style:h_st "Ctx");
        hx := !hx - 1
      end;
      if infra_w > 0 then begin
        hx := !hx - infra_w;
        ignore
          (Ops_common.put_line ~clip:hdr_rect grid ~x:!hx ~y:rect.y
             ~max_w:infra_w ~style:h_st
             (Ops_common.say model ~ko:"격리" ~en:"Env"))
      end;
      if header_h = 2 then
        Card.draw_hairline ~pad_x:0 ~bg:(Color.of_rgb theme.surface_1) grid
          ~rect ~y:(rect.y + 1) ~theme
    end;
    let body_y = rect.y + header_h in
    let body_h = Int.max 0 (rect.h - header_h) in
    let arr = Array.of_list flat_rows in
    let sel_row_idx =
      let rec find i =
        if i >= total then None
        else
          match arr.(i), selected_name with
          | `Keeper k, Some sn when String.equal k.name sn -> Some i
          | _ -> find (i + 1)
      in
      find 0
    in
    let start, _ =
      Table.compute_viewport ~total_rows:total ~viewport_rows:body_h
        ~scroll:model.fleet.scroll_offset ~selected:sel_row_idx
    in
    let visible = Int.min body_h (total - start) in
    for i = 0 to visible - 1 do
      let idx = start + i in
      let py = body_y + i in
      let row_rect = Rect.make ~x:rect.x ~y:py ~w:rect.w ~h:1 in
      match arr.(idx) with
      | `Company (grp, collapsed) ->
          let bg = Color.of_rgb theme.surface_2 in
          Cell_grid.fill_rect ~clip:rect grid ~rect:row_rect
            ~style:(Typography.structure ~bg theme) ();
          let arrow =
            if collapsed then Glyph.to_utf8 Glyph.Expand_closed
            else Glyph.to_utf8 Glyph.Expand_open
          in
          let counts = count_fleet ~model grp.keepers in
          let counts_txt = format_fleet_counts counts in
          let counts_w = Grapheme.display_width counts_txt in
          let extra_meta =
            let infra = format_company_infra_mix grp in
            let turns_cost =
              match grp.turns_24h > 0, grp.cost_24h_usd > 0.005 with
              | true, true ->
                  Printf.sprintf "%dt $%.1f" grp.turns_24h grp.cost_24h_usd
              | true, false -> Printf.sprintf "%dt" grp.turns_24h
              | false, true -> Printf.sprintf "$%.2f" grp.cost_24h_usd
              | false, false -> ""
            in
            let parts =
              List.filter (fun s -> String.length s > 0) [ infra; turns_cost ]
            in
            String.concat " " parts
          in
          let extra_w = Grapheme.display_width extra_meta in
          let show_extra = extra_w > 0 && rect.w >= counts_w + extra_w + 22 in
          let right_total_w =
            counts_w + (if show_extra then extra_w + 2 else 0)
          in
          let max_left = Int.max 8 (rect.w - right_total_w - 4) in
          let adv_arr =
            Ops_common.put_line ~clip:row_rect grid ~x:(rect.x + 1) ~y:py
              ~max_w:2 ~style:(Typography.accent ~bg ~bold:true theme)
              (arrow ^ " ")
          in
          ignore
            (Ops_common.put_line ~clip:row_rect grid
               ~x:(rect.x + 1 + adv_arr) ~y:py
               ~max_w:(Int.max 6 (max_left - adv_arr))
               ~style:(Typography.structure ~bg ~bold:true theme)
               (Printf.sprintf "%s (%d)" grp.company (List.length grp.keepers)));
          let rx = ref (Rect.right row_rect - 1) in
          if counts_w > 0 && rect.w > counts_w + 12 then begin
            rx := !rx - counts_w;
            ignore
              (draw_semantic_fleet_counts grid ~clip:row_rect ~x:!rx ~y:py
                 ~theme ~bg counts);
            rx := !rx - 2
          end;
          if show_extra && !rx - extra_w > rect.x + 12 then begin
            rx := !rx - extra_w;
            ignore
              (Ops_common.put_line ~clip:row_rect grid ~x:!rx ~y:py
                 ~max_w:extra_w ~style:(Typography.whisper ~bg theme)
                 extra_meta)
          end
      | `Keeper k ->
          let is_sel =
            match selected_name with
            | Some sn -> String.equal k.name sn
            | None -> false
          in
          let rail_focused = Model.pane_focused model 0 in
          let bg_rgb =
            if is_sel && rail_focused then theme.selection_bg
            else if is_sel then theme.surface_2
            else theme.surface_1
          in
          let bg = Color.of_rgb bg_rgb in
          let base_st =
            if is_sel && rail_focused then Typography.anchor ~bg theme
            else if is_sel then Typography.primary ~bg theme
            else Typography.primary ~bg theme
          in
          Cell_grid.fill_rect ~clip:rect grid ~rect:row_rect ~style:base_st ();
          let has_attn = Ops_common.keeper_has_attention model.attention k.name in
          let glyph, tone, _ =
            keeper_row_status ~has_attention:has_attn k
          in
          (* Calm v2.5 selection: Left_rail (▎) in accent Bold when focused,
             muted border_inactive when focus moved to Preview/Composer. *)
          if is_sel then begin
            let rail_color =
              if rail_focused then theme.accent else theme.border_inactive
            in
            Card.draw_left_rail ~bg ~color:rail_color grid ~x:rect.x ~y:py
              ~h:1 ~theme
          end;
          Cell_grid.put_glyph ~clip:row_rect grid ~x:(rect.x + 2) ~y:py
            ~style:(Typography.status ~bg ~bold:true theme tone)
            glyph;
          let trail_n = Ops_common.keeper_incident_count model.incidents k.name in
          let trail_str =
            if trail_n > 0 then
              Printf.sprintf "%s%d" (Glyph.to_utf8 Glyph.Recovered) trail_n
            else ""
          in
          let trail_w = Grapheme.display_width trail_str in
          let reserved_right =
            1
            + (if trail_col_w > 0 then trail_col_w + 1 else 0)
            + (if spark_w > 0 then spark_w + 1 else 0)
            + (if ctx_w > 0 then ctx_w + 1 else 0)
            + (if infra_w > 0 then infra_w + 1 else 0)
          in
          let name_x = rect.x + 4 in
          let name_w = Int.max 6 (rect.w - 4 - reserved_right) in
          ignore
            (Ops_common.put_line ~clip:row_rect grid ~x:name_x ~y:py
               ~max_w:name_w ~style:base_st k.name);
          let rx = ref (Rect.right row_rect - 1) in
          if trail_col_w > 0 then begin
            rx := !rx - trail_col_w;
            if trail_w > 0 then
              ignore
                (Ops_common.put_line ~clip:row_rect grid ~x:!rx ~y:py
                   ~max_w:trail_col_w
                   ~style:(Typography.status ~bg theme Theme.Status_historical)
                   trail_str);
            rx := !rx - 1
          end;
          if spark_w > 0 then begin
            rx := !rx - spark_w;
            let samples =
              Ops_common.samples_of_floats
                (Fleet_store.sparkline_24h
                   ~now_unix:model.freshness.last_wall_unix ~keeper:k.name
                   model.fleet)
            in
            ignore
              (Chart.draw_sparkline_run ~clip:row_rect grid ~x:!rx ~y:py
                 ~width:spark_w ~theme ~bg ~unicode:true
                 ~gradient:Chart.Gradient.Cool_flow samples);
            rx := !rx - 1
          end;
          if ctx_w > 0 then begin
            rx := !rx - ctx_w;
            (match rail_context_fill k with
            | Some (ratio, estimated) ->
                let bar_w = 3 in
                ignore
                  (Chart.draw_ratio_bar_run ~clip:row_rect grid ~x:!rx ~y:py
                     ~width:bar_w ~theme ~bg ~unicode:true
                     ~gradient:
                       (if ratio >= 0.80 then Chart.Gradient.Thermal
                        else Chart.Gradient.Cool_flow)
                     ~ratio);
                let pct_s = Fleet_store.context_fill_label ~estimated ratio in
                ignore
                  (Ops_common.put_line ~clip:row_rect grid
                     ~x:(!rx + bar_w + 1) ~y:py
                     ~max_w:(ctx_w - bar_w - 1)
                     ~style:(Typography.structure ~bg theme)
                     pct_s)
            | None ->
                ignore
                  (Ops_common.put_line ~clip:row_rect grid
                     ~x:(!rx + ctx_w - 1) ~y:py ~max_w:1
                     ~style:(Typography.whisper ~bg ~italic:false theme)
                     (Glyph.to_utf8 Glyph.Missing_absent)));
            rx := !rx - 1
          end;
          if infra_w > 0 then begin
            rx := !rx - infra_w;
            let itag, itone = Ops_common.keeper_sandbox_tag ~model k.name in
            ignore
              (Ops_common.put_line ~clip:row_rect grid ~x:!rx ~y:py
                 ~max_w:infra_w ~style:(Typography.status ~bg theme itone) itag)
          end
    done;
    (* Fill spare bottom space cleanly with Fleet Summary & Infra/Turns Rollup *)
    let used_rows = header_h + visible in
    let spare_y = rect.y + used_rows in
    if spare_y < Rect.bottom rect then begin
      let counts = count_fleet ~model (Fleet_store.filtered_keepers model.fleet) in
      let bg = Color.of_rgb theme.surface_1 in
      Card.draw_hairline ~pad_x:1 ~bg grid ~rect ~y:spare_y ~theme;
      if spare_y + 1 < Rect.bottom rect then begin
        let clip_s = Rect.make ~x:(rect.x + 1) ~y:(spare_y + 1) ~w:(Int.max 0 (rect.w - 2)) ~h:1 in
        let adv =
          draw_semantic_fleet_counts grid ~clip:clip_s ~x:(rect.x + 1)
            ~y:(spare_y + 1) ~theme ~bg counts
        in
        let vm_n, ssh_n, _ = Fleet_store.fleet_infra_counts model.fleet in
        let turns_part =
          match
            Fleet_store.total_turns_24h
              ~now_unix:model.freshness.last_wall_unix model.fleet
          with
          | Some t -> Printf.sprintf " · %dt" t
          | None -> ""
        in
        let infra_part =
          if vm_n + ssh_n > 0 then Printf.sprintf "%dvm %dssh%s" vm_n ssh_n turns_part
          else if String.length turns_part > 0 then turns_part
          else ""
        in
        if String.length infra_part > 0 && clip_s.w - adv >= 8 then begin
          let iw = Grapheme.display_width infra_part in
          ignore
            (Ops_common.put_line ~clip:clip_s grid
               ~x:(Rect.right clip_s - iw)
               ~y:(spare_y + 1) ~max_w:iw
               ~style:(Typography.whisper ~bg theme)
               infra_part)
        end
      end
    end

let aggregate_pulse_samples ~(model : Model.t)
    (ks : Wire_fleet.keeper_summary list) =
  let now_unix = model.freshness.last_wall_unix in
  let sparks =
    List.filter_map
      (fun (k : Wire_fleet.keeper_summary) ->
        match
          Fleet_store.sparkline_24h ~now_unix ~keeper:k.name model.fleet
        with
        | [] -> None
        | xs -> Some xs)
      ks
  in
  match sparks with
  | [] -> [||]
  | _ :: _ ->
      let n = Wire_fleet.pulse_window_slots_24h in
      let sums = Array.make n 0.0 in
      List.iter
        (fun spark ->
          List.iteri
            (fun i v ->
              if i < n && Float.is_finite v && v > 0.0 then
                sums.(i) <- sums.(i) +. v)
            spark)
        sparks;
      Array.map
        (fun v -> if v <= 0.0 then Chart.Series.Zero else Chart.Series.Value v)
        sums

let render_full_width_roster grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  let bp = Ops_common.layout_bp model in
  let ks = Fleet_store.filtered_keepers model.fleet in
  if ks = [] then
    Ops_common.draw_observed_empty grid ~rect ~theme ~lang:model.lang
      model.fleet.keepers
      ~empty_msg:
        (Say.make ~ko:"조건에 맞는 키퍼가 없습니다" ~en:"No keepers match current filter")
  else
    let bg = Color.of_rgb theme.surface_1 in
    let selected_name =
      match Fleet_store.selected_keeper_summary model.fleet with
      | Some k -> Some k.name
      | None -> None
    in
    match model.fleet.fleet_mode with
    | Nav.Fleet_companies ->
        let groups = company_groups_for_model ~model in
        let rows =
          List.concat_map
            (fun (grp : Wire_fleet.company_group) ->
              let collapsed =
                Fleet_store.String_set.mem grp.company
                  model.fleet.collapsed_companies
              in
              let hdr = company_group_header_row ~model ~theme ~collapsed grp in
              if collapsed then [ hdr ]
              else
                hdr
                :: List.map
                     (keeper_table_row ~model ~theme ~indent_name:true)
                     grp.keepers)
            groups
        in
        let selected_idx =
          match selected_name with
          | None -> None
          | Some sn ->
              let rec find i = function
                | [] -> None
                | (r : Table.row) :: rest ->
                    if String.equal r.id sn then Some i else find (i + 1) rest
              in
              find 0 rows
        in
        ignore
          (Table.draw grid ~rect ~theme ~caps:Ops_common.default_caps
             ~lang:model.lang ~scroll:model.fleet.scroll_offset
             ?selected:selected_idx ~col_gap:(Layout.table_col_gap bp)
             ~columns:standard_roster_columns rows)
    | Nav.Fleet_attention ->
        let counts = count_fleet ~model ks in
        let bucket_h = if rect.h >= 4 then 1 else 0 in
        let bucket_rect, tbl_rect = Rect.split_v rect ~top_h:bucket_h in
        if bucket_h = 1 then begin
          let total_trail =
            List.fold_left
              (fun acc (k : Wire_fleet.keeper_summary) ->
                acc + Ops_common.keeper_incident_count model.incidents k.name)
              0 ks
          in
          let strip =
            Printf.sprintf "%s %s %d  %s  %s %s %d  %s  %s %s %d  %s  %s %s %d  %s  %s %d %s"
              (Glyph.to_utf8 Glyph.Action_required)
              (Ops_common.say model ~ko:"즉시 조치/장애" ~en:"Action/Fault")
              (counts.attn + counts.failing)
              (Glyph.to_utf8 Glyph.Separator_dot)
              (Glyph.to_utf8 Glyph.Live_working)
              (Ops_common.say model ~ko:"작업 중" ~en:"Working")
              counts.working
              (Glyph.to_utf8 Glyph.Separator_dot)
              (Glyph.to_utf8 Glyph.Live_healthy)
              (Ops_common.say model ~ko:"정상" ~en:"Healthy")
              counts.healthy
              (Glyph.to_utf8 Glyph.Separator_dot)
              (Glyph.to_utf8 Glyph.Live_idle)
              (Ops_common.say model ~ko:"정지/대기" ~en:"Offline/Paused")
              (counts.offline + counts.paused_idle)
              (Glyph.to_utf8 Glyph.Separator_dot)
              (Glyph.to_utf8 Glyph.Recovered)
              total_trail
              (Ops_common.say model ~ko:"과거 이력 (라이브 상태 분리)"
                 ~en:"past trail (isolated from live)")
          in
          ignore
            (Ops_common.put_line ~clip:bucket_rect grid ~x:(bucket_rect.x + 2)
               ~y:bucket_rect.y
               ~max_w:(Int.max 0 (bucket_rect.w - 4))
               ~style:(Typography.structure ~bg theme)
               strip)
        end;
        let rows = List.map (keeper_table_row ~model ~theme ~indent_name:false) ks in
        let selected_idx =
          match selected_name with
          | None -> None
          | Some sn ->
              let rec find i = function
                | [] -> None
                | (r : Table.row) :: rest ->
                    if String.equal r.id sn then Some i else find (i + 1) rest
              in
              find 0 rows
        in
        ignore
          (Table.draw grid ~rect:tbl_rect ~theme ~caps:Ops_common.default_caps
             ~lang:model.lang ~scroll:model.fleet.scroll_offset
             ?selected:selected_idx ~col_gap:(Layout.table_col_gap bp)
             ~columns:standard_roster_columns rows)
    | Nav.Fleet_pulse_wall ->
        let samples = aggregate_pulse_samples ~model ks in
        let chart_h =
          if Array.length samples > 0 && rect.h >= 12 then Int.min 6 (rect.h / 3)
          else 0
        in
        let chart_rect, tbl_rect = Rect.split_v rect ~top_h:chart_h in
        if chart_h > 0 then begin
          let pad_x = Ops_common.pad_x_for ~model chart_rect in
          let padded_chart = Card.pad_inner ~pad_x chart_rect in
          let latest =
            let n = Array.length samples in
            match samples.(n - 1) with
            | Chart.Series.Value v -> Observed.value ~observed_at:Clock.Mono.zero v
            | Chart.Series.Zero -> Observed.value ~observed_at:Clock.Mono.zero 0.0
            | Chart.Series.Unread | Chart.Series.Absent -> Observed.unreported
          in
          let peak_v =
            Array.fold_left
              (fun acc s ->
                match s with
                | Chart.Series.Value v -> Float.max acc v
                | Chart.Series.Zero | Chart.Series.Unread | Chart.Series.Absent ->
                    acc)
              0.0 samples
          in
          let avg_obs =
            let sum, cnt =
              Array.fold_left
                (fun (s, c) sample ->
                  match sample with
                  | Chart.Series.Value v when Float.is_finite v -> (s +. v, c + 1)
                  | Chart.Series.Zero -> (s, c + 1)
                  | Chart.Series.Value _ | Chart.Series.Unread | Chart.Series.Absent ->
                      (s, c))
                (0.0, 0) samples
            in
            if cnt > 0 then
              Observed.value ~observed_at:Clock.Mono.zero
                (sum /. float_of_int cnt)
            else Observed.absent
          in
          let spec : Chart.Spec.t =
            {
              title =
                Say.make ~ko:"플릿 24시간 활동 펄스" ~en:"Fleet 24h Activity Pulse";
              kind =
                Chart.Spec.Time_series
                  {
                    series =
                      {
                        Chart.Series.label = Say.make ~ko:"턴/시간" ~en:"turns/h";
                        unit = Format_val.Count;
                        gradient = Chart.Gradient.Cool_flow;
                        samples;
                        current = latest;
                        peak = Observed.value ~observed_at:Clock.Mono.zero peak_v;
                        avg = avg_obs;
                        delta_pct = None;
                      };
                    scale = Chart.Scale.Auto_ceil { floor = 0.0; nice_step = true };
                    window = Chart.Time_window.Last_24h;
                  };
              hotkey_hint = None;
            }
          in
          ignore
            (Chart.draw grid ~rect:padded_chart ~theme
               ~caps:Ops_common.default_caps ~lang:model.lang
               ~show_title:false spec)
        end;
        let rows = List.map (keeper_table_row ~model ~theme ~indent_name:false) ks in
        let selected_idx =
          match selected_name with
          | None -> None
          | Some sn ->
              let rec find i = function
                | [] -> None
                | (r : Table.row) :: rest ->
                    if String.equal r.id sn then Some i else find (i + 1) rest
              in
              find 0 rows
        in
        ignore
          (Table.draw grid ~rect:tbl_rect ~theme ~caps:Ops_common.default_caps
             ~lang:model.lang ~scroll:model.fleet.scroll_offset
             ?selected:selected_idx ~col_gap:(Layout.table_col_gap bp)
             ~columns:pulse_wall_columns rows)

(* The roster lists a keeper whose meta did not read with only its name and
   the read error, so it has no row in the fleet table; it gets a line under
   the table instead, up to a third of the card. *)
let unreadable_lines_max = 3

let split_unreadable_area ~(model : Model.t) (rect : Rect.t) =
  let n = List.length model.fleet.unreadable_keepers in
  let h = Int.min (Int.min n unreadable_lines_max) (rect.h / 3) in
  if h <= 0 then (rect, Rect.empty) else Rect.split_v rect ~top_h:(rect.h - h)

let draw_unreadable_keepers grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let style = Typography.status ~bg theme Theme.Status_critical in
    let rows = model.fleet.unreadable_keepers in
    let total = List.length rows in
    List.iteri
      (fun i (u : Wire_fleet.unreadable_keeper) ->
        if i < rect.h then
          let line =
            if i = rect.h - 1 && total > rect.h then
              Say.resolve model.lang
                (Say.make
                   ~ko:(Printf.sprintf "설정을 읽지 못한 키퍼 %d개 더" (total - i))
                   ~en:(Printf.sprintf "%d more keepers with unreadable meta"
                          (total - i)))
            else
              Printf.sprintf "%s %s: %s"
                (Glyph.to_utf8 Glyph.Live_failing)
                u.name u.reason
          in
          ignore
            (Ops_common.put_line ~clip:rect grid ~x:rect.x ~y:(rect.y + i)
               ~max_w:rect.w ~style line))
      rows

let render ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Ops_common.theme_of_model model in
    let bp = Ops_common.layout_bp model in
    let all_ks = Fleet_store.filtered_keepers model.fleet in
    let selected_keeper_opt = Fleet_store.selected_keeper_summary model.fleet in
    let is_split =
      (Model.equal_breakpoint model.breakpoint Model.Wide
       || Model.equal_breakpoint model.breakpoint Model.Standard)
      && rect.w >= 104 && not model.nav.zoomed
    in
    if model.nav.zoomed && Option.is_some selected_keeper_opt then
      match selected_keeper_opt with
      | Some k ->
          Keeper_dive.render_tabs_body ~embedded:false ~name:k.name
            ~tab:model.fleet.keeper_dive_tab ~model ~cache ~rect grid
      | None -> ()
    else if is_split then
      (* True 36% / 64% Fleet Tree (clamped 34..46 cols) + Live Keeper Preview split *)
      let split_gap = Layout.card_gap_x bp in
      let split_budget = Int.max 0 (rect.w - split_gap) in
      let left_w =
        Int.max 34
          (Int.min 46
             (int_of_float (Float.floor (float_of_int split_budget *. 0.36))))
      in
      match
        Layout.split_h_bp bp rect [ Layout.Fixed left_w; Layout.Flex 1 ]
      with
      | [ left_rect; right_rect ] ->
          let counts = count_fleet ~model all_ks in
          let groups = company_groups_for_model ~model in
          let roster_spec : Card.spec =
            {
              (Card.default_spec
                 ~title:
                   (Printf.sprintf "%d %s" (List.length all_ks)
                      (Ops_common.say model ~ko:"키퍼 플릿" ~en:"Keepers Fleet")))
              with
              subtitle =
                Some
                  (Printf.sprintf "%d %s" (List.length groups)
                     (Ops_common.say model ~ko:"조직" ~en:"companies"));
              badge =
                (if counts.attn + counts.failing > 0 then
                   Some
                     {
                       Card.glyph = Some Glyph.Action_required;
                       text = Int.to_string (counts.attn + counts.failing);
                       tone = Some Theme.Status_attention;
                     }
                 else
                   Some
                     {
                       Card.glyph = Some Glyph.Live_healthy;
                       text = Int.to_string (counts.working + counts.healthy);
                       tone = Some Theme.Status_ok;
                     });
              hotkey = Some "/Filter";
              focused = Model.pane_focused model 0;
            }
          in
          let left_inner =
            Card.draw ~cache grid ~rect:left_rect ~theme roster_spec
          in
          let rail_rect, unreadable_rect =
            split_unreadable_area ~model left_inner
          in
          if not (Rect.is_empty rail_rect) then
            render_narrow_company_rail grid ~rect:rail_rect ~theme ~model;
          draw_unreadable_keepers grid ~rect:unreadable_rect ~theme ~model;
          (match selected_keeper_opt with
          | Some k ->
              Keeper_dive.render_tabs_body ~embedded:true ~name:k.name
                ~tab:model.fleet.keeper_dive_tab ~model ~cache ~rect:right_rect
                grid
          | None ->
              let empty_spec =
                Card.default_spec
                  ~title:(Ops_common.say model ~ko:"키퍼 상세" ~en:"Keeper Dive")
              in
              let r_inner =
                Card.draw ~cache grid ~rect:right_rect ~theme empty_spec
              in
              Ops_common.draw_observed_empty grid ~rect:r_inner ~theme
                ~lang:model.lang model.fleet.keepers
                ~empty_msg:
                  (Say.make ~ko:"왼쪽 목록에서 키퍼를 선택하세요"
                     ~en:"Select a keeper from the fleet roster"))
      | _ -> ()
    else
      let hc = Fleet_store.fleet_health_counts all_ks in
      let counts = count_fleet ~model all_ks in
      let roster_spec : Card.spec =
        {
          (Card.default_spec
             ~title:
               (Printf.sprintf "%s (%d)"
                  (Ops_common.say model ~ko:"키퍼 플릿" ~en:"Keepers Fleet")
                  (List.length all_ks)))
          with
          subtitle =
            Some
              (Say.resolve model.lang
                 (Nav.keepers_fleet_mode_label model.fleet.fleet_mode));
          badge =
            Some
              {
                Card.glyph =
                  Some
                    (if counts.attn + counts.failing > 0 then
                       Glyph.Action_required
                     else Glyph.Live_healthy);
                text = Printf.sprintf "%d/%d" hc.active hc.total;
                tone =
                  Some
                    (if counts.attn + counts.failing > 0 then
                       Theme.Status_attention
                     else Theme.Status_ok);
              };
          hotkey =
            Some
              (Ops_common.say model ~ko:"[Enter] 상세 · [←→] 모드"
                 ~en:"[Enter] Dive · [←→] Mode");
          focused = Model.body_has_focus model;
        }
      in
      let inner = Card.draw ~cache grid ~rect ~theme roster_spec in
      let roster_rect, unreadable_rect = split_unreadable_area ~model inner in
      if not (Rect.is_empty roster_rect) then
        render_full_width_roster grid ~rect:roster_rect ~theme ~model;
      draw_unreadable_keepers grid ~rect:unreadable_rect ~theme ~model

let render_dive ~name ~tab ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  Keeper_dive.render_tabs_body ~embedded:false ~name ~tab ~model ~cache ~rect
    grid
