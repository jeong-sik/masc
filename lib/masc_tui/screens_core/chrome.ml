open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

type frame_layout = {
  breakpoint : Layout.breakpoint;
  top_rail : Rect.t;
  sub_tab_bar : Rect.t option;
  sidebar : Rect.t option;
  sidebar_is_drawer : bool;
  body : Rect.t;
  approval_strip : Rect.t option;
  composer : Rect.t option;
  footer : Rect.t;
  chrome_rows : int;
  composer_folded : bool;
  is_micro_guard : bool;
  is_too_small : bool;
}

let has_sub_tab_bar (model : Model.t) =
  match Model.active_dive model with
  | Some _ -> true
  | None -> (
      match model.nav.workspace with
      | Nav.Pulse -> false
      | Nav.Work | Nav.Knowledge | Nav.Keepers | Nav.Runtime | Nav.Infra ->
          true)

let model_breakpoint_of_layout = function
  | Layout.Wide -> Model.Wide
  | Layout.Standard -> Model.Standard
  | Layout.Compact -> Model.Compact
  | Layout.Micro -> Model.Micro

let compute_layout ~(model : Model.t) ~cols ~rows =
  let cols = Int.max 0 cols in
  let rows = Int.max 0 rows in
  let breakpoint = Layout.classify_viewport ~cols ~rows in
  let is_too_small = Layout.is_too_small_blocker ~cols ~rows in
  let is_micro_guard =
    (not is_too_small) && Layout.equal_breakpoint breakpoint Layout.Micro
  in
  let top_rail =
    if rows >= 1 then Rect.make ~x:0 ~y:0 ~w:cols ~h:1 else Rect.empty
  in
  let footer =
    if rows >= 2 then Rect.make ~x:0 ~y:(rows - 1) ~w:cols ~h:1 else Rect.empty
  in
  if is_too_small || is_micro_guard then
    let body_h = Int.max 0 (rows - top_rail.h - footer.h) in
    let body =
      Layout.inset_body breakpoint (Rect.make ~x:0 ~y:top_rail.h ~w:cols ~h:body_h)
    in
    {
      breakpoint;
      top_rail;
      sub_tab_bar = None;
      sidebar = None;
      sidebar_is_drawer = false;
      body;
      approval_strip = None;
      composer = None;
      footer;
      chrome_rows = top_rail.h + footer.h;
      composer_folded = true;
      is_micro_guard;
      is_too_small;
    }
  else
    let sized_model =
      {
        model with
        viewport = { cols; rows };
        breakpoint = model_breakpoint_of_layout breakpoint;
      }
    in
    let show_sub_tab = has_sub_tab_bar model in
    let sub_h = if show_sub_tab && rows >= 5 then 1 else 0 in
    let sub_tab_bar =
      if sub_h = 1 then Some (Rect.make ~x:0 ~y:1 ~w:cols ~h:1)
      else None
    in
    let top_h = top_rail.h + sub_h in
    let comp_state = Render_util.composer_state_of_model sized_model in
    let comp_mode = Model.composer_mode sized_model in
    let composer_folded =
      Model.equal_composer_mode comp_mode Model.Auto_folded_pill
    in
    let comp_h =
      match comp_mode with
      | Model.Auto_folded_pill -> 0
      | Model.Collapsed_bar -> 1
      | Model.Expanded_multiline ->
          let max_h = Int.max 2 (Int.min 6 (rows / 4)) in
          Composer.desired_height ~breakpoint ~max_height:max_h comp_state
    in
    let has_approval = Option.is_some (Model.fast_approval_strip_item model) in
    let avail_after_top_footer = Int.max 0 (rows - top_h - footer.h) in
    let comp_h = Int.min comp_h (Int.max 0 (avail_after_top_footer - 3)) in
    let approval_h =
      if has_approval && avail_after_top_footer - comp_h >= 4 then 1 else 0
    in
    (* Subtle 1-row border_subtle hairline above the quiet footer when Wide
       height has ample breathing room. *)
    let footer_sep_h =
      if
        Layout.equal_breakpoint breakpoint Layout.Wide
        && rows >= 36
        && avail_after_top_footer - comp_h - approval_h >= 24
      then 1
      else 0
    in
    let footer_y = rows - footer.h in
    let comp_y = footer_y - footer_sep_h - comp_h in
    let approval_y = comp_y - approval_h in
    let composer =
      if comp_h > 0 then Some (Rect.make ~x:0 ~y:comp_y ~w:cols ~h:comp_h)
      else None
    in
    let approval_strip =
      if approval_h > 0 then
        Some (Rect.make ~x:0 ~y:approval_y ~w:cols ~h:approval_h)
      else None
    in
    let body_h = Int.max 0 (approval_y - top_h) in
    let full_body =
      Layout.inset_body breakpoint (Rect.make ~x:0 ~y:top_h ~w:cols ~h:body_h)
    in
    let sidebar, sidebar_is_drawer, body =
      if
        Model.sidebar_docked sized_model
        && full_body.w >= Model.sidebar_width + 20
      then
        let sw = Model.sidebar_width in
        let gap = Model.sidebar_gap in
        let sb_rect =
          Rect.make ~x:full_body.x ~y:full_body.y ~w:sw ~h:full_body.h
        in
        let b_rect =
          Rect.make ~x:(full_body.x + sw + gap) ~y:full_body.y
            ~w:(Int.max 0 (full_body.w - sw - gap))
            ~h:full_body.h
        in
        (Some sb_rect, false, b_rect)
      else if Model.sidebar_drawer_open sized_model && full_body.w >= 20 then
        let dw = Int.min (Model.sidebar_width + 2) (Int.max 18 (cols - 4)) in
        let dx = if cols > dw + 2 then 1 else 0 in
        let sb_rect = Rect.make ~x:dx ~y:top_h ~w:dw ~h:body_h in
        (Some sb_rect, true, full_body)
      else (None, false, full_body)
    in
    let chrome_rows = top_h + approval_h + comp_h + footer_sep_h + footer.h in
    {
      breakpoint;
      top_rail;
      sub_tab_bar;
      sidebar;
      sidebar_is_drawer;
      body;
      approval_strip;
      composer;
      footer;
      chrome_rows;
      composer_folded;
      is_micro_guard = false;
      is_too_small = false;
    }

let short_workspace_label ~(lang : Say.lang) ~compact ws =
  let full = Say.resolve lang (Nav.workspace_label ws) in
  if not compact then full
  else
    match lang with
    | Say.Lang_ko -> full
    | Say.Lang_en -> (
        match ws with
        | Nav.Pulse -> "Pulse"
        | Nav.Work -> "Work"
        | Nav.Knowledge -> "Know"
        | Nav.Keepers -> "Keep"
        | Nav.Runtime -> "Run"
        | Nav.Infra -> "Infra")

let workspace_basename (m : Model.t) =
  match m.server_identity.workspace with
  | Some ws ->
      let base = Filename.basename ws.base_path in
      if String.equal base "" || String.equal base "/" then None else Some base
  | None -> (
      match Observed.to_option m.fleet.shell with
      | Some sh -> sh.project
      | None -> None)

type rail_item = {
  priority : int;
  segments : (string * Style.t) list;
}

let rail_item_width (item : rail_item) =
  List.fold_left
    (fun acc (s, _) -> acc + Grapheme.display_width s)
    0 item.segments

let render_top_rail grid ~(rect : Rect.t) ~(theme : Theme.t) ~(model : Model.t)
    ~breakpoint =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pill_bg = Color.of_rgb theme.surface_2 in
    let base_style = Typography.primary ~bg theme in
    Cell_grid.fill_rect ~clip:rect grid ~rect ~style:base_style ();
    let compact =
      Layout.equal_breakpoint breakpoint Layout.Compact
      || Layout.equal_breakpoint breakpoint Layout.Micro
    in
    let wide = Layout.equal_breakpoint breakpoint Layout.Wide in
    let is_micro = Layout.equal_breakpoint breakpoint Layout.Micro in
    let sep_style = Typography.whisper ~bg ~italic:false theme in
    let sep =
      if rect.w < 110 then " " else Typography.sep_dot
    in
    let sep_w = Grapheme.display_width sep in
    (* Left side: 1-cell side margin + clickable [b] Menu toggle + Brand (Wide/Std) + 6 Workspace Tabs *)
    let x = ref (rect.x + 1) in
    if not is_micro then begin
      let sb_focused = Model.sidebar_has_focus model in
      let menu_st =
        if sb_focused then
          Typography.accent ~bg:pill_bg ~bold:true theme
        else if Model.sidebar_visible model then
          Typography.accent ~bg theme
        else Typography.structure ~bg theme
      in
      let menu_lbl =
        if sb_focused then
          Glyph.to_utf8 Glyph.Focus_caret ^ "b"
        else if
          Nav.equal_focus_scope (Model.active_focus_scope model)
            Nav.Ask_choice_focused
        then "[^B]"
        else "[b]"
      in
      let m_adv =
        Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y ~style:menu_st
          menu_lbl
      in
      x := !x + m_adv + 1
    end;
    if rect.w >= 100 && not is_micro then begin
      let d_adv =
        Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
          ~style:(Typography.accent ~bg ~bold:true theme)
          (Glyph.to_utf8 Glyph.Action_required ^ " ")
      in
      x := !x + d_adv;
      let b_adv =
        Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
          ~style:(Typography.anchor ~bg theme)
          "MASC"
      in
      x := !x + b_adv;
      let v_adv =
        Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
          ~style:(Style.make ~fg:(Color.of_rgb theme.border_subtle) ~bg ())
          (" " ^ Glyph.to_utf8 Glyph.Box_v ^ "  ")
      in
      x := !x + v_adv
    end;
    let tabs_end_x =
      if is_micro then begin
        let ws = model.nav.workspace in
        let idx = Nav.workspace_index ws in
        let lbl = Say.resolve model.lang (Nav.workspace_label ws) in
        let a0 =
          Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
            ~style:(Typography.anchor ~bg theme)
            "MASC"
        in
        x := !x + a0;
        let a1 =
          Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y ~style:sep_style
            sep
        in
        x := !x + a1;
        let a2 =
          Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
            ~style:(Typography.accent ~bg:pill_bg ~bold:true theme)
            (" " ^ Glyph.to_utf8 Glyph.Left_rail ^ Printf.sprintf "%d " idx)
        in
        x := !x + a2;
        let a3 =
          Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
            ~style:(Typography.anchor ~bg:pill_bg theme)
            (lbl ^ " ")
        in
        !x + a3
      end
      else begin
        let use_compact_tabs =
          rect.w < 98 && Say.equal_lang model.lang Say.Lang_en
        in
        let tab_gap = Layout.tab_gap breakpoint in
        List.iter
          (fun ws ->
            let idx = Nav.workspace_index ws in
            let lbl =
              short_workspace_label ~lang:model.lang ~compact:use_compact_tabs
                ws
            in
            let active = Nav.equal_workspace ws model.nav.workspace in
            if active then begin
              (* Elevated surface_2 pill + Left_rail accent bar + Bold text_bright
                 with 1-cell inner padding each side — ZERO solid cobalt slab! *)
              let p0 =
                Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
                  ~style:(Typography.accent ~bg:pill_bg ~bold:true theme)
                  (" " ^ Glyph.to_utf8 Glyph.Left_rail)
              in
              x := !x + p0;
              let p1 =
                Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
                  ~style:(Typography.accent ~bg:pill_bg ~bold:true theme)
                  (Printf.sprintf "%d " idx)
              in
              x := !x + p1;
              let p2 =
                Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
                  ~style:(Typography.anchor ~bg:pill_bg ~underline:true theme)
                  lbl
              in
              x := !x + p2;
              let p3 =
                Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
                  ~style:(Typography.anchor ~bg:pill_bg theme)
                  " "
              in
              x := !x + p3 + tab_gap
            end
            else begin
              let d_adv =
                Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
                  ~style:(Typography.whisper ~bg ~italic:false theme)
                  (Printf.sprintf "%d " idx)
              in
              x := !x + d_adv;
              let l_adv =
                Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
                  ~style:(Typography.structure ~bg theme)
                  lbl
              in
              x := !x + l_adv + tab_gap
            end)
          Nav.all_workspaces;
        !x
      end
    in
    (* Build right-aligned telemetry items in display order (left-to-right),
       each tagged with drop priority (higher number drops first if narrow). *)
    let freshness_item ~compact =
      let glyph, label, tone = Render_util.freshness_pill ~model ~compact in
      let segments =
        match tone with
        | Theme.Status_ok ->
            [
              (Glyph.to_utf8 glyph, Typography.status ~bg ~bold:true theme tone);
              (" " ^ label, Typography.structure ~bg theme);
            ]
        | Theme.Status_active | Theme.Status_attention | Theme.Status_critical
        | Theme.Status_ai | Theme.Status_historical ->
            [
              ( Printf.sprintf "%s %s" (Glyph.to_utf8 glyph) label,
                Typography.status ~bg ~bold:true theme tone );
            ]
      in
      { priority = 1; segments }
    in
    let attn_count = Attention.count model.attention in
    let attn_item =
      if attn_count > 0 then
        Some
          {
            priority = 1;
            segments =
              [
                ( Printf.sprintf "%s %d"
                    (Glyph.to_utf8 Glyph.Action_required)
                    attn_count,
                  Typography.status ~bg ~bold:true theme Theme.Status_attention
                );
              ];
          }
      else None
    in
    let inc_count = Incidents.active_count model.incidents in
    let inc_badge =
      if inc_count > 0 then
        let label =
          if rect.w < 148 then Printf.sprintf "[I]%d" inc_count
          else Printf.sprintf "[I] Inc(%d)" inc_count
        in
        Some
          {
            priority = 2;
            segments =
              [
                (label, Typography.status ~bg ~bold:true theme Theme.Status_historical);
              ];
          }
      else None
    in
    let help_badge =
      Some
        {
          priority = 3;
          segments = [ ("[?]", Typography.whisper ~bg ~italic:false theme) ];
        }
    in
    let ws_item =
      if wide then
        match workspace_basename model with
        | Some ws_name ->
            let clipped = Grapheme.truncate_to_width ~max_width:14 ws_name in
            Some
              {
                priority = 7;
                segments = [ (clipped, Typography.structure ~bg theme) ];
              }
        | None -> None
      else None
    in
    let clock_item =
      match
        Render_util.format_hhmm_with_offset ~tz_offset_sec:model.tz_offset_sec
          model.freshness.last_wall_unix
      with
      | Some hhmm ->
          Some
            {
              priority = 6;
              segments = [ (hhmm, Typography.whisper ~bg theme) ];
            }
      | None -> None
    in
    let max_right_w = Int.max 0 (Rect.right rect - 1 - tabs_end_x - 1) in
    let fresh_item = freshness_item ~compact in
    let attention_width =
      match attn_item with Some item -> rail_item_width item + sep_w | None -> 0
    in
    let fresh_item =
      if not compact && rail_item_width fresh_item + attention_width > max_right_w
      then freshness_item ~compact:true
      else fresh_item
    in
    let raw_items =
      (if Model.keeper_dive_focused model then
         [ attn_item; Some fresh_item; help_badge ]
       else
         [ attn_item; Some fresh_item; inc_badge; help_badge; ws_item; clock_item ])
      |> List.filter_map Fun.id
    in
    let measure_items xs =
      let rec loop acc = function
        | [] -> acc
        | [ it ] -> acc + rail_item_width it
        | it :: rest -> loop (acc + rail_item_width it + sep_w) rest
      in
      loop 0 xs
    in
    let rec drop_lowest_priority xs =
      if measure_items xs <= max_right_w then xs
      else
        match xs with
        | [] | [ _ ] -> xs
        | _ ->
            let max_p =
              List.fold_left (fun acc it -> Int.max acc it.priority) 0 xs
            in
            let dropped = ref false in
            let next =
              List.filter
                (fun it ->
                  if (not !dropped) && Int.equal it.priority max_p then begin
                    dropped := true;
                    false
                  end
                  else true)
                xs
            in
            drop_lowest_priority next
    in
    let fitted = drop_lowest_priority raw_items in
    let total_rw = measure_items fitted in
    if total_rw > 0 && total_rw <= max_right_w then begin
      let rx = ref (Rect.right rect - 1 - total_rw) in
      let rec draw_list = function
        | [] -> ()
        | it :: rest ->
            List.iter
              (fun (s, st) ->
                let adv =
                  Cell_grid.put_text ~clip:rect grid ~x:!rx ~y:rect.y ~style:st
                    s
                in
                rx := !rx + adv)
              it.segments;
            (match rest with
             | [] -> ()
             | _ :: _ ->
                 let sadv =
                   Cell_grid.put_text ~clip:rect grid ~x:!rx ~y:rect.y
                     ~style:sep_style sep
                 in
                 rx := !rx + sadv;
                 draw_list rest)
      in
      draw_list fitted
    end

let compact_keeper_tab_label ~(lang : Say.lang) ~compact tab =
  if not compact then Say.resolve lang (Nav.keeper_tab_label tab)
  else
    match tab with
    | Nav.Keeper_chat -> Say.resolve lang (Say.make ~ko:"대화" ~en:"Chat")
    | Nav.Keeper_context -> Say.resolve lang (Say.make ~ko:"컨텍스트" ~en:"Ctx")
    | Nav.Keeper_tool_calls -> Say.resolve lang (Say.make ~ko:"도구" ~en:"Tools")
    | Nav.Keeper_memory -> Say.resolve lang (Say.make ~ko:"기억" ~en:"Mem")
    | Nav.Keeper_work_candle -> Say.resolve lang (Say.make ~ko:"작업" ~en:"Work")
    | Nav.Keeper_sandbox -> Say.resolve lang (Say.make ~ko:"격리" ~en:"Sbox")
    | Nav.Keeper_config -> Say.resolve lang (Say.make ~ko:"설정" ~en:"Cfg")
    | Nav.Keeper_logs -> Say.resolve lang (Say.make ~ko:"로그" ~en:"Logs")
    | Nav.Keeper_identity -> Say.resolve lang (Say.make ~ko:"인증" ~en:"Auth")

let compact_work_tab_label ~(lang : Say.lang) ~compact tab =
  if not compact then Say.resolve lang (Nav.work_tab_label tab)
  else
    match tab with
    | Nav.Work_pipeline -> Say.resolve lang (Say.make ~ko:"목표" ~en:"Goals")
    | Nav.Work_tasks -> Say.resolve lang (Say.make ~ko:"작업" ~en:"Tasks")
    | Nav.Work_schedules -> Say.resolve lang (Say.make ~ko:"일정" ~en:"Sched")
    | Nav.Work_inbox -> Say.resolve lang (Say.make ~ko:"수신함" ~en:"Inbox")
    | Nav.Work_candle_scorecard -> Say.resolve lang (Say.make ~ko:"캔들·성과" ~en:"Candle")
    | Nav.Work_harness -> Say.resolve lang (Say.make ~ko:"하네스" ~en:"Harness")

let compact_knowledge_tab_label ~(lang : Say.lang) ~compact tab =
  if not compact then Say.resolve lang (Nav.knowledge_tab_label tab)
  else
    match tab with
    | Nav.Knowledge_board -> Say.resolve lang (Say.make ~ko:"보드" ~en:"Board")
    | Nav.Knowledge_wiki -> Say.resolve lang (Say.make ~ko:"위키" ~en:"Wiki")
    | Nav.Knowledge_artifacts -> Say.resolve lang (Say.make ~ko:"산출물" ~en:"Artif")
    | Nav.Knowledge_memory -> Say.resolve lang (Say.make ~ko:"기억" ~en:"Memory")

let compact_runtime_tab_label ~(lang : Say.lang) ~compact tab =
  if not compact then Say.resolve lang (Nav.runtime_tab_label tab)
  else
    match tab with
    | Nav.Runtime_quotas_credits -> Say.resolve lang (Say.make ~ko:"할당" ~en:"Quotas")
    | Nav.Runtime_efficiency_spend -> Say.resolve lang (Say.make ~ko:"지출" ~en:"Spend")
    | Nav.Runtime_failover_lanes -> Say.resolve lang (Say.make ~ko:"레인" ~en:"Lanes")
    | Nav.Runtime_fusion -> Say.resolve lang (Say.make ~ko:"퓨전" ~en:"Fusion")
    | Nav.Runtime_tools_usage -> Say.resolve lang (Say.make ~ko:"도구" ~en:"Tools")
    | Nav.Runtime_connectors -> Say.resolve lang (Say.make ~ko:"연동" ~en:"Conn")
    | Nav.Runtime_addons_browser -> Say.resolve lang (Say.make ~ko:"웹" ~en:"Addons")

let compact_infra_tab_label ~(lang : Say.lang) ~compact tab =
  if not compact then Say.resolve lang (Nav.infra_tab_label tab)
  else
    match tab with
    | Nav.Infra_sandboxes -> Say.resolve lang (Say.make ~ko:"샌드박스" ~en:"Sbox")
    | Nav.Infra_repos_changes -> Say.resolve lang (Say.make ~ko:"저장소·변경" ~en:"Repos")
    | Nav.Infra_code -> Say.resolve lang (Say.make ~ko:"코드" ~en:"Code")
    | Nav.Infra_activity_logs -> Say.resolve lang (Say.make ~ko:"활동·로그" ~en:"Logs")

let active_filter_text (m : Model.t) =
  if Model.is_keeper_config_active m then m.config.search_query
  else
    match m.nav.workspace with
    | Nav.Pulse | Nav.Keepers -> m.fleet.filter_query
    | Nav.Work -> m.work.filter_query
    | Nav.Knowledge -> m.knowledge.filter_query
    | Nav.Runtime -> m.runtime.filter_query
    | Nav.Infra -> m.infra.filter_query

let render_sub_tab_bar grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~breakpoint =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_0 in
    let pill_bg = Color.of_rgb theme.surface_2 in
    let base_style = Typography.structure ~bg theme in
    let crumb_style = Typography.accent ~bg ~bold:true theme in
    let whisper_style = Typography.whisper ~bg theme in
    Cell_grid.fill_rect ~clip:rect grid ~rect ~style:base_style ();
    let compact =
      Layout.equal_breakpoint breakpoint Layout.Compact
      || Layout.equal_breakpoint breakpoint Layout.Micro
    in
    let lang = model.lang in
    let gap = Layout.sub_tab_gap breakpoint in
    let left_pad = Layout.outer_margin breakpoint + 1 in
    let filter_q = String.trim (active_filter_text model) in
    let filter_active =
      model.nav.filter_focused || not (String.equal filter_q "")
    in
    let keeper_focus_context =
      (not (Model.is_keeper_config_active model))
      && Option.is_none model.nav.overlay
      &&
      match Model.active_dive model with
      | Some (Nav.Dive_keeper _) -> true
      | Some
          ( Nav.Dive_work _
          | Nav.Dive_knowledge _
          | Nav.Dive_runtime _
          | Nav.Dive_infra _ )
      | None -> false
    in
    let keeper_focus_hint =
      keeper_focus_context
      && not filter_active
      && not (Drafts.is_focused model.drafts)
      && not (Model.sidebar_has_focus model)
    in
    let right_text, right_style =
      if model.nav.filter_focused then
        ( Printf.sprintf " / %s_ " filter_q,
          Typography.anchor ~bg:(Color.of_rgb theme.selection_bg) theme )
      else if not (String.equal filter_q "") then
        ( Printf.sprintf " / %s " filter_q,
          Typography.accent ~bg:pill_bg ~bold:true theme )
      else if keeper_focus_context then
        let hint =
          if keeper_focus_hint then
            Say.resolve lang
              (if Model.keeper_dive_focused model then
                 Say.make ~ko:"[z] 집중 해제" ~en:"[z] Exit focus"
               else Say.make ~ko:"[z] 집중 보기" ~en:"[z] Focus view")
          else ""
        in
        (hint, whisper_style)
      else if Option.is_some (Model.active_dive model) then
        let txt =
          if Model.is_keeper_config_active model then
            if compact then "[ / ] [Esc]"
            else
              Say.resolve lang
                (Say.make ~ko:"[←→] 값  [ / ] 탭  [Esc] 뒤로"
                   ~en:"[←→] Cycle  [ / ] Tabs  [Esc] Back")
          else
            match Model.active_dive model with
            | Some (Nav.Dive_keeper _) ->
                if compact then "[ / ] [Esc]"
                else
                  Say.resolve lang
                    (Say.make ~ko:"[ / ] 탭  [Esc] 뒤로"
                       ~en:"[ / ] Tabs  [Esc] Back")
            | Some
                ( Nav.Dive_work _
                | Nav.Dive_knowledge _
                | Nav.Dive_runtime _
                | Nav.Dive_infra _ )
            | None ->
                if compact then "[Esc]"
                else Say.resolve lang (Say.make ~ko:"[Esc] 뒤로" ~en:"[Esc] Back")
        in
        (txt, whisper_style)
      else if model.nav.zoomed && Model.can_zoom_current_view model then
        let txt =
          if compact then "[z/Esc]"
          else if Model.is_keeper_config_active model then
            Say.resolve lang
              (Say.make ~ko:"[z/Esc] 확대 해제  [←→] 값  [ / ] 탭"
                 ~en:"[z/Esc] Unzoom  [←→] Cycle  [ / ] Tabs")
          else if Nav.equal_workspace model.nav.workspace Nav.Keepers then
            Say.resolve lang
              (Say.make ~ko:"[z/Esc] 확대 해제  [ / ] 탭"
                 ~en:"[z/Esc] Unzoom  [ / ] Tabs")
          else
            Say.resolve lang
              (Say.make ~ko:"[z/Esc] 확대 해제" ~en:"[z/Esc] Unzoom")
        in
        (txt, whisper_style)
      else if
        Option.is_none (Model.active_dive model)
        && Nav.equal_workspace model.nav.workspace Nav.Keepers
        && model.nav.pane_index >= 1
        && Option.is_some (Fleet_store.selected_keeper_summary model.fleet)
      then
        let txt =
          if compact then "[Tab] [ / ]"
          else if Model.is_keeper_config_active model then
            Say.resolve lang
              (Say.make ~ko:"[Tab] 목록  [←→] 값  [ / ] 탭"
                 ~en:"[Tab] Fleet  [←→] Cycle  [ / ] Tabs")
          else
            Say.resolve lang
              (Say.make ~ko:"[←→] 패널  [ / ] 탭"
                 ~en:"[←→] Panes  [ / ] Tabs")
        in
        (txt, whisper_style)
      else if Model.is_keeper_config_active model then
        let txt =
          if compact then "[ / ]"
          else
            Say.resolve lang
              (Say.make ~ko:"[/] 검색  [←→] 값  [ / ] 탭"
                 ~en:"[/] Filter  [←→] Cycle  [ / ] Tabs")
        in
        (txt, whisper_style)
      else
        let txt =
          if compact then "[ / ]"
          else
            Say.resolve lang
              (Say.make ~ko:"[/] 검색  [ / ] 탭" ~en:"[/] Filter  [ / ] Tabs")
        in
        (txt, whisper_style)
    in
    let right_pad = Layout.outer_margin breakpoint + 1 in
    let max_right_w = Int.max 8 (rect.w / 2) in
    let fitted_right =
      if filter_active then
        Grapheme.truncate_to_width ~max_width:max_right_w right_text
      else right_text
    in
    let rw = Grapheme.display_width fitted_right in
    let rx = Int.max (rect.x + left_pad) (Rect.right rect - right_pad - rw) in
    let tabs_clip =
      if filter_active || keeper_focus_hint then
        Rect.make ~x:rect.x ~y:rect.y ~w:(Int.max 0 (rx - rect.x - 1)) ~h:1
      else rect
    in
    let x = ref (rect.x + left_pad) in
    let draw_tab_list ?(gap = gap) tabs =
      let arr = Array.of_list tabs in
      let n = Array.length arr in
      if n = 0 then ()
      else begin
        let tab_width (label, is_active) =
          let lw = Grapheme.display_width label in
          if is_active then lw + 3 else lw
        in
        let widths = Array.map tab_width arr in
        let span_width lo hi =
          let w = ref 0 in
          for i = lo to hi do
            if i > lo then w := !w + gap;
            w := !w + widths.(i)
          done;
          !w
        in
        let avail = Int.max 0 (Rect.right tabs_clip - !x) in
        let lo, hi =
          if span_width 0 (n - 1) <= avail then (0, n - 1)
          else
            let active_idx =
              let rec find i =
                if i >= n then 0
                else if snd arr.(i) then i
                else find (i + 1)
              in
              find 0
            in
            let lo = ref active_idx and hi = ref active_idx in
            let fits l h =
              let left_ind = if l > 0 then 2 else 0 in
              let right_ind = if h < n - 1 then 2 else 0 in
              left_ind + span_width l h + right_ind <= avail
            in
            let progress = ref true in
            while !progress do
              progress := false;
              if !hi + 1 < n && fits !lo (!hi + 1) then begin
                incr hi;
                progress := true
              end;
              if !lo - 1 >= 0 && fits (!lo - 1) !hi then begin
                decr lo;
                progress := true
              end
            done;
            (!lo, !hi)
        in
        if lo > 0 then begin
          let a =
            Cell_grid.put_text ~clip:tabs_clip grid ~x:!x ~y:rect.y
              ~style:whisper_style "‹ "
          in
          x := !x + a
        end;
        for i = lo to hi do
          if i > lo then x := !x + gap;
          let label, is_active = arr.(i) in
          if is_active then begin
            (* Calm elevated marker: Left_rail accent + Bold underlined
               text_bright on surface_2 with symmetric 1-space padding. *)
            let a0 =
              Cell_grid.put_text ~clip:tabs_clip grid ~x:!x ~y:rect.y
                ~style:(Typography.accent ~bg:pill_bg ~bold:true theme)
                (Glyph.to_utf8 Glyph.Left_rail ^ " ")
            in
            x := !x + a0;
            let a1 =
              Cell_grid.put_text ~clip:tabs_clip grid ~x:!x ~y:rect.y
                ~style:(Typography.anchor ~bg:pill_bg ~underline:true theme)
                label
            in
            x := !x + a1;
            let a2 =
              Cell_grid.put_text ~clip:tabs_clip grid ~x:!x ~y:rect.y
                ~style:(Typography.anchor ~bg:pill_bg theme)
                " "
            in
            x := !x + a2
          end
          else begin
            let adv =
              Cell_grid.put_text ~clip:tabs_clip grid ~x:!x ~y:rect.y
                ~style:base_style label
            in
            x := !x + adv
          end
        done;
        if hi < n - 1 then begin
          let a =
            Cell_grid.put_text ~clip:tabs_clip grid ~x:!x ~y:rect.y
              ~style:whisper_style " ›"
          in
          x := !x + a
        end
      end
    in
    let dive_root_label = function
      | Nav.Dive_keeper _ -> Nav.workspace_label Nav.Keepers
      | Nav.Dive_work _ -> Nav.workspace_label Nav.Work
      | Nav.Dive_knowledge _ -> Nav.workspace_label Nav.Knowledge
      | Nav.Dive_runtime _ -> Nav.workspace_label Nav.Runtime
      | Nav.Dive_infra (Nav.Lane_dive _) -> Nav.workspace_label Nav.Runtime
      | Nav.Dive_infra (Nav.Incident_dive _) ->
          Nav.workspace_label model.nav.workspace
      | Nav.Dive_infra
          ( Nav.Sandbox_dive _
          | Nav.Runtime_trace_dive _
          | Nav.Log_detail_dive _ ) ->
          Nav.workspace_label Nav.Infra
    in
    let dive_segment_label = function
      | Nav.Dive_keeper { name; _ } ->
          Grapheme.truncate_to_width ~max_width:20 name
      | Nav.Dive_work (Nav.Goal_dive id) ->
          Say.resolve lang (Say.make ~ko:"목표" ~en:"Goal") ^ " " ^ id
      | Nav.Dive_work (Nav.Task_dive id) ->
          Say.resolve lang (Say.make ~ko:"작업" ~en:"Task") ^ " " ^ id
      | Nav.Dive_work (Nav.Verification_dive id) ->
          let tab_tag =
            match model.work.verification_dive_tab with
            | Work_store.Verif_tab_evidence -> ""
            | Work_store.Verif_tab_summary ->
                " [" ^ Say.resolve lang (Say.make ~ko:"요약" ~en:"Summary") ^ "]"
            | Work_store.Verif_tab_specs ->
                " [" ^ Say.resolve lang (Say.make ~ko:"명세" ~en:"Specs") ^ "]"
            | Work_store.Verif_tab_tlc -> " [TLC]"
          in
          Say.resolve lang (Say.make ~ko:"검증" ~en:"Verify")
          ^ " " ^ id ^ tab_tag
      | Nav.Dive_knowledge (Nav.Thread_dive id) ->
          Say.resolve lang (Say.make ~ko:"타래" ~en:"Thread") ^ " " ^ id
      | Nav.Dive_knowledge (Nav.Wiki_dive slug) ->
          Say.resolve lang (Say.make ~ko:"위키" ~en:"Wiki") ^ " " ^ slug
      | Nav.Dive_knowledge (Nav.Artifact_dive id) ->
          Say.resolve lang (Say.make ~ko:"산출물" ~en:"Artifact") ^ " " ^ id
      | Nav.Dive_knowledge (Nav.Memory_diff_dive { keeper; from_rev; to_rev }) ->
          let scope =
            match keeper with
            | Some k -> k
            | None -> Say.resolve lang (Say.make ~ko:"월드" ~en:"World")
          in
          Printf.sprintf "%s rev %d..%d" scope from_rev to_rev
      | Nav.Dive_runtime (Nav.Tool_dive name) ->
          Say.resolve lang (Say.make ~ko:"도구" ~en:"Tool") ^ " " ^ name
      | Nav.Dive_runtime (Nav.Fusion_dive run_id) ->
          Say.resolve lang (Say.make ~ko:"퓨전" ~en:"Fusion") ^ " " ^ run_id
      | Nav.Dive_runtime (Nav.Skill_dive ref_s) ->
          Say.resolve lang (Say.make ~ko:"스킬" ~en:"Skill") ^ " " ^ ref_s
      | Nav.Dive_runtime (Nav.Exact_run_dive run_id) ->
          Say.resolve lang (Say.make ~ko:"Exact실행" ~en:"Exact Run") ^ " " ^ run_id
      | Nav.Dive_infra (Nav.Sandbox_dive name) ->
          Say.resolve lang (Say.make ~ko:"샌드박스" ~en:"Sandbox") ^ " " ^ name
      | Nav.Dive_infra (Nav.Lane_dive id) ->
          Say.resolve lang (Say.make ~ko:"레인" ~en:"Lane") ^ " " ^ id
      | Nav.Dive_infra (Nav.Incident_dive id) ->
          Printf.sprintf "%s #%d"
            (Say.resolve lang (Say.make ~ko:"이력" ~en:"Incident"))
            id
      | Nav.Dive_infra (Nav.Runtime_trace_dive keeper) ->
          Say.resolve lang (Say.make ~ko:"런타임 추적" ~en:"Trace")
          ^ " " ^ keeper
      | Nav.Dive_infra (Nav.Log_detail_dive seq) ->
          Printf.sprintf "%s #%d"
            (Say.resolve lang (Say.make ~ko:"로그" ~en:"Log"))
            seq
    in
    let format_dive_chain () =
      let chain = List.rev model.nav.dive_stack in
      match chain with
      | [] -> ""
      | first :: _ ->
          let sep = " " ^ Glyph.to_utf8 Glyph.Prompt_caret ^ " " in
          let root = Say.resolve lang (dive_root_label first) in
          let segs = List.map dive_segment_label chain in
          String.concat sep (root :: segs)
    in
    (match Model.active_dive model with
     | Some (Nav.Dive_keeper { tab; _ }) ->
         let crumb = format_dive_chain () in
         let adv =
           Cell_grid.put_text ~clip:tabs_clip grid ~x:!x ~y:rect.y
             ~style:crumb_style crumb
         in
         x := !x + adv + 2;
         let use_compact_kt = compact || rect.w < 150 in
         let tabs =
           List.map
             (fun t ->
               ( compact_keeper_tab_label ~lang ~compact:use_compact_kt t,
                 Nav.equal_keeper_tab t tab ))
             Nav.all_keeper_tabs
         in
         draw_tab_list ~gap:(if use_compact_kt then 1 else gap) tabs
     | Some
         ( Nav.Dive_work _
         | Nav.Dive_knowledge _
         | Nav.Dive_runtime _
         | Nav.Dive_infra _ ) ->
         let crumb = format_dive_chain () in
         let adv =
           Cell_grid.put_text ~clip:tabs_clip grid ~x:!x ~y:rect.y
             ~style:crumb_style crumb
         in
         x := !x + adv
     | None -> (
         match model.nav.workspace with
         | Nav.Pulse -> ()
         | Nav.Work ->
             let inbox_n = Attention.count model.attention in
             let tabs =
               List.map
                 (fun t ->
                   let base = compact_work_tab_label ~lang ~compact t in
                   let lbl =
                     match t with
                     | Nav.Work_inbox when inbox_n > 0 ->
                         Printf.sprintf "%s(%d)" base inbox_n
                     | Nav.Work_pipeline
                     | Nav.Work_tasks
                     | Nav.Work_schedules
                     | Nav.Work_inbox
                     | Nav.Work_candle_scorecard
                     | Nav.Work_harness ->
                         base
                   in
                   (lbl, Nav.equal_work_tab t model.work.active_tab))
                 Nav.all_work_tabs
             in
             draw_tab_list tabs
         | Nav.Knowledge ->
             let tabs =
               List.map
                 (fun t ->
                   ( compact_knowledge_tab_label ~lang ~compact t,
                     Nav.equal_knowledge_tab t model.knowledge.active_tab ))
                 Nav.all_knowledge_tabs
             in
             draw_tab_list tabs
         | Nav.Keepers -> (
             (* Sync sub-tab bar with what '['/']' actually control:
                when Preview (pane 1 / zoomed) owns focus and a keeper is
                selected, show the selected keeper's inner preview tabs instead
                of Fleet modes. *)
             match
               if model.nav.pane_index = 1 || model.nav.zoomed then
                 Fleet_store.selected_keeper_summary model.fleet
               else None
             with
             | Some k ->
                 let crumb =
                   Printf.sprintf "%s %s %s"
                     (Say.resolve lang (Nav.workspace_label Nav.Keepers))
                     (Glyph.to_utf8 Glyph.Prompt_caret)
                     (Grapheme.truncate_to_width ~max_width:14 k.name)
                 in
                 let adv =
                   Cell_grid.put_text ~clip:tabs_clip grid ~x:!x ~y:rect.y
                     ~style:crumb_style crumb
                 in
                 x := !x + adv + 2;
                 let use_compact_kt = compact || rect.w < 150 in
                 let tabs =
                   List.map
                     (fun t ->
                       ( compact_keeper_tab_label ~lang ~compact:use_compact_kt t,
                         Nav.equal_keeper_tab t model.fleet.keeper_dive_tab ))
                     Nav.all_keeper_tabs
                 in
                 draw_tab_list ~gap:(if use_compact_kt then 1 else gap) tabs
             | None ->
                 let tabs =
                   List.map
                     (fun m ->
                       ( Say.resolve lang (Nav.keepers_fleet_mode_label m),
                         Nav.equal_keepers_fleet_mode m model.fleet.fleet_mode ))
                     Nav.all_keepers_fleet_modes
                 in
                 draw_tab_list tabs)
         | Nav.Runtime ->
             let use_compact_rt = compact || rect.w < 124 in
             let tabs =
               List.map
                 (fun t ->
                   ( compact_runtime_tab_label ~lang ~compact:use_compact_rt t,
                     Nav.equal_runtime_tab t model.runtime.active_tab ))
                 Nav.all_runtime_tabs
             in
             draw_tab_list tabs
         | Nav.Infra ->
             let tabs =
               List.map
                 (fun t ->
                   ( compact_infra_tab_label ~lang ~compact t,
                     Nav.equal_infra_tab t model.infra.active_tab ))
                 Nav.all_infra_tabs
             in
             draw_tab_list tabs));
    if filter_active || keeper_focus_hint || rx > !x + 2 then
      ignore
        (Cell_grid.put_text ~clip:rect grid ~x:rx ~y:rect.y ~style:right_style
           fitted_right)

let render_approval_strip grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  match Model.fast_approval_strip_item model with
  | None -> ()
  | Some entry ->
      if Rect.is_empty rect then ()
      else
        let bg = Color.of_rgb theme.surface_2 in
        let pri_st = Typography.primary ~bg theme in
        let attn_st =
          Typography.status ~bg ~bold:true theme Theme.Status_attention
        in
        let ok_st = Typography.status ~bg ~bold:true theme Theme.Status_ok in
        let crit_st =
          Typography.status ~bg ~bold:true theme Theme.Status_critical
        in
        let acc_st = Typography.accent ~bg ~bold:true theme in
        let sep_st = Typography.whisper ~bg ~italic:false theme in
        Cell_grid.fill_rect ~clip:rect grid ~rect ~style:pri_st ();
        Card.draw_left_rail ~bg ~tone:Theme.Status_attention grid ~x:rect.x
          ~y:rect.y ~h:1 ~theme;
        let lang = model.lang in
        let full_allow, full_deny, full_dive =
          match entry.payload with
          | Attention.Payload_ask _ ->
              ( Say.resolve lang (Say.make ~ko:"[Y] 질문 답변" ~en:"[Y] Answer Ask")
              , Say.resolve lang (Say.make ~ko:"[N] 건너뛰기" ~en:"[N] Skip")
              , Say.resolve lang (Say.make ~ko:"[J] 수신함" ~en:"[J] Inbox") )
          | Attention.Payload_goal_confirmation _ ->
              ( Say.resolve lang (Say.make ~ko:"[Y/Enter] 확인" ~en:"[Y/Enter] Confirm")
              , Say.resolve lang (Say.make ~ko:"[N] 보류·중단" ~en:"[N] Hold/Drop")
              , Say.resolve lang (Say.make ~ko:"[J] 상세" ~en:"[J] Dive") )
          | Attention.Payload_tool_approval _ | Attention.Payload_gate _ ->
              ( Say.resolve lang (Say.make ~ko:"[Y] 승인" ~en:"[Y] Allow")
              , Say.resolve lang (Say.make ~ko:"[N] 거절" ~en:"[N] Deny")
              , Say.resolve lang (Say.make ~ko:"[J] 상세" ~en:"[J] Dive") )
        in
        let is_ask =
          match entry.payload with
          | Attention.Payload_ask _ -> true
          | Attention.Payload_tool_approval _
          | Attention.Payload_gate _
          | Attention.Payload_goal_confirmation _ ->
              false
        in
        let full_actions_w =
          Grapheme.display_width full_allow
          + 2
          + Grapheme.display_width full_deny
          + 2
          + Grapheme.display_width full_dive
        in
        let compact_actions = rect.w < full_actions_w + 26 in
        let allow_txt, deny_txt, dive_txt, btn_sep, actions_w =
          if compact_actions then
            let a, d, j =
              if is_ask && Say.equal_lang lang Say.Lang_ko && rect.w >= 44 then
                ("[Y]답", "[N]건", "[J]함")
              else ("[Y]", "[N]", "[J]")
            in
            let sep = "/" in
            let w =
              Grapheme.display_width a
              + Grapheme.display_width sep
              + Grapheme.display_width d
              + Grapheme.display_width sep
              + Grapheme.display_width j
            in
            (a, d, j, sep, w)
          else (full_allow, full_deny, full_dive, "  ", full_actions_w)
        in
        let left_start = rect.x + 2 in
        let right_pad = 1 in
        let actions_x = Rect.right rect - right_pad - actions_w in
        let show_actions = actions_x >= left_start in
        let inner_bar_w = Int.max 0 (rect.w - 2) in
        let left_budget =
          if show_actions then
            Int.max 0
              (Int.min (actions_x - left_start - 2)
                 (inner_bar_w - actions_w - 3))
          else Int.max 0 (inner_bar_w - 1)
        in
        let flatten_line s =
          s |> String.trim
          |> String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c)
        in
        if left_budget > 0 then begin
          let left_clip =
            Rect.make ~x:left_start ~y:rect.y ~w:left_budget ~h:1
          in
          let tag = Say.resolve lang (Render_util.attention_kind_tag entry.kind) in
          let keeper_opt =
            match entry.keeper with
            | Some k ->
                let fk = flatten_line k in
                if String.equal fk "" then None else Some fk
            | None -> (
                match Render_util.attention_kind_keeper entry.kind with
                | Some k ->
                    let fk = flatten_line k in
                    if String.equal fk "" then None else Some fk
                | None -> None)
          in
          let title_clean = flatten_line entry.title in
          let sum_raw =
            let fs = flatten_line entry.summary in
            if String.equal fs "" then title_clean else fs
          in
          let prefix_raw, extra_summary =
            match keeper_opt with
            | Some k ->
                ( Printf.sprintf "%s %s %s %s"
                    (Glyph.to_utf8 Glyph.Action_required)
                    tag
                    (Glyph.to_utf8 Glyph.Separator_dot)
                    k,
                  if String.equal sum_raw k then "" else sum_raw )
            | None ->
                ( Printf.sprintf "%s %s %s %s"
                    (Glyph.to_utf8 Glyph.Action_required)
                    tag
                    (Glyph.to_utf8 Glyph.Separator_dot)
                    title_clean,
                  if String.equal sum_raw title_clean then "" else sum_raw )
          in
          let sep_w = Grapheme.display_width Typography.sep_dot in
          let has_extra = not (String.equal extra_summary "") in
          let prefix_fit =
            Grapheme.truncate_to_width ~max_width:left_budget prefix_raw
          in
          let p_adv =
            Cell_grid.put_text ~clip:left_clip grid ~x:left_start ~y:rect.y
              ~style:attn_st prefix_fit
          in
          let rem_after_prefix = left_budget - p_adv in
          if
            has_extra
            && String.equal prefix_fit prefix_raw
            && rem_after_prefix > sep_w + 4
          then begin
            let sx = left_start + p_adv in
            let sep_adv =
              Cell_grid.put_text ~clip:left_clip grid ~x:sx ~y:rect.y
                ~style:sep_st Typography.sep_dot
            in
            let summary_budget = Int.max 0 (rem_after_prefix - sep_adv) in
            if summary_budget > 0 then
              let clipped =
                Grapheme.truncate_to_width ~max_width:summary_budget
                  extra_summary
              in
              ignore
                (Cell_grid.put_text ~clip:left_clip grid ~x:(sx + sep_adv)
                   ~y:rect.y ~style:pri_st clipped)
          end
        end;
        if show_actions then begin
          let zone_x = Int.max (rect.x + 1) (actions_x - 2) in
          let zone_rect =
            Rect.make ~x:zone_x ~y:rect.y
              ~w:(Int.max 0 (Rect.right rect - zone_x))
              ~h:1
          in
          Cell_grid.fill_rect ~clip:rect grid ~rect:zone_rect ~style:pri_st ();
          let ax = ref actions_x in
          let a1 =
            Cell_grid.put_text ~clip:rect grid ~x:!ax ~y:rect.y ~style:ok_st
              allow_txt
          in
          ax := !ax + a1;
          let s1 =
            Cell_grid.put_text ~clip:rect grid ~x:!ax ~y:rect.y ~style:sep_st
              btn_sep
          in
          ax := !ax + s1;
          let a2 =
            Cell_grid.put_text ~clip:rect grid ~x:!ax ~y:rect.y ~style:crit_st
              deny_txt
          in
          ax := !ax + a2;
          let s2 =
            Cell_grid.put_text ~clip:rect grid ~x:!ax ~y:rect.y ~style:sep_st
              btn_sep
          in
          ax := !ax + s2;
          ignore
            (Cell_grid.put_text ~clip:rect grid ~x:!ax ~y:rect.y ~style:acc_st
               dive_txt)
        end

let footer_right_status_hint ~(model : Model.t) =
  let lang = model.lang in
  if model.nav.filter_focused then
    Say.resolve lang
      (Say.make ~ko:"필터 입력 중 · Esc 초기화" ~en:"Filtering · Esc clear")
  else
    match model.nav.overlay with
    | Some (Nav.Settings _) ->
        if Config_store.is_two_pane_width ~cols:model.viewport.cols then
          Say.resolve lang
            (Say.make ~ko:"Tab 좌/우 전환 · / 전체 검색"
               ~en:"Tab tree/inspector · / search all")
        else
          Say.resolve lang
            (Say.make ~ko:"↑↓ 이동 · / 전체 검색" ~en:"↑↓ move · / search all")
    | Some Nav.Palette ->
        Say.resolve lang
          (Say.make ~ko:"↑↓ 이동 · Enter 실행" ~en:"↑↓ select · Enter run")
    | Some Nav.Incidents ->
        Say.resolve lang
          (Say.make ~ko:"Ch 3 과거 이력 · 실시간 상태 무관"
             ~en:"Ch 3 historical trail · live SSOT unaffected")
    | Some (Nav.System_gate (Nav.Auth_gate | Nav.Server_offline)) ->
        Say.resolve lang
          (Say.make ~ko:"r 재시도 · Ctrl+Q 종료" ~en:"r Retry · Ctrl+Q Quit")
    | Some (Nav.System_gate Nav.Micro_viewport) ->
        Say.resolve lang
          (Say.make ~ko:"터미널 >= 40x12 · Ctrl+Q 종료"
             ~en:"Resize >= 40x12 · Ctrl+Q Quit")
    | Some Nav.Ask_answer -> (
        match model.ask_modal with
        | Some md -> (
            let live = Model.ask_live_status model md.ask.ask_id in
            match live with
            | Model.Ask_live_closed ->
                Say.resolve lang
                  (Say.make ~ko:"읽기 전용 · C 채팅 · Esc 닫기"
                     ~en:"Read-only · C chat · Esc close")
            | Model.Ask_live_in_flight ->
                Say.resolve lang
                  (Say.make ~ko:"응답 전송 중 · Esc 닫기"
                     ~en:"Sending answer · Esc close")
            | Model.Ask_live_open when md.submitting ->
                Say.resolve lang
                  (Say.make ~ko:"응답 전송 중 · Esc 닫기"
                     ~en:"Sending answer · Esc close")
            | Model.Ask_live_open when md.editing_free_text ->
                Say.resolve lang
                  (Say.make ~ko:"Enter 확정 · Esc 선택으로"
                     ~en:"Enter confirm · Esc choices")
            | Model.Ask_live_open ->
                Say.resolve lang
                  (Say.make ~ko:"↑↓ 이동 · Space 선택 · Enter 제출"
                     ~en:"↑↓ move · Space toggle · Enter submit"))
        | None ->
            Say.resolve lang (Say.make ~ko:"Esc 닫기" ~en:"Esc close"))
    | Some
        ( Nav.Queue_context _
        | Nav.Inline_action _
        | Nav.Help
        | Nav.System_gate Nav.Media_viewer ) ->
        Say.resolve lang (Say.make ~ko:"Esc 돌아가기" ~en:"Esc return")
    | None -> ""

let render_footer grid ~(rect : Rect.t) ~(theme : Theme.t) ~(model : Model.t)
    ~breakpoint ~composer_folded =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let keycap_st = Typography.keycap theme in
    let lbl_st = Typography.keycap_label ~bg theme in
    let whisper_st = Typography.whisper ~bg theme in
    Cell_grid.fill_rect ~clip:rect grid ~rect ~style:lbl_st ();
    let compact =
      Layout.equal_breakpoint breakpoint Layout.Compact
      || Layout.equal_breakpoint breakpoint Layout.Micro
    in
    let x = ref (rect.x + 1) in
    let right_edge = Rect.right rect - 1 in
    let avail_w = Int.max 0 (right_edge - !x) in
    (* Right-aligned hint for the active overlay or filter. *)
    let right_hint =
      if (not compact) && rect.w >= 100 then footer_right_status_hint ~model
      else ""
    in
    let right_hint_w =
      if String.equal right_hint "" then 0
      else Int.min 34 (Grapheme.display_width right_hint)
    in
    let right_hint_reserve =
      if right_hint_w > 0 then right_hint_w + 3 else 0
    in
    (* Far-left persistent Focus Pill: makes the active input target unmistakable
       at a glance across multi-pane bodies, Composer, Filter, and Overlays. *)
    if avail_w >= 28 then begin
      let focus_raw = Say.resolve model.lang (Model.active_focus_label model) in
      let max_fw = if compact then 16 else 24 in
      let focus_txt =
        Printf.sprintf " %s %s "
          (Glyph.to_utf8 Glyph.Focus_caret)
          (Grapheme.truncate_to_width ~max_width:max_fw focus_raw)
      in
      let pill_bg = Color.of_rgb theme.surface_2 in
      let focus_st =
        if model.nav.filter_focused || Drafts.is_focused model.drafts then
          Typography.status ~bg:pill_bg ~bold:true theme Theme.Status_attention
        else if Option.is_some model.nav.overlay then
          Typography.status ~bg:pill_bg ~bold:true theme Theme.Status_ai
        else Typography.accent ~bg:pill_bg ~bold:true theme
      in
      let f_adv =
        Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y ~style:focus_st
          focus_txt
      in
      x := !x + f_adv + 2
    end;
    (* On Compact idle (when no overlay is open), fold composer cleanly into left side *)
    if composer_folded && Option.is_none model.nav.overlay && avail_w >= 16 then
      begin
        let comp_st = Render_util.composer_state_of_model model in
        let raw_pill = Composer.folded_footer_pill ~lang:model.lang comp_st in
        let max_pill_w = Int.min 26 (avail_w / 2) in
        let pill = Grapheme.truncate_to_width ~max_width:max_pill_w raw_pill in
        let pill_bg = Color.of_rgb theme.surface_2 in
        let p_adv =
          Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
            ~style:(Typography.anchor ~bg:pill_bg theme)
            (" " ^ pill ^ " ")
        in
        x := !x + p_adv + 2
      end;
    let hints_right_limit = Int.max !x (right_edge - right_hint_reserve) in
    let remaining_w = Int.max 0 (hints_right_limit - !x) in
    let scope_chain = Model.focus_scope_chain model in
    let max_pairs = if compact || Option.is_none model.nav.overlay then 6 else 14 in
    let pair_gap = if compact && rect.w < 84 then 1 else 2 in
    let candidates =
      let mk key ko en action : Keymap.footer_hint =
        {
          Keymap.key_display = key;
          label = Say.resolve model.lang (Say.make ~ko ~en);
          action;
          priority = 1;
        }
      in
      if
        Model.is_too_small_viewport model.viewport
        || (Layout.equal_breakpoint breakpoint Layout.Micro
            && Option.is_none model.nav.overlay)
      then
        (if
           (not (Model.is_too_small_viewport model.viewport))
           && Attention.count model.attention > 0
         then [ mk "J" "대기 이동" "Jump" Keymap.Teleport_blocked ]
         else [])
        @ (if not (Model.is_too_small_viewport model.viewport) then
             [
               mk "Ctrl+," "설정" "Settings" Keymap.Open_settings;
               mk "?" "도움말" "Help" Keymap.Open_help;
             ]
           else [])
        @ [ mk "Ctrl+Q" "종료" "Quit" Keymap.Quit_app ]
      else
      match model.nav.overlay with
      | Some (Nav.System_gate Nav.Auth_gate) ->
          [
            mk "r" "재시도" "Retry" Keymap.Refresh;
            mk "Ctrl+Q" "종료" "Quit" Keymap.Quit_app;
          ]
      | Some (Nav.System_gate Nav.Server_offline) ->
          [
            mk "s" "서버 시작" "Start Server" Keymap.Confirm_selected;
            mk "r" "재시도" "Retry" Keymap.Refresh;
            mk "Ctrl+Q" "종료" "Quit" Keymap.Quit_app;
          ]
      | ( Some
            ( Nav.Palette
            | Nav.Settings _
            | Nav.Incidents
            | Nav.Queue_context _
            | Nav.Inline_action _
            | Nav.Help
            | Nav.System_gate (Nav.Micro_viewport | Nav.Media_viewer) )
        | None )
        when model.nav.filter_focused ->
        [
          mk "↑↓" "이동" "Move" (Keymap.Move Keymap.Down);
          mk "Enter" "적용" "Apply" Keymap.Confirm_selected;
          mk "Tab" "완료" "Done" (Keymap.Cycle_focus_pane Keymap.Next);
          mk "Esc" "초기화" "Clear" Keymap.Pop_back_or_close;
        ]
      | ( Some
            ( Nav.Palette
            | Nav.Settings _
            | Nav.Incidents
            | Nav.Queue_context _
            | Nav.Inline_action _
            | Nav.Help
            | Nav.System_gate (Nav.Micro_viewport | Nav.Media_viewer) )
        | None )
        when Model.sidebar_has_focus model ->
        [
          mk "↑↓" "화면 이동" "Navigate" (Keymap.Move Keymap.Down);
          mk "Enter" "본문 진입" "Open" Keymap.Confirm_selected;
          mk "Tab" "본문" "Body" (Keymap.Cycle_focus_pane Keymap.Next);
          mk "b" "메뉴 접기" "Hide Menu" Keymap.Toggle_sidebar;
          mk "Esc" "닫기" "Back" Keymap.Pop_back_or_close;
        ]
      | Some
          ( Nav.Palette
          | Nav.Settings _
          | Nav.Incidents
          | Nav.Queue_context _
          | Nav.Inline_action _
          | Nav.Ask_answer
          | Nav.Help
          | Nav.System_gate (Nav.Micro_viewport | Nav.Media_viewer) )
      | None ->
        let raw =
          Keymap.footer_hints ~scope_chain ~max_width:(remaining_w + 180)
            ~lang:model.lang
        in
        let thread_reading =
          Model.body_has_focus model
          && (match Model.active_dive model with
              | Some (Nav.Dive_knowledge (Nav.Thread_dive _)) -> true
              | Some
                  ( Nav.Dive_knowledge
                      (Nav.Wiki_dive _ | Nav.Artifact_dive _ | Nav.Memory_diff_dive _)
                  | Nav.Dive_keeper _
                  | Nav.Dive_work _
                  | Nav.Dive_runtime _
                  | Nav.Dive_infra _ )
              | None -> false)
        in
        let show_tab_hint =
          match model.nav.overlay with
          | Some (Nav.Help | Nav.Incidents | Nav.System_gate _) -> false
          | Some (Nav.Settings _) ->
              Config_store.is_two_pane_width ~cols:model.viewport.cols
          | Some (Nav.Palette | Nav.Queue_context _) -> true
          | Some Nav.Ask_answer -> (
              match model.ask_modal with
              | Some md -> List.length md.ask.questions > 1
              | None -> false)
          | Some (Nav.Inline_action _) -> (
              match model.inline_modal with
              | Some modal ->
                  List.length modal.fields > 1
                  && (not (Nav.equal_inline_action_kind modal.kind Nav.Btw_query)
                      ||
                      match model.drafts.btw with
                      | Drafts.Btw_idle -> true
                      | Drafts.Btw_sending _
                      | Drafts.Btw_streaming _
                      | Drafts.Btw_answered _
                      | Drafts.Btw_failed _ ->
                          false)
              | None -> false)
          | None ->
              thread_reading || Model.focusable_pane_count model > 1
              || Model.sidebar_visible model
        in
        let show_overlay_confirm_hint =
          match model.nav.overlay with
          | Some
              ( Nav.Help
              | Nav.System_gate _
              | Nav.Queue_context _ ) ->
              false
          | Some Nav.Ask_answer -> (
              match model.ask_modal with
              | Some md ->
                  (not md.submitting)
                  && Model.equal_ask_live_status
                       (Model.ask_live_status model md.ask.ask_id)
                       Model.Ask_live_open
              | None -> false)
          | Some
              ( Nav.Palette
              | Nav.Settings _
              | Nav.Incidents
              | Nav.Inline_action _ )
          | None ->
              true
        in
        let slash_routes_to_cmd =
          Option.is_none model.nav.overlay
          && (not (Model.is_keeper_config_active model))
          &&
          match Model.active_dive model with
          | Some (Nav.Dive_knowledge (Nav.Artifact_dive _)) -> false
          | Some
              ( Nav.Dive_keeper _
              | Nav.Dive_work _
              | Nav.Dive_knowledge
                  ( Nav.Thread_dive _
                  | Nav.Wiki_dive _
                  | Nav.Memory_diff_dive _ )
              | Nav.Dive_runtime _
              | Nav.Dive_infra _ ) ->
              true
          | None -> Nav.equal_workspace model.nav.workspace Nav.Pulse
        in
        let tab_relabel_opt =
          match model.nav.overlay with
          | Some (Nav.Settings _) -> Some ("패널", "Pane")
          | Some (Nav.Queue_context _) -> Some ("탭", "Tab")
          | Some Nav.Palette -> Some ("다음", "Next")
          | Some Nav.Ask_answer -> Some ("질문", "Q")
          | Some (Nav.Inline_action _ | Nav.Help | Nav.Incidents | Nav.System_gate _) ->
              None
          | None when thread_reading -> (
              match model.knowledge.thread_view with
              | Knowledge_store.Thread_post -> Some ("댓글", "Comments")
              | Knowledge_store.Thread_comments -> Some ("본문", "Post"))
          | None ->
              if
                Model.focusable_pane_count model <= 1
                && Model.sidebar_visible model
              then Some ("메뉴", "Menu")
              else None
        in
        let enter_hint =
          match model.nav.overlay with
          | None -> Update_nav.enter_hint model
          | Some _ -> Update_nav.Enter_hint_dive
        in
        let relabel (h : Keymap.footer_hint) ~ko ~en =
          { h with label = Say.resolve model.lang (Say.make ~ko ~en) }
        in
        let approval_strip_shown =
          Option.is_none model.nav.overlay
          && Option.is_some (Model.fast_approval_strip_item model)
        in
        let show_sub_tab_hint =
          match model.nav.overlay with
          | Some (Nav.Settings _ | Nav.Queue_context _) -> true
          | Some Nav.Ask_answer -> (
              match model.ask_modal with
              | Some md -> List.length md.ask.questions > 1
              | None -> false)
          | Some
              ( Nav.Palette
              | Nav.Incidents
              | Nav.Inline_action _
              | Nav.Help
              | Nav.System_gate _ ) ->
              false
          | None -> (
              match Model.active_dive model with
              | Some (Nav.Dive_keeper _) -> true
              | Some
                  ( Nav.Dive_work _
                  | Nav.Dive_knowledge _
                  | Nav.Dive_runtime _
                  | Nav.Dive_infra _ ) ->
                  false
              | None -> not (Nav.equal_workspace model.nav.workspace Nav.Pulse))
        in
        let show_esc_hint =
          Option.is_some model.nav.overlay
          || Option.is_some (Model.active_dive model)
          || Drafts.is_focused model.drafts
          || model.nav.filter_focused
          || Model.sidebar_has_focus model
          || Model.sidebar_drawer_open model
          || model.nav.zoomed
          || not (String.equal (String.trim (active_filter_text model)) "")
          || Option.is_some (Memory_diagram.active_diagram model)
          || Model.has_active_memory_reading model
          || Option.is_some model.knowledge.armed_vote
          || Option.is_some model.keeper_stop_armed
          || Option.is_some model.quit_armed_at
          || Option.is_some model.knowledge.pending_wiki_edit_slug
          || (Option.is_none (Model.active_dive model)
              && Nav.equal_workspace model.nav.workspace Nav.Infra
              && Nav.equal_infra_tab model.infra.active_tab Nav.Infra_code
              && not
                   (Infra_store.equal_code_right_mode
                      model.infra.code.right_mode Infra_store.Code_file))
          || (Option.is_none (Model.active_dive model)
              && Nav.equal_workspace model.nav.workspace Nav.Runtime
              && Nav.equal_runtime_tab model.runtime.active_tab
                   Nav.Runtime_addons_browser
              && model.runtime.addon_catalog_mode)
          || (Model.is_keeper_config_active model
              && (Config_store.is_editing_field model.config
                  || not (String.equal model.config.search_query "")))
          || (match Model.active_dive model with
              | Some (Nav.Dive_keeper { name; tab = Nav.Keeper_work_candle }) ->
                  Board_recovery.shown ~keeper:name model.knowledge.board_recovery
              | Some
                  ( Nav.Dive_keeper
                      {
                        tab =
                          ( Nav.Keeper_chat
                          | Nav.Keeper_context
                          | Nav.Keeper_tool_calls
                          | Nav.Keeper_memory
                          | Nav.Keeper_sandbox
                          | Nav.Keeper_config
                          | Nav.Keeper_logs
                          | Nav.Keeper_identity );
                        _;
                      }
                  | Nav.Dive_work _
                  | Nav.Dive_knowledge _
                  | Nav.Dive_runtime _
                  | Nav.Dive_infra _ ) ->
                  false
              | None ->
                  Nav.equal_workspace model.nav.workspace Nav.Keepers
                  && Nav.equal_keeper_tab model.fleet.keeper_dive_tab
                       Nav.Keeper_work_candle
                  && (model.nav.pane_index = 1
                     || (model.nav.zoomed && Model.can_zoom_current_view model))
                  &&
                  match Fleet_store.selected_keeper_summary model.fleet with
                  | Some k ->
                      Board_recovery.shown ~keeper:k.name
                        model.knowledge.board_recovery
                  | None -> false)
          || (Nav.equal_workspace model.nav.workspace Nav.Work
              && Nav.equal_work_tab model.work.active_tab Nav.Work_tasks
              && not
                   (Work_store.equal_task_status_filter
                      model.work.task_status_filter Work_store.Status_all))
          || (Nav.equal_workspace model.nav.workspace Nav.Work
              && Nav.equal_work_tab model.work.active_tab Nav.Work_pipeline
              && not
                   (Work_store.equal_goal_phase_filter
                      model.work.goal_phase_filter Work_store.Goal_filter_all))
        in
        List.filter_map
          (fun (h : Keymap.footer_hint) ->
            let is_pane_cycle =
              Keymap.equal_action h.action (Keymap.Cycle_focus_pane Keymap.Next)
              || Keymap.equal_action h.action
                   (Keymap.Cycle_focus_pane Keymap.Prev)
            in
            let is_dup_approval =
              approval_strip_shown
              && (Keymap.equal_action h.action Keymap.Fast_approve_top
                  || Keymap.equal_action h.action Keymap.Fast_deny_top)
            in
            let is_sub_tab =
              Keymap.equal_action h.action (Keymap.Sub_tab Keymap.Prev)
              || Keymap.equal_action h.action (Keymap.Sub_tab Keymap.Next)
            in
            let is_esc =
              Keymap.equal_action h.action Keymap.Pop_back_or_close
            in
            let is_confirm =
              Keymap.equal_action h.action Keymap.Confirm_selected
            in
            let repeats_menu =
              Option.is_none model.nav.overlay
              && Keymap.equal_action h.action Keymap.Toggle_sidebar
            in
            let shown =
              (show_tab_hint || not is_pane_cycle)
              && (show_overlay_confirm_hint || not is_confirm)
              && (not is_dup_approval)
              && not repeats_menu
              && (show_sub_tab_hint || not is_sub_tab)
              && (show_esc_hint || not is_esc)
            in
            if not shown then None
            else if
              slash_routes_to_cmd
              && Keymap.equal_action h.action Keymap.Focus_filter
            then Some (relabel h ~ko:"명령" ~en:"Cmd")
            else if is_pane_cycle then
              match tab_relabel_opt with
              | Some (ko, en) -> Some (relabel h ~ko ~en)
              | None -> Some h
            else if not (Keymap.equal_action h.action Keymap.Dive_selected) then
              Some h
            else
              match enter_hint with
              | Update_nav.Enter_hint_hidden -> None
              | Update_nav.Enter_hint_dive -> Some h
              | Update_nav.Enter_hint_memory_reading ->
                  Some (relabel h ~ko:"전문" ~en:"Read")
              | Update_nav.Enter_hint_dos_screen ->
                  Some (relabel h ~ko:"DOS 화면" ~en:"DOS screen")
              | Update_nav.Enter_hint_edit_field ->
                  Some (relabel h ~ko:"편집" ~en:"Edit")
              | Update_nav.Enter_hint_confirm_field ->
                  Some (relabel h ~ko:"확인" ~en:"Confirm"))
          raw
    in
    let rec draw_keycaps count = function
      | [] -> ()
      | _ when count >= max_pairs -> ()
      | (h : Keymap.footer_hint) :: rest ->
          let key_badge = " " ^ h.key_display ^ " " in
          let pair_w =
            Grapheme.display_width key_badge
            + 1
            + Grapheme.display_width h.label
          in
          let need_gap = if count > 0 then pair_gap else 0 in
          if !x + need_gap + pair_w <= hints_right_limit then begin
            x := !x + need_gap;
            let k_adv =
              Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y
                ~style:keycap_st key_badge
            in
            x := !x + k_adv + 1;
            let l_adv =
              Cell_grid.put_text ~clip:rect grid ~x:!x ~y:rect.y ~style:lbl_st
                h.label
            in
            x := !x + l_adv;
            draw_keycaps (count + 1) rest
          end
          else draw_keycaps count rest
    in
    draw_keycaps 0 candidates;
    if right_hint_w > 0 then begin
      let fitted_hint =
        Grapheme.truncate_to_width ~max_width:right_hint_w right_hint
      in
      let fw = Grapheme.display_width fitted_hint in
      let rx = right_edge - fw in
      if rx > !x + 2 then
        ignore
          (Cell_grid.put_text ~clip:rect grid ~x:rx ~y:rect.y ~style:whisper_st
             fitted_hint)
    end

let render_toast_pill grid ~(body_rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  match model.toast with
  | None -> ()
  | Some toast ->
      if body_rect.w < 16 || body_rect.h < 2 then ()
      else
        let glyph, tone =
          match toast.level with
          | Model.Toast_info -> (Glyph.Live_healthy, Theme.Status_active)
          | Model.Toast_success -> (Glyph.Check_mark, Theme.Status_ok)
          | Model.Toast_warning -> (Glyph.Warning_triangle, Theme.Status_attention)
          | Model.Toast_error -> (Glyph.Live_failing, Theme.Status_critical)
        in
        let msg = Say.resolve model.lang toast.message in
        let raw = Printf.sprintf "%s %s" (Glyph.to_utf8 glyph) msg in
        let max_w = Int.min (body_rect.w - 4) 64 in
        let text = Grapheme.truncate_to_width ~max_width:max_w raw in
        let pw = Grapheme.display_width text + 3 in
        let px = Int.max body_rect.x (Rect.right body_rect - pw - 1) in
        let py =
          if Option.is_some model.nav.overlay && body_rect.h >= 4 then
            Rect.bottom body_rect - 2
          else Rect.bottom body_rect - 1
        in
        let pill_rect = Rect.make ~x:px ~y:py ~w:pw ~h:1 in
        let fg = Color.of_rgb (Theme.status_color theme tone) in
        let bg = Color.of_rgb theme.surface_2 in
        Card.draw_left_rail ~bg ~tone grid ~x:px ~y:py ~h:1 ~theme;
        ignore
          (Render_util.draw_pill ~clip:pill_rect grid ~x:(px + 1) ~y:py ~fg ~bg
             ~bold:true text)

let render_too_small_guard grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  let bg = Color.of_rgb theme.surface_0 in
  let attn_st = Typography.status ~bg ~bold:true theme Theme.Status_attention in
  let sec_st = Typography.whisper ~bg theme in
  Cell_grid.fill_rect grid ~rect ~style:(Typography.primary ~bg theme) ();
  let lang = model.lang in
  let line1 =
    Say.resolve lang
      (Say.make
         ~ko:(Printf.sprintf "%s 창 크기 확대 필요 (%dx%d < 40x12)"
                (Glyph.to_utf8 Glyph.Warning_triangle) rect.w rect.h)
         ~en:(Printf.sprintf "%s Resize >= 40x12 (%dx%d)"
                (Glyph.to_utf8 Glyph.Warning_triangle) rect.w rect.h))
  in
  let line2, line2_st =
    if Option.is_some model.quit_armed_at then
      ( Say.resolve lang
          (Say.make ~ko:"한 번 더 Ctrl+Q를 누르면 종료합니다"
             ~en:"Press Ctrl+Q again to quit")
      , attn_st )
    else if
      Drafts.has_non_empty_draft model.drafts
      || Drafts.other_keepers_draft_count model.drafts > 0
    then
      ( Say.resolve lang
          (Say.make ~ko:"초안 안전 보호 중 · Ctrl+Q 종료"
             ~en:"Draft preserved · Ctrl+Q quit")
      , sec_st )
    else
      ( Say.resolve lang (Say.make ~ko:"Ctrl+Q 종료" ~en:"Ctrl+Q quit")
      , sec_st )
  in
  let mid_y = rect.y + (rect.h / 2) in
  if rect.h >= 1 then
    ignore
      (Cell_grid.put_text ~clip:rect grid ~x:(rect.x + 1)
         ~y:(Int.max rect.y (mid_y - 1))
         ~style:attn_st
         (Grapheme.truncate_to_width ~max_width:(Int.max 0 (rect.w - 2)) line1));
  if rect.h >= 2 then
    ignore
      (Cell_grid.put_text ~clip:rect grid ~x:(rect.x + 1) ~y:mid_y
         ~style:line2_st
         (Grapheme.truncate_to_width ~max_width:(Int.max 0 (rect.w - 2)) line2))

let render_micro_cockpit grid ~cache ~(body : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) =
  if Rect.is_empty body then ()
  else
    let lang = model.lang in
    let fresh_glyph, fresh_lbl, fresh_tone =
      Render_util.freshness_pill ~model ~compact:true
    in
    let attn_count = Attention.count model.attention in
    let lookup_keeper = Render_util.target_keeper_of_model model in
    let display_keeper = Render_util.display_target_keeper_of_model model in
    let grid_cols = Cell_grid.cols grid in
    let grid_rows = Cell_grid.rows grid in
    let title =
      Say.resolve lang
        (Say.make
           ~ko:(Printf.sprintf "마이크로 뷰 (%dx%d)" grid_cols grid_rows)
           ~en:(Printf.sprintf "Micro Cockpit (%dx%d)" grid_cols grid_rows))
    in
    let badge : Card.badge =
      { glyph = Some fresh_glyph; text = fresh_lbl; tone = Some fresh_tone }
    in
    let inner =
      Card.draw ~cache grid ~rect:body ~theme
        {
          (Card.default_spec ~title) with
          badge = Some badge;
          hotkey = Some ">=80x24";
          focused = true;
        }
    in
    let content = Card.pad_inner ~pad_x:1 inner in
    if not (Rect.is_empty content) then begin
      let bg = Color.of_rgb theme.surface_1 in
      let pri = Typography.primary ~bg theme in
      let sec = Typography.structure ~bg theme in
      let whisper = Typography.whisper ~bg theme in
      let attn_st =
        Typography.status ~bg ~bold:true theme Theme.Status_attention
      in
      let ok_st = Typography.status ~bg ~bold:true theme Theme.Status_ok in
      let y = ref content.y in
      let put_line style txt =
        if !y < Rect.bottom content then begin
          let row_r = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:1 in
          ignore
            (Cell_grid.put_text ~clip:row_r grid ~x:content.x ~y:!y ~style
               (Grapheme.truncate_to_width ~max_width:content.w txt));
          incr y
        end
      in
      let queue_line =
        if attn_count > 0 then
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "%s 확인 대기 %d건 (J: 이동)"
                      (Glyph.to_utf8 Glyph.Action_required) attn_count)
               ~en:(Printf.sprintf "%s Action Queue: %d pending (J: jump)"
                      (Glyph.to_utf8 Glyph.Action_required) attn_count))
        else
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "%s 확인 대기 없음 (0건)"
                      (Glyph.to_utf8 Glyph.Live_healthy))
               ~en:(Printf.sprintf "%s Action Queue: 0 pending"
                      (Glyph.to_utf8 Glyph.Live_healthy)))
      in
      put_line (if attn_count > 0 then attn_st else ok_st) queue_line;
      (match Attention.top_fast_path model.attention with
       | Some top ->
           let tag = Say.resolve lang (Render_util.attention_kind_tag top.kind) in
           put_line pri
             (Printf.sprintf "  %s %s %s %s"
                (Glyph.to_utf8 Glyph.Left_rail)
                tag
                (Glyph.to_utf8 Glyph.Separator_dot)
                top.summary)
       | None -> ());
      let keeper_status =
        match Fleet_store.find_keeper ~name:lookup_keeper model.fleet with
        | Some k ->
            let g, _ = Render_util.keeper_health_glyph_and_tone k.health in
            Printf.sprintf "%s @%s %s %s" (Glyph.to_utf8 g) k.name
              (Glyph.to_utf8 Glyph.Separator_dot)
              k.company
        | None ->
            Printf.sprintf "%s @%s" (Glyph.to_utf8 Glyph.Prompt_caret)
              display_keeper
      in
      put_line pri keeper_status;
      (match
         Fleet_store.String_map.find_opt lookup_keeper model.fleet.chat_histories
       with
       | Some obs -> (
           match Observed.to_option obs with
           | Some page -> (
               match List.rev page.messages with
               | last :: _ ->
                   let prefix =
                     match last.role with
                     | Wire_fleet.Role_user | Wire_fleet.Role_peer _ ->
                         Glyph.to_utf8 Glyph.Prompt_caret
                     | Wire_fleet.Role_assistant -> Glyph.to_utf8 Glyph.Live_healthy
                     | Wire_fleet.Role_tool -> Glyph.to_utf8 Glyph.Tool_square
                     | Wire_fleet.Role_system -> Glyph.to_utf8 Glyph.Separator_dot
                     | Wire_fleet.Role_request_failure ->
                         Glyph.to_utf8 Glyph.Live_failing
                   in
                   let one_line =
                     String.map
                       (function '\n' | '\r' -> ' ' | c -> c)
                       last.content
                   in
                   put_line sec (Printf.sprintf "  %s %s" prefix one_line)
               | [] -> ())
           | None -> ())
       | None -> ());
      let cur_draft = Drafts.current_draft model.drafts in
      let other_drafts = Drafts.other_keepers_draft_count model.drafts in
      let has_hidden_draft =
        String.length (String.trim cur_draft.text) > 0 || other_drafts > 0
      in
      if has_hidden_draft then begin
        let total =
          (if String.length (String.trim cur_draft.text) > 0 then 1 else 0)
          + other_drafts
        in
        let draft_msg =
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "%s 숨은 초안 %d건 보호 중 (입력 차단 · 80x24 이상에서 편집)"
                      (Glyph.to_utf8 Glyph.Warning_triangle) total)
               ~en:(Printf.sprintf "%s %d hidden draft(s) protected (edits locked < 80x24)"
                      (Glyph.to_utf8 Glyph.Warning_triangle) total))
        in
        put_line attn_st draft_msg
      end;
      let keys_line =
        Say.resolve lang
          (Say.make
             ~ko:"키: Ctrl+K 명령 · 0/? 도움말 · 7/, 설정 · 8/I 이슈 · 9/Ctrl+T 큐 · J 이동 · r 새로고침 · Ctrl+Q 종료"
             ~en:"Keys: Ctrl+K palette · 0/? help · 7/, settings · 8/I incidents · 9/Ctrl+T queue · J jump · r refresh · Ctrl+Q quit")
      in
      put_line sec keys_line;
      let resize_note =
        Say.resolve lang
          (Say.make ~ko:"전체 화면 레이아웃을 보려면 터미널을 80x24 이상으로 넓히세요."
             ~en:"Resize terminal to >= 80x24 for full multi-pane cockpit.")
      in
      put_line whisper resize_note
    end

let render_sidebar grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~elevated =
  if Rect.is_empty rect then ()
  else
    let lang = model.lang in
    let focused = Model.sidebar_has_focus model in
    let title = Say.resolve lang (Say.make ~ko:"메뉴" ~en:"Menu") in
    let hotkey =
      if focused then Say.resolve lang (Say.make ~ko:"[Tab] 본문" ~en:"[Tab] Body")
      else "[b]"
    in
    let inner =
      Card.draw ~cache grid ~rect ~theme
        {
          (Card.default_spec ~title) with
          hotkey = Some hotkey;
          focused;
          elevated;
        }
    in
    if Rect.is_empty inner then ()
    else
      let bg_rgb = if elevated then theme.surface_2 else theme.surface_1 in
      let bg = Color.of_rgb bg_rgb in
      let active_target = Model.active_menu_target model in
      let effective_cursor =
        if focused then model.nav.sidebar_cursor
        else Nav.menu_item_index active_target
      in
      let rows = Array.of_list Model.sidebar_visual_rows in
      let total = Array.length rows in
      let start =
        Model.sidebar_viewport_start ~inner_h:inner.h
          ~scroll:model.nav.sidebar_scroll ~cursor:effective_cursor
      in
      let data_rows =
        Model.sidebar_visible_data_rows ~inner_h:inner.h ~start
      in
      let attn_n = Attention.count model.attention in
      let inc_n = Incidents.active_count model.incidents in
      let hero = Model.pulse_hero_metrics model in
      for i = 0 to data_rows - 1 do
        let row_idx = start + i in
        if row_idx < total then begin
          let py = inner.y + i in
          let row_r = Rect.make ~x:inner.x ~y:py ~w:inner.w ~h:1 in
          match rows.(row_idx) with
          | Model.Sidebar_section sec ->
              let sec_lbl =
                String.uppercase_ascii
                  (Say.resolve lang (Nav.menu_section_label sec))
              in
              let sec_st = Typography.whisper ~bg ~italic:false theme in
              let right_edge = Rect.right inner - 1 in
              let sc_opt = Nav.menu_section_shortcut sec in
              let sc_w =
                match sc_opt with
                | None -> 0
                | Some s -> Grapheme.display_width s + 1
              in
              let max_sec_w =
                Int.max 0 (right_edge - (inner.x + 1) - sc_w)
              in
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:(inner.x + 1) ~y:py
                   ~style:sec_st
                   (Grapheme.truncate_to_width ~max_width:max_sec_w sec_lbl));
              (match sc_opt with
               | None -> ()
               | Some s ->
                   let sw = Grapheme.display_width s in
                   let sx = right_edge - sw in
                   if sx > inner.x + 2 then
                     ignore
                       (Cell_grid.put_text ~clip:row_r grid ~x:sx ~y:py
                          ~style:sec_st s))
          | Model.Sidebar_item { index; item } ->
              let is_cursor = focused && Int.equal index model.nav.sidebar_cursor in
              let is_active = Nav.equal_menu_target item.target active_target in
              let row_bg_rgb =
                if is_cursor then theme.selection_bg else bg_rgb
              in
              let row_bg = Color.of_rgb row_bg_rgb in
              if is_cursor then
                Cell_grid.fill_rect ~clip:inner grid ~rect:row_r
                  ~style:(Typography.primary ~bg:row_bg theme) ();
              if is_cursor then
                Card.draw_left_rail ~bg:row_bg ~color:theme.border_focused grid
                  ~x:inner.x ~y:py ~h:1 ~theme
              else if is_active then begin
                let rail_color =
                  if focused then theme.border_inactive else theme.border_focused
                in
                Card.draw_left_rail ~bg:row_bg ~color:rail_color grid
                  ~x:inner.x ~y:py ~h:1 ~theme
              end;
              let badge_opt : (string * Style.t) option =
                match item.target with
                | Nav.Menu_work Nav.Work_inbox when attn_n > 0 ->
                    Some
                      ( Printf.sprintf "%d" attn_n,
                        Typography.status ~bg:row_bg ~bold:true theme
                          Theme.Status_attention )
                | Nav.Menu_keepers when hero.total_keepers > 0 ->
                    Some
                      ( Printf.sprintf "%d/%d" hero.running_keepers
                          hero.total_keepers,
                        Typography.whisper ~bg:row_bg ~italic:false theme )
                | Nav.Menu_incidents when inc_n > 0 ->
                    Some
                      ( Printf.sprintf "%d" inc_n,
                        Typography.status ~bg:row_bg theme
                          Theme.Status_historical )
                | Nav.Menu_pulse
                | Nav.Menu_work
                    ( Nav.Work_pipeline
                    | Nav.Work_tasks
                    | Nav.Work_schedules
                    | Nav.Work_inbox
                    | Nav.Work_candle_scorecard
                    | Nav.Work_harness )
                | Nav.Menu_knowledge _
                | Nav.Menu_keepers
                | Nav.Menu_keeper_tab _
                | Nav.Menu_runtime _
                | Nav.Menu_infra _
                | Nav.Menu_settings
                | Nav.Menu_incidents
                | Nav.Menu_queue_context
                | Nav.Menu_help -> (
                    match item.shortcut with
                    | Some sc ->
                        Some
                          ( sc,
                            Typography.whisper ~bg:row_bg ~italic:false theme )
                    | None -> None)
              in
              let right_edge = Rect.right inner - 1 in
              let badge_w =
                match badge_opt with
                | None -> 0
                | Some (btxt, _) -> Grapheme.display_width btxt + 1
              in
              let lbl_x = inner.x + 2 in
              let max_lbl_w = Int.max 0 (right_edge - lbl_x - badge_w) in
              let lbl_st =
                if is_cursor then Typography.anchor ~bg:row_bg theme
                else if is_active then
                  Typography.accent ~bg:row_bg ~bold:(not focused) theme
                else if focused then Typography.primary ~bg:row_bg theme
                else Typography.structure ~bg:row_bg theme
              in
              let lbl =
                Grapheme.truncate_to_width ~max_width:max_lbl_w
                  (Say.resolve lang item.label)
              in
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:lbl_x ~y:py
                   ~style:lbl_st lbl);
              (match badge_opt with
               | None -> ()
               | Some (btxt, bst) ->
                   let bw = Grapheme.display_width btxt in
                   let bx = right_edge - bw in
                   if bx > lbl_x + 2 then
                     ignore
                       (Cell_grid.put_text ~clip:row_r grid ~x:bx ~y:py
                          ~style:bst btxt))
        end
      done;
      if start > 0 && inner.w >= 4 then
        ignore
          (Cell_grid.put_text ~clip:inner grid
             ~x:(Rect.right inner - 1) ~y:inner.y
             ~style:(Typography.whisper ~bg ~italic:false theme)
             "▲");
      if Model.sidebar_has_below_overflow ~inner_h:inner.h ~start then begin
        let hidden_n =
          let count = ref 0 in
          for idx = start + data_rows to total - 1 do
            match rows.(idx) with
            | Model.Sidebar_item _ -> incr count
            | Model.Sidebar_section _ -> ()
          done;
          Int.max 1 !count
        in
        let hidden_secs =
          Model.sidebar_hidden_below_sections ~inner_h:inner.h ~start
          |> List.map (fun sec -> Say.resolve lang (Nav.menu_section_label sec))
        in
        let sec_hint =
          match hidden_secs with
          | [] -> Say.resolve lang (Say.make ~ko:"더 보기" ~en:"more")
          | secs -> String.concat "·" secs
        in
        let py = Rect.bottom inner - 1 in
        let footer_r = Rect.make ~x:inner.x ~y:py ~w:inner.w ~h:1 in
        let footer_bg = Color.of_rgb theme.surface_2 in
        Cell_grid.fill_rect ~clip:inner grid ~rect:footer_r
          ~style:(Typography.accent ~bg:footer_bg theme) ();
        let label =
          Grapheme.truncate_to_width
            ~max_width:(Int.max 0 (inner.w - 2))
            (Printf.sprintf "▼ +%d %s" hidden_n sec_hint)
        in
        ignore
          (Cell_grid.put_text ~clip:footer_r grid ~x:(inner.x + 1) ~y:py
             ~style:(Typography.accent ~bg:footer_bg ~bold:true theme)
             label)
      end
      else if start + inner.h < total && inner.w >= 4 && inner.h >= 2 then
        ignore
          (Cell_grid.put_text ~clip:inner grid
             ~x:(Rect.right inner - 1) ~y:(Rect.bottom inner - 1)
             ~style:(Typography.whisper ~bg ~italic:false theme)
             "▼")

let render_frame ~(model : Model.t) ~cache ~render_body ~render_overlay grid =
  let cols = Cell_grid.cols grid in
  let rows = Cell_grid.rows grid in
  let theme = Theme.of_preset model.theme_preset in
  let base_style =
    Typography.primary ~bg:(Color.of_rgb theme.surface_0) theme
  in
  Cell_grid.clear ~style:base_style grid;
  let layout = compute_layout ~model ~cols ~rows in
  if layout.is_too_small then begin
    render_too_small_guard grid
      ~rect:(Rect.make ~x:0 ~y:0 ~w:cols ~h:rows)
      ~theme ~model;
    Presenter.hidden_cursor
  end
  else begin
    render_top_rail grid ~rect:layout.top_rail ~theme ~model
      ~breakpoint:layout.breakpoint;
    (match layout.sub_tab_bar with
     | Some r ->
         render_sub_tab_bar grid ~rect:r ~theme ~model
           ~breakpoint:layout.breakpoint
     | None -> ());
    if layout.is_micro_guard then
      render_micro_cockpit grid ~cache ~body:layout.body ~theme ~model
    else begin
      (match layout.sidebar with
       | Some sr when not layout.sidebar_is_drawer ->
           render_sidebar grid ~cache ~rect:sr ~theme ~model ~elevated:false
       | Some _ | None -> ());
      render_body layout.body grid;
      (match layout.sidebar with
       | Some sr when layout.sidebar_is_drawer ->
           Cell_grid.dim_rect grid ~rect:layout.body
             ~fg:(Color.of_rgb theme.border_subtle)
             ~bg:(Color.of_rgb theme.surface_0);
           render_sidebar grid ~cache ~rect:sr ~theme ~model ~elevated:true
       | Some _ | None -> ())
    end;
    (match layout.approval_strip with
     | Some r -> render_approval_strip grid ~rect:r ~theme ~model
     | None -> ());
    let comp_cursor =
      match layout.composer with
      | None -> Presenter.hidden_cursor
      | Some r ->
          let comp_st = Render_util.composer_state_of_model model in
          let progress_in_chat =
            (* The chat needs two inner rows to reserve its status strip. *)
            layout.body.h >= 4
            &&
            match Model.active_dive model with
            | Some dive ->
                Nav.equal_dive dive
                  (Nav.Dive_keeper { name = comp_st.target_keeper; tab = Nav.Keeper_chat })
            | None ->
                Nav.equal_workspace model.nav.workspace Nav.Keepers
                && Nav.equal_keeper_tab model.fleet.keeper_dive_tab Nav.Keeper_chat
                && (model.nav.zoomed
                    || Model.uses_keeper_split ~width:layout.body.w model)
                && Option.exists
                     (fun (keeper : Wire_fleet.keeper_summary) ->
                       String.equal keeper.name comp_st.target_keeper)
                     (Fleet_store.selected_keeper_summary model.fleet)
          in
          let c =
            Composer.draw ~show_pending_tx:(not progress_in_chat) grid ~rect:r
              ~theme ~lang:model.lang
              ~breakpoint:layout.breakpoint comp_st
          in
          (match comp_st.popup with
           | Composer.Popup_none -> ()
           | Composer.Popup_slash _ | Composer.Popup_mention _ ->
               let scrim_fg = Color.of_rgb theme.border_subtle in
               let scrim_bg = Color.of_rgb theme.surface_0 in
               Cell_grid.dim_rect grid ~rect:layout.body ~fg:scrim_fg
                 ~bg:scrim_bg;
               (match layout.approval_strip with
                | Some ar ->
                    Cell_grid.dim_rect grid ~rect:ar ~fg:scrim_fg ~bg:scrim_bg
                | None -> ());
               ignore
                 (Composer.draw_popup grid ~anchor:r ~theme ~lang:model.lang
                    comp_st.popup));
          c
    in
    (* Paint subtle border_subtle hairline separating composer/body from footer
       whenever compute_layout reserved the 1-row separator on Wide. *)
    let footer_sep_y = layout.footer.y - 1 in
    let bottom_above_sep =
      match layout.composer with
      | Some r -> Rect.bottom r
      | None -> (
          match layout.approval_strip with
          | Some r -> Rect.bottom r
          | None -> Rect.bottom layout.body)
    in
    if footer_sep_y >= bottom_above_sep && footer_sep_y > layout.top_rail.y then
      let sep_r = Rect.make ~x:0 ~y:footer_sep_y ~w:cols ~h:1 in
      Card.draw_hairline ~bg:(Color.of_rgb theme.surface_1) grid ~rect:sep_r
        ~y:footer_sep_y ~theme
    else ();
    render_footer grid ~rect:layout.footer ~theme ~model
      ~breakpoint:layout.breakpoint ~composer_folded:layout.composer_folded;
    match model.nav.overlay with
    | None ->
        render_toast_pill grid ~body_rect:layout.body ~theme ~model;
        comp_cursor
    | Some _ ->
        let overlay_rect =
          Rect.make ~x:0 ~y:layout.top_rail.h ~w:cols
            ~h:(Int.max 0 (rows - layout.top_rail.h - layout.footer.h))
        in
        Cell_grid.dim_rect grid ~rect:overlay_rect
          ~fg:(Color.of_rgb theme.border_subtle)
          ~bg:(Color.of_rgb theme.surface_0);
        render_overlay overlay_rect grid;
        render_toast_pill grid ~body_rect:overlay_rect ~theme ~model;
        Presenter.hidden_cursor
  end
