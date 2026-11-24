open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let default_caps = Presenter.default_capabilities

let say (lang : Say.lang) ~ko ~en = Say.resolve lang (Say.make ~ko ~en)

let sanitize_single_line s =
  let buf = Buffer.create (String.length s) in
  let prev_space = ref false in
  String.iter
    (fun c ->
      let code = Char.code c in
      if c = '\n' || c = '\r' || c = '\t' then begin
        if not !prev_space then Buffer.add_char buf ' ';
        prev_space := true
      end
      else if code >= 32 then begin
        Buffer.add_char buf c;
        prev_space := c = ' '
      end)
    s;
  String.trim (Buffer.contents buf)

let short_hash ?(len = 8) s =
  if String.length s <= len then s else String.sub s 0 len

let format_age ~now_unix ts_unix =
  if
    (not (Float.is_finite now_unix))
    || (not (Float.is_finite ts_unix))
    || now_unix <= 0.0
    || ts_unix <= 0.0
  then Glyph.to_utf8 Glyph.Missing_absent
  else
    let delta = Float.max 0.0 (now_unix -. ts_unix) in
    if delta < 5.0 then "now" else Format_val.format_duration_s delta

let wrap_lines = Knowledge_store.wrap_lines

let put_clipped ~grid ~clip ~x ~y ~max_w ~style s =
  if max_w <= 0 then 0
  else
    let clipped = Grapheme.truncate_to_width ~max_width:max_w s in
    Cell_grid.put_text ~clip grid ~x ~y ~style clipped

let put_right ~grid ~clip ~right_x ~y ~max_w ~style s =
  if max_w <= 0 then 0
  else
    let clipped = Grapheme.truncate_to_width ~max_width:max_w s in
    let w = Grapheme.display_width clipped in
    let x = Int.max clip.Rect.x (right_x - w) in
    Cell_grid.put_text ~clip grid ~x ~y ~style clipped

let paint_selected_row ~grid ~clip ~(row_rect : Rect.t) ~(theme : Theme.t)
    ?tone () =
  let bg = Color.of_rgb theme.selection_bg in
  Cell_grid.fill_rect ~clip grid ~rect:row_rect
    ~style:(Style.make ~bg ())
    ();
  let rail_fg =
    match tone with
    | Some tok -> Color.of_rgb (Theme.status_color theme tok)
    | None -> Color.of_rgb theme.accent
  in
  Cell_grid.put_glyph ~clip grid ~x:row_rect.x ~y:row_rect.y
    ~style:(Style.make ~fg:rail_fg ~bg ~attrs:Attr.bold ())
    Glyph.Left_rail

let draw_observed_notice ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~bg (obs : 'a Observed.t) =
  if Rect.is_empty rect then ()
  else
    let cy = rect.y + Int.min 1 (Int.max 0 (rect.h / 2)) in
    match obs with
    | Observed.Loading _ ->
        let txt =
          Glyph.to_utf8 Glyph.Transport_reconnecting ^ " "
          ^ say lang ~ko:"불러오는 중..." ~en:"Loading..."
        in
        ignore
          (put_clipped ~grid ~clip:rect ~x:rect.x ~y:cy ~max_w:rect.w
             ~style:(Typography.whisper ~bg theme) txt)
    | Observed.Absent ->
        let txt =
          Glyph.to_utf8 Glyph.Missing_absent ^ " "
          ^ say lang ~ko:"표시할 항목 없음" ~en:"No data available"
        in
        ignore
          (put_clipped ~grid ~clip:rect ~x:rect.x ~y:cy ~max_w:rect.w
             ~style:(Typography.whisper ~bg theme) txt)
    | Observed.Unreported ->
        let txt =
          Glyph.to_utf8 Glyph.Missing_unreported ^ " "
          ^ say lang ~ko:"서버 미보고" ~en:"Unreported by server"
        in
        ignore
          (put_clipped ~grid ~clip:rect ~x:rect.x ~y:cy ~max_w:rect.w
             ~style:(Typography.whisper ~bg theme) txt)
    | Observed.Failed { reason; retryable; _ } ->
        let suffix =
          if retryable then say lang ~ko:" (재시도 가능 · [r])" ~en:" (retryable · [r])"
          else ""
        in
        Card.draw_left_rail ~bg ~tone:Theme.Status_critical grid ~x:rect.x ~y:cy
          ~h:1 ~theme;
        let txt =
          Glyph.to_utf8 Glyph.Live_failing ^ " "
          ^ say lang
              ~ko:("조회 실패: " ^ reason ^ suffix)
              ~en:("Fetch failed: " ^ reason ^ suffix)
        in
        ignore
          (put_clipped ~grid ~clip:rect ~x:(rect.x + 2) ~y:cy
             ~max_w:(Int.max 0 (rect.w - 2))
             ~style:(Typography.status ~bg ~bold:true theme Theme.Status_critical)
             txt)
    | Observed.Value _ -> ()

let activity_kind_spec ~lang = function
  | Wire_knowledge.Activity_created ->
      ("+", say lang ~ko:"생성" ~en:"Created", Theme.Status_ok)
  | Wire_knowledge.Activity_reobserved ->
      ("↻", say lang ~ko:"재관측" ~en:"Reobserved", Theme.Status_active)
  | Wire_knowledge.Activity_revised ->
      ("~", say lang ~ko:"수정" ~en:"Revised", Theme.Status_active)
  | Wire_knowledge.Activity_absorbed ->
      ("⊕", say lang ~ko:"흡수" ~en:"Absorbed", Theme.Status_ai)
  | Wire_knowledge.Activity_retracted ->
      ("-", say lang ~ko:"철회" ~en:"Retracted", Theme.Status_critical)
  | Wire_knowledge.Activity_removed ->
      ("✕", say lang ~ko:"삭제" ~en:"Removed", Theme.Status_critical)
  | Wire_knowledge.Activity_invalidated ->
      ("!", say lang ~ko:"무효화" ~en:"Invalidated", Theme.Status_attention)
  | Wire_knowledge.Activity_relation_unavailable ->
      ("?", say lang ~ko:"관계 미확인" ~en:"Relation N/A", Theme.Status_attention)

let relation_label ~lang = function
  | Wire_knowledge.Revision -> say lang ~ko:"개정" ~en:"rev"
  | Wire_knowledge.Program_revision -> say lang ~ko:"규칙 개정" ~en:"prog-rev"
  | Wire_knowledge.Program_absorption -> say lang ~ko:"흡수" ~en:"absorb"

let heat_badge = function
  | Wire_knowledge.Heat_hot -> ("HOT", Theme.Status_attention)
  | Wire_knowledge.Heat_warm -> ("WARM", Theme.Status_active)
  | Wire_knowledge.Heat_cold -> ("COLD", Theme.Status_historical)
  | Wire_knowledge.Heat_never_retrieved -> ("0x", Theme.Status_historical)

let json_kv_summary = function
  | `Assoc fields ->
      List.filter_map
        (fun (k, v) ->
          match v with
          | `String s -> Some (k, sanitize_single_line s)
          | `Int n -> Some (k, string_of_int n)
          | `Float f -> Some (k, Printf.sprintf "%.2f" f)
          | `Bool b -> Some (k, string_of_bool b)
          | `Null | `List _ | `Assoc _ | `Intlit _ -> None)
        fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> []

(* --- Full Reading Renderer (scrollable word-wrapped detail) --- *)

let style_of_reading_tone ~theme ~bg = function
  | Knowledge_store.Reading_anchor -> Typography.anchor ~bg theme
  | Knowledge_store.Reading_primary -> Typography.primary ~bg theme
  | Knowledge_store.Reading_structure { bold } ->
      Typography.structure ~bg ~bold theme
  | Knowledge_store.Reading_whisper { italic } ->
      Typography.whisper ~bg ~italic theme
  | Knowledge_store.Reading_status { tone; bold } ->
      Typography.status ~bg ~bold theme tone

let render_full_reading ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~now_unix ~entry ~scroll =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let hdr_rect, body_rect = Rect.split_v rect ~top_h:1 in
    let hdr_bg = Color.of_rgb theme.surface_2 in
    Cell_grid.fill_rect ~clip:hdr_rect grid ~rect:hdr_rect
      ~style:(Style.make ~bg:hdr_bg ())
      ();
    let title =
      say lang ~ko:"전문 읽기 (Full Reading)" ~en:"Full Reading"
    in
    let hint =
      say lang ~ko:"[j/k] 스크롤 · [y] 복사 · [Esc] 닫기"
        ~en:"[j/k] Scroll · [y] Copy · [Esc] Close"
    in
    let hw = Grapheme.display_width hint in
    ignore
      (put_clipped ~grid ~clip:hdr_rect ~x:(hdr_rect.x + 1) ~y:hdr_rect.y
         ~max_w:(Int.max 6 (hdr_rect.w - hw - 3))
         ~style:(Typography.anchor ~bg:hdr_bg theme)
         title);
    if hdr_rect.w > hw + 10 then
      ignore
        (put_right ~grid ~clip:hdr_rect ~right_x:(Rect.right hdr_rect - 1)
           ~y:hdr_rect.y ~max_w:hw
           ~style:(Typography.whisper ~bg:hdr_bg ~italic:false theme)
           hint);
    if not (Rect.is_empty body_rect) then begin
      let lines =
        Knowledge_store.project_memory_reading_lines ~width:body_rect.w ~lang
          ~now_unix entry
      in
      let vis_h = Int.max 1 body_rect.h in
      let max_scroll = Int.max 0 (List.length lines - vis_h) in
      let skip = Int.min max_scroll (Int.max 0 scroll) in
      let y = ref body_rect.y in
      let bottom = Rect.bottom body_rect in
      List.iter
        (fun (ln : Knowledge_store.reading_line) ->
          if !y < bottom then begin
            let tx =
              match ln.rail with
              | Some tone ->
                  Card.draw_left_rail ~bg ~tone grid ~x:body_rect.x ~y:!y ~h:1
                    ~theme;
                  body_rect.x + 2
              | None -> body_rect.x
            in
            let style = style_of_reading_tone ~theme ~bg ln.tone in
            ignore
              (put_clipped ~grid ~clip:body_rect ~x:tx ~y:!y
                 ~max_w:(Int.max 0 (Rect.right body_rect - tx))
                 ~style ln.text);
            incr y
          end)
        (Store_scroll.drop skip lines)
    end

(* --- Interactive Memory Diagram Renderer (Pele SVG / Mermaid / Formation Tree) --- *)

let active_diagram_body_rect = Memory_diagram.active_diagram_body_rect

let render_memory_diagram ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~(diagram : Knowledge_store.memory_diagram_state) =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let hdr_rect, after_hdr = Rect.split_v rect ~top_h:1 in
    let hdr_bg = Color.of_rgb theme.surface_2 in
    Cell_grid.fill_rect ~clip:hdr_rect grid ~rect:hdr_rect
      ~style:(Style.make ~bg:hdr_bg ())
      ();
    let kind_lbl =
      match diagram.kind with
      | Knowledge_store.Diagram_pele_card ->
          say lang ~ko:"Pele/Mermaid 카드" ~en:"Pele/Mermaid Card"
      | Knowledge_store.Diagram_formation_tree ->
          say lang ~ko:"기억 형성 트리" ~en:"Formation Tree"
    in
    let mode_lbl =
      match diagram.mode with
      | Knowledge_store.Diagram_mode_auto -> (
          match Observed.to_option diagram.payload with
          | Some (Knowledge_store.Diagram_pele_png { format_label; _ }) ->
              "Auto · " ^ format_label
          | Some (Knowledge_store.Diagram_text _) | None -> "Auto")
      | Knowledge_store.Diagram_mode_mermaid -> "Mermaid"
      | Knowledge_store.Diagram_mode_tree -> "Tree"
    in
    let title =
      Printf.sprintf "%s · r%d [%s]" kind_lbl diagram.revision mode_lbl
    in
    let hint =
      say lang ~ko:"[v] Pele/Mermaid/Tree · [y] 복사 · [Esc] 닫기"
        ~en:"[v] Pele/Mermaid/Tree · [y] Copy · [Esc] Close"
    in
    let hw = Grapheme.display_width hint in
    ignore
      (put_clipped ~grid ~clip:hdr_rect ~x:(hdr_rect.x + 1) ~y:hdr_rect.y
         ~max_w:(Int.max 6 (hdr_rect.w - hw - 3))
         ~style:(Typography.anchor ~bg:hdr_bg theme)
         title);
    if hdr_rect.w > hw + 10 then
      ignore
        (put_right ~grid ~clip:hdr_rect ~right_x:(Rect.right hdr_rect - 1)
           ~y:hdr_rect.y ~max_w:hw
           ~style:(Typography.whisper ~bg:hdr_bg ~italic:false theme)
           hint);
    if not (Rect.is_empty after_hdr) then begin
      let body_rect, has_note =
        Memory_diagram.diagram_body_rect ~content_rect:rect diagram
      in
      let draw_note note_txt =
        if has_note then begin
          let note_r, _ = Rect.split_v after_hdr ~top_h:1 in
          Card.draw_left_rail ~bg ~tone:Theme.Status_attention grid ~x:note_r.x
            ~y:note_r.y ~h:1 ~theme;
          ignore
            (put_clipped ~grid ~clip:note_r ~x:(note_r.x + 2) ~y:note_r.y
               ~max_w:(Int.max 0 (note_r.w - 2))
               ~style:(Typography.status ~bg theme Theme.Status_attention)
               note_txt)
        end
      in
      let draw_text_lines lines =
        if not (Rect.is_empty body_rect) then begin
          let vis_h = Int.max 1 body_rect.h in
          let max_scroll = Int.max 0 (List.length lines - vis_h) in
          let skip = Int.min max_scroll (Int.max 0 diagram.scroll) in
          let y = ref body_rect.y in
          let bottom = Rect.bottom body_rect in
          List.iter
            (fun line ->
              if !y < bottom then begin
                ignore
                  (put_clipped ~grid ~clip:body_rect ~x:body_rect.x ~y:!y
                     ~max_w:body_rect.w
                     ~style:(Typography.primary ~bg theme)
                     line);
                incr y
              end)
            (Store_scroll.drop skip lines)
        end
      in
      match diagram.payload with
      | Observed.Value { data = Knowledge_store.Diagram_pele_png { fallback_lines; _ }; _ } ->
          if Memory_diagram.can_render_png_in_rect ~content_rect:rect diagram
          then
            (* Clean surface canvas so Kitty/iTerm2 pixel overlay paints without text bleed *)
            Cell_grid.fill_rect ~clip:body_rect grid ~rect:body_rect
              ~style:(Style.make ~bg ())
              ()
          else begin
            draw_note
              (say lang ~ko:"표시 영역이 좁아 텍스트 폴백으로 전환됨"
                 ~en:"Viewport narrow · showing text fallback");
            draw_text_lines fallback_lines
          end
      | Observed.Value { data = Knowledge_store.Diagram_text { lines; note }; _ } ->
          (match note with
          | Some n when not (String.equal (String.trim n) "") -> draw_note n
          | Some _ | None -> ());
          draw_text_lines lines
      | Observed.Loading _ ->
          let msg =
            Glyph.to_utf8 Glyph.Transport_reconnecting ^ " "
            ^ say lang ~ko:"다이어그램 렌더링 중..." ~en:"Rendering diagram..."
          in
          ignore
            (put_clipped ~grid ~clip:body_rect ~x:body_rect.x ~y:body_rect.y
               ~max_w:body_rect.w
               ~style:(Typography.whisper ~bg theme)
               msg)
      | (Observed.Absent | Observed.Unreported | Observed.Failed _) as obs ->
          draw_observed_notice ~grid ~rect:body_rect ~theme ~lang ~bg obs
    end

(* --- Mode Switch Pills Bar --- *)

let draw_mode_pills ~grid ~(rect : Rect.t) ~(theme : Theme.t) ~(lang : Say.lang)
    ~bg ~(k : Knowledge_store.t) ~keeper =
  if Rect.is_empty rect then ()
  else
    let ev_cnt =
      match
        Observed.to_option (Knowledge_store.keeper_memory_activity_for ~keeper k)
      with
      | Some act -> Printf.sprintf " (%d)" (List.length act.events)
      | None -> ""
    in
    let fact_cnt =
      match
        Observed.to_option (Knowledge_store.keeper_memory_facts_for ~keeper k)
      with
      | Some _ ->
          let n = List.length (Knowledge_store.filtered_memory_fact_rows ~keeper k) in
          Printf.sprintf " (%d)" n
      | None -> ""
    in
    let win_s =
      match k.memory_diff_window with
      | Knowledge_store.Window_24h -> "24h"
      | Knowledge_store.Window_7d -> "7d"
      | Knowledge_store.Window_30d -> "30d"
      | Knowledge_store.Window_revs { from_rev; to_rev } ->
          Printf.sprintf "r%d..%d" from_rev to_rev
    in
    let pills =
      [
        ( Printf.sprintf "[e] %s%s"
            (say lang ~ko:"변천 과정" ~en:"Evolution")
            ev_cnt
        , Knowledge_store.equal_memory_view_mode k.memory_view_mode
            Knowledge_store.View_evolution
        , Theme.Status_active );
        ( Printf.sprintf "[f] %s%s"
            (say lang ~ko:"전체 기억" ~en:"Facts")
            fact_cnt
        , Knowledge_store.equal_memory_view_mode k.memory_view_mode
            Knowledge_store.View_facts
        , Theme.Status_ok );
        ( Printf.sprintf "[d] %s (%s)"
            (say lang ~ko:"기간 Diff" ~en:"Diff")
            win_s
        , Knowledge_store.equal_memory_view_mode k.memory_view_mode
            Knowledge_store.View_diff
        , Theme.Status_ai );
      ]
    in
    let right_hint =
      match k.memory_view_mode with
      | Knowledge_store.View_evolution ->
          say lang ~ko:"[Enter] 전문 · [.] Pele/Mermaid · [Ctrl+O] 형성 트리"
            ~en:"[Enter] Read · [.] Pele/Mermaid · [Ctrl+O] Tree"
      | Knowledge_store.View_facts ->
          let sort_lbl =
            match k.memory_facts_sort with
            | Knowledge_store.Sort_recency ->
                say lang ~ko:"최근순" ~en:"Recency"
            | Knowledge_store.Sort_retrieved ->
                say lang ~ko:"조회순" ~en:"Retrieved"
          in
          Printf.sprintf "[s] %s · [Enter] %s" sort_lbl
            (say lang ~ko:"전문" ~en:"Read")
      | Knowledge_store.View_diff ->
          say lang ~ko:"[w] 기간 · [M] 흐름/총량 · [Enter] 전문"
            ~en:"[w] Win · [M] Flow/Net · [Enter] Read"
    in
    let rh_w = Grapheme.display_width right_hint in
    let pills_limit =
      if rect.w > rh_w + 24 then Rect.right rect - rh_w - 2 else Rect.right rect
    in
    let cx = ref rect.x in
    List.iter
      (fun (label, active, tone) ->
        if !cx < pills_limit then begin
          let avail = pills_limit - !cx in
          if active then begin
            let pbg = Color.of_rgb theme.surface_2 in
            Cell_grid.put_glyph ~clip:rect grid ~x:!cx ~y:rect.y
              ~style:
                (Style.make
                   ~fg:(Color.of_rgb (Theme.status_color theme tone))
                   ~bg:pbg ~attrs:Attr.bold ())
              Glyph.Left_rail;
            let adv =
              put_clipped ~grid ~clip:rect ~x:(!cx + 1) ~y:rect.y
                ~max_w:(Int.max 0 (avail - 1))
                ~style:(Typography.anchor ~bg:pbg ~underline:true theme)
                (" " ^ label ^ " ")
            in
            cx := !cx + 1 + adv + 1
          end
          else begin
            let adv =
              put_clipped ~grid ~clip:rect ~x:!cx ~y:rect.y ~max_w:avail
                ~style:(Typography.structure ~bg theme)
                label
            in
            cx := !cx + adv + 2
          end
        end)
      pills;
    if rect.w > rh_w + 24 then
      ignore
        (put_right ~grid ~clip:rect ~right_x:(Rect.right rect) ~y:rect.y
           ~max_w:rh_w ~style:(Typography.whisper ~bg ~italic:false theme)
           right_hint)

(* --- Responsive Chart Strip (24-bin Age Ladder + facts_by_hour Braille + OS Internals) --- *)

let draw_os_internals_line ~grid ~clip ~x ~y ~max_w ~theme ~bg ~keeper
    (k : Knowledge_store.t) =
  match
    Observed.to_option (Knowledge_store.memory_os_internals_for ~keeper k)
  with
  | Some intr when String.equal intr.keeper keeper ->
      let comp_s =
        if intr.compaction.present then
          Printf.sprintf "cmp:%dep/%dt/%dB" intr.compaction.epoch_count
            intr.compaction.archived_turns_count intr.compaction.anchor_bytes
        else "cmp:none"
      in
      let ct_s =
        if intr.canonical_turns.present then
          let rk =
            Option.value intr.canonical_turns.latest_runtime_kind ~default:"?"
          in
          Printf.sprintf "turns:%d(%s,rst:%d)" intr.canonical_turns.turn_count rk
            intr.canonical_turns.history_resets_count
        else "turns:none"
      in
      let dig_s =
        if intr.memory_digest.present then
          let rev_s =
            match intr.memory_digest.revision with
            | Some r -> Printf.sprintf "r%d" r
            | None -> "r?"
          in
          Printf.sprintf "dig:%s/%df/%dB" rev_s intr.memory_digest.fact_count
            intr.memory_digest.bytes
        else "dig:none"
      in
      let molt_s =
        match intr.librarian_molt.pending_molt_kind with
        | Some mk ->
            let cats =
              if intr.librarian_molt.pending_molt_categories = [] then ""
              else
                "("
                ^ String.concat "," intr.librarian_molt.pending_molt_categories
                ^ ")"
            in
            "molt:" ^ mk ^ cats
        | None -> "molt:clear"
      in
      let line =
        Printf.sprintf "OS %s · %s · %s · %s" comp_s ct_s dig_s molt_s
      in
      ignore
        (put_clipped ~grid ~clip ~x ~y ~max_w
           ~style:(Typography.structure ~bg theme)
           line);
      true
  | Some _ | None -> false

let draw_keeper_chart_strip ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~bg ~keeper ~(k : Knowledge_store.t) : int =
  if Rect.is_empty rect then 0
  else
    let y = ref rect.y in
    let bottom = Rect.bottom rect in
    let draw_source_err_if_any (row : Wire_knowledge.keeper_memory_health_row) =
      match row.source_read_error with
      | Some serr when !y < bottom ->
          Card.draw_left_rail ~bg ~tone:Theme.Status_attention grid ~x:rect.x
            ~y:!y ~h:1 ~theme;
          let msg =
            Printf.sprintf "%s %s: %s"
              (Glyph.to_utf8 Glyph.Warning_triangle)
              (say lang ~ko:"소스 기억 읽기 오류" ~en:"Source read error")
              serr
          in
          ignore
            (put_clipped ~grid ~clip:rect ~x:(rect.x + 2) ~y:!y
               ~max_w:(Int.max 0 (rect.w - 2))
               ~style:(Typography.status ~bg theme Theme.Status_attention)
               msg);
          incr y
      | Some _ | None -> ()
    in
    let health_opt = Knowledge_store.health_row_for_keeper ~keeper k in
    (match health_opt with
    | Some row when Option.is_some row.read_error ->
        let err = Option.value row.read_error ~default:"" in
        if !y < bottom then begin
          Card.draw_left_rail ~bg ~tone:Theme.Status_critical grid ~x:rect.x
            ~y:!y ~h:1 ~theme;
          let msg =
            Printf.sprintf "%s %s: %s"
              (Glyph.to_utf8 Glyph.Live_failing)
              (say lang ~ko:"스냅샷 읽기 오류" ~en:"Snapshot read error")
              err
          in
          ignore
            (put_clipped ~grid ~clip:rect ~x:(rect.x + 2) ~y:!y
               ~max_w:(Int.max 0 (rect.w - 2))
               ~style:
                 (Typography.status ~bg ~bold:true theme Theme.Status_critical)
               msg);
          incr y
        end;
        draw_source_err_if_any row
    | Some row when not row.snapshot_present ->
        if !y < bottom then begin
          let msg =
            Printf.sprintf "%s %s"
              (Glyph.to_utf8 Glyph.Missing_absent)
              (say lang ~ko:"기억 스냅샷 없음 (커밋 대기 중)"
                 ~en:"No memory snapshot yet")
          in
          ignore
            (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
               ~style:(Typography.whisper ~bg theme)
               msg);
          incr y
        end;
        draw_source_err_if_any row
    | Some row when bottom - !y >= 8 ->
        let chart_h = if bottom - !y >= 14 then 5 else 4 in
        let chart_r = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:chart_h in
        let obs_drv = (row.observed_facts, row.derived_facts) in
        if rect.w >= 62 then begin
          match
            Layout.split_h ~gap:2 chart_r [ Layout.Fixed 30; Layout.Flex 1 ]
          with
          | [ left_r; right_r ] ->
              ignore
                (Memory_charts.draw_age_ladder grid ~rect:left_r ~theme
                   ~caps:default_caps ~lang ~bg ~observed_derived:obs_drv
                   row.age_bins);
              Card.draw_v_hairline ~bg grid ~x:(right_r.x - 1) ~y:chart_r.y
                ~h:chart_r.h ~theme;
              ignore
                (Memory_charts.draw_facts_trend grid ~rect:right_r ~theme
                   ~caps:default_caps ~lang ~bg ~observed_derived:obs_drv
                   row.facts_by_hour)
          | _ ->
              ignore
                (Memory_charts.draw_age_ladder grid ~rect:chart_r ~theme
                   ~caps:default_caps ~lang ~bg ~observed_derived:obs_drv
                   row.age_bins)
        end
        else
          ignore
            (Memory_charts.draw_age_ladder grid ~rect:chart_r ~theme
               ~caps:default_caps ~lang ~bg ~observed_derived:obs_drv
               row.age_bins);
        y := !y + chart_h;
        if !y < bottom then begin
          let bytes_s =
            Format_val.format_value Format_val.Bytes
              (float_of_int row.snapshot_bytes)
          in
          let alerts_s =
            match row.alerts with
            | [] -> ""
            | xs -> Printf.sprintf " · %s %d" (Glyph.to_utf8 Glyph.Warning_triangle) (List.length xs)
          in
          let fail_s =
            if row.librarian_failures > 0 then
              Printf.sprintf " · fail:%d" row.librarian_failures
            else ""
          in
          let stat =
            Printf.sprintf "r%d · %d %s (%s %d · %s %d) · +%d -%d · %s%s%s"
              row.revision row.facts
              (say lang ~ko:"사실" ~en:"facts")
              (say lang ~ko:"관측" ~en:"obs")
              row.observed_facts
              (say lang ~ko:"유도" ~en:"drv")
              row.derived_facts row.added row.removed bytes_s fail_s alerts_s
          in
          let st =
            if row.librarian_failures > 0 || row.alerts <> [] then
              Typography.status ~bg theme Theme.Status_attention
            else Typography.whisper ~bg ~italic:false theme
          in
          ignore
            (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w ~style:st
               stat);
          incr y
        end;
        draw_source_err_if_any row
    | Some row when bottom - !y >= 5 ->
        let compact_r = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:3 in
        let used =
          Memory_charts.draw_age_ladder grid ~rect:compact_r ~theme
            ~caps:default_caps ~lang ~bg
            ~observed_derived:(row.observed_facts, row.derived_facts)
            row.age_bins
        in
        y := !y + used;
        draw_source_err_if_any row
    | Some _ | None -> ());
    if !y < bottom then begin
      if
        draw_os_internals_line ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
          ~theme ~bg ~keeper k
      then incr y
    end;
    let consumed = !y - rect.y in
    if consumed > 0 && !y < bottom then begin
      Card.draw_hairline ~pad_x:0 ~bg grid ~rect ~y:!y ~theme;
      incr y
    end;
    !y - rect.y

(* --- Evolution (Activity) Table View --- *)

let render_evolution_view ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~now_unix ~bg ~keeper ~(k : Knowledge_store.t) ~focused =
  if Rect.is_empty rect then ()
  else
    match Knowledge_store.keeper_memory_activity_for ~keeper k with
    | Observed.Value { data = act; stale; _ } ->
        begin
          let y = ref rect.y in
          let bottom = Rect.bottom rect in
          let events = Knowledge_store.filtered_memory_activity_events ~keeper k in
          (* Summary line *)
          if !y < bottom then begin
            let stale_s =
              if stale then " " ^ Glyph.to_utf8 Glyph.Transport_stale else ""
            in
            let undec_s =
              if act.undecodable_lines > 0 then
                Printf.sprintf " · %s %d undecodable"
                  (Glyph.to_utf8 Glyph.Warning_triangle)
                  act.undecodable_lines
              else ""
            in
            let hdr =
              Printf.sprintf "%d %s · %d/%d %s%s%s"
                (List.length events)
                (say lang ~ko:"변천 이벤트" ~en:"events")
                act.journal_lines act.limit
                (say lang ~ko:"저널 줄" ~en:"journal lines")
                undec_s stale_s
            in
            ignore
              (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                 ~style:(Typography.structure ~bg theme)
                 hdr);
            incr y
          end;
          if events = [] then begin
            if !y < bottom then
              let empty_msg =
                match act.notes with
                | first :: _ -> first
                | [] ->
                    if String.equal (String.trim k.filter_query) "" then
                      say lang ~ko:"기록된 기억 변천 이벤트가 없습니다."
                        ~en:"No memory evolution events recorded yet."
                    else
                      say lang ~ko:"필터에 일치하는 변천 이벤트가 없습니다."
                        ~en:"No evolution events match filter."
              in
              ignore
                (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                   ~style:(Typography.whisper ~bg theme)
                   empty_msg)
          end
          else begin
            let avail_rows = Int.max 1 (bottom - !y) in
            let rows_per_entry = if avail_rows >= 8 then 2 else 1 in
            let visible_entries = Int.max 1 (avail_rows / rows_per_entry) in
            let total = List.length events in
            let sel = Store_scroll.clamp_index total k.selected_activity_index in
            let start, _ =
              Table.compute_viewport ~total_rows:total
                ~viewport_rows:visible_entries ~scroll:k.activity_scroll_offset
                ~selected:(Some sel)
            in
            List.iteri
              (fun local_i (ev : Wire_knowledge.memory_activity_event) ->
                let abs_i = start + local_i in
                if !y < bottom then begin
                  let is_sel = Int.equal abs_i sel in
                  let row_bg =
                    if is_sel && focused then Color.of_rgb theme.selection_bg
                    else bg
                  in
                  let g, lbl, tone = activity_kind_spec ~lang ev.kind in
                  let row_h =
                    if rows_per_entry >= 2 && !y + 1 < bottom then 2 else 1
                  in
                  if is_sel && focused then
                    paint_selected_row ~grid ~clip:rect
                      ~row_rect:
                        (Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:row_h)
                      ~theme ~tone ()
                  else
                    Card.draw_left_rail ~bg:row_bg ~tone grid ~x:rect.x ~y:!y
                      ~h:row_h ~theme;
                  let tx = rect.x + 2 in
                  let tw = Int.max 0 (rect.w - 2) in
                  let age_s = format_age ~now_unix ev.recorded_at_unix in
                  let counts_s =
                    Printf.sprintf "%d→%d" (List.length ev.before)
                      (List.length ev.after)
                  in
                  let meta_right = Printf.sprintf "%s · %s" counts_s age_s in
                  let mw = Grapheme.display_width meta_right in
                  let left_head =
                    Printf.sprintf "%s %s · r%d" g lbl ev.revision
                  in
                  let primary_preview =
                    let first_claim xs =
                      List.find_map
                        (fun (f : Wire_knowledge.memory_activity_fact) ->
                          match f.claim with
                          | Some c when not (String.equal (String.trim c) "") ->
                              Some (sanitize_single_line c)
                          | Some _ | None -> None)
                        xs
                    in
                    match first_claim ev.after with
                    | Some c -> c
                    | None -> (
                        match first_claim ev.before with
                        | Some c -> c
                        | None -> (
                            match ev.reason with
                            | Some r -> sanitize_single_line r
                            | None -> ev.identity))
                  in
                  if row_h >= 2 then begin
                    ignore
                      (put_clipped ~grid ~clip:rect ~x:tx ~y:!y
                         ~max_w:(Int.max 6 (tw - mw - 2))
                         ~style:
                           (Typography.status ~bg:row_bg ~bold:true theme tone)
                         left_head);
                    ignore
                      (put_right ~grid ~clip:rect ~right_x:(Rect.right rect)
                         ~y:!y ~max_w:mw
                         ~style:(Typography.whisper ~bg:row_bg ~italic:false theme)
                         meta_right);
                    incr y;
                    let preview_txt =
                      match ev.reason with
                      | Some r when not (String.equal (String.trim r) "") ->
                          Printf.sprintf "%s  (%s)" primary_preview
                            (sanitize_single_line r)
                      | Some _ | None -> primary_preview
                    in
                    ignore
                      (put_clipped ~grid ~clip:rect ~x:tx ~y:!y ~max_w:tw
                         ~style:
                           (if is_sel && focused then
                              Typography.anchor ~bg:row_bg theme
                            else Typography.primary ~bg:row_bg theme)
                         preview_txt);
                    incr y
                  end
                  else begin
                    let head_adv =
                      put_clipped ~grid ~clip:rect ~x:tx ~y:!y
                        ~max_w:(Int.max 6 (tw - mw - 2))
                        ~style:
                          (Typography.status ~bg:row_bg ~bold:true theme tone)
                        (left_head ^ "  ")
                    in
                    let rem_w = tw - head_adv - mw - 2 in
                    if rem_w > 4 then
                      ignore
                        (put_clipped ~grid ~clip:rect ~x:(tx + head_adv) ~y:!y
                           ~max_w:rem_w
                           ~style:(Typography.primary ~bg:row_bg theme)
                           primary_preview);
                    ignore
                      (put_right ~grid ~clip:rect ~right_x:(Rect.right rect)
                         ~y:!y ~max_w:mw
                         ~style:(Typography.whisper ~bg:row_bg ~italic:false theme)
                         meta_right);
                    incr y
                  end
                end)
              (Store_scroll.drop start events |> fun xs ->
               let rec take n acc = function
                 | _ when n <= 0 -> List.rev acc
                 | [] -> List.rev acc
                 | hd :: tl -> take (n - 1) (hd :: acc) tl
               in
               take visible_entries [] xs)
          end
        end
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        draw_observed_notice ~grid ~rect ~theme ~lang ~bg obs

(* --- Full Facts Explorer View --- *)

let render_facts_view ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~now_unix ~bg ~keeper ~(k : Knowledge_store.t) ~focused =
  if Rect.is_empty rect then ()
  else
    match Knowledge_store.keeper_memory_facts_for ~keeper k with
    | Observed.Value { data = mf; stale; _ } ->
        begin
          let y = ref rect.y in
          let bottom = Rect.bottom rect in
          (* Status header + partial error disclosure *)
          if !y < bottom then begin
            let ord_summary =
              match mf.ordinary with
              | Wire_knowledge.Memory_store_present o ->
                  Printf.sprintf "r%d · %d %s" o.revision (List.length o.facts)
                    (say lang ~ko:"일반" ~en:"ord")
              | Wire_knowledge.Memory_store_absent ->
                  say lang ~ko:"일반 없음" ~en:"ord absent"
              | Wire_knowledge.Memory_store_read_error e -> "ord err: " ^ e
            in
            let src_summary =
              match mf.source_bound with
              | Wire_knowledge.Memory_store_present s ->
                  Printf.sprintf "%d %s" (List.length s.facts)
                    (say lang ~ko:"소스" ~en:"src")
              | Wire_knowledge.Memory_store_absent ->
                  say lang ~ko:"소스 0" ~en:"src 0"
              | Wire_knowledge.Memory_store_read_error e -> "src err: " ^ e
            in
            let sort_s =
              match k.memory_facts_sort with
              | Knowledge_store.Sort_recency ->
                  say lang ~ko:"정렬: 최근순 [s]" ~en:"Sort: Recency [s]"
              | Knowledge_store.Sort_retrieved ->
                  say lang ~ko:"정렬: 조회순 [s]" ~en:"Sort: Retrieved [s]"
            in
            let stale_s =
              if stale then " " ^ Glyph.to_utf8 Glyph.Transport_stale else ""
            in
            let hdr =
              Printf.sprintf "%s · %s · %s%s" ord_summary src_summary sort_s
                stale_s
            in
            ignore
              (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                 ~style:(Typography.structure ~bg theme)
                 hdr);
            incr y
          end;
          (match mf.events_read_error with
          | Some err when !y < bottom ->
              ignore
                (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                   ~style:(Typography.status ~bg theme Theme.Status_attention)
                   (Glyph.to_utf8 Glyph.Warning_triangle ^ " events: " ^ err));
              incr y
          | Some _ | None -> ());
          let rows = Knowledge_store.filtered_memory_fact_rows ~keeper k in
          if rows = [] then begin
            if !y < bottom then
              let msg =
                if String.equal (String.trim k.filter_query) "" then
                  say lang ~ko:"저장된 기억 사실이 없습니다."
                    ~en:"No memory facts stored."
                else
                  say lang ~ko:"필터에 일치하는 기억 사실이 없습니다."
                    ~en:"No memory facts match filter."
              in
              ignore
                (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                   ~style:(Typography.whisper ~bg theme)
                   msg)
          end
          else begin
            let avail_rows = Int.max 1 (bottom - !y) in
            let rows_per_entry = if avail_rows >= 8 then 2 else 1 in
            let visible_entries = Int.max 1 (avail_rows / rows_per_entry) in
            let total = List.length rows in
            let sel = Store_scroll.clamp_index total k.selected_fact_index in
            let start, _ =
              Table.compute_viewport ~total_rows:total
                ~viewport_rows:visible_entries ~scroll:k.facts_scroll_offset
                ~selected:(Some sel)
            in
            List.iteri
              (fun local_i (row : Knowledge_store.memory_fact_row) ->
                let abs_i = start + local_i in
                if !y < bottom then begin
                  let is_sel = Int.equal abs_i sel in
                  let row_bg =
                    if is_sel && focused then Color.of_rgb theme.selection_bg
                    else bg
                  in
                  let tone, left_meta, right_meta, claim_txt =
                    match row with
                    | Knowledge_store.Fact_ordinary { fact; _ } ->
                        let cat_s =
                          Wire_knowledge.memory_fact_category_to_string
                            fact.category
                        in
                        let basis_tag =
                          match fact.basis with
                          | Wire_knowledge.Basis_observed -> "obs"
                          | Wire_knowledge.Basis_observed_board _ -> "board"
                          | Wire_knowledge.Basis_derived _ -> "drv"
                        in
                        let ret_s, ret_tone =
                          match fact.events.retrieval with
                          | Wire_knowledge.Never_retrieved ->
                              ("0x", Theme.Status_historical)
                          | Wire_knowledge.Retrieved { count; _ } ->
                              let t =
                                if count >= 5 then Theme.Status_attention
                                else Theme.Status_ok
                              in
                              (Printf.sprintf "%dx" count, t)
                        in
                        let age_s = format_age ~now_unix fact.last_seen_unix in
                        ( ret_tone
                        , Printf.sprintf "[%s] %s" cat_s basis_tag
                        , Printf.sprintf "%s · %s" ret_s age_s
                        , sanitize_single_line fact.claim )
                    | Knowledge_store.Fact_source sf ->
                        let age_s = format_age ~now_unix sf.first_seen_unix in
                        ( Theme.Status_ai
                        , "[source] " ^ sf.path
                        , age_s
                        , sanitize_single_line sf.claim )
                    | Knowledge_store.Fact_source_invalidation inv ->
                        let age_s = format_age ~now_unix inv.invalidated_at_unix in
                        ( Theme.Status_attention
                        , "! [source-inv] "
                          ^ Wire_knowledge.source_invalidation_reason_to_string
                              inv.reason
                        , age_s
                        , inv.source_path )
                  in
                  let row_h =
                    if rows_per_entry >= 2 && !y + 1 < bottom then 2 else 1
                  in
                  if is_sel && focused then
                    paint_selected_row ~grid ~clip:rect
                      ~row_rect:
                        (Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:row_h)
                      ~theme ~tone ()
                  else
                    Card.draw_left_rail ~bg:row_bg ~tone grid ~x:rect.x ~y:!y
                      ~h:row_h ~theme;
                  let tx = rect.x + 2 in
                  let tw = Int.max 0 (rect.w - 2) in
                  let mw = Grapheme.display_width right_meta in
                  if row_h >= 2 then begin
                    ignore
                      (put_clipped ~grid ~clip:rect ~x:tx ~y:!y
                         ~max_w:(Int.max 6 (tw - mw - 2))
                         ~style:
                           (Typography.status ~bg:row_bg ~bold:true theme tone)
                         left_meta);
                    ignore
                      (put_right ~grid ~clip:rect ~right_x:(Rect.right rect)
                         ~y:!y ~max_w:mw
                         ~style:(Typography.whisper ~bg:row_bg ~italic:false theme)
                         right_meta);
                    incr y;
                    ignore
                      (put_clipped ~grid ~clip:rect ~x:tx ~y:!y ~max_w:tw
                         ~style:
                           (if is_sel && focused then
                              Typography.anchor ~bg:row_bg theme
                            else Typography.primary ~bg:row_bg theme)
                         claim_txt);
                    incr y
                  end
                  else begin
                    let adv =
                      put_clipped ~grid ~clip:rect ~x:tx ~y:!y
                        ~max_w:(Int.max 6 (tw - mw - 2))
                        ~style:
                          (Typography.status ~bg:row_bg ~bold:true theme tone)
                        (left_meta ^ "  ")
                    in
                    let rem_w = tw - adv - mw - 2 in
                    if rem_w > 4 then
                      ignore
                        (put_clipped ~grid ~clip:rect ~x:(tx + adv) ~y:!y
                           ~max_w:rem_w
                           ~style:(Typography.primary ~bg:row_bg theme)
                           claim_txt);
                    ignore
                      (put_right ~grid ~clip:rect ~right_x:(Rect.right rect)
                         ~y:!y ~max_w:mw
                         ~style:(Typography.whisper ~bg:row_bg ~italic:false theme)
                         right_meta);
                    incr y
                  end
                end)
              (Store_scroll.drop start rows |> fun xs ->
               let rec take n acc = function
                 | _ when n <= 0 -> List.rev acc
                 | [] -> List.rev acc
                 | hd :: tl -> take (n - 1) (hd :: acc) tl
               in
               take visible_entries [] xs)
          end
        end
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        draw_observed_notice ~grid ~rect ~theme ~lang ~bg obs

(* --- Word-Wrapped Temporal Memory Diff View (Keeper & World) --- *)

type diff_visual_row =
  | Diff_header_heat_age of {
      rail : Theme.status_token;
      style : Style.t;
      left_txt : string;
      heat_lbl : string;
      heat_tone : Theme.status_token;
      age : string;
      selected : bool;
    }
  | Diff_header_right of {
      rail : Theme.status_token;
      style : Style.t;
      left_txt : string;
      right_txt : string;
      right_style : Style.t;
      selected : bool;
    }
  | Diff_plain of {
      rail : Theme.status_token;
      style : Style.t;
      text : string;
      selected : bool;
    }

let build_diff_visual_rows ~theme ~bg ~lang ~now_unix ~wrap_w ~selected_idx
    (items : Knowledge_store.memory_diff_item list) : diff_visual_row list =
  let acc = ref [] in
  let push r = acc := r :: !acc in
  let push_wrapped ~rail ~style ~selected ~prefix text =
    let avail = Int.max 8 (wrap_w - Grapheme.display_width prefix) in
    let wrapped = wrap_lines ~max_width:avail text in
    let indent = String.make (Grapheme.display_width prefix) ' ' in
    List.iteri
      (fun i ln ->
        let p = if i = 0 then prefix else indent in
        push (Diff_plain { rail; style; text = p ^ ln; selected }))
      wrapped
  in
  List.iteri
    (fun idx item ->
      let selected = Int.equal idx selected_idx in
      match item with
      | Knowledge_store.Keeper_added f ->
          let heat_lbl, heat_tone = heat_badge f.heat in
          let age = format_age ~now_unix f.first_seen_unix in
          let left_txt = Printf.sprintf "+ [%s] %s" f.category f.origin in
          push
            (Diff_header_heat_age
               {
                 rail = Theme.Status_ok;
                 style = Typography.status ~bg ~bold:true theme Theme.Status_ok;
                 left_txt;
                 heat_lbl = Printf.sprintf "%s %dx" heat_lbl f.retrieval_count;
                 heat_tone;
                 age;
                 selected;
               });
          push_wrapped ~rail:Theme.Status_ok
            ~style:(Typography.primary ~bg theme) ~selected ~prefix:"" f.text
      | Knowledge_store.Keeper_updated u ->
          let heat_lbl, heat_tone = heat_badge u.after.heat in
          let hdr =
            Printf.sprintf "~ [%s] %s @r%d" u.after.category
              (relation_label ~lang u.relation)
              u.at_rev
          in
          push
            (Diff_header_right
               {
                 rail = Theme.Status_active;
                 style =
                   Typography.status ~bg ~bold:true theme Theme.Status_active;
                 left_txt = hdr;
                 right_txt =
                   Printf.sprintf "%s %dx" heat_lbl u.after.retrieval_count;
                 right_style = Typography.status ~bg theme heat_tone;
                 selected;
               });
          push_wrapped ~rail:Theme.Status_active
            ~style:(Typography.status ~bg theme Theme.Status_critical)
            ~selected ~prefix:"- " u.before.text;
          push_wrapped ~rail:Theme.Status_active
            ~style:(Typography.status ~bg theme Theme.Status_ok) ~selected
            ~prefix:"+ " u.after.text
      | Knowledge_store.Keeper_retracted r ->
          let why =
            match r.drop_reason with Some s -> " · " ^ s | None -> ""
          in
          let hdr =
            Printf.sprintf "- [%s] %s @r%d · %s%s" r.category
              (say lang ~ko:"대체/철회" ~en:"retracted")
              r.removed_at_rev r.removed_by why
          in
          push
            (Diff_plain
               {
                 rail = Theme.Status_critical;
                 style = Typography.status ~bg theme Theme.Status_critical;
                 text = hdr;
                 selected;
               });
          push_wrapped ~rail:Theme.Status_critical
            ~style:(Typography.whisper ~bg theme) ~selected ~prefix:"- " r.text
      | Knowledge_store.Keeper_invalidated inv ->
          let prems = String.concat ", " inv.missing_premise_ids in
          let hdr =
            Printf.sprintf "! [invalidated] @r%d missing: %s" inv.at_rev prems
          in
          push
            (Diff_plain
               {
                 rail = Theme.Status_attention;
                 style = Typography.status ~bg theme Theme.Status_attention;
                 text = hdr;
                 selected;
               });
          push_wrapped ~rail:Theme.Status_attention
            ~style:(Typography.whisper ~bg theme) ~selected ~prefix:"- " inv.text
      | Knowledge_store.World_added e ->
          let ts =
            match String.index_opt e.recorded_at 'T' with
            | Some i when i + 9 <= String.length e.recorded_at ->
                String.sub e.recorded_at (i + 1) 8
            | Some _ | None -> e.recorded_at
          in
          let line =
            Printf.sprintf "+ #%d [%s] %s" e.seq (short_hash ~len:8 e.fact_id)
              e.summary
          in
          push
            (Diff_header_right
               {
                 rail = Theme.Status_ok;
                 style = Typography.status ~bg theme Theme.Status_ok;
                 left_txt = line;
                 right_txt = ts;
                 right_style = Typography.whisper ~bg theme;
                 selected;
               })
      | Knowledge_store.World_updated u ->
          let ts =
            match String.index_opt u.recorded_at 'T' with
            | Some i when i + 9 <= String.length u.recorded_at ->
                String.sub u.recorded_at (i + 1) 8
            | Some _ | None -> u.recorded_at
          in
          let hdr =
            Printf.sprintf "~ #%d [%s] %s" u.seq (short_hash ~len:8 u.fact_id)
              u.summary
          in
          push
            (Diff_header_right
               {
                 rail = Theme.Status_active;
                 style =
                   Typography.status ~bg ~bold:true theme Theme.Status_active;
                 left_txt = hdr;
                 right_txt = ts;
                 right_style = Typography.whisper ~bg theme;
                 selected;
               });
          let fmt_kvs j =
            json_kv_summary j
            |> (fun xs ->
                 let rec take n acc = function
                   | _ when n <= 0 -> List.rev acc
                   | [] -> List.rev acc
                   | hd :: tl -> take (n - 1) (hd :: acc) tl
                 in
                 take 3 [] xs)
            |> List.map (fun (k, v) -> k ^ "=" ^ v)
            |> String.concat " · "
          in
          let b_s = fmt_kvs u.before in
          if not (String.equal b_s "") then
            push_wrapped ~rail:Theme.Status_active
              ~style:(Typography.status ~bg theme Theme.Status_critical)
              ~selected ~prefix:"- " b_s;
          let a_s = fmt_kvs u.after in
          if not (String.equal a_s "") then
            push_wrapped ~rail:Theme.Status_active
              ~style:(Typography.status ~bg theme Theme.Status_ok) ~selected
              ~prefix:"+ " a_s
      | Knowledge_store.World_retracted r ->
          let ts =
            match String.index_opt r.recorded_at 'T' with
            | Some i when i + 9 <= String.length r.recorded_at ->
                String.sub r.recorded_at (i + 1) 8
            | Some _ | None -> r.recorded_at
          in
          let line =
            Printf.sprintf "- #%d [%s] %s" r.seq (short_hash ~len:8 r.fact_id)
              r.summary
          in
          push
            (Diff_header_right
               {
                 rail = Theme.Status_critical;
                 style = Typography.status ~bg theme Theme.Status_critical;
                 left_txt = line;
                 right_txt = ts;
                 right_style = Typography.whisper ~bg theme;
                 selected;
               }))
    items;
  List.rev !acc

let diff_viewport_skip ~total_rows ~avail_h ~scroll ~selected_range =
  let vis_h = Int.max 1 avail_h in
  let max_skip = Int.max 0 (total_rows - vis_h) in
  let base_skip = Int.min max_skip (Int.max 0 scroll) in
  match selected_range with
  | None -> base_skip
  | Some (sel_start, sel_end) ->
      let target_end = Int.min sel_end (sel_start + vis_h - 1) in
      let adjusted =
        if sel_start < base_skip then sel_start
        else if target_end >= base_skip + vis_h then target_end - vis_h + 1
        else base_skip
      in
      Int.min max_skip (Int.max 0 adjusted)

let diff_row_selected = function
  | Diff_header_heat_age { selected; _ }
  | Diff_header_right { selected; _ }
  | Diff_plain { selected; _ } ->
      selected

let selected_visual_range rows =
  let rec scan idx first last = function
    | [] -> (
        match first, last with
        | Some s, Some e -> Some (s, e)
        | (Some _ | None), (Some _ | None) -> None)
    | row :: rest ->
        if diff_row_selected row then
          let first' = match first with Some _ -> first | None -> Some idx in
          scan (idx + 1) first' (Some idx) rest
        else scan (idx + 1) first last rest
  in
  scan 0 None None rows

let draw_diff_rows ~grid ~content ~y ~bottom ~(theme : Theme.t) ~bg ~scroll
    ~focused rows =
  let avail_h = Int.max 1 (bottom - !y) in
  let selected_range = selected_visual_range rows in
  let skip =
    diff_viewport_skip ~total_rows:(List.length rows) ~avail_h ~scroll
      ~selected_range
  in
  let tx = content.Rect.x + 2 in
  let tw = Int.max 0 (content.Rect.w - 2) in
  List.iter
    (fun row ->
      if !y < bottom then begin
        let sel = focused && diff_row_selected row in
        let row_bg = if sel then Color.of_rgb theme.selection_bg else bg in
        if sel then
          Cell_grid.fill_rect ~clip:content grid
            ~rect:(Rect.make ~x:content.x ~y:!y ~w:content.w ~h:1)
            ~style:(Style.make ~bg:row_bg ())
            ();
        (match row with
        | Diff_header_heat_age
            { rail; style; left_txt; heat_lbl; heat_tone; age; _ } ->
            Card.draw_left_rail ~bg:row_bg ~tone:rail grid ~x:content.x ~y:!y
              ~h:1 ~theme;
            let hw = Grapheme.display_width heat_lbl in
            let aw = Grapheme.display_width age in
            let st = { style with bg = row_bg } in
            ignore
              (put_clipped ~grid ~clip:content ~x:tx ~y:!y
                 ~max_w:(Int.max 6 (tw - hw - aw - 4))
                 ~style:st left_txt);
            ignore
              (put_right ~grid ~clip:content
                 ~right_x:(Rect.right content - aw - 2) ~y:!y ~max_w:hw
                 ~style:(Typography.status ~bg:row_bg theme heat_tone)
                 heat_lbl);
            ignore
              (put_right ~grid ~clip:content ~right_x:(Rect.right content)
                 ~y:!y ~max_w:aw ~style:(Typography.whisper ~bg:row_bg theme)
                 age)
        | Diff_header_right { rail; style; left_txt; right_txt; right_style; _ }
          ->
            Card.draw_left_rail ~bg:row_bg ~tone:rail grid ~x:content.x ~y:!y
              ~h:1 ~theme;
            let rw = Grapheme.display_width right_txt in
            ignore
              (put_clipped ~grid ~clip:content ~x:tx ~y:!y
                 ~max_w:(Int.max 6 (tw - rw - 2))
                 ~style:{ style with bg = row_bg } left_txt);
            ignore
              (put_right ~grid ~clip:content ~right_x:(Rect.right content)
                 ~y:!y ~max_w:rw
                 ~style:{ right_style with bg = row_bg } right_txt)
        | Diff_plain { rail; style; text; _ } ->
            Card.draw_left_rail ~bg:row_bg ~tone:rail grid ~x:content.x ~y:!y
              ~h:1 ~theme;
            ignore
              (put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                 ~style:{ style with bg = row_bg } text));
        incr y
      end)
    (Store_scroll.drop skip rows)

let render_keeper_diff_view ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~now_unix ~bg ~keeper ~(k : Knowledge_store.t) ~focused
    ~diff_scroll =
  if Rect.is_empty rect then ()
  else
    match
      Knowledge_store.memory_diff_for ~keeper:(Some keeper)
        ~window:k.memory_diff_window k
    with
    | Observed.Value { data = diff; _ } -> (
        match diff.scope, diff.body with
        | Wire_knowledge.Scope_keeper kp, Wire_knowledge.Keeper_diff { counts; _ }
          when String.equal kp keeper ->
            let y = ref rect.y in
            let bottom = Rect.bottom rect in
            let win_str =
              match k.memory_diff_window with
              | Knowledge_store.Window_24h -> "24h"
              | Knowledge_store.Window_7d -> "7d"
              | Knowledge_store.Window_30d -> "30d"
              | Knowledge_store.Window_revs { from_rev; to_rev } ->
                  Printf.sprintf "rev %d→%d" from_rev to_rev
            in
            let rev_range =
              match diff.range.from_rev, diff.range.to_rev with
              | Some a, Some b -> Printf.sprintf "rev %d → %d" a b
              | Some a, None -> Printf.sprintf "rev %d+" a
              | None, Some b -> Printf.sprintf "..rev %d" b
              | None, None -> win_str
            in
            if !y < bottom then begin
              let h = diff.retrieval_heat in
              let summary =
                Printf.sprintf "%s · %d %s · +%d ~%d -%d !%d · HOT:%d WARM:%d COLD:%d"
                  rev_range counts.total_facts_now
                  (say lang ~ko:"사실" ~en:"facts")
                  counts.added counts.updated counts.retracted counts.invalidated
                  h.hot h.warm h.cold
              in
              ignore
                (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                   ~style:(Typography.structure ~bg ~bold:true theme)
                   summary);
              incr y
            end;
            let h = diff.retrieval_heat in
            let heat_total = h.hot + h.warm + h.cold + h.never_retrieved in
            if heat_total > 0 && bottom - !y >= 4 then begin
              let bar_r = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:2 in
              let segments =
                [
                  (Say.literal "HOT", float_of_int h.hot, Theme.Status_attention);
                  (Say.literal "WARM", float_of_int h.warm, Theme.Status_active);
                  ( Say.literal "COLD"
                  , float_of_int (h.cold + h.never_retrieved)
                  , Theme.Status_historical );
                ]
                |> List.filter (fun (_, v, _) -> v > 0.0)
              in
              ignore
                (Chart.draw grid ~rect:bar_r ~theme ~caps:default_caps ~lang
                   ~show_title:false
                   {
                     Chart.Spec.title = Say.make ~ko:"기억 계층" ~en:"Heat";
                     hotkey_hint = None;
                     kind =
                       Chart.Spec.Stacked_bar
                         {
                           segments;
                           total_label =
                             Say.literal (Printf.sprintf "%d hits" h.total_events);
                           unit = Format_val.Count;
                         };
                   });
              y := !y + 2;
              if !y < bottom then begin
                Card.draw_hairline ~pad_x:0 ~bg grid ~rect ~y:!y ~theme;
                incr y
              end
            end;
            (* Observed Memory Flow Braille chart (Flow ▲/▼ or [g] Net Total) *)
            let flow_h = Memory_flow.chart_height_for ~avail_h:(bottom - !y) in
            if flow_h > 0 then begin
              let flow_r = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:flow_h in
              let flow_inp =
                Knowledge_store.memory_flow_input_of_diff diff
                  k.memory_diff_window
              in
              Memory_flow.draw grid ~rect:flow_r ~theme ~caps:default_caps ~lang
                ~now_unix ~mode:k.memory_flow_mode flow_inp;
              y := !y + flow_h;
              if !y < bottom then begin
                Card.draw_hairline ~pad_x:0 ~bg grid ~rect ~y:!y ~theme;
                incr y
              end
            end;
            let items =
              Knowledge_store.filtered_memory_diff_items_for
                ~keeper_opt:(Some keeper) k
            in
            if items = [] then begin
              if !y < bottom then
                ignore
                  (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                     ~style:(Typography.whisper ~bg theme)
                     (say lang ~ko:"선택한 기간 내 기억 변경 사항이 없습니다."
                        ~en:"No memory changes recorded in this window."))
            end
            else
              let sel_idx =
                Store_scroll.clamp_index (List.length items) k.selected_diff_index
              in
              let rows =
                build_diff_visual_rows ~theme ~bg ~lang ~now_unix
                  ~wrap_w:(Int.max 10 (rect.w - 2)) ~selected_idx:sel_idx items
              in
              draw_diff_rows ~grid ~content:rect ~y ~bottom ~theme ~bg
                ~scroll:diff_scroll ~focused rows
        | ( (Wire_knowledge.Scope_keeper _ | Wire_knowledge.Scope_world)
          , (Wire_knowledge.Keeper_diff _ | Wire_knowledge.World_diff _) ) ->
            let msg =
              say lang
                ~ko:
                  (Printf.sprintf
                     "%s 기억 Diff 불러오기 대기 중 · [r] 키로 새로고침" keeper)
                ~en:
                  (Printf.sprintf
                     "Awaiting scoped memory diff for %s · press [r] to refresh"
                     keeper)
            in
            ignore
              (put_clipped ~grid ~clip:rect ~x:rect.x ~y:rect.y ~max_w:rect.w
                 ~style:(Typography.whisper ~bg theme)
                 (Glyph.to_utf8 Glyph.Transport_reconnecting ^ " " ^ msg)))
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        draw_observed_notice ~grid ~rect ~theme ~lang ~bg obs

(* --- Public Entrypoints --- *)

let render_keeper_memory ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp:_ ~(model : Model.t) ~keeper ~focused ~diff_scroll =
  if Rect.is_empty rect then ()
  else
    let lang = model.lang in
    let now_unix = model.freshness.last_wall_unix in
    let k = model.knowledge in
    let bg = Color.of_rgb theme.surface_1 in
    match k.memory_diagram with
    | Some diagram
      when Knowledge_store.memory_diagram_matches_scope
             ~keeper_opt:(Some keeper) diagram ->
        render_memory_diagram ~grid ~rect ~theme ~lang ~diagram
    | Some _ | None -> (
        match k.memory_reading with
        | Some entry
          when Knowledge_store.memory_reading_matches_scope
                 ~keeper_opt:(Some keeper) entry ->
            render_full_reading ~grid ~rect ~theme ~lang ~now_unix ~entry
              ~scroll:k.memory_reading_scroll
        | Some _ | None ->
            let bar_rect, body_rect = Rect.split_v rect ~top_h:1 in
            draw_mode_pills ~grid ~rect:bar_rect ~theme ~lang ~bg ~k ~keeper;
            if not (Rect.is_empty body_rect) then begin
              let chart_used =
                draw_keeper_chart_strip ~grid ~rect:body_rect ~theme ~lang ~bg
                  ~keeper ~k
              in
              let list_rect =
                Rect.make ~x:body_rect.x ~y:(body_rect.y + chart_used)
                  ~w:body_rect.w ~h:(Int.max 0 (body_rect.h - chart_used))
              in
              match k.memory_view_mode with
              | Knowledge_store.View_evolution ->
                  render_evolution_view ~grid ~rect:list_rect ~theme ~lang
                    ~now_unix ~bg ~keeper ~k ~focused
              | Knowledge_store.View_facts ->
                  render_facts_view ~grid ~rect:list_rect ~theme ~lang ~now_unix
                    ~bg ~keeper ~k ~focused
              | Knowledge_store.View_diff ->
                  render_keeper_diff_view ~grid ~rect:list_rect ~theme ~lang
                    ~now_unix ~bg ~keeper ~k ~focused ~diff_scroll
            end)

let render_world_diff_body ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~now_unix ~(k : Knowledge_store.t) ~focused ~diff_scroll
    =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    match k.memory_reading with
    | Some entry
      when Knowledge_store.memory_reading_matches_scope ~keeper_opt:None entry
      ->
        render_full_reading ~grid ~rect ~theme ~lang ~now_unix ~entry
          ~scroll:k.memory_reading_scroll
    | Some _ | None -> (
        match
          Knowledge_store.memory_diff_for ~keeper:None
            ~window:k.memory_diff_window k
        with
        | Observed.Value { data = diff; _ } -> (
            match diff.scope, diff.body with
            | ( Wire_knowledge.Scope_world
              , Wire_knowledge.World_diff { counts; _ } ) ->
                let y = ref rect.y in
                let bottom = Rect.bottom rect in
                let win_str =
                  match k.memory_diff_window with
                  | Knowledge_store.Window_24h -> "24h"
                  | Knowledge_store.Window_7d -> "7d"
                  | Knowledge_store.Window_30d -> "30d"
                  | Knowledge_store.Window_revs { from_rev; to_rev } ->
                      Printf.sprintf "rev %d→%d" from_rev to_rev
                in
                if !y < bottom then begin
                  let rev_range =
                    match diff.range.from_rev, diff.range.to_rev with
                    | Some a, Some b -> Printf.sprintf "rev %d → %d" a b
                    | Some a, None -> Printf.sprintf "rev %d+" a
                    | None, Some b -> Printf.sprintf "..rev %d" b
                    | None, None -> win_str
                  in
                  let line =
                    Printf.sprintf "%s · %d %s · +%d ~%d -%d" rev_range
                      counts.total_claims_now
                      (say lang ~ko:"주장" ~en:"claims")
                      counts.added counts.updated counts.retracted
                  in
                  ignore
                    (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                       ~style:(Typography.anchor ~bg theme)
                       line);
                  incr y
                end;
                if !y + 1 < bottom then begin
                  let h = diff.retrieval_heat in
                  let bar_rect = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:2 in
                  let heat_spec : Chart.Spec.t =
                    {
                      title = Say.make ~ko:"기억 계층" ~en:"Memory Tiers";
                      hotkey_hint = None;
                      kind =
                        Chart.Spec.Stacked_bar
                          {
                            segments =
                              [
                                ( Say.literal "HOT"
                                , float_of_int h.hot
                                , Theme.Status_attention );
                                ( Say.literal "WARM"
                                , float_of_int h.warm
                                , Theme.Status_active );
                                ( Say.literal "COLD"
                                , float_of_int (h.cold + h.never_retrieved)
                                , Theme.Status_historical );
                              ];
                            total_label =
                              Say.literal
                                (Printf.sprintf "%d hits" h.total_events);
                            unit = Format_val.Count;
                          };
                    }
                  in
                  ignore
                    (Chart.draw grid ~rect:bar_rect ~theme ~caps:default_caps
                       ~lang ~show_title:false heat_spec);
                  y := !y + 2
                end;
                (* Fleet-aggregated 24-bin Age Ladder when fleet health is loaded *)
                (match Observed.to_option k.keeper_memory_health with
                | Some fleet when bottom - !y >= 10 ->
                    let fleet_bins =
                      List.filter_map
                        (fun (r : Wire_knowledge.keeper_memory_health_row) ->
                          r.age_bins)
                        fleet.keepers
                      |> Memory_charts.aggregate_fleet_age_bins
                    in
                    (match fleet_bins with
                    | Some _ ->
                        let obs_tot =
                          List.fold_left
                            (fun acc
                                 (r : Wire_knowledge.keeper_memory_health_row)
                             -> acc + r.observed_facts)
                            0 fleet.keepers
                        in
                        let drv_tot =
                          List.fold_left
                            (fun acc
                                 (r : Wire_knowledge.keeper_memory_health_row)
                             -> acc + r.derived_facts)
                            0 fleet.keepers
                        in
                        let ladder_r =
                          Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:4
                        in
                        let used =
                          Memory_charts.draw_age_ladder grid ~rect:ladder_r
                            ~theme ~caps:default_caps ~lang ~bg
                            ~title:
                              (say lang ~ko:"함대 기억 연령 분포 (24-bin)"
                                 ~en:"Fleet Fact Age Ladder (24-bin)")
                            ~observed_derived:(obs_tot, drv_tot) fleet_bins
                        in
                        y := !y + used
                    | None -> ())
                | Some _ | None -> ());
                (* Observed Memory Flow Braille chart (Flow ▲/▼ or [g] Net Total) *)
                let flow_h =
                  Memory_flow.chart_height_for ~avail_h:(bottom - !y)
                in
                if flow_h > 0 then begin
                  let flow_r = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:flow_h in
                  let flow_inp =
                    Knowledge_store.memory_flow_input_of_diff diff
                      k.memory_diff_window
                  in
                  Memory_flow.draw grid ~rect:flow_r ~theme ~caps:default_caps
                    ~lang ~now_unix ~mode:k.memory_flow_mode flow_inp;
                  y := !y + flow_h
                end;
                if !y < bottom then begin
                  Card.draw_hairline ~pad_x:0 ~bg grid ~rect ~y:!y ~theme;
                  incr y
                end;
                let items =
                  Knowledge_store.filtered_memory_diff_items_for
                    ~keeper_opt:None k
                in
                if items = [] then begin
                  if !y < bottom then
                    let q = String.trim k.filter_query in
                    let msg =
                      if String.equal q "" then
                        say lang ~ko:"이 기간 내 월드 메모리 변동 없음"
                          ~en:"No world memory changes in this window"
                      else
                        say lang ~ko:"필터에 일치하는 월드 메모리 변동 없음"
                          ~en:"No world memory changes match filter"
                    in
                    ignore
                      (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y
                         ~max_w:rect.w ~style:(Typography.whisper ~bg theme) msg)
                end
                else
                  let sel_idx =
                    Store_scroll.clamp_index (List.length items)
                      k.selected_diff_index
                  in
                  let rows =
                    build_diff_visual_rows ~theme ~bg ~lang ~now_unix
                      ~wrap_w:(Int.max 10 (rect.w - 2)) ~selected_idx:sel_idx
                      items
                  in
                  draw_diff_rows ~grid ~content:rect ~y ~bottom ~theme ~bg
                    ~scroll:diff_scroll ~focused rows
            | ( (Wire_knowledge.Scope_world | Wire_knowledge.Scope_keeper _)
              , (Wire_knowledge.World_diff _ | Wire_knowledge.Keeper_diff _) )
              ->
                let msg =
                  say lang
                    ~ko:"월드 메모리 Diff 불러오기 대기 중 · [r] 키로 새로고침"
                    ~en:"Awaiting world memory diff · press [r] to refresh"
                in
                ignore
                  (put_clipped ~grid ~clip:rect ~x:rect.x ~y:rect.y
                     ~max_w:rect.w ~style:(Typography.whisper ~bg theme)
                     (Glyph.to_utf8 Glyph.Transport_reconnecting ^ " " ^ msg)))
        | ( Observed.Loading _
          | Observed.Absent
          | Observed.Unreported
          | Observed.Failed _ ) as obs ->
            draw_observed_notice ~grid ~rect ~theme ~lang ~bg obs)
