open Masc_tui_core
open Masc_tui_keymap
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let layout_breakpoint_of_model = function
  | Model.Wide -> Layout.Wide
  | Model.Standard -> Layout.Standard
  | Model.Compact -> Layout.Compact
  | Model.Micro -> Layout.Micro

let target_keeper_of_model (m : Model.t) =
  match Model.target_keeper m with
  | Some k -> k
  | None -> Drafts.target_keeper_key m.drafts

let display_target_keeper_of_model (m : Model.t) =
  match Model.target_keeper m with
  | Some k -> k
  | None -> Say.resolve m.lang (Say.make ~ko:"미선택" ~en:"none")

type sandbox_fallback_source = Fleet_snapshot | Keeper_roster

let draw_sandbox_detail_notice grid ~(rect : Rect.t) ~theme ~lang
    ~(read : Infra_store.keeper_sandbox_read) ~fallback =
  let source =
    match fallback with
    | Some Fleet_snapshot -> [ Say.make ~ko:"플릿 스냅샷" ~en:"Fleet snapshot" ]
    | Some Keeper_roster -> [ Say.make ~ko:"키퍼 목록 기반" ~en:"From Keeper roster" ]
    | None ->
        if Option.is_some (Infra_store.keeper_sandbox_detail read) then
          [ Say.make ~ko:"마지막 상세 관측" ~en:"Last detail observed" ]
        else []
  in
  let notice tone label details =
    let body =
      match source @ details with
      | [] -> []
      | items -> [ (Say.concat ~sep:" · " items, tone) ]
    in
    (label, tone) :: body
  in
  let retry label =
    Say.concat ~sep:" · " [ label; Say.make ~ko:"[r] 재시도" ~en:"[r] Retry" ]
  in
  let rows =
    match read.requested_at, read.observation with
    | Some _, _ | None, Observed.Loading _ ->
        notice Theme.Status_active
          (Say.make ~ko:"상세 조회 중…" ~en:"Reading detail…") []
    | None, Observed.Absent ->
        notice Theme.Status_historical
          (retry (Say.make ~ko:"상세 없음" ~en:"No detail")) []
    | None, Observed.Unreported ->
        notice Theme.Status_historical
          (Say.make ~ko:"상세 조회 전" ~en:"Detail awaits a read") []
    | None, Observed.Failed { reason; _ } ->
        notice Theme.Status_critical
          (retry (Say.make ~ko:"상세 조회 실패" ~en:"Detail read failed"))
          [ Say.literal reason ]
    | None, Observed.Value { stale = true; _ } ->
        [ (Say.make ~ko:"마지막 상세 관측" ~en:"Last detail observed", Theme.Status_historical) ]
    | None, Observed.Value { stale = false; _ } -> []
  in
  if Rect.is_empty rect then 0
  else
    let height =
      Int.min rect.h
        (Infra_store.keeper_sandbox_notice_rows ~has_displayed_rows:(source <> []) read)
    in
    let bg = Color.of_rgb theme.Theme.surface_1 in
    List.iteri
      (fun i (label, tone) ->
        if i < height then
          let fitted =
            Grapheme.truncate_to_width ~max_width:rect.w (Say.resolve lang label)
          in
          ignore
            (Cell_grid.put_text ~clip:rect grid ~x:rect.x ~y:(rect.y + i)
               ~style:(Typography.status ~bg theme tone) fitted))
      rows;
    height

let voice_state_of_drafts (drafts : Drafts.t) =
  match drafts.voice with
  | Drafts.Voice_off | Drafts.Voice_error _ ->
      Composer.Voice_off
  | Drafts.Voice_recording { levels; elapsed_s; _ } ->
      Composer.Voice_recording { levels = Array.of_list levels; elapsed_s }
  | Drafts.Voice_transcribing -> Composer.Voice_transcribing

let contains_ci = Text_util.contains_ci

let popup_of_draft (m : Model.t) (_draft : Drafts.keeper_draft) =
  let to_item (c : Update_nav.popup_candidate) : Composer.popup_item =
    { Composer.trigger = c.trigger; label = c.label; detail = c.detail }
  in
  match Update_nav.resolve_composer_popup m with
  | Update_nav.Composer_popup_none -> Composer.Popup_none
  | Update_nav.Composer_popup_slash { query; items; selected } ->
      Composer.Popup_slash { query; items = List.map to_item items; selected }
  | Update_nav.Composer_popup_mention { query; items; selected } ->
      Composer.Popup_mention { query; items = List.map to_item items; selected }

let composer_state_of_model (m : Model.t) : Composer.state =
  let tk_opt = Model.target_keeper m in
  let lookup_keeper =
    match tk_opt with Some k -> k | None -> Drafts.target_keeper_key m.drafts
  in
  let target_keeper =
    match tk_opt with
    | Some k -> k
    | None -> Say.resolve m.lang (Say.make ~ko:"미선택" ~en:"none")
  in
  let draft = Drafts.current_draft m.drafts in
  let phase = Chat_transcript.live_chat_phase ~model:m ~keeper:lookup_keeper in
  {
    Composer.target_keeper;
    draft = draft.text;
    cursor = draft.cursor;
    focused = Drafts.is_focused m.drafts;
    pending_tx = Chat_transcript.composer_pending_tx_of_phase phase;
    voice = voice_state_of_drafts m.drafts;
    popup = popup_of_draft m draft;
    draft_count_other_keepers = Drafts.other_keepers_draft_count m.drafts;
  }

let snapshot_age_str ~(model : Model.t) (obs_opt : Clock.Mono.t option) =
  match obs_opt with
  | None -> None
  | Some obs ->
      if Clock.Mono.equal obs Clock.Mono.zero then None
      else if Clock.Mono.compare model.freshness.last_mono obs >= 0 then
        let age_s = Clock.Mono.seconds_since model.freshness.last_mono ~since:obs in
        Some (Format_val.format_duration_s (Float.max 0.0 age_s))
      else None

let freshness_pill ~(model : Model.t) ~compact =
  let lang = model.lang in
  let mismatch =
    match model.server_identity.mismatch_state with
    | Model.Mismatch_none -> false
    | Model.Mismatch_recovering | Model.Mismatch_halted -> true
  in
  if mismatch then
    let lbl =
      Say.resolve lang
        (if compact then Say.make ~ko:"불일치" ~en:"MISMATCH"
         else Say.make ~ko:"워크스페이스 불일치" ~en:"MISMATCH")
    in
    (Glyph.Transport_stale, lbl, Theme.Status_critical)
  else if model.freshness.server_offline then
    let lbl = Say.resolve lang (Say.make ~ko:"오프라인" ~en:"OFFLINE") in
    (Glyph.Live_idle, lbl, Theme.Status_critical)
  else
    let fleet_degraded_pill () =
      let lbl =
        Say.resolve lang
          (if compact then Say.make ~ko:"저하" ~en:"DEGR"
           else Say.make ~ko:"플리트 저하" ~en:"DEGRADED")
      in
      (Glyph.Transport_stale, lbl, Theme.Status_attention)
    in
    let is_degraded = Option.is_some model.fleet.fleet_degradation in
    match Model.active_view_ssot_mode model with
    | Model.Live_sse { freshness; live_count; planned_count; _ } -> (
        match freshness with
        | Health.Disconnected _ ->
            let lbl = Say.resolve lang (Say.make ~ko:"오프라인" ~en:"OFFLINE") in
            (Glyph.Live_idle, lbl, Theme.Status_critical)
        | Health.Workspace_mismatch _ ->
            let lbl = Say.resolve lang (Say.make ~ko:"불일치" ~en:"MISMATCH") in
            (Glyph.Transport_stale, lbl, Theme.Status_critical)
        | Health.Live _ when is_degraded -> fleet_degraded_pill ()
        | Health.Live _ ->
            let lbl =
              if compact then Say.resolve lang (Say.make ~ko:"LIVE" ~en:"LIVE")
              else Printf.sprintf "LIVE SSE %d/%d" live_count planned_count
            in
            (Glyph.Live_healthy, lbl, Theme.Status_ok)
        | Health.Connecting ->
            let lbl =
              Say.resolve lang
                (if compact then Say.make ~ko:"연결" ~en:"SYNC"
                 else Say.make ~ko:"연결 중" ~en:"CONNECTING")
            in
            (Glyph.Transport_reconnecting, lbl, Theme.Status_active)
        | Health.Reconnecting { attempt; _ } ->
            let lbl =
              Say.resolve lang
                (if compact then Say.make ~ko:"재연결" ~en:"RECON"
                 else
                   Say.make
                     ~ko:(Printf.sprintf "재연결 #%d" attempt)
                     ~en:(Printf.sprintf "RECON #%d" attempt))
            in
            (Glyph.Transport_reconnecting, lbl, Theme.Status_attention)
        | Health.Stale { age_sec; _ } ->
            let lbl =
              if compact then Say.resolve lang (Say.make ~ko:"지연" ~en:"STALE")
              else
                Printf.sprintf "%s %s"
                  (Say.resolve lang (Say.make ~ko:"지연" ~en:"STALE"))
                  (Format_val.format_duration_s age_sec)
            in
            (Glyph.Transport_stale, lbl, Theme.Status_attention))
    | Model.Synced_snapshot { observer; observed_at } -> (
        let age_suffix =
          match snapshot_age_str ~model observed_at with
          | Some a -> " " ^ Glyph.to_utf8 Glyph.Separator_dot ^ " " ^ a
          | None -> ""
        in
        match observer with
        | Health.Disconnected _ ->
            let lbl = Say.resolve lang (Say.make ~ko:"오프라인" ~en:"OFFLINE") in
            (Glyph.Live_idle, lbl, Theme.Status_critical)
        | Health.Workspace_mismatch _ ->
            let lbl = Say.resolve lang (Say.make ~ko:"불일치" ~en:"MISMATCH") in
            (Glyph.Transport_stale, lbl, Theme.Status_critical)
        | Health.Live _ when is_degraded -> fleet_degraded_pill ()
        | Health.Live _ ->
            let lbl =
              if compact then Say.resolve lang (Say.make ~ko:"동기화" ~en:"SYNCED")
              else
                Say.resolve lang (Say.make ~ko:"동기화" ~en:"SYNCED") ^ age_suffix
            in
            (Glyph.Live_working, lbl, Theme.Status_active)
        | Health.Connecting ->
            let lbl =
              Say.resolve lang
                (if compact then Say.make ~ko:"연결" ~en:"SYNC"
                 else Say.make ~ko:"동기화 중" ~en:"SYNCING")
            in
            (Glyph.Transport_reconnecting, lbl, Theme.Status_active)
        | Health.Reconnecting { attempt; _ } ->
            let lbl =
              if compact then Say.resolve lang (Say.make ~ko:"재연결" ~en:"RECON")
              else
                Printf.sprintf "%s #%d"
                  (Say.resolve lang (Say.make ~ko:"재연결" ~en:"RECON"))
                  attempt
            in
            (Glyph.Transport_reconnecting, lbl, Theme.Status_attention)
        | Health.Stale { age_sec; _ } ->
            let lbl =
              if compact then Say.resolve lang (Say.make ~ko:"지연" ~en:"STALE")
              else
                Printf.sprintf "%s %s"
                  (Say.resolve lang (Say.make ~ko:"동기화 지연" ~en:"SYNCED STALE"))
                  (Format_val.format_duration_s age_sec)
            in
            (Glyph.Transport_stale, lbl, Theme.Status_attention))
    | Model.Snapshot_only { observed_at } ->
        let lbl =
          if compact then Say.resolve lang (Say.make ~ko:"스냅샷" ~en:"SNAP")
          else
            match snapshot_age_str ~model observed_at with
            | Some a ->
                Printf.sprintf "%s %s %s r"
                  (Say.resolve lang (Say.make ~ko:"스냅샷" ~en:"SNAPSHOT"))
                  a
                  (Glyph.to_utf8 Glyph.Separator_dot)
            | None ->
                Printf.sprintf "%s %s r"
                  (Say.resolve lang (Say.make ~ko:"스냅샷" ~en:"SNAPSHOT"))
                  (Glyph.to_utf8 Glyph.Separator_dot)
        in
        (Glyph.Live_idle, lbl, Theme.Status_historical)

let attention_kind_tag = function
  | Health.Pending_ask _ -> Say.make ~ko:"질문" ~en:"ASK"
  | Health.Held_tool_approval _ -> Say.make ~ko:"도구" ~en:"TOOL"
  | Health.Goal_confirmation _ -> Say.make ~ko:"목표" ~en:"GOAL"

let attention_kind_keeper = function
  | Health.Pending_ask { keeper; _ } | Health.Held_tool_approval { keeper; _ } ->
      Some keeper
  | Health.Goal_confirmation _ -> None

let keeper_health_glyph_and_tone = function
  | Wire_fleet.Keeper_healthy -> (Glyph.Live_healthy, Theme.Status_ok)
  | Wire_fleet.Keeper_working -> (Glyph.Live_working, Theme.Status_active)
  | Wire_fleet.Keeper_idle -> (Glyph.Live_idle, Theme.Status_historical)
  | Wire_fleet.Keeper_degraded -> (Glyph.Warning_triangle, Theme.Status_attention)
  | Wire_fleet.Keeper_recovering | Wire_fleet.Keeper_booting ->
      (Glyph.Transport_reconnecting, Theme.Status_active)
  | Wire_fleet.Keeper_failing | Wire_fleet.Keeper_offline ->
      (Glyph.Live_failing, Theme.Status_critical)
  | Wire_fleet.Keeper_paused -> (Glyph.Live_paused, Theme.Status_historical)

let format_hhmm_with_offset ~tz_offset_sec ts =
  Format_val.format_hhmm_opt ~tz_offset_sec ts

let format_hhmm_utc ts = format_hhmm_with_offset ~tz_offset_sec:0 ts

let format_relative_age ~now_unix ~at_unix =
  if
    (not (Float.is_finite now_unix))
    || (not (Float.is_finite at_unix))
    || now_unix <= 0.0
    || at_unix <= 0.0
  then None
  else
    let diff = Float.max 0.0 (now_unix -. at_unix) in
    Some (Format_val.format_duration_s diff)

let format_milli_candles raw =
  let trimmed = String.trim raw in
  match float_of_string_opt trimmed with
  | Some v when Float.is_finite v ->
      Format_val.format_value Format_val.Candles (v /. 1000.0)
  | Some _ | None ->
      if String.equal trimmed "" then Glyph.to_utf8 Glyph.Missing_absent
      else trimmed ^ " C"

let box_h_glyph = Cell_grid.Utf8 (Glyph.to_utf8 Glyph.Box_h)

let draw_hline ?clip grid ~x ~y ~w ~style =
  if w > 0 then
    Cell_grid.fill_rect ?clip grid ~rect:(Rect.make ~x ~y ~w ~h:1) ~style
      ~glyph:box_h_glyph ()

let draw_pill ?clip grid ~x ~y ~fg ~bg ?(bold = false) text =
  if String.length text = 0 then 0
  else
    let attrs = if bold then Attr.bold else Attr.none in
    let style = Style.make ~fg ~bg ~attrs () in
    let padded = " " ^ text ^ " " in
    Cell_grid.put_text ?clip grid ~x ~y ~style padded

let extract_embedded_json = Update_nav.extract_embedded_json

let redact_plain_text_secrets = Chat_transcript.scrub_secrets_in_text

let string_of_transport_error ~lang = function
  | Health.Connect_refused ->
      Say.resolve lang (Say.make ~ko:"연결 거부됨 (서버 중지)" ~en:"Connection refused (server stopped)")
  | Health.Timeout ->
      Say.resolve lang (Say.make ~ko:"요청 시간 초과" ~en:"Request timed out")
  | Health.Timeout_detail { phase; after_sec; path } ->
      Say.resolve lang (Health.timeout_detail_say ~phase ~after_sec ~path)
  | Health.Http_status code ->
      Say.resolve lang
        (Say.make
           ~ko:(Printf.sprintf "HTTP 오류 (%d)" code)
           ~en:(Printf.sprintf "HTTP error (%d)" code))
  | Health.Stream_eof ->
      Say.resolve lang (Say.make ~ko:"SSE 스트림 종료됨" ~en:"SSE stream closed (EOF)")
  | Health.Protocol_error msg ->
      Say.resolve lang
        (Say.make
           ~ko:("프로토콜 오류: " ^ msg)
           ~en:("Protocol error: " ^ msg))
  | Health.Other_io msg ->
      Say.resolve lang
        (Say.make ~ko:("I/O 오류: " ^ msg) ~en:("I/O error: " ^ msg))

let draw_locked_panel grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~(title : Say.t) ~(reason : Rbac.deny_reason) =
  if Rect.is_empty rect then ()
  else
    let lang = model.lang in
    let title_s = Say.resolve lang title in
    let badge_text =
      Say.resolve lang (Say.make ~ko:"제한됨" ~en:"LOCKED")
    in
    let inner =
      Card.draw ~cache grid ~rect ~theme
        {
          (Card.default_spec ~title:title_s) with
          badge =
            Some
              {
                glyph = Some Glyph.Locked;
                text = badge_text;
                tone = Some Theme.Status_attention;
              };
          focused = true;
          elevated = false;
        }
    in
    if not (Rect.is_empty inner) then begin
      let bg = Color.of_rgb theme.surface_1 in
      let attn_st =
        Typography.status ~bg ~bold:true theme Theme.Status_attention
      in
      let pri_st = Typography.primary ~bg theme in
      let whisper_st = Typography.whisper ~bg theme in
      let session_s =
        Say.resolve lang (Rbac.session_badge ~compact:false model.auth_session)
      in
      let actor_suffix =
        match model.auth_session with
        | Rbac.Single_user_local { effective_agent = Some agent; _ } ->
            " (" ^ agent ^ ")"
        | Rbac.Multi_account_signed_in { principal; _ } ->
            Printf.sprintf " (%s:%s)"
              (Rbac.principal_kind_to_string principal.kind)
              principal.id
        | Rbac.Single_user_local { effective_agent = None; _ }
        | Rbac.Probing_health
        | Rbac.Probing_single_user _
        | Rbac.Probing_multi_account _
        | Rbac.Single_user_auth_required _
        | Rbac.Multi_account_signed_out _
        | Rbac.Auth_unavailable _ ->
            ""
      in
      let session_line =
        Say.resolve lang
          (Say.make
             ~ko:("현재 세션: " ^ session_s ^ actor_suffix)
             ~en:("Current session: " ^ session_s ^ actor_suffix))
      in
      let hint_line =
        match reason with
        | Rbac.Pat_cannot_admin ->
            Say.resolve lang
              (Say.make
                 ~ko:"다중 계정 PAT는 관리자 권한을 가질 수 없습니다. 웹 콘솔 브라우저 세션에서 관리자 작업을 수행하세요."
                 ~en:"Multi-account PATs cannot hold admin permissions. Use a browser admin session in the web console.")
        | Rbac.Single_user_only_in_multi_account ->
            Say.resolve lang
              (Say.make
                 ~ko:"다중 계정 서버에서는 브리지된 워크스페이스 조회 경로만 제공됩니다."
                 ~en:"Multi-account mode serves bridged workspace read routes only.")
        | Rbac.Token_auth_not_enabled ->
            Say.resolve lang
              (Say.make
                 ~ko:"서버 워크스페이스 인증(auth.enabled=true, require_token=true)과 관리자 토큰이 필요합니다."
                 ~en:"Requires server workspace auth (auth.enabled=true, require_token=true) with an admin token.")
        | Rbac.Requires_admin ->
            Say.resolve lang
              (Say.make
                 ~ko:"관리자 토큰으로 연결하거나 [1-5]의 허용된 워크스페이스를 사용하세요."
                 ~en:"Connect with an admin token or switch to an allowed workspace ([1-5]).")
        | Rbac.Probing_auth
        | Rbac.Auth_required _
        | Rbac.Service_cannot_manage_own_provider
        | Rbac.Requires_worker_or_admin
        | Rbac.Multi_account_only_in_single_user ->
            Say.resolve lang
              (Say.make ~ko:"[r] 세션 다시 확인 · [?] 허용된 단축키 보기"
                 ~en:"[r] Re-check session · [?] View allowed keybindings")
      in
      let lines =
        [
          (attn_st, Glyph.to_utf8 Glyph.Locked ^ " " ^ Say.resolve lang (Rbac.deny_reason_say reason));
          (pri_st, session_line);
          (whisper_st, "");
          (whisper_st, hint_line);
        ]
      in
      let pad_x = if inner.w >= 48 then 2 else 1 in
      let body = Card.pad_inner ~pad_x inner in
      if not (Rect.is_empty body) then begin
        let rail_h = Int.min (List.length lines) body.h in
        if rail_h > 0 then
          Card.draw_left_rail ~bg
            ~color:(Theme.status_color theme Theme.Status_attention)
            grid ~x:body.x ~y:body.y ~h:rail_h ~theme;
        let text_x = body.x + 2 in
        let text_w = Int.max 0 (body.w - 2) in
        List.iteri
          (fun idx (st, txt) ->
            let y = body.y + idx in
            if y < Rect.bottom body && text_w > 0 then
              let row_clip = Rect.make ~x:text_x ~y ~w:text_w ~h:1 in
              ignore
                (Cell_grid.put_text ~clip:row_clip grid ~x:text_x ~y ~style:st
                   (Grapheme.truncate_to_width ~max_width:text_w txt)))
          lines
      end
    end
