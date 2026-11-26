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

let utf8_scalars_lower s =
  let len = String.length s in
  let acc = ref [] in
  let i = ref 0 in
  while !i < len do
    let d = String.get_utf_8_uchar s !i in
    let step = Uchar.utf_decode_length d in
    let code = Uchar.to_int (Uchar.utf_decode_uchar d) in
    let folded = if code >= 65 && code <= 90 then code + 32 else code in
    acc := folded :: !acc;
    i := !i + Int.max 1 step
  done;
  Array.of_list (List.rev !acc)

let fuzzy_score ~query target =
  let q_raw = String.trim query in
  if String.equal q_raw "" then Some 100
  else
    let q = utf8_scalars_lower q_raw in
    let t = utf8_scalars_lower target in
    let q_len = Array.length q in
    let t_len = Array.length t in
    if q_len > t_len then None
    else if
      Int.equal q_len t_len
      &&
      let rec eq i =
        i >= q_len || (Int.equal q.(i) t.(i) && eq (i + 1))
      in
      eq 0
    then Some 1000
    else if
      let rec pref i =
        i >= q_len || (Int.equal q.(i) t.(i) && pref (i + 1))
      in
      pref 0
    then Some (800 - (t_len - q_len))
    else if
      let rec has_sub start =
        if start + q_len > t_len then false
        else
          let rec eq i =
            i >= q_len || (Int.equal q.(i) t.(start + i) && eq (i + 1))
          in
          if eq 0 then true else has_sub (start + 1)
      in
      has_sub 0
    then Some (500 - (t_len - q_len))
    else
      let rec match_seq qi ti score consecutive =
        if qi >= q_len then Some (Int.max 1 score)
        else if ti >= t_len then None
        else if Int.equal q.(qi) t.(ti) then
          let bonus = if consecutive then 12 else 4 in
          let start_bonus = if ti = 0 then 10 else 0 in
          match_seq (qi + 1) (ti + 1) (score + bonus + start_bonus) true
        else match_seq qi (ti + 1) (score - 1) false
      in
      match_seq 0 0 100 false

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

let dim_backdrop grid ~(rect : Rect.t) ~(theme : Theme.t) =
  let bounds = Rect.intersect rect (Cell_grid.bounds grid) in
  if not (Rect.is_empty bounds) then
    let dim_fg = Color.of_rgb theme.text_muted in
    let dim_bg = Color.of_rgb theme.surface_0 in
    for y = bounds.y to Rect.bottom bounds - 1 do
      for x = bounds.x to Rect.right bounds - 1 do
        let c = Cell_grid.get grid ~x ~y in
        match c.glyph with
        | Cell_grid.Continuation -> ()
        | Cell_grid.Empty
        | Cell_grid.Ascii _
        | Cell_grid.Braille _
        | Cell_grid.Utf8 _ ->
            let style =
              Style.make ~fg:dim_fg ~bg:dim_bg ~attrs:Attr.none ()
            in
            Cell_grid.set_cell ~clip:bounds grid ~x ~y { c with style }
      done
    done

let parse_json_struct_only s =
  match Yojson.Safe.from_string s with
  | (`Assoc _ | `List _) as json -> Some json
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> None
  | exception Yojson.Json_error _ -> None

let strip_trailing_colon s =
  let t = String.trim s in
  let len = String.length t in
  if len > 0 && Char.equal t.[len - 1] ':' then
    String.trim (String.sub t 0 (len - 1))
  else t

let max_embedded_json_bytes = 262_144
let max_embedded_json_attempts = 8

let extract_embedded_json raw =
  let trimmed = String.trim raw in
  let len = String.length trimmed in
  if len < 2 || len > max_embedded_json_bytes then None
  else
    let rec try_from attempts i =
      if i >= len || attempts >= max_embedded_json_attempts then None
      else if Char.equal trimmed.[i] '{' || Char.equal trimmed.[i] '[' then
        let candidate = String.sub trimmed i (len - i) in
        match parse_json_struct_only candidate with
        | Some json ->
            let prefix =
              if i = 0 then ""
              else strip_trailing_colon (String.sub trimmed 0 i)
            in
            let prefix_opt =
              if String.equal prefix "" then None else Some prefix
            in
            Some (prefix_opt, json)
        | None -> try_from (attempts + 1) (i + 1)
      else try_from attempts (i + 1)
    in
    try_from 0 0

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
