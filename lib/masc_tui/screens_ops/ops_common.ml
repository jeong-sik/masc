open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let theme_of_model (model : Model.t) = Theme.of_preset model.theme_preset
let default_caps = Presenter.default_capabilities
let say (model : Model.t) ~ko ~en = Say.resolve model.lang (Say.make ~ko ~en)

let layout_bp (model : Model.t) =
  match model.breakpoint with
  | Model.Wide -> Layout.Wide
  | Model.Standard -> Layout.Standard
  | Model.Compact -> Layout.Compact
  | Model.Micro -> Layout.Micro

let pad_x_for ~(model : Model.t) (rect : Rect.t) =
  Layout.card_pad_x_for_width (layout_bp model) rect.w

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

let put_line ?clip grid ~x ~y ~max_w ~style text =
  if max_w <= 0 then 0
  else
    let clean =
      String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c) text
    in
    let fitted = Grapheme.truncate_to_width ~max_width:max_w clean in
    let line_clip =
      match clip with
      | Some c -> Rect.intersect c (Rect.make ~x ~y ~w:max_w ~h:1)
      | None -> Rect.make ~x ~y ~w:max_w ~h:1
    in
    Cell_grid.put_text ~clip:line_clip grid ~x ~y ~style fitted

let draw_pills grid ~(rect : Rect.t) ~(theme : Theme.t) ~bg pills =
  if Rect.is_empty rect then 0
  else
    let right_edge = Rect.right rect in
    let gap = if rect.w >= 72 then 2 else 1 in
    let start_x =
      if rect.w >= 44 then rect.x + 2
      else if rect.w >= 24 then rect.x + 1
      else rect.x
    in
    let rec loop cx = function
      | [] -> cx - rect.x
      | (label, active, tone_opt) :: rest ->
          if cx >= right_edge then cx - rect.x
          else
            let avail = right_edge - cx in
            if active then begin
              let pill_bg = Color.of_rgb theme.surface_2 in
              let rail_rgb =
                match tone_opt with
                | Some tok -> Theme.status_color theme tok
                | None -> theme.accent
              in
              let rail_st =
                Style.make ~fg:(Color.of_rgb rail_rgb) ~bg:pill_bg
                  ~attrs:Attr.bold ()
              in
              let lbl_st =
                Typography.anchor ~bg:pill_bg ~underline:true theme
              in
              let pad_st = Typography.primary ~bg:pill_bg theme in
              let cur = ref cx in
              if !cur < right_edge then begin
                Cell_grid.put_glyph ~clip:rect grid ~x:!cur ~y:rect.y
                  ~style:rail_st Glyph.Left_rail;
                incr cur
              end;
              if !cur < right_edge then begin
                Cell_grid.put_ascii ~clip:rect grid ~x:!cur ~y:rect.y
                  ~style:pad_st ' ';
                incr cur
              end;
              let adv =
                put_line ~clip:rect grid ~x:!cur ~y:rect.y
                  ~max_w:(Int.max 0 (right_edge - !cur))
                  ~style:lbl_st label
              in
              cur := !cur + adv;
              if !cur < right_edge then begin
                Cell_grid.put_ascii ~clip:rect grid ~x:!cur ~y:rect.y
                  ~style:pad_st ' ';
                incr cur
              end;
              loop (!cur + gap) rest
            end
            else begin
              let fg_rgb =
                match tone_opt with
                | Some tok -> Theme.status_color theme tok
                | None -> theme.text_secondary
              in
              let style = Style.make ~fg:(Color.of_rgb fg_rgb) ~bg () in
              let adv =
                put_line ~clip:rect grid ~x:cx ~y:rect.y ~max_w:avail ~style
                  label
              in
              loop (cx + adv + gap) rest
            end
    in
    loop start_x pills

let draw_keycap_bar grid ~(rect : Rect.t) ~(theme : Theme.t) ~bg pairs =
  if Rect.is_empty rect then 0
  else
    let right_edge = Rect.right rect in
    let cap_st = Typography.keycap theme in
    let lbl_st = Typography.keycap_label ~bg theme in
    let gap = if rect.w >= 64 then 2 else 1 in
    let rec loop cx = function
      | [] -> cx - rect.x
      | (key, label) :: rest ->
          if cx >= right_edge then cx - rect.x
          else
            let cap_txt = " " ^ key ^ " " in
            let adv_k =
              put_line ~clip:rect grid ~x:cx ~y:rect.y
                ~max_w:(right_edge - cx) ~style:cap_st cap_txt
            in
            let lx = cx + adv_k in
            if lx >= right_edge then lx - rect.x
            else
              let lbl_txt = " " ^ label in
              let adv_l =
                put_line ~clip:rect grid ~x:lx ~y:rect.y
                  ~max_w:(right_edge - lx) ~style:lbl_st lbl_txt
              in
              loop (lx + adv_l + gap) rest
    in
    loop rect.x pairs

let draw_kv_row grid ~(rect : Rect.t) ~y ~(theme : Theme.t) ~bg ~label_w ~key
    ~value ?val_fg ?(val_attrs = Attr.none) () =
  if Rect.is_empty rect || y < rect.y || y >= Rect.bottom rect then ()
  else
    let lw = Int.max 4 (Int.min label_w (Int.max 4 (rect.w - 4))) in
    let key_style = Typography.structure ~bg theme in
    let v_fg =
      match val_fg with Some c -> c | None -> theme.text_primary
    in
    let val_style = Style.make ~fg:(Color.of_rgb v_fg) ~bg ~attrs:val_attrs () in
    ignore (put_line ~clip:rect grid ~x:rect.x ~y ~max_w:lw ~style:key_style key);
    let vx = rect.x + lw + 1 in
    let vw = Rect.right rect - vx in
    if vw > 0 then
      ignore (put_line ~clip:rect grid ~x:vx ~y ~max_w:vw ~style:val_style value)

let draw_kpi_line grid ~(rect : Rect.t) ~y ~(theme : Theme.t) ~bg ~label
    ~short_label ~value ~val_style =
  if Rect.is_empty rect || y < rect.y || y >= Rect.bottom rect then ()
  else
    let val_w = Grapheme.display_width value in
    let lbl_w = Grapheme.display_width label in
    let short_w = Grapheme.display_width short_label in
    let lbl_st = Typography.structure ~bg theme in
    if lbl_w > 0 && lbl_w + 1 + val_w <= rect.w then begin
      let adv =
        put_line ~clip:rect grid ~x:rect.x ~y ~max_w:(lbl_w + 1) ~style:lbl_st
          (label ^ " ")
      in
      ignore
        (put_line ~clip:rect grid ~x:(rect.x + adv) ~y
           ~max_w:(Int.max 0 (rect.w - adv))
           ~style:val_style value)
    end
    else if short_w > 0 && short_w + 1 + val_w <= rect.w then begin
      let adv =
        put_line ~clip:rect grid ~x:rect.x ~y ~max_w:(short_w + 1)
          ~style:lbl_st (short_label ^ " ")
      in
      ignore
        (put_line ~clip:rect grid ~x:(rect.x + adv) ~y
           ~max_w:(Int.max 0 (rect.w - adv))
           ~style:val_style value)
    end
    else begin
      let lbl_budget = Int.max 0 (rect.w - val_w - 1) in
      if short_w > 0 && lbl_budget >= 2 then begin
        let adv =
          put_line ~clip:rect grid ~x:rect.x ~y ~max_w:lbl_budget ~style:lbl_st
            short_label
        in
        let vx = rect.x + adv + 1 in
        ignore
          (put_line ~clip:rect grid ~x:vx ~y
             ~max_w:(Int.max 0 (Rect.right rect - vx))
             ~style:val_style value)
      end
      else
        ignore
          (put_line ~clip:rect grid ~x:rect.x ~y ~max_w:rect.w ~style:val_style
             value)
    end

let scrub_secrets_in_text = Chat_transcript.scrub_secrets_in_text
let scrub_json_secrets = Chat_transcript.scrub_json_secrets

let draw_hrule grid ~(rect : Rect.t) ~y ~(theme : Theme.t) ~bg ?title () =
  Card.draw_hairline ~pad_x:0 ?label:title ~bg grid ~rect ~y ~theme

let observed_read_notice ~lang obs =
  let notice ~ko ~en = Some (Say.resolve lang (Say.make ~ko ~en)) in
  match obs with
  | Observed.Failed _ -> notice ~ko:"조회 실패" ~en:"unavailable"
  | Observed.Value { stale = true; _ } -> notice ~ko:"마지막 조회" ~en:"last read"
  | Observed.Loading _ -> notice ~ko:"불러오는 중" ~en:"loading"
  | Observed.Unreported | Observed.Absent -> notice ~ko:"미관측" ~en:"unobserved"
  | Observed.Value { stale = false; _ } -> None

let draw_verification_read_notices grid ~(rect : Rect.t) ~(theme : Theme.t) ~lang
    (work : Work_store.t) =
  let notices = List.take (Int.max 0 rect.h) (Work_store.verification_read_notices work) in
  let tone =
    match work.verification_failure with
    | Some _ -> Theme.Status_critical
    | None when Observed.is_loading work.verifications -> Theme.Status_active
    | None -> Theme.Status_attention
  in
  let bg = Color.of_rgb theme.surface_1 in
  List.iteri
    (fun i notice ->
      ignore (put_line ~clip:rect grid ~x:rect.x ~y:(rect.y + i) ~max_w:rect.w
        ~style:(Typography.status ~bg ~bold:(i = 0) theme tone) (Say.resolve lang notice)))
    notices;
  List.length notices

let draw_observed_empty grid ~(rect : Rect.t) ~(theme : Theme.t) ~lang obs
    ~empty_msg =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad = if rect.w >= 24 then 2 else 1 in
    let py = rect.y + Int.min 1 (Int.max 0 (rect.h - 1)) in
    let px = rect.x + Int.min pad (Int.max 0 (rect.w - 1)) in
    let max_w = Int.max 0 (Rect.right rect - px - pad) in
    match obs with
    | Observed.Failed { reason; _ } ->
        Card.draw_left_rail ~bg ~tone:Theme.Status_critical grid ~x:px ~y:py
          ~h:1 ~theme;
        let line =
          Glyph.to_utf8 Glyph.Live_failing ^ " "
          ^ Say.resolve lang
              (Say.make
                 ~ko:("조회 실패: " ^ reason)
                 ~en:("Fetch failed: " ^ reason))
        in
        ignore
          (put_line ~clip:rect grid ~x:(px + 2) ~y:py
             ~max_w:(Int.max 0 (max_w - 2))
             ~style:(Typography.status ~bg ~bold:true theme Theme.Status_critical)
             line)
    | Observed.Loading _ ->
        let line =
          Glyph.to_utf8 Glyph.Transport_reconnecting ^ " "
          ^ Say.resolve lang
              (Say.make ~ko:"서버 스냅샷 불러오는 중…" ~en:"Loading server snapshot…")
        in
        ignore
          (put_line ~clip:rect grid ~x:px ~y:py ~max_w
             ~style:(Typography.status ~bg ~italic:true theme Theme.Status_active)
             line)
    | Observed.Unreported ->
        let line =
          Glyph.to_utf8 Glyph.Missing_unreported ^ " "
          ^ Say.resolve lang
              (Say.make ~ko:"아직 보고된 데이터가 없습니다"
                 ~en:"Not yet reported by server")
        in
        ignore
          (put_line ~clip:rect grid ~x:px ~y:py ~max_w
             ~style:(Typography.whisper ~bg theme)
             line)
    | Observed.Absent ->
        let line =
          Glyph.to_utf8 Glyph.Missing_absent ^ " " ^ Say.resolve lang empty_msg
        in
        ignore
          (put_line ~clip:rect grid ~x:px ~y:py ~max_w
             ~style:(Typography.whisper ~bg theme)
             line)
    | Observed.Value _ ->
        let line =
          Glyph.to_utf8 Glyph.Live_idle ^ " " ^ Say.resolve lang empty_msg
        in
        ignore
          (put_line ~clip:rect grid ~x:px ~y:py ~max_w
             ~style:(Typography.whisper ~bg theme)
             line)

let format_age ~now_unix ts ~lang =
  if
    (not (Float.is_finite ts))
    || (not (Float.is_finite now_unix))
    || now_unix <= 0.0
    || ts <= 0.0
  then Glyph.to_utf8 Glyph.Missing_absent
  else
    let delta = Float.max 0.0 (now_unix -. ts) in
    let dur = Format_val.format_duration_s delta in
    match lang with
    | Say.Lang_ko -> dur ^ " 전"
    | Say.Lang_en -> dur ^ " ago"

let format_due_delta ~now_unix ts ~lang =
  if
    (not (Float.is_finite ts))
    || (not (Float.is_finite now_unix))
    || now_unix <= 0.0
    || ts <= 0.0
  then Glyph.to_utf8 Glyph.Missing_absent
  else if ts >= now_unix then
    let dur = Format_val.format_duration_s (ts -. now_unix) in
    match lang with
    | Say.Lang_ko -> dur ^ " 뒤"
    | Say.Lang_en -> "in " ^ dur
  else
    let dur = Format_val.format_duration_s (now_unix -. ts) in
    match lang with
    | Say.Lang_ko -> dur ^ " 늦음"
    | Say.Lang_en -> dur ^ " late"

let format_hhmm ?(tz_offset_sec = 0) ts =
  if (not (Float.is_finite ts)) || ts <= 0.0 then "--:--"
  else
    let secs = Int64.add (Int64.of_float (Float.floor ts)) (Int64.of_int tz_offset_sec) in
    let day_secs = Int64.rem secs 86400L in
    let day_secs =
      if Int64.compare day_secs 0L < 0 then Int64.add day_secs 86400L
      else day_secs
    in
    let h = Int64.to_int (Int64.div day_secs 3600L) in
    let m = Int64.to_int (Int64.div (Int64.rem day_secs 3600L) 60L) in
    Printf.sprintf "%02d:%02d" h m

let samples_of_floats xs =
  Array.of_list
    (List.map
       (fun v ->
         if not (Float.is_finite v) then Chart.Series.Absent
         else if v <= 0.0 then Chart.Series.Zero
         else Chart.Series.Value v)
       xs)

let format_milli_candles milli =
  let f = Float.of_int milli /. 1000.0 in
  Format_val.format_value Format_val.Candles f

let format_milli_string raw =
  let trimmed = String.trim raw in
  match float_of_string_opt trimmed with
  | Some f when Float.is_finite f ->
      Format_val.format_value Format_val.Candles (f /. 1000.0)
  | Some _ | None ->
      if String.equal trimmed "" then Glyph.to_utf8 Glyph.Missing_absent
      else trimmed ^ " mC"

let rewrite_masc_links_for_markdown =
  Chat_transcript.rewrite_masc_links_for_markdown

let keeper_has_attention (attn : Attention.t) name =
  List.exists
    (fun (entry : Attention.entry) ->
      match entry.keeper with
      | Some k -> String.equal k name
      | None -> false)
    attn.items

let keeper_incident_count (inc : Incidents.t) name =
  List.fold_left
    (fun acc (e : Health.incident) ->
      match e.status, e.source with
      | Health.Dismissed, _ -> acc
      | (Health.Resolved | Health.Retried | Health.Superseded), Health.Source_keeper k
        when String.equal k name ->
          acc + 1
      | (Health.Resolved | Health.Retried | Health.Superseded),
        ( Health.Source_keeper _
        | Health.Source_runtime _
        | Health.Source_sandbox _
        | Health.Source_client_http
        | Health.Source_stream ) ->
          acc)
    0 inc.entries

let keeper_attention_badge =
  ( Glyph.Action_required
  , Theme.Status_attention
  , Say.make ~ko:"승인/질문 필요" ~en:"Needs Action" )

let keeper_idle_badge =
  (Glyph.Live_idle, Theme.Status_historical, Say.make ~ko:"유휴" ~en:"Idle")

let keeper_live_status ~has_attention (k : Wire_fleet.keeper_summary) =
  if has_attention then keeper_attention_badge
  else
    match k.health with
    | Wire_fleet.Keeper_failing ->
        ( Glyph.Live_failing
        , Theme.Status_critical
        , Say.make ~ko:"실행 실패" ~en:"Failing" )
    | Wire_fleet.Keeper_offline ->
        ( Glyph.Live_failing
        , Theme.Status_critical
        , Say.make ~ko:"오프라인" ~en:"Offline" )
    | Wire_fleet.Keeper_working ->
        ( Glyph.Live_working
        , Theme.Status_active
        , Say.make ~ko:"작업 중" ~en:"Working" )
    | Wire_fleet.Keeper_booting ->
        ( Glyph.Live_working
        , Theme.Status_active
        , Say.make ~ko:"시작 중" ~en:"Booting" )
    | Wire_fleet.Keeper_degraded ->
        ( Glyph.Live_working
        , Theme.Status_attention
        , Say.make ~ko:"성능 저하" ~en:"Degraded" )
    | Wire_fleet.Keeper_recovering ->
        ( Glyph.Live_working
        , Theme.Status_attention
        , Say.make ~ko:"복구 중" ~en:"Recovering" )
    | Wire_fleet.Keeper_healthy -> (
        match k.active_turn with
        | Some _ ->
            ( Glyph.Live_working
            , Theme.Status_active
            , Say.make ~ko:"작업 중" ~en:"Working" )
        | None ->
            ( Glyph.Live_healthy
            , Theme.Status_ok
            , Say.make ~ko:"정상" ~en:"Healthy" ))
    | Wire_fleet.Keeper_paused ->
        ( Glyph.Live_paused
        , Theme.Status_historical
        , Say.make ~ko:"일시 정지" ~en:"Paused" )
    | Wire_fleet.Keeper_idle -> (
        match k.active_turn with
        | Some _ ->
            ( Glyph.Live_working
            , Theme.Status_active
            , Say.make ~ko:"작업 중" ~en:"Working" )
        | None -> keeper_idle_badge)

let activation_label = function
  | Wire_fleet.Activation_autonomous -> Say.make ~ko:"자율" ~en:"AUTO"
  | Wire_fleet.Activation_on_demand -> Say.make ~ko:"호출" ~en:"ON-DEMAND"
  | Wire_fleet.Activation_manual -> Say.make ~ko:"수동" ~en:"MANUAL"

let turn_lane_label = function
  | Wire_fleet.Lane_chat -> Say.make ~ko:"대화" ~en:"chat"
  | Wire_fleet.Lane_proactive -> Say.make ~ko:"자율" ~en:"proactive"
  | Wire_fleet.Lane_schedule -> Say.make ~ko:"일정" ~en:"schedule"
  | Wire_fleet.Lane_board -> Say.make ~ko:"보드" ~en:"board"
  | Wire_fleet.Lane_task -> Say.make ~ko:"작업" ~en:"task"
  | Wire_fleet.Lane_verification -> Say.make ~ko:"검증" ~en:"verify"
  | Wire_fleet.Lane_maintenance -> Say.make ~ko:"점검" ~en:"maint"
  | Wire_fleet.Lane_internal -> Say.make ~ko:"내부" ~en:"internal"

let keeper_infra_tag (infra : Infra_store.t) name =
  match Observed.to_option infra.sandboxes with
  | None -> (Glyph.to_utf8 Glyph.Missing_absent, Theme.Status_historical)
  | Some snap ->
      let in_vm =
        List.find_opt
          (fun (g : Wire_infra.microvm_guest) -> String.equal g.keeper name)
          snap.microvm_guests
      in
      match in_vm with
      | Some g ->
          let tone =
            match g.agent_socket, g.volume with
            | Wire_infra.Socket_present _, Wire_infra.Volume_declared _ ->
                Theme.Status_ok
            | (Wire_infra.Socket_absent _ | Wire_infra.Socket_non_socket _ | Wire_infra.Socket_unreadable _), _
            | _, Wire_infra.Volume_invalid _ ->
                Theme.Status_attention
          in
          ("vm", tone)
      | None ->
          let in_ssh_pool =
            List.find_opt
              (fun (p : Wire_infra.ssh_pool) ->
                List.exists
                  (fun (s : Wire_infra.ssh_keeper_session) ->
                    String.equal s.keeper name)
                  p.keeper_sessions)
              snap.ssh_pools
          in
          match in_ssh_pool with
          | Some pool ->
              let tone =
                match pool.reachability with
                | Wire_infra.Ssh_reachable _ -> Theme.Status_ok
                | Wire_infra.Ssh_probe_pending -> Theme.Status_active
                | Wire_infra.Ssh_unreachable _ -> Theme.Status_critical
              in
              ("ssh", tone)
          | None ->
              if
                List.exists
                  (fun (u : Wire_infra.ssh_unbound_keeper) ->
                    String.equal u.keeper name)
                  snap.ssh_unbound_keepers
              then ("ssh!", Theme.Status_attention)
              else if
                List.exists
                  (fun (d : Wire_infra.docker_keeper) ->
                    String.equal d.keeper name)
                  snap.docker_keepers
              then ("dkr", Theme.Status_active)
              else (Glyph.to_utf8 Glyph.Missing_absent, Theme.Status_historical)

let keeper_sandbox_tag ~(model : Model.t) name =
  let tag, tone = keeper_infra_tag model.infra name in
  let dash = Glyph.to_utf8 Glyph.Missing_absent in
  if not (String.equal tag dash) then (tag, tone)
  else
    match Fleet_store.sandbox_profile_of ~keeper:name model.fleet with
    | Some Wire_fleet.Profile_microvm -> ("vm", Theme.Status_ok)
    | Some Wire_fleet.Profile_remote_ssh -> ("ssh", Theme.Status_ok)
    | Some Wire_fleet.Profile_docker -> ("dkr", Theme.Status_active)
    | Some (Wire_fleet.Profile_other s) -> (s, Theme.Status_historical)
    | None -> (dash, Theme.Status_historical)

let keeper_sandbox_label ~(model : Model.t) name =
  let tag, tone = keeper_sandbox_tag ~model name in
  match tag with
  | "vm" -> ("apple_container", tone)
  | "ssh" -> ("remote_ssh", tone)
  | "ssh!" -> ("remote_ssh (unbound)", tone)
  | "dkr" -> ("docker", tone)
  | other -> (other, tone)

let human_runtime_label ~(model : Model.t) (k : Wire_fleet.keeper_summary) =
  let runtimes = Runtime_store.runtime_options model.runtime in
  let raw =
    match k.model_id with
    | Some m when not (String.equal (String.trim m) "") -> m
    | Some _ | None -> k.runtime_id
  in
  let resolved = Wire_runtime.human_runtime_slot_label ~runtimes raw in
  if String.equal (String.trim resolved) "" then raw else resolved

let keeper_candle_milli ~(model : Model.t) name =
  let from_ledger =
    match Observed.to_option model.work.candle_ledger with
    | Some l -> (
        match
          List.find_opt
            (fun (b : Wire_work.candle_balance_row) ->
              String.equal b.keeper name)
            l.balances
        with
        | Some b -> Some (b.balance_milli, b.decayed_milli)
        | None -> None)
    | None -> None
  in
  match from_ledger with
  | Some _ as hit -> hit
  | None -> (
      match Fleet_store.String_map.find_opt name model.fleet.candle_balances_milli with
      | Some m -> Some (m, Int.to_string m)
      | None -> None)

let keeper_turn_summary ~lang (k : Wire_fleet.keeper_summary) =
  match k.active_turn with
  | Some turn -> (
      let lane = Say.resolve lang (turn_lane_label turn.lane) in
      match turn.preview with
      | Some _ ->
          Printf.sprintf "%s · %s" lane
            (Say.resolve lang (Chat_transcript.active_turn_short_activity turn))
      | None -> lane)
  | None -> (
      match k.current_task_id with
      | Some tid -> tid
      | None -> Say.resolve lang (activation_label k.activation_mode))

let goal_phase_badge = function
  | Wire_work.Executing ->
      (Glyph.Live_working, Theme.Status_active, Say.make ~ko:"진행 중" ~en:"Executing")
  | Wire_work.Verifying ->
      (Glyph.Live_working, Theme.Status_active, Say.make ~ko:"검증 중" ~en:"Verifying")
  | Wire_work.Awaiting_confirmation ->
      ( Glyph.Action_required
      , Theme.Status_attention
      , Say.make ~ko:"확정 대기" ~en:"Awaiting Confirm" )
  | Wire_work.Completed ->
      (Glyph.Check_mark, Theme.Status_ok, Say.make ~ko:"완료" ~en:"Completed")
  | Wire_work.Dropped ->
      (Glyph.Live_failing, Theme.Status_historical, Say.make ~ko:"중단" ~en:"Dropped")
  | Wire_work.Paused _ ->
      (Glyph.Live_paused, Theme.Status_historical, Say.make ~ko:"보류" ~en:"Paused")
  | Wire_work.Blocked _ ->
      (Glyph.Live_failing, Theme.Status_critical, Say.make ~ko:"차단됨" ~en:"Blocked")

let task_status_badge = function
  | Wire_work.Todo ->
      (Glyph.Live_idle, Theme.Status_historical, Say.make ~ko:"대기" ~en:"Todo")
  | Wire_work.Claimed _ ->
      (Glyph.Live_working, Theme.Status_active, Say.make ~ko:"배정" ~en:"Claimed")
  | Wire_work.InProgress _ ->
      (Glyph.Live_working, Theme.Status_active, Say.make ~ko:"진행" ~en:"InProgress")
  | Wire_work.AwaitingVerification _ ->
      ( Glyph.Action_required
      , Theme.Status_attention
      , Say.make ~ko:"검증 대기" ~en:"AwaitingVerify" )
  | Wire_work.Done _ ->
      (Glyph.Check_mark, Theme.Status_ok, Say.make ~ko:"완료" ~en:"Done")
  | Wire_work.Cancelled _ ->
      (Glyph.Live_failing, Theme.Status_historical, Say.make ~ko:"취소" ~en:"Cancelled")

let task_assignee_opt = function
  | Wire_work.Todo -> None
  | Wire_work.Claimed { assignee; _ }
  | Wire_work.InProgress { assignee; _ }
  | Wire_work.AwaitingVerification { assignee; _ }
  | Wire_work.Done { assignee; _ } ->
      Some assignee
  | Wire_work.Cancelled { cancelled_by; _ } -> Some cancelled_by

let task_started_at_opt = function
  | Wire_work.InProgress { started_at; _ }
  | Wire_work.AwaitingVerification { started_at; _ } ->
      Some started_at
  | Wire_work.Todo
  | Wire_work.Claimed _
  | Wire_work.Done _
  | Wire_work.Cancelled _ ->
      None

let task_is_active = function
  | Wire_work.Claimed _ | Wire_work.InProgress _ | Wire_work.AwaitingVerification _ ->
      true
  | Wire_work.Todo | Wire_work.Done _ | Wire_work.Cancelled _ -> false

let task_is_done = function
  | Wire_work.Done _ -> true
  | Wire_work.Todo
  | Wire_work.Claimed _
  | Wire_work.InProgress _
  | Wire_work.AwaitingVerification _
  | Wire_work.Cancelled _ ->
      false

let task_is_awaiting_verification = function
  | Wire_work.AwaitingVerification _ -> true
  | Wire_work.Todo
  | Wire_work.Claimed _
  | Wire_work.InProgress _
  | Wire_work.Done _
  | Wire_work.Cancelled _ ->
      false

let review_state_badge = function
  | Wire_work.Review_unobserved ->
      (Glyph.Missing_unreported, Theme.Status_historical, Say.make ~ko:"미관측" ~en:"Unobserved")
  | Wire_work.Review_running ->
      (Glyph.Live_working, Theme.Status_active, Say.make ~ko:"심사 중" ~en:"Running")
  | Wire_work.Review_approved ->
      (Glyph.Check_mark, Theme.Status_ok, Say.make ~ko:"승인" ~en:"Approved")
  | Wire_work.Review_rejected ->
      (Glyph.Live_failing, Theme.Status_critical, Say.make ~ko:"반려" ~en:"Rejected")
  | Wire_work.Review_unavailable ->
      (Glyph.Warning_triangle, Theme.Status_attention, Say.make ~ko:"심사 불가" ~en:"Unavailable")
  | Wire_work.Review_not_reviewed ->
      (Glyph.Live_idle, Theme.Status_historical, Say.make ~ko:"미심사" ~en:"Not Reviewed")
  | Wire_work.Review_commit_failed ->
      (Glyph.Live_failing, Theme.Status_critical, Say.make ~ko:"커밋 실패" ~en:"Commit Failed")
  | Wire_work.Review_execution_pending ->
      (Glyph.Transport_reconnecting, Theme.Status_active, Say.make ~ko:"실행 대기" ~en:"Exec Pending")
  | Wire_work.Review_execution_repair_required ->
      (Glyph.Warning_triangle, Theme.Status_attention, Say.make ~ko:"복구 필요" ~en:"Repair Needed")
  | Wire_work.Review_failed ->
      (Glyph.Live_failing, Theme.Status_critical, Say.make ~ko:"실패" ~en:"Failed")
  | Wire_work.Review_cancelled ->
      (Glyph.Live_paused, Theme.Status_historical, Say.make ~ko:"취소됨" ~en:"Cancelled")
  | Wire_work.Review_superseded ->
      (Glyph.Recovered, Theme.Status_historical, Say.make ~ko:"대체됨" ~en:"Superseded")

let schedule_status_badge = function
  | Wire_work.Sched_scheduled ->
      (Glyph.Live_healthy, Theme.Status_ok, Say.make ~ko:"예약됨" ~en:"Scheduled")
  | Wire_work.Sched_due ->
      (Glyph.Action_required, Theme.Status_attention, Say.make ~ko:"실행 도래" ~en:"Due")
  | Wire_work.Sched_running ->
      (Glyph.Live_working, Theme.Status_active, Say.make ~ko:"실행 중" ~en:"Running")
  | Wire_work.Sched_succeeded ->
      (Glyph.Check_mark, Theme.Status_ok, Say.make ~ko:"성공" ~en:"Succeeded")
  | Wire_work.Sched_failed ->
      (Glyph.Live_failing, Theme.Status_critical, Say.make ~ko:"실패" ~en:"Failed")
  | Wire_work.Sched_cancelled ->
      (Glyph.Live_paused, Theme.Status_historical, Say.make ~ko:"취소" ~en:"Cancelled")
  | Wire_work.Sched_expired ->
      (Glyph.Recovered, Theme.Status_historical, Say.make ~ko:"만료" ~en:"Expired")

let wake_disposition_text ~lang = function
  | Wire_work.Wake_succeeded ->
      ( Glyph.to_utf8 Glyph.Check_mark ^ " "
        ^ Say.resolve lang (Say.make ~ko:"정상 기상" ~en:"Woke OK")
      , Theme.Status_ok )
  | Wire_work.Wake_failed reason ->
      let label =
        match reason with
        | Some r -> Say.make ~ko:("실패: " ^ r) ~en:("Failed: " ^ r)
        | None -> Say.make ~ko:"실패" ~en:"Failed"
      in
      ( Glyph.to_utf8 Glyph.Live_failing ^ " " ^ Say.resolve lang label
      , Theme.Status_critical )
  | Wire_work.Wake_running ->
      ( Glyph.to_utf8 Glyph.Live_working ^ " "
        ^ Say.resolve lang (Say.make ~ko:"실행 중" ~en:"Running")
      , Theme.Status_active )
  | Wire_work.Wake_never ->
      ( Glyph.to_utf8 Glyph.Missing_absent ^ " "
        ^ Say.resolve lang (Say.make ~ko:"기상 이력 없음" ~en:"Never woken")
      , Theme.Status_historical )
