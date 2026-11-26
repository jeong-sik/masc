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
          ignore
            (Cell_grid.put_text ~clip:rect grid ~x:rect.x ~y:(rect.y + i)
               ~style:(Typography.status ~bg theme tone) (Say.resolve lang label)))
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
  let lookup_keeper = target_keeper_of_model m in
  let target_keeper = display_target_keeper_of_model m in
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
  if (not (Float.is_finite ts)) || ts <= 0.0 then None
  else
    let secs = Int64.add (Int64.of_float (Float.floor ts)) (Int64.of_int tz_offset_sec) in
    let day_s =
      let r = Int64.rem secs 86400L in
      Int64.to_int (if Int64.compare r 0L < 0 then Int64.add r 86400L else r)
    in
    let h = day_s / 3600 in
    let m = (day_s mod 3600) / 60 in
    Some (Printf.sprintf "%02d:%02d" h m)

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

let draw_hline ?clip grid ~x ~y ~w ~style =
  if w > 0 then
    for dx = 0 to w - 1 do
      Cell_grid.put_glyph ?clip grid ~x:(x + dx) ~y ~style Glyph.Box_h
    done

let draw_pill ?clip grid ~x ~y ~fg ~bg ?(bold = false) text =
  if String.length text = 0 then 0
  else
    let attrs = if bold then Attr.bold else Attr.none in
    let style = Style.make ~fg ~bg ~attrs () in
    let padded = " " ^ text ^ " " in
    Cell_grid.put_text ?clip grid ~x ~y ~style padded

let extract_embedded_json = Update_nav.extract_embedded_json

let is_ident_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false

let is_ws = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false

let is_value_delim = function
  | ' ' | '\t' | '\n' | '\r' | ',' | '}' | ']' | ';' | '"' | '\'' | '?' | '&' ->
      true
  | _ -> false

let redact_plain_text_secrets raw =
  let len = String.length raw in
  let buf = Buffer.create len in
  let rec skip_ws i = if i < len && is_ws raw.[i] then skip_ws (i + 1) else i in
  let rec skip_quoted_string i =
    if i >= len then len
    else if Char.equal raw.[i] '\\' && i + 1 < len then
      skip_quoted_string (i + 2)
    else if Char.equal raw.[i] '"' then i + 1
    else skip_quoted_string (i + 1)
  in
  let rec skip_unquoted_value i =
    if i >= len || is_value_delim raw.[i] then i
    else skip_unquoted_value (i + 1)
  in
  let rec find_substr ~needle from =
    let nlen = String.length needle in
    if nlen = 0 || from + nlen > len then None
    else if String.equal (String.sub raw from nlen) needle then Some from
    else find_substr ~needle (from + 1)
  in
  let rec scan_plain_quoted ~quoted_end i =
    if i < quoted_end then begin
      (* Already inside a previously measured quoted span (e.g. an escaped
         quote or the closing quote): emit the char and keep scanning inside
         without re-running [skip_quoted_string], preserving O(N) runtime
         while still redacting embedded key=value / Bearer / PEM secrets. *)
      Buffer.add_char buf '"';
      scan ~quoted_end (i + 1)
    end
    else
      let str_end = skip_quoted_string (i + 1) in
      let has_closing_quote =
        str_end > i + 1 && Char.equal raw.[str_end - 1] '"'
      in
      let inner_len =
        if has_closing_quote then str_end - i - 2 else str_end - i - 1
      in
      let inner =
        if inner_len > 0 then String.sub raw (i + 1) inner_len else ""
      in
      if Json_tree.is_secret_value inner then begin
        Buffer.add_string buf "\"[redacted]\"";
        scan ~quoted_end:str_end str_end
      end
      else begin
        Buffer.add_char buf '"';
        scan ~quoted_end:str_end (i + 1)
      end
  and scan ~quoted_end i =
    if i >= len then ()
    else if
      i + 11 <= len && String.equal (String.sub raw i 11) "-----BEGIN "
      && contains_ci ~needle:"PRIVATE KEY"
           (String.sub raw i (Int.min 64 (len - i)))
    then begin
      Buffer.add_string buf "[redacted]";
      match find_substr ~needle:"-----END " (i + 11) with
      | Some end_hdr -> (
          match find_substr ~needle:"-----" (end_hdr + 9) with
          | Some close_dashes -> scan ~quoted_end (close_dashes + 5)
          | None -> ())
      | None -> ()
    end
    else if Char.equal raw.[i] '"' then begin
      (* Check quoted key: "secret_key" : value *)
      let k_start = i + 1 in
      let rec scan_key j =
        if j < len && is_ident_char raw.[j] then scan_key (j + 1) else j
      in
      let k_end = scan_key k_start in
      if k_end > k_start && k_end < len && Char.equal raw.[k_end] '"' then
        let key = String.sub raw k_start (k_end - k_start) in
        let after_q = skip_ws (k_end + 1) in
        if
          after_q < len
          && (Char.equal raw.[after_q] ':' || Char.equal raw.[after_q] '=')
          && Json_tree.is_secret_key key
        then begin
          Buffer.add_substring buf raw i (after_q - i + 1);
          let v_start = skip_ws (after_q + 1) in
          if v_start > after_q + 1 then Buffer.add_char buf ' ';
          if v_start >= len then ()
          else if Char.equal raw.[v_start] '"' then begin
            Buffer.add_string buf "\"[redacted]\"";
            let v_end = skip_quoted_string (v_start + 1) in
            scan ~quoted_end:(Int.max quoted_end v_end) v_end
          end
          else begin
            Buffer.add_string buf "[redacted]";
            scan ~quoted_end (skip_unquoted_value v_start)
          end
        end
        else scan_plain_quoted ~quoted_end i
      else scan_plain_quoted ~quoted_end i
    end
    else if is_ident_char raw.[i] then begin
      let t_end = skip_unquoted_value i in
      let k_end =
        let rec go j =
          if j < len && is_ident_char raw.[j] then go (j + 1) else j
        in
        go i
      in
      let key = String.sub raw i (k_end - i) in
      let after_k = skip_ws k_end in
      if
        after_k < len
        && (Char.equal raw.[after_k] '=' || Char.equal raw.[after_k] ':')
        && Json_tree.is_secret_key key
      then begin
        Buffer.add_substring buf raw i (after_k - i + 1);
        let v_start = skip_ws (after_k + 1) in
        if v_start > after_k + 1 then Buffer.add_char buf ' ';
        if v_start >= len then ()
        else if Char.equal raw.[v_start] '"' then begin
          Buffer.add_string buf "\"[redacted]\"";
          let v_end = skip_quoted_string (v_start + 1) in
          scan ~quoted_end:(Int.max quoted_end v_end) v_end
        end
        else begin
          let v1_end = skip_unquoted_value v_start in
          let first_word =
            String.lowercase_ascii (String.sub raw v_start (v1_end - v_start))
          in
          let final_end =
            if String.equal first_word "bearer" || String.equal first_word "basic"
            then
              let v2_start = skip_ws v1_end in
              skip_unquoted_value v2_start
            else v1_end
          in
          Buffer.add_string buf "[redacted]";
          scan ~quoted_end final_end
        end
      end
      else if
        String.equal (String.lowercase_ascii key) "bearer"
        && k_end < len && is_ws raw.[k_end]
      then begin
        let tok_start = skip_ws k_end in
        let tok_end = skip_unquoted_value tok_start in
        if tok_end > tok_start then begin
          Buffer.add_string buf "Bearer [redacted]";
          scan ~quoted_end tok_end
        end
        else begin
          Buffer.add_substring buf raw i (k_end - i);
          scan ~quoted_end k_end
        end
      end
      else begin
        let token = String.sub raw i (t_end - i) in
        if Json_tree.is_secret_value token then begin
          Buffer.add_string buf "[redacted]";
          scan ~quoted_end t_end
        end
        else begin
          Buffer.add_substring buf raw i (t_end - i);
          scan ~quoted_end t_end
        end
      end
    end
    else begin
      Buffer.add_char buf raw.[i];
      scan ~quoted_end (i + 1)
    end
  in
  scan ~quoted_end:0 0;
  Buffer.contents buf

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
