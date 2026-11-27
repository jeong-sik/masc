open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let put_clipped grid ~clip ~x ~y ~style text =
  let max_width = Int.max 0 (Rect.right clip - x) in
  if max_width <= 0 || y < clip.y || y >= Rect.bottom clip then 0
  else
    Cell_grid.put_text ~clip grid ~x ~y ~style
      (Grapheme.truncate_to_width ~max_width text)

let scrub_single s =
  Chat_transcript.scrub_secrets_in_text s |> Text_util.sanitize_single_line

let wrap_prefixed ~width ~prefix ~cont_prefix text =
  let clean = Chat_transcript.scrub_secrets_in_text text in
  let max_w = Int.max 12 width in
  let lines = String.split_on_char '\n' clean in
  let rec split_chunk first acc chunk =
    let pfx = if first then prefix else cont_prefix in
    let pfx_w = Grapheme.display_width pfx in
    let avail = Int.max 8 (max_w - pfx_w) in
    let chunk = String.map (function '\r' | '\t' -> ' ' | c -> c) chunk in
    if Grapheme.display_width chunk <= avail then (pfx ^ chunk) :: acc
    else
      let head = Grapheme.truncate_to_width ~max_width:avail ~ellipsis:"" chunk in
      let head_len = String.length head in
      if head_len <= 0 then (pfx ^ chunk) :: acc
      else
        let rest =
          String.sub chunk head_len (String.length chunk - head_len)
        in
        split_chunk false ((pfx ^ head) :: acc) rest
  in
  let acc, _ =
    List.fold_left
      (fun (acc, is_first) line -> (split_chunk is_first acc line, false))
      ([], true) lines
  in
  List.rev acc

let render_left_pane ~model ~cache ~(rect : Rect.t) ~(theme : Theme.t) grid =
  let lang = model.Model.lang in
  let pk = model.Model.personal_keepers in
  let keepers = Personal_keepers_store.keepers_list pk in
  let title =
    Say.resolve lang (Say.make ~ko:"개인 키퍼" ~en:"Personal Keepers")
  in
  let badge =
    match pk.own_keeper_forbidden with
    | Some _ ->
        Some
          {
            Card.glyph = Some Glyph.Locked;
            text = "403";
            tone = Some Theme.Status_critical;
          }
    | None -> (
        match pk.keepers with
        | Observed.Value _ ->
            Some
              {
                Card.glyph = None;
                text = string_of_int (List.length keepers);
                tone = Some Theme.Status_ok;
              }
        | Observed.Loading _ ->
            Some
              {
                Card.glyph = None;
                text = "...";
                tone = Some Theme.Status_attention;
              }
        | Observed.Failed _ ->
            Some
              {
                Card.glyph = Some Glyph.Live_failing;
                text = "ERR";
                tone = Some Theme.Status_critical;
              }
        | Observed.Absent | Observed.Unreported -> None)
  in
  let hotkey =
    Say.resolve lang
      (Say.make ~ko:"[n] 생성 · [a] 배정 · [r] 새로고침"
         ~en:"[n] Create · [a] Assign · [r] Refresh")
  in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      {
        (Card.default_spec ~title) with
        badge;
        hotkey = Some hotkey;
        focused = Model.pane_focused model 0;
      }
  in
  if Rect.is_empty inner then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = if inner.w >= 32 then 1 else 0 in
    let cx = inner.x + pad_x in
    let cw = Int.max 0 (inner.w - (2 * pad_x)) in
    let anchor_st = Typography.anchor ~bg theme in
    let primary_st = Typography.primary ~bg theme in
    let whisper_st = Typography.whisper ~bg theme in
    let warn_st = Typography.status ~bg ~bold:true theme Theme.Status_attention in
    let crit_st = Typography.status ~bg ~bold:true theme Theme.Status_critical in
    let ok_st = Typography.status ~bg ~bold:true theme Theme.Status_ok in
    let acc_st = Typography.accent ~bg ~bold:true theme in
    let footer_h = if inner.h >= 6 then 1 else 0 in
    let body_bottom = Rect.bottom inner - footer_h in
    let clip =
      Rect.make ~x:cx ~y:inner.y ~w:cw ~h:(Int.max 0 (body_bottom - inner.y))
    in
    let y = ref inner.y in
    let line_ok () = !y < body_bottom in
    let next_line () = y := !y + 1 in
    (* Explicit HTTP 403 banner (never logs out) *)
    (match pk.own_keeper_forbidden with
    | Some detail when line_ok () ->
        let msg =
          Glyph.to_utf8 Glyph.Locked
          ^ " HTTP 403 (manage_own_keeper required): "
          ^ scrub_single detail
        in
        ignore (put_clipped grid ~clip ~x:cx ~y:!y ~style:crit_st msg);
        next_line ()
    | Some _ | None -> ());
    (* Keepers list *)
    if line_ok () then begin
      match pk.keepers with
      | Observed.Loading _ ->
          ignore
            (put_clipped grid ~clip ~x:cx ~y:!y ~style:whisper_st
               (Say.resolve lang
                  (Say.make ~ko:"개인 키퍼 불러오는 중..."
                     ~en:"Personal keepers: loading...")));
          next_line ()
      | Observed.Failed { reason; _ } ->
          ignore
            (put_clipped grid ~clip ~x:cx ~y:!y ~style:warn_st
               ("Keepers error: " ^ scrub_single reason));
          next_line ()
      | Observed.Unreported | Observed.Absent ->
          ignore
            (put_clipped grid ~clip ~x:cx ~y:!y ~style:whisper_st
               (Say.resolve lang
                  (Say.make ~ko:"미로드 ([r] 새로고침)"
                     ~en:"Personal keepers: not loaded ([r] refresh)")));
          next_line ()
      | Observed.Value { data = []; _ } ->
          ignore
            (put_clipped grid ~clip ~x:cx ~y:!y ~style:whisper_st
               (Say.resolve lang
                  (Say.make ~ko:"개인 키퍼 없음 — [n]을 눌러 생성하세요"
                     ~en:"No personal keepers yet — press [n] to create one")));
          next_line ()
      | Observed.Value { data = rows; _ } ->
          let sel_idx = pk.selected_keeper_idx in
          List.iteri
            (fun idx (k : Wire_personal_keepers.personal_keeper) ->
              if line_ok () then begin
                let is_sel = Int.equal idx sel_idx in
                let rbg =
                  Color.of_rgb
                    (if is_sel then theme.selection_bg else theme.surface_1)
                in
                let row_r = Rect.make ~x:cx ~y:!y ~w:cw ~h:1 in
                Cell_grid.fill_rect ~clip grid ~rect:row_r
                  ~style:(Typography.primary ~bg:rbg theme) ();
                let prefix =
                  if is_sel then Glyph.to_utf8 Glyph.Prompt_caret ^ " "
                  else "  "
                in
                let rt_tag =
                  match k.runtime_id with
                  | Some rt -> "[" ^ rt ^ "]"
                  | None -> "[unassigned]"
                in
                let st =
                  if is_sel then Typography.anchor ~bg:rbg theme
                  else Typography.primary ~bg:rbg theme
                in
                ignore
                  (put_clipped grid ~clip:row_r ~x:cx ~y:!y ~style:st
                     (Printf.sprintf "%s%s  %s" prefix k.keeper_id rt_tag));
                next_line ()
              end)
            rows
    end;
    (* Owned Runtimes section *)
    if line_ok () then next_line ();
    if line_ok () then begin
      let hdr =
        Say.resolve lang (Say.make ~ko:"보유 런타임" ~en:"Owned Runtimes")
      in
      Card.draw_hairline ~pad_x ~label:hdr ~focused:false ~bg grid ~rect:inner
        ~y:!y ~theme;
      next_line ()
    end;
    if line_ok () then begin
      match model.account.own_provider_forbidden with
      | Some detail ->
          ignore
            (put_clipped grid ~clip ~x:cx ~y:!y ~style:warn_st
               ("HTTP 403 (manage_own_provider): " ^ scrub_single detail));
          next_line ()
      | None -> (
          let rts = Account_store.all_runtimes model.account in
          match rts with
          | [] -> (
              match model.account.provider_accounts with
              | Observed.Loading _ ->
                  ignore
                    (put_clipped grid ~clip ~x:cx ~y:!y ~style:whisper_st
                       "Runtimes: loading...");
                  next_line ()
              | Observed.Failed { reason; _ } ->
                  ignore
                    (put_clipped grid ~clip ~x:cx ~y:!y ~style:warn_st
                       ("Runtimes error: " ^ scrub_single reason));
                  next_line ()
              | Observed.Value _ | Observed.Absent | Observed.Unreported ->
                  ignore
                    (put_clipped grid ~clip ~x:cx ~y:!y ~style:whisper_st
                       (Say.resolve lang
                          (Say.make ~ko:"없음 — [@] 계정에서 프로바이더를 연결하세요"
                             ~en:"None connected — press [@] Account to connect")));
                  next_line ())
          | _ :: _ as xs ->
              List.iter
                (fun (r : Wire_account.provider_runtime) ->
                  if line_ok () then begin
                    let desc =
                      match r.model with
                      | Wire_account.Runtime_model m ->
                          Printf.sprintf "%s (%s)" r.runtime_id m
                      | Wire_account.Runtime_model_unread u ->
                          Printf.sprintf "%s (unread:%s)" r.runtime_id
                            (Wire_account.runtime_unread_reason_to_string u)
                    in
                    let st =
                      match r.model with
                      | Wire_account.Runtime_model _ -> ok_st
                      | Wire_account.Runtime_model_unread _ -> warn_st
                    in
                    ignore (put_clipped grid ~clip ~x:cx ~y:!y ~style:st desc);
                    next_line ()
                  end)
                xs)
    end;
    ignore anchor_st;
    ignore primary_st;
    if footer_h > 0 then begin
      let fy = Rect.bottom inner - 1 in
      let fclip = Rect.make ~x:cx ~y:fy ~w:cw ~h:1 in
      let bar =
        Say.resolve lang
          (Say.make ~ko:"[n] 키퍼 생성  [a] 런타임 배정  [r] 새로고침"
             ~en:"[n] Create  [a] Assign  [r] Refresh")
      in
      ignore (put_clipped grid ~clip:fclip ~x:cx ~y:fy ~style:acc_st bar)
    end

let build_transcript_lines ~width ~lang ~theme ~bg
    ~(snap : Wire_personal_keepers.conversation_snapshot option)
    ~(ephemeral : Personal_keepers_store.ephemeral_turn list) =
  let anchor_st = Typography.anchor ~bg theme in
  let primary_st = Typography.primary ~bg theme in
  let whisper_st = Typography.whisper ~bg theme in
  let warn_st = Typography.status ~bg ~bold:true theme Theme.Status_attention in
  let crit_st = Typography.status ~bg ~bold:true theme Theme.Status_critical in
  let ok_st = Typography.status ~bg ~bold:true theme Theme.Status_ok in
  let acc_st = Typography.accent ~bg ~bold:true theme in
  let lines = ref [] in
  let push st s = lines := (st, s) :: !lines in
  (match snap with
  | None -> ()
  | Some s ->
      if s.turns = [] && ephemeral = [] then
        push whisper_st
          (Say.resolve lang
             (Say.make
                ~ko:"대화 기록이 없습니다 — [s]로 첫 메시지를 보내세요"
                ~en:"No turns in this conversation — press [s] to send a turn"))
      else
        List.iter
          (fun (turn : Wire_personal_keepers.conversation_turn) ->
            List.iter (push anchor_st)
              (wrap_prefixed ~width ~prefix:"You: " ~cont_prefix:"     "
                 turn.message);
            (match turn.outcome with
            | Wire_personal_keepers.Turn_answered { text; model; _ } ->
                List.iter (push primary_st)
                  (wrap_prefixed ~width
                     ~prefix:(Printf.sprintf "Keeper (%s): " model)
                     ~cont_prefix:"  " text)
            | Wire_personal_keepers.Turn_failed
                { failure; model_may_have_read; _ } ->
                let why =
                  Say.resolve lang
                    (Wire_personal_keepers.turn_failure_say failure)
                in
                let read_note =
                  if model_may_have_read then
                    Say.resolve lang
                      (Say.make ~ko:" [모델이 메시지를 읽었을 수 있음]"
                         ~en:" [model_may_have_read=true]")
                  else ""
                in
                push crit_st (Printf.sprintf "[FAILED] %s%s" why read_note)
            | Wire_personal_keepers.Turn_unrecorded { model_may_have_read } ->
                let read_note =
                  if model_may_have_read then
                    Say.resolve lang
                      (Say.make ~ko:" [모델이 메시지를 읽었을 수 있음]"
                         ~en:" [model_may_have_read=true]")
                  else ""
                in
                push warn_st
                  (Say.resolve lang
                     (Say.make
                        ~ko:("[미기록 응답] 서버가 응답을 기록하지 못했습니다" ^ read_note)
                        ~en:("[UNRECORDED] Reply was not recorded" ^ read_note))));
            push whisper_st "")
          s.turns);
  List.iter
    (fun (ep : Personal_keepers_store.ephemeral_turn) ->
      List.iter (push anchor_st)
        (wrap_prefixed ~width ~prefix:"You: " ~cont_prefix:"     " ep.message);
      push warn_st
        (Say.resolve lang
           (Say.make
              ~ko:
                (Printf.sprintf "[미기록 · 일시 응답] (%s) — 디스크에 저장되지 않음"
                   ep.answer.model)
              ~en:
                (Printf.sprintf
                   "[UNRECORDED / EPHEMERAL] (%s) — not saved to conversation history"
                   ep.answer.model)));
      List.iter (push primary_st)
        (wrap_prefixed ~width ~prefix:"  " ~cont_prefix:"  " ep.answer.text);
      push whisper_st "")
    ephemeral;
  ignore ok_st;
  ignore acc_st;
  List.rev !lines

let render_right_pane ~model ~cache ~(rect : Rect.t) ~(theme : Theme.t) grid =
  let lang = model.Model.lang in
  let pk = model.Model.personal_keepers in
  let sel_keeper = Personal_keepers_store.selected_keeper pk in
  let title =
    Say.resolve lang (Say.make ~ko:"개인 대화" ~en:"Personal Conversation")
  in
  let badge =
    match sel_keeper with
    | Some k ->
        Some
          {
            Card.glyph = None;
            text = k.keeper_id;
            tone =
              Some
                (if Option.is_some k.runtime_id then Theme.Status_ok
                 else Theme.Status_attention);
          }
    | None -> None
  in
  let hotkey =
    Say.resolve lang
      (Say.make ~ko:"[N] 새 대화 · [s] 전송 · [d] 삭제 · [[]/[]] 이력"
         ~en:"[N] New · [s] Send · [d] Delete · [[]/[]] History")
  in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      {
        (Card.default_spec ~title) with
        badge;
        hotkey = Some hotkey;
        focused = Model.pane_focused model 1;
      }
  in
  if Rect.is_empty inner then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = if inner.w >= 40 then 1 else 0 in
    let cx = inner.x + pad_x in
    let cw = Int.max 0 (inner.w - (2 * pad_x)) in
    let anchor_st = Typography.anchor ~bg theme in
    let primary_st = Typography.primary ~bg theme in
    let struct_st = Typography.structure ~bg theme in
    let whisper_st = Typography.whisper ~bg theme in
    let warn_st = Typography.status ~bg ~bold:true theme Theme.Status_attention in
    let crit_st = Typography.status ~bg ~bold:true theme Theme.Status_critical in
    let acc_st = Typography.accent ~bg ~bold:true theme in
    let footer_h = if inner.h >= 6 then 1 else 0 in
    let body_bottom = Rect.bottom inner - footer_h in
    let clip =
      Rect.make ~x:cx ~y:inner.y ~w:cw ~h:(Int.max 0 (body_bottom - inner.y))
    in
    let y = ref inner.y in
    let line_ok () = !y < body_bottom in
    let next_line () = y := !y + 1 in
    (match sel_keeper with
    | None ->
        if line_ok () then
          ignore
            (put_clipped grid ~clip ~x:cx ~y:!y ~style:whisper_st
               (Say.resolve lang
                  (Say.make
                     ~ko:"개인 키퍼를 선택하거나 [n]으로 새 개인 키퍼를 만드세요."
                     ~en:"Select a personal keeper or press [n] to create one.")))
    | Some k ->
        (* Keeper & Runtime header *)
        if line_ok () then begin
          let rt_desc =
            match k.runtime_id with
            | Some rt -> rt
            | None ->
                Say.resolve lang
                  (Say.make ~ko:"미배정 ([a]로 런타임 배정)"
                     ~en:"unassigned (press [a] to assign runtime)")
          in
          ignore
            (put_clipped grid ~clip ~x:cx ~y:!y ~style:anchor_st
               (Printf.sprintf "Keeper: %s   Runtime: %s" k.keeper_id rt_desc));
          next_line ()
        end;
        (* 2-step delete confirmation banner *)
        (match pk.delete_armed_conv_id with
        | Some cid when line_ok () ->
            let msg =
              Say.resolve lang
                (Say.make
                   ~ko:
                     (Printf.sprintf
                        "삭제 확인: 한 번 더 [d]를 누르면 %s 삭제 · [Esc] 취소"
                        cid)
                   ~en:
                     (Printf.sprintf
                        "Press [d] again to delete conversation %s, [Esc] to cancel"
                        cid))
            in
            ignore (put_clipped grid ~clip ~x:cx ~y:!y ~style:warn_st msg);
            next_line ()
        | Some _ | None -> ());
        (* Delete outcome / 503 recovery notice *)
        (match pk.last_delete_notice with
        | Some notice when line_ok () ->
            ignore
              (put_clipped grid ~clip ~x:cx ~y:!y ~style:warn_st
                 ("Delete status: " ^ scrub_single notice));
            next_line ()
        | Some _ | None -> ());
        (* Conversation 403 scope banner *)
        (match pk.conversation_forbidden with
        | Some detail when line_ok () ->
            ignore
              (put_clipped grid ~clip ~x:cx ~y:!y ~style:crit_st
                 (Glyph.to_utf8 Glyph.Locked
                  ^ " HTTP 403 (read_state + manage_own_keeper required): "
                  ^ scrub_single detail));
            next_line ()
        | Some _ | None -> ());
        (* Turn in-flight / last turn error *)
        (match pk.turn_in_flight with
        | Some (tk, preview) when String.equal tk k.keeper_id && line_ok () ->
            ignore
              (put_clipped grid ~clip ~x:cx ~y:!y ~style:acc_st
                 (Printf.sprintf "Sending turn... \"%s\" (up to 120s)"
                    (scrub_single preview)));
            next_line ()
        | Some _ | None -> ());
        (match pk.last_turn_error with
        | Some (tk, reason) when String.equal tk k.keeper_id && line_ok () ->
            ignore
              (put_clipped grid ~clip ~x:cx ~y:!y ~style:crit_st
                 ("Turn error: " ^ scrub_single reason));
            next_line ()
        | Some _ | None -> ());
        (* Conversation list + turns *)
        let snap_opt = Personal_keepers_store.conversation_for_selected pk in
        let ephemeral =
          Personal_keepers_store.ephemeral_turns_for ~keeper_id:k.keeper_id pk
        in
        (match snap_opt with
        | Some snap ->
            if snap.conversations <> [] && line_ok () then begin
              let max_list_rows = Int.min 4 (List.length snap.conversations) in
              let total = List.length snap.conversations in
              let start =
                if pk.selected_conv_idx >= max_list_rows then
                  Int.min (total - max_list_rows)
                    (pk.selected_conv_idx - max_list_rows + 1)
                else 0
              in
              List.iteri
                (fun i (c : Wire_personal_keepers.conversation_summary) ->
                  if i >= start && i < start + max_list_rows && line_ok () then begin
                    let is_sel = Int.equal i pk.selected_conv_idx in
                    let is_cur =
                      Option.equal String.equal snap.current_conversation_id
                        (Some c.conversation_id)
                    in
                    let tag =
                      match c.deletion with
                      | Wire_personal_keepers.Deletion_failed ->
                          "[DELETION FAILED — press d to retry]"
                      | Wire_personal_keepers.Deletion_kept ->
                          if is_cur then "[current]" else "[history]"
                    in
                    let st =
                      match c.deletion with
                      | Wire_personal_keepers.Deletion_failed -> crit_st
                      | Wire_personal_keepers.Deletion_kept ->
                          if is_sel then acc_st else struct_st
                    in
                    let pfx = if is_sel then "▸ " else "  " in
                    ignore
                      (put_clipped grid ~clip ~x:cx ~y:!y ~style:st
                         (Printf.sprintf "%s%s %s (%s)" pfx c.conversation_id tag
                            c.provider_account_id));
                    next_line ()
                  end)
                snap.conversations
            end;
            if line_ok () then begin
              let hdr =
                match snap.conversation_id with
                | Some cid -> "Turns · " ^ cid
                | None -> "Turns"
              in
              Card.draw_hairline ~pad_x ~label:hdr ~focused:false ~bg grid
                ~rect:inner ~y:!y ~theme;
              next_line ()
            end;
            let tlines =
              build_transcript_lines ~width:cw ~lang ~theme ~bg
                ~snap:(Some snap) ~ephemeral
            in
            let avail = Int.max 0 (body_bottom - !y) in
            let max_scroll = Int.max 0 (List.length tlines - avail) in
            let scroll = Int.min max_scroll (Int.max 0 pk.transcript_scroll) in
            List.iteri
              (fun idx (st, text) ->
                if idx >= scroll && line_ok () then begin
                  ignore (put_clipped grid ~clip ~x:cx ~y:!y ~style:st text);
                  next_line ()
                end)
              tlines
        | None -> (
            (match pk.conversation with
            | Observed.Loading _ when line_ok () ->
                ignore
                  (put_clipped grid ~clip ~x:cx ~y:!y ~style:whisper_st
                     "Conversation: loading...");
                next_line ()
            | Observed.Failed { reason; _ } when line_ok () ->
                ignore
                  (put_clipped grid ~clip ~x:cx ~y:!y ~style:warn_st
                     ("Conversation error: " ^ scrub_single reason));
                next_line ()
            | Observed.Loading _
            | Observed.Failed _
            | Observed.Value _
            | Observed.Absent
            | Observed.Unreported ->
                ());
            if ephemeral <> [] then begin
              let tlines =
                build_transcript_lines ~width:cw ~lang ~theme ~bg ~snap:None
                  ~ephemeral
              in
              List.iter
                (fun (st, text) ->
                  if line_ok () then begin
                    ignore (put_clipped grid ~clip ~x:cx ~y:!y ~style:st text);
                    next_line ()
                  end)
                tlines
            end)));
    ignore primary_st;
    if footer_h > 0 then begin
      let fy = Rect.bottom inner - 1 in
      let fclip = Rect.make ~x:cx ~y:fy ~w:cw ~h:1 in
      let bar =
        Say.resolve lang
          (Say.make
             ~ko:"[N] 새 대화  [s] 메시지 전송  [d] 대화 삭제(2회)  [[]/[]] 대화 전환"
             ~en:"[N] New Conv  [s] Send Turn  [d] Delete (2x)  [[]/[]] Switch Conv")
      in
      ignore (put_clipped grid ~clip:fclip ~x:cx ~y:fy ~style:acc_st bar)
    end

let render ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Ops_common.theme_of_model model in
    match Rbac.decide model.auth_session Rbac.Multi_account_own_keeper with
    | Rbac.Denied reason ->
        Masc_tui_screens_core.Render_util.draw_locked_panel grid ~cache ~rect
          ~theme ~model
          ~title:(Say.make ~ko:"개인 키퍼" ~en:"Personal Keepers")
          ~reason
    | Rbac.Allowed ->
        if rect.w >= 88 then begin
          let gap =
            match model.breakpoint with
            | Model.Wide -> 2
            | Model.Standard | Model.Compact | Model.Micro -> 1
          in
          let avail = Int.max 0 (rect.w - gap) in
          let lw = Int.max 28 (Int.min (avail - 36) (avail * 36 / 100)) in
          let lw = Int.max 0 (Int.min avail lw) in
          let rw = Int.max 0 (avail - lw) in
          let left_r = Rect.make ~x:rect.x ~y:rect.y ~w:lw ~h:rect.h in
          let right_r =
            Rect.make ~x:(rect.x + lw + gap) ~y:rect.y ~w:rw ~h:rect.h
          in
          render_left_pane ~model ~cache ~rect:left_r ~theme grid;
          render_right_pane ~model ~cache ~rect:right_r ~theme grid
        end
        else begin
          let top_h = Int.max 6 (rect.h * 42 / 100) in
          let bot_h = Int.max 0 (rect.h - top_h) in
          let top_r = Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:top_h in
          let bot_r =
            Rect.make ~x:rect.x ~y:(rect.y + top_h) ~w:rect.w ~h:bot_h
          in
          render_left_pane ~model ~cache ~rect:top_r ~theme grid;
          render_right_pane ~model ~cache ~rect:bot_r ~theme grid
        end
