open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

(* Names follow the injection sites Prompt_block_id documents. *)
let block_name : Prompt_block_id.t -> Say.t = function
  | Prompt_block_id.Keeper_instructions ->
      Say.make ~ko:"Keeper 지시문" ~en:"Keeper instructions"
  | Prompt_block_id.Dynamic_context -> Say.make ~ko:"턴 맥락" ~en:"Turn context"
  | Prompt_block_id.Active_goals -> Say.make ~ko:"진행 중 Goal" ~en:"Active goals"
  | Prompt_block_id.Direct_input_source ->
      Say.make ~ko:"직접 작업 출처" ~en:"Direct input source"
  | Prompt_block_id.Completion_authority ->
      Say.make ~ko:"완료 승인 기록" ~en:"Completion authority"
  | Prompt_block_id.Goals_awaiting_proof ->
      Say.make ~ko:"증명 기다리는 Goal" ~en:"Goals awaiting proof"
  | Prompt_block_id.Constitution_amendments ->
      Say.make ~ko:"세계 조항" ~en:"World articles"
  | Prompt_block_id.Temporal_summary ->
      Say.make ~ko:"시간 요약" ~en:"Temporal summary"
  | Prompt_block_id.Memory_os_recall ->
      Say.make ~ko:"Memory 회상" ~en:"Memory OS recall"
  | Prompt_block_id.Librarian_working_context ->
      Say.make ~ko:"사서 작업 맥락" ~en:"Librarian working context"
  | Prompt_block_id.Recalled_memory ->
      Say.make ~ko:"불러온 기억" ~en:"Recalled memory"
  | Prompt_block_id.Recalled_memory_status ->
      Say.make ~ko:"회상 판정" ~en:"Recall judgment"
  | Prompt_block_id.Operator_note -> Say.make ~ko:"운영자 메모" ~en:"Operator note"
  | Prompt_block_id.Skill_compositions ->
      Say.make ~ko:"Skill 조합" ~en:"Skill compositions"
  | Prompt_block_id.Arrived_stimuli ->
      Say.make ~ko:"턴 중 도착" ~en:"Arrived during the turn"

let format_bytes n =
  Format_val.format_value Format_val.Bytes (float_of_int (Int.max 0 n))

(* How the selected turn's block stands against the previous turn's record. *)
let change_mark (entry : Wire_keeper_context.turn_record_entry)
    (block : Turn_record.prompt_block) =
  match entry.diff_vs_prev with
  | None -> ""
  | Some diff ->
      let same (b : Turn_record.prompt_block) =
        Prompt_block_id.equal b.block block.block
      in
      if List.exists same diff.added then "+"
      else if
        List.exists
          (fun ((_, next) : Turn_record.prompt_block * Turn_record.prompt_block) ->
            same next)
          diff.changed
      then "~"
      else ""

let columns : Table.column list =
  [
    {
      id = "idx";
      header = Say.literal "#";
      priority = 0;
      min_width = 3;
      max_width = Some 4;
      weight = 1;
      align = Table.Right;
    };
    {
      id = "name";
      header = Say.make ~ko:"블록" ~en:"Block";
      priority = 0;
      min_width = 14;
      max_width = None;
      weight = 4;
      align = Table.Left;
    };
    {
      id = "bytes";
      header = Say.make ~ko:"크기" ~en:"Bytes";
      priority = 0;
      min_width = 7;
      max_width = Some 10;
      weight = 1;
      align = Table.Right;
    };
    {
      id = "share";
      header = Say.literal "%";
      priority = 1;
      min_width = 4;
      max_width = Some 5;
      weight = 1;
      align = Table.Right;
    };
    {
      id = "change";
      header = Say.literal "Δ";
      priority = 1;
      min_width = 2;
      max_width = Some 2;
      weight = 1;
      align = Table.Left;
    };
  ]

let draw_text_pane grid ~(rect : Rect.t) ~(theme : Theme.t) ~(model : Model.t)
    ~(st : Keeper_context_store.keeper_state) ~focused
    (record : Turn_record.t) (block : Turn_record.prompt_block) =
  let bg = Color.of_rgb theme.surface_1 in
  let hdr_style =
    if focused then Typography.anchor ~bg:(Color.of_rgb theme.selection_bg) theme
    else Typography.anchor ~bg theme
  in
  let prefix = if focused then Glyph.to_utf8 Glyph.Focus_caret ^ " " else "" in
  let hdr =
    Printf.sprintf "%s%s · %s · %s" prefix
      (Say.resolve model.lang (block_name block.block))
      (Prompt_block_id.to_string block.block)
      (format_bytes block.bytes)
  in
  ignore
    (Ops_common.put_line ~clip:rect grid ~x:rect.x ~y:rect.y ~max_w:rect.w
       ~style:hdr_style hdr);
  let body_r =
    Rect.make ~x:rect.x ~y:(rect.y + 1) ~w:rect.w ~h:(Int.max 0 (rect.h - 1))
  in
  (* A note that stands in for the text wraps over the whole pane. *)
  let say_lines ~ko ~en =
    Chat_transcript.wrap_plain_lines ~width:body_r.w (Ops_common.say model ~ko ~en)
    |> List.iteri (fun i line ->
           if i < body_r.h then
             ignore
               (Ops_common.put_line ~clip:body_r grid ~x:body_r.x
                  ~y:(body_r.y + i) ~max_w:body_r.w
                  ~style:(Typography.whisper ~bg theme)
                  line))
  in
  let draw_text (r : Rect.t) text =
    if Rect.is_empty r then ()
    else
      ignore
        (Markdown.draw grid ~rect:r ~theme ~osc8:false ~scroll:st.scroll_offset
           (Ops_common.scrub_secrets_in_text text))
  in
  if Rect.is_empty body_r then ()
  else if not (Rbac.can_single_user_token_admin model.auth_session) then
    say_lines ~ko:"블록 본문은 관리자 세션에서 읽어요 (/last-prompt)"
      ~en:"Block text needs an admin session (/last-prompt)"
  else
    match Observed.to_option st.last_prompt with
    | None ->
        Ops_common.draw_observed_empty grid ~rect:body_r ~theme ~lang:model.lang
          st.last_prompt
          ~empty_msg:
            (Say.make
               ~ko:"프롬프트 기록을 남기기 시작한 뒤로 이 Keeper 가 조립한 턴이 없어요"
               ~en:"This keeper has not assembled a turn since prompt capture began")
    | Some capture -> (
        let capture_ref =
          Printf.sprintf "%s#%d" capture.lp_trace_id capture.lp_absolute_turn
        in
        let block_text =
          Keeper_context_store.block_text_in_capture capture record block
        in
        let text_r = Keeper_context_store.prompt_block_text_rect rect block_text in
        match block_text with
        | Keeper_context_store.Block_text text -> draw_text text_r text
        | Keeper_context_store.Block_text_rewritten text ->
            (* One row, as [prompt_block_text_rect] counts it. *)
            ignore
              (Ops_common.put_line ~clip:body_r grid ~x:body_r.x ~y:body_r.y
                 ~max_w:body_r.w
                 ~style:(Typography.whisper ~bg theme)
                 (if
                    Prompt_block_id.equal block.block
                      Prompt_block_id.Dynamic_context
                  then
                    Ops_common.say model
                      ~ko:"서버 사본 · sha256 다름 · 비밀값과 연결 앱 개인 기억을 뺐어요"
                      ~en:"The server's copy · sha256 differs · secrets and connector personal memory removed"
                  else
                    Ops_common.say model ~ko:"서버 사본 · sha256 다름 · 비밀값을 가렸어요"
                      ~en:"The server's copy · sha256 differs · secrets redacted"));
            draw_text text_r text
        | Keeper_context_store.Block_text_differs ->
            say_lines
              ~ko:
                (Printf.sprintf
                   "이 턴의 본문은 남아 있지 않아요. 마지막 기록(%s)의 같은 블록은 내용이 달라요."
                   capture_ref)
              ~en:
                (Printf.sprintf
                   "This turn's text is not kept. The same block in the last record (%s) has other content."
                   capture_ref)
        | Keeper_context_store.Block_text_not_captured ->
            say_lines
              ~ko:(Printf.sprintf "마지막 기록(%s)에는 이 블록이 없어요." capture_ref)
              ~en:
                (Printf.sprintf "The last record (%s) has no such block."
                   capture_ref))

let draw grid ~(rect : Rect.t) ~(theme : Theme.t) ~(model : Model.t)
    ~(st : Keeper_context_store.keeper_state) =
  let bg = Color.of_rgb theme.surface_1 in
  let pad_x = Ops_common.pad_x_for ~model rect in
  let content = Card.pad_inner ~pad_x rect in
  if Rect.is_empty content then ()
  else
    match Keeper_context_store.selected_turn_entry st with
    | None ->
        Ops_common.draw_observed_empty grid ~rect:content ~theme ~lang:model.lang
          st.turn_records
          ~empty_msg:
            (Say.make ~ko:"기록된 턴 레코드가 없습니다"
               ~en:"No turn records observed yet")
    | Some entry ->
        let blocks = entry.record.blocks in
        let total =
          List.fold_left
            (fun acc (b : Turn_record.prompt_block) -> acc + b.bytes)
            0 blocks
        in
        let layout = Keeper_context_store.prompt_blocks_layout content in
        let header = layout.Keeper_context_store.pb_header in
        let y = ref header.y in
        let bot = Rect.bottom header in
        if !y < bot then begin
          ignore
            (Ops_common.put_line ~clip:header grid ~x:header.x ~y:!y
               ~max_w:header.w
               ~style:(Typography.whisper ~bg theme)
               (Ops_common.say model
                  ~ko:
                    (Printf.sprintf "블록 %d개 · %s · 조립 순서"
                       (List.length blocks) (format_bytes total))
                  ~en:
                    (Printf.sprintf "%d blocks · %s · assembly order"
                       (List.length blocks) (format_bytes total))));
          incr y
        end;
        if !y < bot then begin
          Card.draw_hairline ~pad_x:0 ~bg
            ~label:
              (Ops_common.say model
                 ~ko:"블록 ([↑↓] 선택 · [→] 본문 · [PgUp/PgDn] 본문 넘김 · Δ 앞 턴 대비)"
                 ~en:"Blocks ([↑↓] Select · [→] Text · [PgUp/PgDn] Scroll text · Δ vs previous turn)")
            grid ~rect:header ~y:!y ~theme
        end;
        let list_r = layout.Keeper_context_store.pb_blocks in
        let text_r = layout.Keeper_context_store.pb_text in
        if Rect.is_empty list_r then ()
        else if blocks = [] then
          ignore
            (Ops_common.put_line ~clip:list_r grid ~x:list_r.x ~y:list_r.y
               ~max_w:list_r.w
               ~style:(Typography.whisper ~bg theme)
               (Ops_common.say model ~ko:"이 턴에 기록된 블록이 없어요"
                  ~en:"No blocks recorded for this turn"))
        else
          let rows =
            List.mapi
              (fun idx (b : Turn_record.prompt_block) ->
                let share =
                  if total > 0 then Printf.sprintf "%d" (b.bytes * 100 / total)
                  else Glyph.to_utf8 Glyph.Missing_absent
                in
                {
                  Table.id = Int.to_string idx;
                  cells =
                    [
                      ("idx", Table.text_cell (Int.to_string (idx + 1)));
                      ( "name"
                      , Table.text_cell (Say.resolve model.lang (block_name b.block))
                      );
                      ("bytes", Table.text_cell (format_bytes b.bytes));
                      ( "share"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                          share );
                      ( "change"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                          (change_mark entry b) );
                    ];
                })
              blocks
          in
          let selected =
            Text_util.clamp_index (List.length blocks) st.selected_block_idx
          in
          let is_zoomed = Model.is_zoomed_active model in
          let list_focused =
            if is_zoomed then Model.pane_focused model 0
            else Model.pane_focused model 1
          in
          let text_focused =
            if is_zoomed then Model.pane_focused model 1
            else Model.pane_focused model 2
          in
          ignore
            (Table.draw grid ~rect:list_r ~theme ~caps:Ops_common.default_caps
               ~lang:model.lang ~selected ~focused:list_focused ~columns rows);
          match Keeper_context_store.selected_prompt_block st with
          | Some block when not (Rect.is_empty text_r) ->
              draw_text_pane grid ~rect:text_r ~theme ~model ~st
                ~focused:text_focused entry.record block
          | Some _ | None -> ()
