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
    let show_sub_tab = has_sub_tab_bar model in
    let sub_h = if show_sub_tab && rows >= 5 then 1 else 0 in
    let sub_tab_bar =
      if sub_h = 1 then Some (Rect.make ~x:0 ~y:1 ~w:cols ~h:1) else None
    in
    let top_h = top_rail.h + sub_h in
    let sized_model =
      {
        model with
        viewport = { cols; rows };
        breakpoint = model_breakpoint_of_layout breakpoint;
      }
    in
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
    let body =
      Layout.inset_body breakpoint (Rect.make ~x:0 ~y:top_h ~w:cols ~h:body_h)
    in
    let chrome_rows = top_h + approval_h + comp_h + footer_sep_h + footer.h in
    {
      breakpoint;
      top_rail;
      sub_tab_bar;
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
    let standard_or_wide = not compact in
    let is_micro = Layout.equal_breakpoint breakpoint Layout.Micro in
    let sep_style = Typography.whisper ~bg ~italic:false theme in
    let sep = Typography.sep_dot in
    let sep_w = Grapheme.display_width sep in
    (* Left side: 1-cell side margin + Brand (Wide/Std) + 6 Workspace Tabs *)
    let x = ref (rect.x + 1) in
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
    let fresh_glyph, fresh_label, fresh_tone =
      Render_util.freshness_pill ~model ~compact
    in
    let is_live =
      match (fresh_tone, model.freshness.observer) with
      | Theme.Status_ok, Health.Live _ -> true
      | ( Theme.Status_ok
        | Theme.Status_active
        | Theme.Status_attention
        | Theme.Status_critical
        | Theme.Status_ai
        | Theme.Status_historical ),
        ( Health.Connecting
        | Health.Live _
        | Health.Reconnecting _
        | Health.Stale _
        | Health.Disconnected _
        | Health.Workspace_mismatch _ ) ->
          false
    in
    let fresh_item =
      let segments =
        if is_live then
          [
            ( Glyph.to_utf8 fresh_glyph,
              Typography.status ~bg ~bold:true theme Theme.Status_ok );
            (" " ^ fresh_label, Typography.structure ~bg theme);
          ]
        else
          [
            ( Printf.sprintf "%s %s" (Glyph.to_utf8 fresh_glyph) fresh_label,
              Typography.status ~bg ~bold:true theme fresh_tone );
          ]
      in
      { priority = 1; segments }
    in
    let attn_count = Attention.count model.attention in
    let attn_item =
      if attn_count > 0 then
        Some
          {
            priority = 2;
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
    let fleet_item =
      if standard_or_wide then
        let hero = Model.pulse_hero_metrics model in
        if hero.total_keepers > 0 then
          Some
            {
              priority = 5;
              segments =
                [
                  ( Printf.sprintf "%d/%d" hero.running_keepers
                      hero.total_keepers,
                    Typography.primary ~bg theme );
                ];
            }
        else None
      else None
    in
    let inc_count = Incidents.active_count model.incidents in
    let inc_item =
      if inc_count > 0 then
        (* Channel-3 muted historical count — strictly Status_historical *)
        Some
          {
            priority = 4;
            segments =
              [
                ( Printf.sprintf "%s %d"
                    (Glyph.to_utf8 Glyph.Historical_incident)
                    inc_count,
                  Typography.status ~bg theme Theme.Status_historical );
              ];
          }
      else None
    in
    let ws_item =
      if wide then
        match workspace_basename model with
        | Some ws_name ->
            let clipped = Grapheme.truncate_to_width ~max_width:14 ws_name in
            Some
              {
                priority = 6;
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
              priority = 3;
              segments = [ (hhmm, Typography.whisper ~bg theme) ];
            }
      | None -> None
    in
    let raw_items =
      [ attn_item; Some fresh_item; fleet_item; inc_item; ws_item; clock_item ]
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
    let max_right_w = Int.max 0 (Rect.right rect - 1 - tabs_end_x - 1) in
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
    | Nav.Keeper_memory -> Say.resolve lang (Say.make ~ko:"기억" ~en:"Mem")
    | Nav.Keeper_work_candle -> Say.resolve lang (Say.make ~ko:"작업" ~en:"Work")
    | Nav.Keeper_sandbox -> Say.resolve lang (Say.make ~ko:"격리" ~en:"Sbox")
    | Nav.Keeper_config -> Say.resolve lang (Say.make ~ko:"설정" ~en:"Cfg")

let compact_work_tab_label ~(lang : Say.lang) ~compact tab =
  if not compact then Say.resolve lang (Nav.work_tab_label tab)
  else
    match tab with
    | Nav.Work_pipeline -> Say.resolve lang (Say.make ~ko:"파이프라인" ~en:"Pipe")
    | Nav.Work_tasks_schedules -> Say.resolve lang (Say.make ~ko:"작업·일정" ~en:"Tasks")
    | Nav.Work_inbox -> Say.resolve lang (Say.make ~ko:"수신함" ~en:"Inbox")
    | Nav.Work_candle_scorecard -> Say.resolve lang (Say.make ~ko:"캔들·성과" ~en:"Candle")

let compact_knowledge_tab_label ~(lang : Say.lang) ~compact tab =
  if not compact then Say.resolve lang (Nav.knowledge_tab_label tab)
  else
    match tab with
    | Nav.Knowledge_board -> Say.resolve lang (Say.make ~ko:"보드" ~en:"Board")
    | Nav.Knowledge_wiki_artifacts -> Say.resolve lang (Say.make ~ko:"위키·산출" ~en:"Wiki")
    | Nav.Knowledge_memory -> Say.resolve lang (Say.make ~ko:"기억" ~en:"Memory")

let compact_runtime_tab_label ~(lang : Say.lang) ~compact tab =
  if not compact then Say.resolve lang (Nav.runtime_tab_label tab)
  else
    match tab with
    | Nav.Runtime_quotas_credits -> Say.resolve lang (Say.make ~ko:"할당·크레딧" ~en:"Quotas")
    | Nav.Runtime_efficiency_spend -> Say.resolve lang (Say.make ~ko:"효율·지출" ~en:"Spend")
    | Nav.Runtime_failover_lanes -> Say.resolve lang (Say.make ~ko:"페일오버" ~en:"Lanes")
    | Nav.Runtime_tools_connectors -> Say.resolve lang (Say.make ~ko:"도구·연동" ~en:"Tools")

let compact_infra_tab_label ~(lang : Say.lang) ~compact tab =
  if not compact then Say.resolve lang (Nav.infra_tab_label tab)
  else
    match tab with
    | Nav.Infra_sandboxes -> Say.resolve lang (Say.make ~ko:"샌드박스" ~en:"Sbox")
    | Nav.Infra_repos_changes -> Say.resolve lang (Say.make ~ko:"저장소·변경" ~en:"Repos")
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
    let right_text, right_style =
      if model.nav.filter_focused then
        ( Printf.sprintf " / %s_ " filter_q,
          Typography.anchor ~bg:(Color.of_rgb theme.selection_bg) theme )
      else if not (String.equal filter_q "") then
        ( Printf.sprintf " / %s " filter_q,
          Typography.accent ~bg:pill_bg ~bold:true theme )
      else if Option.is_some (Model.active_dive model) then
        let txt =
          if compact then "[Esc]"
          else Say.resolve lang (Say.make ~ko:"[Esc] 뒤로" ~en:"[Esc] Back")
        in
        (txt, whisper_style)
      else if Model.is_keeper_config_active model then
        let txt =
          if compact then "[[ ]]"
          else
            Say.resolve lang
              (Say.make ~ko:"[/] 검색  [←→] 값  [[ ]] 탭"
                 ~en:"[/] Filter  [←→] Cycle  [[ ]] Tabs")
        in
        (txt, whisper_style)
      else
        let txt =
          if compact then "[←→]"
          else
            Say.resolve lang
              (Say.make ~ko:"[/] 검색  [←→] 탭" ~en:"[/] Filter  [←→] Tabs")
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
      if filter_active then
        Rect.make ~x:rect.x ~y:rect.y ~w:(Int.max 0 (rx - rect.x - 1)) ~h:1
      else rect
    in
    let x = ref (rect.x + left_pad) in
    let draw_tab_list tabs =
      let rec loop first = function
        | [] -> ()
        | (label, is_active) :: rest ->
            if not first then x := !x + gap;
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
            end;
            loop false rest
      in
      loop true tabs
    in
    (match Model.active_dive model with
     | Some (Nav.Dive_keeper { name; tab }) ->
         let crumb =
           Printf.sprintf "%s %s %s"
             (Say.resolve lang (Nav.workspace_label Nav.Keepers))
             (Glyph.to_utf8 Glyph.Prompt_caret)
             (Grapheme.truncate_to_width ~max_width:20 name)
         in
         let adv =
           Cell_grid.put_text ~clip:tabs_clip grid ~x:!x ~y:rect.y
             ~style:crumb_style crumb
         in
         x := !x + adv + 2;
         let tabs =
           List.map
             (fun t ->
               ( compact_keeper_tab_label ~lang ~compact t,
                 Nav.equal_keeper_tab t tab ))
             Nav.all_keeper_tabs
         in
         draw_tab_list tabs
     | Some (Nav.Dive_work target) ->
         let label =
           match target with
           | Nav.Goal_dive id ->
               Say.resolve lang (Say.make ~ko:"목표" ~en:"Goal") ^ " " ^ id
           | Nav.Task_dive id ->
               Say.resolve lang (Say.make ~ko:"작업" ~en:"Task") ^ " " ^ id
           | Nav.Verification_dive id ->
               Say.resolve lang (Say.make ~ko:"검증" ~en:"Verify") ^ " " ^ id
         in
         let crumb =
           Printf.sprintf "%s %s %s"
             (Say.resolve lang (Nav.workspace_label Nav.Work))
             (Glyph.to_utf8 Glyph.Prompt_caret)
             label
         in
         let adv =
           Cell_grid.put_text ~clip:tabs_clip grid ~x:!x ~y:rect.y
             ~style:crumb_style crumb
         in
         x := !x + adv
     | Some (Nav.Dive_knowledge target) ->
         let label =
           match target with
           | Nav.Thread_dive id ->
               Say.resolve lang (Say.make ~ko:"타래" ~en:"Thread") ^ " " ^ id
           | Nav.Wiki_dive slug ->
               Say.resolve lang (Say.make ~ko:"위키" ~en:"Wiki") ^ " " ^ slug
           | Nav.Artifact_dive id ->
               Say.resolve lang (Say.make ~ko:"산출물" ~en:"Artifact") ^ " " ^ id
           | Nav.Memory_diff_dive { keeper; from_rev; to_rev } ->
               let scope =
                 match keeper with
                 | Some k -> k
                 | None -> Say.resolve lang (Say.make ~ko:"월드" ~en:"World")
               in
               Printf.sprintf "%s rev %d..%d" scope from_rev to_rev
         in
         let crumb =
           Printf.sprintf "%s %s %s"
             (Say.resolve lang (Nav.workspace_label Nav.Knowledge))
             (Glyph.to_utf8 Glyph.Prompt_caret)
             label
         in
         let adv =
           Cell_grid.put_text ~clip:tabs_clip grid ~x:!x ~y:rect.y
             ~style:crumb_style crumb
         in
         x := !x + adv
     | Some (Nav.Dive_infra target) ->
         let label =
           match target with
           | Nav.Sandbox_dive name ->
               Say.resolve lang (Say.make ~ko:"샌드박스" ~en:"Sandbox") ^ " " ^ name
           | Nav.Lane_dive id ->
               Say.resolve lang (Say.make ~ko:"레인" ~en:"Lane") ^ " " ^ id
           | Nav.Incident_dive id ->
               Printf.sprintf "%s #%d"
                 (Say.resolve lang (Say.make ~ko:"이력" ~en:"Incident"))
                 id
         in
         let crumb =
           Printf.sprintf "%s %s %s"
             (Say.resolve lang (Nav.workspace_label Nav.Infra))
             (Glyph.to_utf8 Glyph.Prompt_caret)
             label
         in
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
                     | Nav.Work_tasks_schedules
                     | Nav.Work_inbox
                     | Nav.Work_candle_scorecard ->
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
         | Nav.Keepers ->
             let tabs =
               List.map
                 (fun m ->
                   ( Say.resolve lang (Nav.keepers_fleet_mode_label m),
                     Nav.equal_keepers_fleet_mode m model.fleet.fleet_mode ))
                 Nav.all_keepers_fleet_modes
             in
             draw_tab_list tabs
         | Nav.Runtime ->
             let tabs =
               List.map
                 (fun t ->
                   ( compact_runtime_tab_label ~lang ~compact t,
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
    (* Always anchor active / query_ pill on right; hide idle hint only if tight *)
    if filter_active || rx > !x + 2 then
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
        let full_allow =
          Say.resolve lang (Say.make ~ko:"[Y] 승인" ~en:"[Y] Allow")
        in
        let full_deny =
          Say.resolve lang (Say.make ~ko:"[N] 거절" ~en:"[N] Deny")
        in
        let full_dive =
          Say.resolve lang (Say.make ~ko:"[J] 상세" ~en:"[J] Dive")
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
            let a = "[Y]" and d = "[N]" and j = "[J]" and sep = "/" in
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
    | Some
        ( Nav.Queue_context _
        | Nav.Inline_action _
        | Nav.Help
        | Nav.System_gate Nav.Media_viewer ) ->
        Say.resolve lang (Say.make ~ko:"Esc 돌아가기" ~en:"Esc return")
    | None -> (
        let _, fresh_lbl, _ = Render_util.freshness_pill ~model ~compact:true in
        match workspace_basename model with
        | Some ws ->
            Printf.sprintf "SSE %s %s %s" fresh_lbl
              (Glyph.to_utf8 Glyph.Separator_dot)
              (Grapheme.truncate_to_width ~max_width:14 ws)
        | None -> Printf.sprintf "SSE %s" fresh_lbl)

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
    (* Right-aligned Tier-4 italic connection/context hint on Wide/Standard *)
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
    (* Request candidate hints generously, then fit max 6-7 elevated keycap pairs
       strictly within remaining_w with zero clipping. *)
    let max_pairs = if compact then 6 else 7 in
    let pair_gap = if compact && rect.w < 84 then 1 else 2 in
    let candidates =
      if model.nav.filter_focused then
        let mk key ko en action : Keymap.footer_hint =
          {
            Keymap.key_display = key;
            label = Say.resolve model.lang (Say.make ~ko ~en);
            action;
            priority = 1;
          }
        in
        [
          mk "↑↓" "이동" "Move" (Keymap.Move Keymap.Down);
          mk "Enter" "적용" "Apply" Keymap.Confirm_selected;
          mk "Tab" "완료" "Done" (Keymap.Cycle_focus_pane Keymap.Next);
          mk "Esc" "초기화" "Clear" Keymap.Pop_back_or_close;
        ]
      else
        let raw =
          Keymap.footer_hints ~scope_chain ~max_width:(remaining_w + 24)
            ~lang:model.lang
        in
        let show_tab_hint =
          match model.nav.overlay with
          | Some (Nav.Help | Nav.Incidents | Nav.System_gate _) -> false
          | Some (Nav.Settings _) ->
              Config_store.is_two_pane_width ~cols:model.viewport.cols
          | Some (Nav.Palette | Nav.Queue_context _ | Nav.Inline_action _) ->
              true
          | None -> Model.focusable_pane_count model > 1
        in
        let enter_hint =
          match model.nav.overlay with
          | None -> Update_nav.enter_hint model
          | Some _ -> Update_nav.Enter_hint_dive
        in
        let relabel (h : Keymap.footer_hint) ~ko ~en =
          { h with label = Say.resolve model.lang (Say.make ~ko ~en) }
        in
        List.filter_map
          (fun (h : Keymap.footer_hint) ->
            let is_tab_hint =
              Keymap.equal_action h.action (Keymap.Cycle_focus_pane Keymap.Next)
              || Keymap.equal_action h.action
                   (Keymap.Cycle_focus_pane Keymap.Prev)
            in
            if is_tab_hint && not show_tab_hint then None
            else if not (Keymap.equal_action h.action Keymap.Dive_selected) then
              Some h
            else
              match enter_hint with
              | Update_nav.Enter_hint_hidden -> None
              | Update_nav.Enter_hint_dive -> Some h
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
        let py = Rect.bottom body_rect - 1 in
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
  let line2 =
    if
      Drafts.has_non_empty_draft model.drafts
      || Drafts.other_keepers_draft_count model.drafts > 0
    then
      Say.resolve lang
        (Say.make ~ko:"초안 안전 보호 중 · Ctrl+Q 종료"
           ~en:"Draft preserved · Ctrl+Q quit")
    else
      Say.resolve lang (Say.make ~ko:"Ctrl+Q 종료" ~en:"Ctrl+Q quit")
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
      (Cell_grid.put_text ~clip:rect grid ~x:(rect.x + 1) ~y:mid_y ~style:sec_st
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
      let resize_note =
        Say.resolve lang
          (Say.make ~ko:"전체 화면 레이아웃을 보려면 터미널을 80x24 이상으로 넓히세요."
             ~en:"Resize terminal to >= 80x24 for full multi-pane cockpit.")
      in
      put_line whisper resize_note
    end

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
    else render_body layout.body grid;
    (match layout.approval_strip with
     | Some r -> render_approval_strip grid ~rect:r ~theme ~model
     | None -> ());
    let comp_cursor =
      match layout.composer with
      | None -> Presenter.hidden_cursor
      | Some r ->
          let comp_st = Render_util.composer_state_of_model model in
          let c =
            Composer.draw grid ~rect:r ~theme ~lang:model.lang
              ~breakpoint:layout.breakpoint comp_st
          in
          ignore
            (Composer.draw_popup grid ~anchor:r ~theme ~lang:model.lang
               comp_st.popup);
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
        render_overlay overlay_rect grid;
        render_toast_pill grid ~body_rect:overlay_rect ~theme ~model;
        Presenter.hidden_cursor
  end
