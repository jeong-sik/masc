module Glyph = Masc_tui_core.Glyph
module Rect = Masc_tui_core.Rect
module Say = Masc_tui_core.Say
module Theme = Masc_tui_core.Theme
module Attr = Masc_tui_term.Attr
module Color = Masc_tui_term.Color
module Style = Masc_tui_term.Style
module Grapheme = Masc_tui_term.Grapheme
module Cell_grid = Masc_tui_term.Cell_grid
module Presenter = Masc_tui_term.Presenter

type turn_running_kind =
  | Turn_kind_active
  | Turn_kind_tool
  | Turn_kind_attention

let turn_running_kind_rank = function
  | Turn_kind_active -> 0
  | Turn_kind_tool -> 1
  | Turn_kind_attention -> 2

let equal_turn_running_kind a b =
  Int.equal (turn_running_kind_rank a) (turn_running_kind_rank b)

type pending_tx =
  | Tx_idle
  | Tx_queued
  | Tx_queued_count of int
  | Tx_sending
  | Tx_awaiting_turn
  | Tx_thinking
  | Tx_tool_running of string
  | Tx_tool_waiting of string
  | Tx_streaming
  | Tx_turn_running of { kind : turn_running_kind; label : Say.t }
  | Tx_confirming
  | Tx_interrupting
  | Tx_failed of string

type voice_state =
  | Voice_off
  | Voice_recording of { levels : float array; elapsed_s : float }
  | Voice_transcribing

type popup_item = {
  trigger : string;
  label : string;
  detail : string option;
}

type popup =
  | Popup_none
  | Popup_slash of { query : string; items : popup_item list; selected : int }
  | Popup_mention of { query : string; items : popup_item list; selected : int }

type mode =
  | Auto_folded_pill
  | Collapsed_bar
  | Expanded_multiline

type state = {
  target_keeper : string;
  draft : string;
  cursor : int;
  focused : bool;
  pending_tx : pending_tx;
  voice : voice_state;
  popup : popup;
  draft_count_other_keepers : int;
}

let equal_pending_tx a b =
  match a, b with
  | Tx_idle, Tx_idle
  | Tx_queued, Tx_queued
  | Tx_sending, Tx_sending
  | Tx_awaiting_turn, Tx_awaiting_turn
  | Tx_thinking, Tx_thinking
  | Tx_streaming, Tx_streaming
  | Tx_confirming, Tx_confirming
  | Tx_interrupting, Tx_interrupting ->
      true
  | Tx_queued_count x, Tx_queued_count y -> Int.equal x y
  | Tx_tool_waiting x, Tx_tool_waiting y
  | Tx_tool_running x, Tx_tool_running y | Tx_failed x, Tx_failed y ->
      String.equal x y
  | Tx_turn_running x, Tx_turn_running y ->
      equal_turn_running_kind x.kind y.kind && Say.equal x.label y.label
  | ( ( Tx_idle
      | Tx_queued
      | Tx_queued_count _
      | Tx_sending
      | Tx_awaiting_turn
      | Tx_thinking
      | Tx_tool_running _
      | Tx_tool_waiting _
      | Tx_streaming
      | Tx_turn_running _
      | Tx_confirming
      | Tx_interrupting
      | Tx_failed _ )
    , ( Tx_idle
      | Tx_queued
      | Tx_queued_count _
      | Tx_sending
      | Tx_awaiting_turn
      | Tx_thinking
      | Tx_tool_running _
      | Tx_tool_waiting _
      | Tx_streaming
      | Tx_turn_running _
      | Tx_confirming
      | Tx_interrupting
      | Tx_failed _ ) ) -> false

let mode_rank = function
  | Auto_folded_pill -> 0
  | Collapsed_bar -> 1
  | Expanded_multiline -> 2

let equal_mode a b = Int.equal (mode_rank a) (mode_rank b)

let empty ~target_keeper =
  {
    target_keeper;
    draft = "";
    cursor = 0;
    focused = false;
    pending_tx = Tx_idle;
    voice = Voice_off;
    popup = Popup_none;
    draft_count_other_keepers = 0;
  }

let pending_tx_label = function
  | Tx_idle -> None
  | Tx_queued -> Some (Say.make ~ko:"전송 대기" ~en:"Queued")
  | Tx_queued_count n ->
      Some
        (Say.make
           ~ko:(if n > 1 then Printf.sprintf "대기열 %d" n else "전송 대기")
           ~en:(if n > 1 then Printf.sprintf "Queued %d" n else "Queued"))
  | Tx_sending -> Some (Say.make ~ko:"전송 중" ~en:"Sending")
  | Tx_awaiting_turn -> Some (Say.make ~ko:"응답 대기" ~en:"Waiting for response")
  (* The same words the status strip uses for a turn the server reports
     (Fleet_store.open_work_of_preview), so both read alike. *)
  | Tx_thinking -> Some (Say.make ~ko:"추론 중" ~en:"Thinking")
  | Tx_tool_running tool ->
      Some (Say.make ~ko:("도구 실행 중 · " ^ tool) ~en:("Running " ^ tool))
  | Tx_tool_waiting tool ->
      Some (Say.make ~ko:("도구 결과 대기 · " ^ tool) ~en:("Waiting for tool result · " ^ tool))
  | Tx_streaming -> Some (Say.make ~ko:"답변 중" ~en:"Answering")
  | Tx_turn_running { label; _ } -> Some label
  | Tx_confirming -> Some (Say.make ~ko:"전송 확인 중" ~en:"Confirming")
  | Tx_interrupting -> Some (Say.make ~ko:"중단 요청 중" ~en:"Interrupting")
  | Tx_failed _ -> Some (Say.make ~ko:"전송 실패" ~en:"Send failed")

let activity_spinner = [| "⠋"; "⠙"; "⠚"; "⠒"; "⠲"; "⠴"; "⠦"; "⠇" |]

let activity_runs ~theme ~bg ~lang ~animate (glyph, tone, detail) =
  let emphasis = Typography.status ~bg ~bold:true theme tone in
  let marker = emphasis, Glyph.to_utf8 glyph ^ " " in
  let detail = Say.resolve lang detail in
  (match glyph with
   | Glyph.Live_working_frame frame ->
       let frame = Int.max 0 frame mod Array.length activity_spinner in
       let marker = emphasis, activity_spinner.(frame) ^ " " in
       let label = "Working" in
       let name =
         if animate then
           let length = String.length label in
           let cursor = Int.max 0 (Int.min frame (length - 1)) in
           [ emphasis, String.sub label 0 cursor;
             Typography.anchor ~bg ~underline:true theme, String.sub label cursor 1;
             emphasis, String.sub label (cursor + 1) (length - cursor - 1) ]
         else [ emphasis, label ]
       in
       marker :: (name @ [ Typography.status ~bg theme tone, Typography.sep_dot ^ detail ])
   | Glyph.Check_mark -> [ marker; emphasis, detail ]
   | _ -> [ marker; Typography.primary ~bg theme, detail ]) [@warning "-4"]

let draw_activity_runs grid ~(rect : Rect.t) runs =
  ignore
    (List.fold_left (fun x (style, text) ->
       let max_width = Rect.right rect - x in
       if max_width <= 0 || String.equal text "" then x
       else
         x + Cell_grid.put_text ~clip:rect grid ~x ~y:rect.y ~style
               (Grapheme.truncate_to_width ~max_width text))
       rect.x runs)

let pending_tx_badge state =
  pending_tx_label state
  |> Option.map (fun label ->
         let glyph, tone =
           match state with
           | Tx_thinking -> (Glyph.Ai_spark, Theme.Status_ai)
           | Tx_tool_running _ | Tx_tool_waiting _
           | Tx_turn_running { kind = Turn_kind_tool; _ } ->
               (Glyph.Tool_square, Theme.Status_active)
           | Tx_failed _ -> (Glyph.Live_failing, Theme.Status_critical)
           | Tx_interrupting -> (Glyph.Live_paused, Theme.Status_attention)
           | Tx_awaiting_turn -> (Glyph.Live_idle, Theme.Status_active)
           | Tx_queued | Tx_queued_count _
           | Tx_turn_running { kind = Turn_kind_attention; _ } ->
               (Glyph.Live_working, Theme.Status_attention)
           | Tx_turn_running { kind = Turn_kind_active; _ }
           | Tx_idle | Tx_sending | Tx_streaming | Tx_confirming ->
               (Glyph.Live_working, Theme.Status_active)
         in
         (glyph, tone, label))

let is_voice_active = function
  | Voice_off -> false
  | Voice_recording _ | Voice_transcribing -> true

let resolve_mode ~breakpoint (st : state) =
  let has_draft = String.length st.draft > 0 in
  let voice_on = is_voice_active st.voice in
  let has_pending = not (equal_pending_tx st.pending_tx Tx_idle) in
  match breakpoint with
  | Layout.Compact ->
      if (not st.focused) && (not has_draft) && (not voice_on) && not has_pending
      then Auto_folded_pill
      else if st.focused || String.contains st.draft '\n' || voice_on then
        Expanded_multiline
      else Collapsed_bar
  | Layout.Wide | Layout.Standard ->
      if st.focused || String.contains st.draft '\n' || voice_on then
        Expanded_multiline
      else Collapsed_bar
  | Layout.Micro -> Collapsed_bar

let desired_height ~breakpoint ~max_height (st : state) =
  let cap = Int.max 1 (Int.min 6 max_height) in
  match resolve_mode ~breakpoint st with
  | Auto_folded_pill -> 0
  | Collapsed_bar -> 1
  | Expanded_multiline ->
      let draft_lines = List.length (String.split_on_char '\n' st.draft) in
      let extra = if is_voice_active st.voice then 1 else 0 in
      Int.max 2 (Int.min cap (draft_lines + 1 + extra))

let folded_footer_pill ~lang (st : state) =
  let hint = Say.resolve lang (Say.make ~ko:"[i] 입력" ~en:"[i] write") in
  Printf.sprintf "%s @%s %s" (Glyph.to_utf8 Glyph.Prompt_caret) st.target_keeper hint

let clamp_cursor draft pos =
  let len = String.length draft in
  let p = Int.max 0 (Int.min len pos) in
  let rec align i =
    if i <= 0 || i >= len then i
    else if (Char.code draft.[i] land 0xC0) = 0x80 then align (i - 1)
    else i
  in
  align p

let prev_utf8_boundary s pos =
  if pos <= 0 then 0
  else
    let i = ref (pos - 1) in
    while !i > 0 && (Char.code s.[!i] land 0xC0) = 0x80 do
      decr i
    done;
    !i

let next_utf8_boundary s pos =
  let len = String.length s in
  if pos >= len then len
  else
    let i = ref (pos + 1) in
    while !i < len && (Char.code s.[!i] land 0xC0) = 0x80 do
      incr i
    done;
    !i

let insert_text txt (st : state) =
  if String.length txt = 0 then st
  else
    let cur = clamp_cursor st.draft st.cursor in
    let before = String.sub st.draft 0 cur in
    let after = String.sub st.draft cur (String.length st.draft - cur) in
    let draft = before ^ txt ^ after in
    { st with draft; cursor = cur + String.length txt }

let insert_newline st = insert_text "\n" st

let backspace (st : state) =
  let cur = clamp_cursor st.draft st.cursor in
  if cur <= 0 then st
  else
    let prev = prev_utf8_boundary st.draft cur in
    let before = String.sub st.draft 0 prev in
    let after = String.sub st.draft cur (String.length st.draft - cur) in
    { st with draft = before ^ after; cursor = prev }

let is_space_byte c =
  Char.equal c ' ' || Char.equal c '\t' || Char.equal c '\n'

let kill_word (st : state) =
  let cur = clamp_cursor st.draft st.cursor in
  if cur <= 0 then st
  else
    let i = ref cur in
    while !i > 0 && is_space_byte st.draft.[!i - 1] do
      decr i
    done;
    while !i > 0 && not (is_space_byte st.draft.[!i - 1]) do
      decr i
    done;
    let start = clamp_cursor st.draft !i in
    let before = String.sub st.draft 0 start in
    let after = String.sub st.draft cur (String.length st.draft - cur) in
    { st with draft = before ^ after; cursor = start }

let move_cursor dir (st : state) =
  let cur = clamp_cursor st.draft st.cursor in
  let next =
    match dir with
    | `Left -> prev_utf8_boundary st.draft cur
    | `Right -> next_utf8_boundary st.draft cur
    | `Home -> 0
    | `End -> String.length st.draft
  in
  { st with cursor = next }

(* Braille symmetric waveform masks (0..4 vertical amplitude centered/bottom-up). *)
let wave_left = [| 0x40; 0x40; 0x44; 0x46; 0x47 |]
let wave_right = [| 0x80; 0x80; 0xA0; 0xB0; 0xB8 |]

let level_to_dots v =
  let clamped = if not (Float.is_finite v) then 0.0 else Float.max 0.0 (Float.min 1.0 v) in
  Int.max 0 (Int.min 4 (int_of_float (Float.round (clamped *. 4.0))))

let render_voice_waveform ?clip grid ~x ~y ~width ~(theme : Theme.t) ~bg levels =
  if width <= 0 then 0
  else
    let n = Array.length levels in
    let subcols = width * 2 in
    let sample_at idx =
      if n = 0 then 0.0
      else
        let src = (idx * n) / subcols in
        levels.(Int.max 0 (Int.min (n - 1) src))
    in
    for c = 0 to width - 1 do
      let l = sample_at (2 * c) in
      let r = sample_at ((2 * c) + 1) in
      let mask = wave_left.(level_to_dots l) lor wave_right.(level_to_dots r) in
      let peak = Float.max l r in
      let fg = Color.of_rgb (Theme.gradient_sample theme Theme.Warm_flow peak) in
      let style = Style.make ~fg ~bg () in
      Cell_grid.put_braille ?clip grid ~x:(x + c) ~y ~style mask
    done;
    width

let draw_popup grid ~(anchor : Rect.t) ~(theme : Theme.t) ~lang (popup : popup) =
  match popup with
  | Popup_none -> None
  | Popup_slash { query; items; selected }
  | Popup_mention { query; items; selected } ->
      let count = List.length items in
      if count = 0 || anchor.y < 3 || anchor.w < 12 then None
      else
        let max_rows = Int.min 8 (Int.min count (anchor.y - 2)) in
        if max_rows <= 0 then None
        else
          let selected = Int.max 0 (Int.min (count - 1) selected) in
          let pop_h = max_rows + 2 in
          let pop_w = Int.min anchor.w (Int.max 44 (anchor.w * 3 / 4)) in
          let pop_rect =
            Rect.make ~x:anchor.x ~y:(anchor.y - pop_h) ~w:pop_w ~h:pop_h
          in
          let title =
            match popup with
            | Popup_slash _ ->
                Say.resolve lang
                  (Say.make
                     ~ko:(Printf.sprintf "슬래시 명령 /%s" query)
                     ~en:(Printf.sprintf "Slash Commands /%s" query))
            | Popup_mention _ ->
                Say.resolve lang
                  (Say.make
                     ~ko:(Printf.sprintf "엔티티 멘션 @%s" query)
                     ~en:(Printf.sprintf "Mention @%s" query))
            | Popup_none -> ""
          in
          let counter_badge : Card.badge =
            {
              glyph = None;
              text = Printf.sprintf "%d/%d" (selected + 1) count;
              tone = Some Theme.Status_active;
            }
          in
          let footer_hint =
            Say.resolve lang
              (Say.make ~ko:"↑↓ 선택 · Tab 완성 · Enter 실행 · Esc 닫기"
                 ~en:"↑↓ Select · Tab Complete · Enter Run · Esc Close")
          in
          let inner =
            Card.draw grid ~rect:pop_rect ~theme
              {
                (Card.default_spec ~title) with
                badge = Some counter_badge;
                footer_hint = Some footer_hint;
                focused = true;
                elevated = true;
              }
          in
          let items_arr = Array.of_list items in
          let start =
            if selected >= max_rows then Int.min (count - max_rows) (selected - max_rows + 1)
            else 0
          in
          for i = 0 to max_rows - 1 do
            let idx = start + i in
            if idx < count then begin
              let item = items_arr.(idx) in
              let py = inner.y + i in
              let is_sel = Int.equal idx selected in
              let bg =
                Color.of_rgb (if is_sel then theme.selection_bg else theme.surface_2)
              in
              let trig_style =
                if is_sel then Typography.anchor ~bg theme
                else Typography.accent ~bg ~bold:true theme
              in
              let lbl_style =
                if is_sel then Typography.primary ~bg theme
                else Typography.structure ~bg theme
              in
              let detail_style = Typography.whisper ~bg theme in
              let row_r = Rect.make ~x:inner.x ~y:py ~w:inner.w ~h:1 in
              Cell_grid.fill_rect ~clip:inner grid ~rect:row_r ~style:lbl_style ();
              if is_sel then
                Cell_grid.put_glyph ~clip:row_r grid ~x:inner.x ~y:py
                  ~style:(Typography.accent ~bg ~bold:true theme)
                  Glyph.Left_rail;
              let start_x = inner.x + 2 in
              let adv =
                Cell_grid.put_text ~clip:row_r grid ~x:start_x ~y:py
                  ~style:trig_style item.trigger
              in
              let rest_x = start_x + adv + 2 in
              let rest_w = Int.max 0 (Rect.right inner - rest_x - 1) in
              if rest_w > 0 then begin
                let lbl_adv =
                  Cell_grid.put_text ~clip:row_r grid ~x:rest_x ~y:py
                    ~style:lbl_style
                    (Grapheme.truncate_to_width ~max_width:rest_w item.label)
                in
                match item.detail with
                | Some d ->
                    let dx = rest_x + lbl_adv in
                    let dw = Int.max 0 (Rect.right inner - dx - 1) in
                    if dw > 4 then
                      let sep_d = Typography.sep_dot ^ d in
                      ignore
                        (Cell_grid.put_text ~clip:row_r grid ~x:dx ~y:py
                           ~style:detail_style
                           (Grapheme.truncate_to_width ~max_width:dw sep_d))
                | None -> ()
              end
            end
          done;
          Some pop_rect

let draw ?(show_pending_tx = true) ?(terminal_focused = true) grid
    ~(rect : Rect.t) ~(theme : Theme.t) ~lang ~breakpoint (st : state) =
  if Rect.is_empty rect then Presenter.hidden_cursor
  else
    let mode = resolve_mode ~breakpoint st in
    let vis_focused = st.focused && terminal_focused in
    match mode with
    | Auto_folded_pill -> Presenter.hidden_cursor
    | Collapsed_bar | Expanded_multiline ->
        let bg_rgb = if vis_focused then theme.surface_2 else theme.surface_1 in
        let bg = Color.of_rgb bg_rgb in
        let input_style =
          if vis_focused then
            Style.make ~fg:(Color.of_rgb theme.text_bright) ~bg ()
          else Typography.primary ~bg theme
        in
        Cell_grid.fill_rect ~clip:rect grid ~rect ~style:input_style ();
        if vis_focused then
          Card.draw_left_rail ~bg grid ~x:rect.x ~y:rect.y ~h:rect.h ~theme;
        let left_x = rect.x + 2 in
        let caret_style =
          if terminal_focused then Typography.accent ~bg ~bold:true theme
          else Typography.structure ~bg theme
        in
        let target_style =
          if vis_focused then Typography.accent ~bg ~bold:true theme
          else if terminal_focused then Typography.primary ~bg ~bold:true theme
          else Typography.structure ~bg theme
        in
        let placeholder_style = Typography.whisper ~bg theme in
        let header_y = rect.y in
        let header_r = Rect.make ~x:rect.x ~y:header_y ~w:rect.w ~h:1 in
        let caret_s = Glyph.to_utf8 Glyph.Prompt_caret ^ " " in
        let c_adv =
          Cell_grid.put_text ~clip:header_r grid ~x:left_x ~y:header_y
            ~style:caret_style caret_s
        in
        let target_s = Printf.sprintf "@%s " st.target_keeper in
        let t_adv =
          Cell_grid.put_text ~clip:header_r grid ~x:(left_x + c_adv) ~y:header_y
            ~style:target_style target_s
        in
        let pref_end_x = left_x + c_adv + t_adv in
        (* Send and editing shortcuts are shown in the footer. *)
        let right_parts = ref [] in
        if st.draft_count_other_keepers > 0 then begin
          let badge =
            Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "초안 %d" st.draft_count_other_keepers)
                 ~en:(Printf.sprintf "drafts %d" st.draft_count_other_keepers))
          in
          right_parts :=
            (badge, Typography.status ~bg ~bold:true theme Theme.Status_attention)
            :: !right_parts
        end;
        if show_pending_tx then
          Option.iter
            (fun (glyph, tone, label) ->
              let text = Glyph.to_utf8 glyph ^ " " ^ Say.resolve lang label in
              right_parts :=
                (text, Typography.status ~bg ~bold:true theme tone) :: !right_parts)
            (pending_tx_badge st.pending_tx);
        let right_margin = if rect.w >= 32 then 1 else 0 in
        let right_total_w =
          List.fold_left
            (fun acc (s, _) -> acc + Grapheme.display_width s + 2)
            0 !right_parts
        in
        let rx = ref (Rect.right rect - right_margin - right_total_w + 2) in
        let right_drawn = right_total_w > 0 && !rx > pref_end_x + 4 in
        if right_drawn then
          List.iter
            (fun (text, style) ->
              let adv =
                Cell_grid.put_text ~clip:header_r grid ~x:!rx ~y:header_y ~style
                  text
              in
              rx := !rx + adv + 2)
            !right_parts;
        (* Voice PTT waveform bar if active *)
        let voice_row_offset =
          match st.voice with
          | Voice_off -> 0
          | Voice_recording { levels; elapsed_s } ->
              let vy =
                if rect.h >= 2 then rect.y + rect.h - 1 else rect.y
              in
              let vx = if rect.h >= 2 then left_x else pref_end_x in
              let vr = Rect.make ~x:vx ~y:vy ~w:(Int.max 0 (Rect.right rect - vx)) ~h:1 in
              let rec_lbl =
                Say.resolve lang
                  (Say.make
                     ~ko:(Printf.sprintf "%s 음성 녹음 %.1fs " (Glyph.to_utf8 Glyph.Live_working) elapsed_s)
                     ~en:(Printf.sprintf "%s REC %.1fs " (Glyph.to_utf8 Glyph.Live_working) elapsed_s))
              in
              let rec_style =
                Typography.status ~bg ~bold:true theme Theme.Status_critical
              in
              let lw =
                Cell_grid.put_text ~clip:vr grid ~x:vx ~y:vy ~style:rec_style
                  rec_lbl
              in
              let wave_w = Int.max 0 (Int.min 28 (vr.w - lw - 1)) in
              ignore
                (render_voice_waveform ~clip:vr grid ~x:(vx + lw) ~y:vy
                   ~width:wave_w ~theme ~bg levels);
              if rect.h >= 2 then 1 else 0
          | Voice_transcribing ->
              let vy = if rect.h >= 2 then rect.y + rect.h - 1 else rect.y in
              let vx = if rect.h >= 2 then left_x else pref_end_x in
              let vr = Rect.make ~x:vx ~y:vy ~w:(Int.max 0 (Rect.right rect - vx)) ~h:1 in
              let lbl =
                Say.resolve lang
                  (Say.make
                     ~ko:(Glyph.to_utf8 Glyph.Transport_reconnecting ^ " 음성 인식 중…")
                     ~en:(Glyph.to_utf8 Glyph.Transport_reconnecting ^ " Transcribing…"))
              in
              ignore
                (Cell_grid.put_text ~clip:vr grid ~x:vx ~y:vy
                   ~style:(Typography.status ~bg ~italic:true theme Theme.Status_active)
                   lbl);
              if rect.h >= 2 then 1 else 0
        in
        (* Horizontal viewport panning around cursor on UAX #29 cluster boundaries. *)
        let pan_line_for_cursor ~max_width ~cursor_byte line =
          if max_width <= 0 then ("", 0)
          else
            let line_len = String.length line in
            let cbyte = Int.max 0 (Int.min line_len cursor_byte) in
            let cursor_col =
              Grapheme.display_width (String.sub line 0 cbyte)
            in
            if cursor_col < max_width then
              let shown =
                Grapheme.truncate_to_width ~max_width ~ellipsis:"" line
              in
              (shown, cursor_col)
            else
              let target_start = Int.max 0 (cursor_col - (max_width - 1)) in
              let buf = Buffer.create max_width in
              let col = ref 0 in
              let started = ref false in
              let stopped = ref false in
              let actual_start = ref target_start in
              let taken_w = ref 0 in
              Grapheme.iter_clusters line
                (fun ~text ~start_offset ~end_offset ~cell_width ->
                  if not !started then begin
                    if !col >= target_start then begin
                      started := true;
                      actual_start := !col
                    end
                  end;
                  if !started && not !stopped then begin
                    if !taken_w + cell_width <= max_width then begin
                      Buffer.add_substring buf text start_offset
                        (end_offset - start_offset);
                      taken_w := !taken_w + cell_width
                    end
                    else stopped := true
                  end;
                  col := !col + cell_width);
              let cursor_dx =
                Int.max 0 (Int.min (max_width - 1) (cursor_col - !actual_start))
              in
              (Buffer.contents buf, cursor_dx)
        in
        (* Draw draft text (single line on collapsed bar, multiline on expanded) *)
        let cur = clamp_cursor st.draft st.cursor in
        if rect.h = 1 || equal_mode mode Collapsed_bar then begin
          if rect.h = 1 && is_voice_active st.voice then Presenter.hidden_cursor
          else begin
            let tx = pref_end_x in
            let reserved_right =
              if right_drawn then right_total_w + right_margin else 0
            in
            let avail = Int.max 0 (Rect.right rect - tx - reserved_right) in
            if String.length st.draft = 0 then begin
              let placeholder =
                Say.resolve lang
                  (Say.make ~ko:"i 입력 · / 명령 · @ 멘션 · V 음성"
                     ~en:"i write · / cmd · @ mention · V voice")
              in
              ignore
                (Cell_grid.put_text ~clip:header_r grid ~x:tx ~y:header_y
                   ~style:placeholder_style
                   (Grapheme.truncate_to_width ~max_width:avail placeholder));
              if vis_focused && avail > 0 then
                { Presenter.x = tx; y = header_y; visible = true; shape = Presenter.Bar }
              else Presenter.hidden_cursor
            end
            else begin
              let first =
                match String.split_on_char '\n' st.draft with
                | h :: _ -> h
                | [] -> ""
              in
              let first_cur = Int.min (String.length first) cur in
              let shown, cursor_dx =
                if st.focused then
                  pan_line_for_cursor ~max_width:avail ~cursor_byte:first_cur first
                else
                  (Grapheme.truncate_to_width ~max_width:avail first, 0)
              in
              ignore
                (Cell_grid.put_text ~clip:header_r grid ~x:tx ~y:header_y
                   ~style:input_style shown);
              if vis_focused && avail > 0 then
                {
                  Presenter.x = Int.min (Rect.right rect - 1) (tx + cursor_dx);
                  y = header_y;
                  visible = true;
                  shape = Presenter.Bar;
                }
              else Presenter.hidden_cursor
            end
          end
        end
        else begin
          (* Expanded multiline editor below header row *)
          let body_top = rect.y + 1 in
          let body_rows = Int.max 0 (rect.h - 1 - voice_row_offset) in
          if body_rows = 0 then Presenter.hidden_cursor
          else begin
            let lines = String.split_on_char '\n' st.draft in
            let lines_arr = Array.of_list lines in
            let total_lines = Array.length lines_arr in
            let cursor_line = ref 0 in
            let cursor_byte_in_line = ref cur in
            let remaining = ref cur in
            let found = ref false in
            for li = 0 to total_lines - 1 do
              if not !found then begin
                let ll = String.length lines_arr.(li) in
                if !remaining <= ll then begin
                  cursor_line := li;
                  cursor_byte_in_line := !remaining;
                  found := true
                end
                else remaining := !remaining - ll - 1
              end
            done;
            let start_line =
              if !cursor_line >= body_rows then !cursor_line - body_rows + 1
              else 0
            in
            let content_x = rect.x + 2 in
            let content_w = Int.max 1 (rect.w - 2) in
            let active_cursor_dx = ref 0 in
            if String.length st.draft = 0 then begin
              let rr = Rect.make ~x:rect.x ~y:body_top ~w:rect.w ~h:1 in
              let placeholder =
                Say.resolve lang
                  (Say.make ~ko:"메시지를 입력하세요…" ~en:"Type a message…")
              in
              ignore
                (Cell_grid.put_text ~clip:rr grid ~x:content_x ~y:body_top
                   ~style:placeholder_style
                   (Grapheme.truncate_to_width ~max_width:content_w placeholder))
            end
            else
              for r = 0 to body_rows - 1 do
                let li = start_line + r in
                let py = body_top + r in
                if li < total_lines then begin
                  let rr = Rect.make ~x:rect.x ~y:py ~w:rect.w ~h:1 in
                  let text_to_draw =
                    if st.focused && Int.equal li !cursor_line then
                      let panned, dx =
                        pan_line_for_cursor ~max_width:content_w
                          ~cursor_byte:!cursor_byte_in_line lines_arr.(li)
                      in
                      active_cursor_dx := dx;
                      panned
                    else
                      Grapheme.truncate_to_width ~max_width:content_w lines_arr.(li)
                  in
                  ignore
                    (Cell_grid.put_text ~clip:rr grid ~x:content_x ~y:py
                       ~style:input_style text_to_draw)
                end
              done;
            if vis_focused then
              let cx =
                Int.min (Rect.right rect - 1) (content_x + !active_cursor_dx)
              in
              let cy =
                Int.min (body_top + body_rows - 1)
                  (body_top + (!cursor_line - start_line))
              in
              { Presenter.x = cx; y = cy; visible = true; shape = Presenter.Bar }
            else Presenter.hidden_cursor
          end
        end
