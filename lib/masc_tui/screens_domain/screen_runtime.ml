open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

module H = Domain_helpers

(* --- 1. Sub-Tab 1: Quotas & Credits (Signal-First, Strictly Observation-Only) --- *)

let compact_window_label = function
  | Wire_runtime.Window_five_hour -> "5h"
  | Wire_runtime.Window_seven_day -> "7d"
  | Wire_runtime.Window_duration_minutes m ->
      if m >= 1440 && m mod 1440 = 0 then Printf.sprintf "%dd" (m / 1440)
      else if m >= 60 && m mod 60 = 0 then Printf.sprintf "%dh" (m / 60)
      else Printf.sprintf "%dm" m
  | Wire_runtime.Window_provider_label s -> (
      match Wire_runtime.classify_window_provider_label s with
      | Wire_runtime.Window_label_session -> "sess"
      | Wire_runtime.Window_label_weekly -> "7d"
      | Wire_runtime.Window_label_daily -> "24h"
      | Wire_runtime.Window_label_monthly -> "30d"
      | Wire_runtime.Window_label_other raw ->
          Grapheme.truncate_to_width ~max_width:6 (H.sanitize_single_line raw))

let is_window_exhausted (w : Wire_runtime.usage_window) =
  match w.utilization with
  | Wire_runtime.Util_fraction f -> f >= 0.995
  | Wire_runtime.Util_percent p -> p >= 100
  | Wire_runtime.Util_usd { used; limit = Some l } -> l > 0.0 && used >= l
  | Wire_runtime.Util_usd { used = _; limit = None } -> false
  | Wire_runtime.Util_credit_balance { remaining; _ } -> remaining <= 0.0
  | Wire_runtime.Util_credit_unlimited | Wire_runtime.Util_credit_retracted ->
      false

let is_account_cooldown_or_exhausted (acct : Wire_runtime.account_usage) =
  match acct.cost_state with
  | Format_val.Exhausted_zero -> true
  | Format_val.Amount _ | Format_val.Subscription_zero | Format_val.Unreported
    -> (
      match acct.state with
      | Wire_runtime.Account_reported ws -> List.exists is_window_exhausted ws
      | Wire_runtime.Account_not_reported_since_start
      | Wire_runtime.Account_reported_no_windows _ ->
          false)

let subscription_windows_of (acct : Wire_runtime.account_usage) =
  match acct.state with
  | Wire_runtime.Account_reported ws ->
      List.filter
        (fun (w : Wire_runtime.usage_window) ->
          match w.utilization with
          | Wire_runtime.Util_fraction _
          | Wire_runtime.Util_percent _
          | Wire_runtime.Util_credit_unlimited ->
              true
          | Wire_runtime.Util_usd _
          | Wire_runtime.Util_credit_balance _
          | Wire_runtime.Util_credit_retracted ->
              false)
        ws
  | Wire_runtime.Account_not_reported_since_start
  | Wire_runtime.Account_reported_no_windows _ ->
      []

type flat_sub_window = {
  acct : Wire_runtime.account_usage;
  window : Wire_runtime.usage_window;
  is_first_for_acct : bool;
}

let collect_subscription_windows (accounts : Wire_runtime.account_usage list) =
  List.concat_map
    (fun (acct : Wire_runtime.account_usage) ->
      let ws = subscription_windows_of acct in
      List.mapi
        (fun idx window -> { acct; window; is_first_for_acct = idx = 0 })
        ws)
    accounts

let window_used_pct (w : Wire_runtime.usage_window) =
  match w.utilization with
  | Wire_runtime.Util_fraction f ->
      Some (Float.max 0.0 (Float.min 100.0 (f *. 100.0)))
  | Wire_runtime.Util_percent p ->
      Some (Float.max 0.0 (Float.min 100.0 (float_of_int p)))
  | Wire_runtime.Util_credit_unlimited -> None
  | Wire_runtime.Util_usd _
  | Wire_runtime.Util_credit_balance _
  | Wire_runtime.Util_credit_retracted ->
      None

let draw_subscription_windows ~grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp ~lang ~now_unix ~(rt : Runtime_store.t)
    (sub_rows : flat_sub_window list)
    (obs : Wire_runtime.provider_usage_windows Observed.t) ~focused =
  let cooldown_n =
    List.fold_left
      (fun acc r -> if is_window_exhausted r.window then acc + 1 else acc)
      0 sub_rows
  in
  let badge =
    if cooldown_n > 0 then
      Some
        (H.make_badge ~glyph:Glyph.Action_required ~tone:Theme.Status_attention
           (Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%d 일시 중지" cooldown_n)
                 ~en:(Printf.sprintf "%d paused" cooldown_n))))
    else
      Some
        (H.make_badge ~glyph:Glyph.Live_healthy ~tone:Theme.Status_ok
           (Printf.sprintf "%d" (List.length sub_rows)))
  in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ?badge ~focused
         (Say.resolve lang
            (Say.make ~ko:"구독 한도 창 (5h / 7d)"
               ~en:"Subscription Quota Windows")))
  in
  let content = H.pad_content ~bp inner in
  if Rect.is_empty content then ()
  else if sub_rows = [] then
    match obs with
    | Observed.Value _ ->
        H.draw_empty_notice ~grid ~rect:content ~theme
          (Say.resolve lang
             (Say.make ~ko:"보고된 구독 한도 창 없음"
                ~en:"No subscription quota windows reported"))
    | Observed.Loading _ | Observed.Absent | Observed.Unreported
    | Observed.Failed _ ->
        H.draw_observed_placeholder ~grid ~rect:content ~theme ~lang obs
  else
    let y = ref content.y in
    let bottom = Rect.bottom content in
    let bg = Color.of_rgb theme.surface_1 in
    let show_eta = content.w >= 42 in
    let eta_w = if show_eta then 11 else 0 in
    let pct_w = 5 in
    let win_w = 5 in
    let name_w =
      Int.max 10 (Int.min 20 ((content.w - eta_w - pct_w - win_w - 6) * 52 / 100))
    in
    let bar_w =
      Int.max 6
        (content.w - name_w - win_w - pct_w - (if show_eta then eta_w + 1 else 0)
        - 3)
    in
    let total_sub = List.length sub_rows in
    let truncated = total_sub > content.h && content.h >= 2 in
    let visible_limit = if truncated then content.h - 1 else content.h in
    let max_scroll = Int.max 0 (total_sub - visible_limit) in
    let start_idx = Int.min max_scroll (Int.max 0 rt.quota_scroll_offset) in
    let visible_rows =
      Store_scroll.drop start_idx sub_rows |> H.safe_take visible_limit
    in
    let row_bottom = if truncated then bottom - 1 else bottom in
    List.iter
      (fun (row : flat_sub_window) ->
        if !y < row_bottom then begin
          let w = row.window in
          let exhausted = is_window_exhausted w in
          let alias = Runtime_store.account_display_name ~lang rt row.acct in
          let name_txt =
            if row.is_first_for_acct then alias
            else "  " ^ Glyph.to_utf8 Glyph.Tree_corner
          in
          let name_style =
            if not row.is_first_for_acct then
              H.whisper_style ~theme ~italic:false ()
            else if exhausted then
              H.status_style ~theme ~attrs:Attr.bold Theme.Status_critical
            else H.text_style ~theme ()
          in
          let cx = ref content.x in
          ignore
            (H.put_clipped ~grid ~clip:content ~x:!cx ~y:!y ~max_w:name_w
               ~style:name_style name_txt);
          cx := !cx + name_w + 1;
          let win_lbl = compact_window_label w.kind in
          ignore
            (H.put_clipped ~grid ~clip:content ~x:!cx ~y:!y ~max_w:win_w
               ~style:(H.secondary_style ~theme ())
               win_lbl);
          cx := !cx + win_w + 1;
          (match window_used_pct w with
           | Some used_pct ->
               ignore
                 (Chart.draw_ratio_bar_run ~clip:content grid ~x:!cx ~y:!y
                    ~width:bar_w ~theme ~bg ~unicode:true
                    ~gradient:Chart.Gradient.Thermal
                    ~ratio:(used_pct /. 100.0));
               cx := !cx + bar_w + 1;
               let pct_txt = Printf.sprintf "%3.0f%%" used_pct in
               let pct_style =
                 if exhausted then
                   H.status_style ~theme ~attrs:Attr.bold Theme.Status_critical
                 else if used_pct >= 80.0 then
                   H.status_style ~theme ~attrs:Attr.bold Theme.Status_attention
                 else H.anchor_style ~theme ()
               in
               ignore
                 (H.put_right ~grid ~clip:content ~right_x:(!cx + pct_w) ~y:!y
                    ~max_w:pct_w ~style:pct_style pct_txt);
               cx := !cx + pct_w
           | None ->
               let unlim =
                 Say.resolve lang (Say.make ~ko:"무제한" ~en:"unlim")
               in
               ignore
                 (H.put_clipped ~grid ~clip:content ~x:!cx ~y:!y
                    ~max_w:(bar_w + pct_w + 1)
                    ~style:(H.status_style ~theme Theme.Status_ok)
                    (Glyph.to_utf8 Glyph.Live_healthy ^ " " ^ unlim));
               cx := !cx + bar_w + pct_w + 1);
          if show_eta && !cx + 2 < Rect.right content then begin
            let eta_txt =
              match w.resets_at_unix with
              | Some ts ->
                  let cd = H.format_countdown ~now_unix ts in
                  Say.resolve lang
                    (Say.make ~ko:("리셋 " ^ cd) ~en:("rst " ^ cd))
              | None -> Glyph.to_utf8 Glyph.Missing_absent
            in
            ignore
              (H.put_right ~grid ~clip:content ~right_x:(Rect.right content)
                 ~y:!y ~max_w:eta_w ~style:(H.whisper_style ~theme ()) eta_txt)
          end;
          incr y
        end)
      visible_rows;
    if truncated then begin
      let hidden_below =
        Int.max 0 (total_sub - start_idx - List.length visible_rows)
      in
      let more_txt =
        if start_idx > 0 && hidden_below > 0 then
          Say.resolve lang
            (Say.make
               ~ko:
                 (Printf.sprintf "%s %d · %s %d개 더"
                    (Glyph.to_utf8 Glyph.Delta_up) start_idx
                    (Glyph.to_utf8 Glyph.Delta_down) hidden_below)
               ~en:
                 (Printf.sprintf "%s %d · %s %d more"
                    (Glyph.to_utf8 Glyph.Delta_up) start_idx
                    (Glyph.to_utf8 Glyph.Delta_down) hidden_below))
        else if start_idx > 0 then
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "%s %d개 위" (Glyph.to_utf8 Glyph.Delta_up) start_idx)
               ~en:(Printf.sprintf "%s %d above" (Glyph.to_utf8 Glyph.Delta_up) start_idx))
        else
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "%s %d개 더" (Glyph.to_utf8 Glyph.Delta_down) hidden_below)
               ~en:(Printf.sprintf "%s %d more" (Glyph.to_utf8 Glyph.Delta_down) hidden_below))
      in
      ignore
        (H.put_right ~grid ~clip:content ~right_x:(Rect.right content)
           ~y:(bottom - 1) ~max_w:content.w
           ~style:(H.accent_style ~theme ()) more_txt)
    end

type quota_health_buckets = {
  total : int;
  healthy : int;
  cooldown : int;
  exhausted : int;
  unreported : int;
  cooldown_accts : Wire_runtime.account_usage list;
}

let compute_quota_health_buckets (part : Runtime_store.partitioned_accounts) :
    quota_health_buckets =
  let all_reported = part.exhausted_and_credits @ part.active_subscriptions in
  let exhausted =
    List.fold_left
      (fun acc (a : Wire_runtime.account_usage) ->
        match a.cost_state with
        | Format_val.Exhausted_zero -> acc + 1
        | Format_val.Amount _ | Format_val.Subscription_zero
        | Format_val.Unreported ->
            acc)
      0 all_reported
  in
  let cooldown_accts =
    List.filter
      (fun (a : Wire_runtime.account_usage) ->
        match a.cost_state with
        | Format_val.Exhausted_zero -> true
        | Format_val.Amount _ | Format_val.Subscription_zero
        | Format_val.Unreported ->
            is_account_cooldown_or_exhausted a)
      all_reported
  in
  let cooldown = Int.max 0 (List.length cooldown_accts - exhausted) in
  let healthy =
    Int.max 0 (List.length all_reported - List.length cooldown_accts)
  in
  let unreported = List.length part.unreported in
  let total = healthy + cooldown + exhausted + unreported in
  { total; healthy; cooldown; exhausted; unreported; cooldown_accts }

let format_cooldown_duration ~now_unix resets_at_unix =
  if
    (not (Float.is_finite now_unix))
    || (not (Float.is_finite resets_at_unix))
    || now_unix <= 0.0
    || resets_at_unix <= 0.0
  then None
  else
    let rem = Int.max 0 (int_of_float (resets_at_unix -. now_unix)) in
    if rem >= 172_800 then
      let days = rem / 86_400 in
      let hours = (rem mod 86_400) / 3600 in
      Some (Printf.sprintf "%dd %dh" days hours)
    else if rem >= 3600 then
      let hours = rem / 3600 in
      let mins = (rem mod 3600) / 60 in
      Some (Printf.sprintf "%dh %02dm" hours mins)
    else if rem >= 60 then
      let mins = rem / 60 in
      let secs = rem mod 60 in
      Some (Printf.sprintf "%dm %02ds" mins secs)
    else Some (Printf.sprintf "%ds" rem)

type provider_quota_state =
  | Quota_ok
  | Quota_cooldown of string
  | Quota_exhausted

let provider_quota_status ~now_unix ~provider
    (uw_opt : Wire_runtime.provider_usage_windows option) : provider_quota_state =
  match uw_opt with
  | None -> Quota_ok
  | Some uw ->
      let want = String.lowercase_ascii provider in
      let matching =
        List.filter
          (fun (a : Wire_runtime.account_usage) ->
            List.exists
              (fun (p : Wire_runtime.usage_provider_ref) ->
                String.equal (String.lowercase_ascii p.id) want)
              a.providers)
          uw.accounts
      in
      let any_exhausted_credit =
        List.exists
          (fun (a : Wire_runtime.account_usage) ->
            match a.cost_state with
            | Format_val.Exhausted_zero -> true
            | Format_val.Amount _ | Format_val.Subscription_zero
            | Format_val.Unreported ->
                false)
          matching
      in
      if any_exhausted_credit then Quota_exhausted
      else
        let exhausted_windows =
          List.concat_map
            (fun (a : Wire_runtime.account_usage) ->
              match a.state with
              | Wire_runtime.Account_reported ws ->
                  List.filter is_window_exhausted ws
              | Wire_runtime.Account_not_reported_since_start
              | Wire_runtime.Account_reported_no_windows _ ->
                  [])
            matching
        in
        match exhausted_windows with
        | [] -> Quota_ok
        | ws -> (
            let max_reset =
              List.fold_left
                (fun acc (w : Wire_runtime.usage_window) ->
                  match (acc, w.resets_at_unix) with
                  | Some a, Some b -> Some (Float.max a b)
                  | None, Some b -> Some b
                  | Some a, None -> Some a
                  | None, None -> None)
                None ws
            in
            match max_reset with
            | Some ts -> (
                match format_cooldown_duration ~now_unix ts with
                | Some dur -> Quota_cooldown dur
                | None -> Quota_exhausted)
            | None -> Quota_exhausted)

let probe_quota_status ~now_unix ~runtimes_tbl ~usage_windows
    (p : Wire_runtime.provider_probe_row) : provider_quota_state =
  match Hashtbl.find_opt runtimes_tbl p.runtime_id with
  | Some (r : Wire_runtime.runtime_option) ->
      provider_quota_status ~now_unix ~provider:r.provider_id usage_windows
  | None -> Quota_ok

let standing_restricts_readiness ~now_unix ~(rt : Runtime_store.t) rid =
  match Runtime_store.standing_for ~runtime_id:rid rt with
  | Some st -> Wire_runtime.standing_restricts_readiness ~now_unix st
  | None -> false

let quota_rest_cause_presentation ~lang cause =
  match Wire_runtime.classify_quota_rest_cause cause with
  | Wire_runtime.Rest_provider_quota_refused ->
      ( Glyph.Live_paused
      , Theme.Status_attention
      , Say.resolve lang (Say.make ~ko:"한도 초과" ~en:"Quota limit") )
  | Wire_runtime.Rest_payment_refused ->
      ( Glyph.Live_failing
      , Theme.Status_critical
      , Say.resolve lang (Say.make ~ko:"결제 거절" ~en:"Payment refused") )
  | Wire_runtime.Rest_usage_read ->
      ( Glyph.Live_paused
      , Theme.Status_attention
      , Say.resolve lang (Say.make ~ko:"사용량 100%" ~en:"Usage 100%") )
  | Wire_runtime.Rest_other other ->
      let lbl =
        if String.equal other "" then
          Say.resolve lang (Say.make ~ko:"일시 중지" ~en:"Paused")
        else
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "일시 중지 (%s)" other)
               ~en:(Printf.sprintf "Paused (%s)" other))
      in
      (Glyph.Live_paused, Theme.Status_attention, lbl)

let format_local_release_clock ~tz_offset_sec ~now_unix ts =
  if
    (not (Float.is_finite now_unix))
    || (not (Float.is_finite ts))
    || now_unix <= 0.0
    || ts <= 0.0
  then None
  else
    let off = Float.of_int tz_offset_sec in
    let now_s = Wire_common.format_unix_rfc3339 (now_unix +. off) in
    let ts_s = Wire_common.format_unix_rfc3339 (ts +. off) in
    if String.length now_s >= 16 && String.length ts_s >= 16 then
      let hhmm = String.sub ts_s 11 5 in
      if String.equal (String.sub now_s 0 10) (String.sub ts_s 0 10) then
        Some hhmm
      else
        Some
          (Printf.sprintf "%s/%s %s"
             (String.sub ts_s 5 2) (String.sub ts_s 8 2) hhmm)
    else None

type quota_rest_provider_group = {
  provider_id : string;
  paused_count : int;
  total_count : int;
  primary_cause : string;
  soonest_until : float option;
  soonest_reset_stated : bool;
}

let active_quota_rest_cause ~now_unix (st : Wire_runtime.runtime_standing) =
  match (st.credential_refused_at_unix, st.quota_rest_cause) with
  | Some _, _ -> None
  | None, Some cause -> (
      match st.quota_rest_until_unix with
      | None -> Some cause
      | Some u when u > now_unix -> Some cause
      | Some _ -> None)
  | None, None -> None

let compare_opt_until a b =
  match (a, b) with
  | Some x, Some y -> Float.compare x y
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0

let provider_disambiguator provider_id =
  let trimmed = String.trim provider_id in
  let raw =
    match String.rindex_opt trimmed '_' with
    | Some idx when idx + 1 < String.length trimmed ->
        String.sub trimmed (idx + 1) (String.length trimmed - idx - 1)
    | Some _ | None -> trimmed
  in
  let clusters = Grapheme.split_clusters raw in
  let rec take_suffix acc width = function
    | [] -> acc
    | (g, w) :: rest ->
        let gw = Int.max 1 w in
        if width + gw > 8 then acc
        else take_suffix (g :: acc) (width + gw) rest
  in
  String.concat "" (take_suffix [] 0 (List.rev clusters))

let group_active_quota_rest_standings ~now_unix ~runtimes ~runtimes_tbl
    (degraded : (string * Wire_runtime.runtime_standing) list) =
  let provider_totals : (string, int) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun (r : Wire_runtime.runtime_option) ->
      let cur =
        match Hashtbl.find_opt provider_totals r.provider_id with
        | Some n -> n
        | None -> 0
      in
      Hashtbl.replace provider_totals r.provider_id (cur + 1))
    runtimes;
  let grouped : (string, quota_rest_provider_group) Hashtbl.t =
    Hashtbl.create 16
  in
  let paused_runtimes_n = ref 0 in
  let others_rev = ref [] in
  List.iter
    (fun ((rid, st) as entry) ->
      match active_quota_rest_cause ~now_unix st with
      | None -> others_rev := entry :: !others_rev
      | Some cause ->
          incr paused_runtimes_n;
          let provider_id =
            match Hashtbl.find_opt runtimes_tbl rid with
            | Some (r : Wire_runtime.runtime_option) -> r.provider_id
            | None -> rid
          in
          let until_opt =
            match st.quota_rest_until_unix with
            | Some u when Float.is_finite u && u > 0.0 -> Some u
            | Some _ | None -> None
          in
          let total_for_prov =
            match Hashtbl.find_opt provider_totals provider_id with
            | Some n -> n
            | None -> 1
          in
          let next =
            match Hashtbl.find_opt grouped provider_id with
            | None ->
                {
                  provider_id;
                  paused_count = 1;
                  total_count = Int.max 1 total_for_prov;
                  primary_cause = cause;
                  soonest_until = until_opt;
                  soonest_reset_stated = st.quota_rest_reset_stated;
                }
            | Some cur ->
                let paused_count = cur.paused_count + 1 in
                let total_count = Int.max paused_count cur.total_count in
                let soonest_until, soonest_reset_stated =
                  match (cur.soonest_until, until_opt) with
                  | Some a, Some b ->
                      if b < a then (Some b, st.quota_rest_reset_stated)
                      else if Float.equal a b then
                        (Some a, cur.soonest_reset_stated || st.quota_rest_reset_stated)
                      else (Some a, cur.soonest_reset_stated)
                  | None, Some b -> (Some b, st.quota_rest_reset_stated)
                  | Some a, None -> (Some a, cur.soonest_reset_stated)
                  | None, None ->
                      (None, cur.soonest_reset_stated && st.quota_rest_reset_stated)
                in
                let primary_cause =
                  if Wire_runtime.is_payment_refused_cause cur.primary_cause
                  then cur.primary_cause
                  else if Wire_runtime.is_payment_refused_cause cause then cause
                  else cur.primary_cause
                in
                {
                  provider_id;
                  paused_count;
                  total_count;
                  primary_cause;
                  soonest_until;
                  soonest_reset_stated;
                }
          in
          Hashtbl.replace grouped provider_id next)
    degraded;
  let groups =
    Hashtbl.to_seq_values grouped
    |> List.of_seq
    |> List.sort (fun a b ->
           let c = compare_opt_until a.soonest_until b.soonest_until in
           if c <> 0 then c
           else
             let c2 = Int.compare b.paused_count a.paused_count in
             if c2 <> 0 then c2
             else String.compare a.provider_id b.provider_id)
  in
  (!paused_runtimes_n, groups, List.rev !others_rev)

let standing_override_for ~now_unix ~lang ~(rt : Runtime_store.t) rid =
  match Runtime_store.standing_for ~runtime_id:rid rt with
  | Some st when Wire_runtime.standing_is_degraded ~now_unix st -> (
      match st.credential_refused_at_unix with
      | Some _ ->
          Some
            ( Glyph.Live_failing
            , Theme.Status_critical
            , Say.resolve lang (Say.make ~ko:"인증 거부" ~en:"Cred refused")
            , "" )
      | None -> (
          match st.quota_rest_cause with
          | Some cause
            when match st.quota_rest_until_unix with
                 | None -> true
                 | Some u -> u > now_unix ->
              let glyph, tone, cause_lbl =
                quota_rest_cause_presentation ~lang cause
              in
              let eta =
                match st.quota_rest_until_unix with
                | Some ts -> " " ^ H.format_countdown ~now_unix ts
                | None -> ""
              in
              Some (glyph, tone, cause_lbl ^ eta, "")
          | Some _ | None ->
              if
                st.rate_limited
                && match st.rate_limit_resets_at_unix with
                   | None -> true
                   | Some u -> u > now_unix
              then
                let eta =
                  match st.rate_limit_resets_at_unix with
                  | Some ts -> " " ^ H.format_countdown ~now_unix ts
                  | None -> ""
                in
                Some
                  ( Glyph.Live_paused
                  , Theme.Status_attention
                  , Say.resolve lang (Say.make ~ko:"속도 제한" ~en:"Rate limit")
                    ^ eta
                  , "429" )
              else
                match st.failed_attempt_failure with
                | Some f ->
                    Some (Glyph.Warning_triangle, Theme.Status_attention, f, "")
                | None -> None))
  | Some _ | None -> None

let is_probe_effectively_ok ~now_unix ~rt ~runtimes_tbl ~usage_windows
    (p : Wire_runtime.provider_probe_row) =
  if standing_restricts_readiness ~now_unix ~rt p.runtime_id then false
  else
    match p.reachable with
    | Some true -> (
        match probe_quota_status ~now_unix ~runtimes_tbl ~usage_windows p with
        | Quota_ok -> true
        | Quota_cooldown _ | Quota_exhausted -> false)
    | Some false | None -> false

let is_probe_effectively_failed ~now_unix ~rt ~runtimes_tbl ~usage_windows
    (p : Wire_runtime.provider_probe_row) =
  if standing_restricts_readiness ~now_unix ~rt p.runtime_id then true
  else
    match p.reachable with
    | Some false -> true
    | Some true -> (
        match probe_quota_status ~now_unix ~runtimes_tbl ~usage_windows p with
        | Quota_ok -> false
        | Quota_cooldown _ | Quota_exhausted -> true)
    | None -> false

let draw_cooldown_health_summary ~grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp ~lang ~now_unix ~tz_offset_sec ~(rt : Runtime_store.t)
    (part : Runtime_store.partitioned_accounts) =
  let buckets = compute_quota_health_buckets part in
  let exhausted_n = buckets.exhausted in
  let cooldown_accts = buckets.cooldown_accts in
  let cooldown_only_n = buckets.cooldown in
  let healthy_n = buckets.healthy in
  let unreported_n = buckets.unreported in
  let active_probes, _ = Runtime_store.active_and_outside_probes rt in
  let runtimes = Runtime_store.runtime_options rt in
  let runtimes_tbl : (string, Wire_runtime.runtime_option) Hashtbl.t =
    Hashtbl.create 32
  in
  List.iter
    (fun (r : Wire_runtime.runtime_option) -> Hashtbl.replace runtimes_tbl r.id r)
    runtimes;
  let usage_windows = Observed.to_option rt.usage_windows in
  let active_ok =
    List.fold_left
      (fun acc p ->
        if is_probe_effectively_ok ~now_unix ~rt ~runtimes_tbl ~usage_windows p
        then acc + 1
        else acc)
      0 active_probes
  in
  let active_bad =
    List.filter
      (is_probe_effectively_failed ~now_unix ~rt ~runtimes_tbl ~usage_windows)
      active_probes
  in
  let active_http_bad =
    List.filter
      (fun (p : Wire_runtime.provider_probe_row) ->
        match p.reachable with Some false -> true | Some true | None -> false)
      active_probes
  in
  let degraded_standings = Runtime_store.degraded_standings ~now_unix rt in
  let paused_runtimes_n, quota_rest_groups, other_degraded_standings =
    group_active_quota_rest_standings ~now_unix ~runtimes ~runtimes_tbl
      degraded_standings
  in
  let has_payment_refused =
    List.exists
      (fun (g : quota_rest_provider_group) ->
        Wire_runtime.is_payment_refused_cause g.primary_cause)
      quota_rest_groups
  in
  let any_failed =
    Observed.is_failed rt.runtime_resolved
    || Observed.is_failed rt.runtime_probe
    || Observed.is_failed rt.usage_windows
    || Option.is_some rt.runtime_standings_error
  in
  let any_loading =
    Observed.is_loading rt.runtime_resolved
    || Observed.is_loading rt.runtime_probe
    || Observed.is_loading rt.usage_windows
  in
  let is_settled obs =
    match obs with
    | Observed.Value _ | Observed.Absent -> true
    | Observed.Loading _ | Observed.Unreported | Observed.Failed _ -> false
  in
  let all_observed =
    is_settled rt.runtime_resolved
    && is_settled rt.runtime_probe
    && is_settled rt.usage_windows
  in
  let any_stale =
    Observed.is_stale rt.runtime_resolved
    || Observed.is_stale rt.runtime_probe
    || Observed.is_stale rt.usage_windows
  in
  let badge =
    let alerts =
      List.length cooldown_accts
      + List.length active_http_bad
      + List.length degraded_standings
    in
    if alerts > 0 then
      let tone =
        if has_payment_refused then Theme.Status_critical
        else Theme.Status_attention
      in
      let glyph =
        if has_payment_refused then Glyph.Live_failing
        else Glyph.Action_required
      in
      Some
        (H.make_badge ~glyph ~tone
           (Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%d 경고" alerts)
                 ~en:(Printf.sprintf "%d alerts" alerts))))
    else if any_failed then
      Some
        (H.make_badge ~glyph:Glyph.Live_failing ~tone:Theme.Status_critical
           (Say.resolve lang (Say.make ~ko:"조회 실패" ~en:"Failed")))
    else if any_loading && not all_observed then
      Some
        (H.make_badge ~glyph:Glyph.Transport_reconnecting
           ~tone:Theme.Status_active
           (Say.resolve lang (Say.make ~ko:"불러오는 중" ~en:"Loading")))
    else if not all_observed then
      Some
        (H.make_badge ~glyph:Glyph.Missing_unreported
           ~tone:Theme.Status_historical
           (Say.resolve lang (Say.make ~ko:"미관측" ~en:"Unreported")))
    else if any_stale then
      Some
        (H.make_badge ~glyph:Glyph.Transport_stale ~tone:Theme.Status_attention
           (Say.resolve lang (Say.make ~ko:"갱신 지연" ~en:"Stale")))
    else
      Some
        (H.make_badge ~glyph:Glyph.Live_healthy ~tone:Theme.Status_ok
           (Say.resolve lang (Say.make ~ko:"정상" ~en:"Healthy")))
  in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ?badge
         (Say.resolve lang
            (Say.make ~ko:"일시 중지 · 프로바이더 헬스 & 24h 요약"
               ~en:"Paused · Provider Health & 24h")))
  in
  let content = H.pad_content ~bp inner in
  if Rect.is_empty content then ()
  else
    let y = ref content.y in
    let bottom = Rect.bottom content in
    let bg = Color.of_rgb theme.surface_1 in
    (* 1. Provider Health Stacked Bar *)
    if !y + 1 < bottom then begin
      let bar_rect = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:2 in
      let spec : Chart.Spec.t =
        {
          title = Say.make ~ko:"헬스" ~en:"Health";
          hotkey_hint = None;
          kind =
            Chart.Spec.Stacked_bar
              {
                segments =
                  [
                    ( Say.make ~ko:"정상" ~en:"OK"
                    , float_of_int healthy_n
                    , Theme.Status_ok );
                    ( Say.make ~ko:"일시 중지" ~en:"Paused"
                    , float_of_int cooldown_only_n
                    , Theme.Status_attention );
                    ( Say.make ~ko:"소진" ~en:"Full"
                    , float_of_int exhausted_n
                    , Theme.Status_critical );
                    ( Say.make ~ko:"미보고" ~en:"Unrep"
                    , float_of_int unreported_n
                    , Theme.Status_historical );
                  ];
                total_label = Say.literal "";
                unit = Format_val.Count;
              };
        }
      in
      ignore
        (Chart.draw grid ~rect:bar_rect ~theme ~caps:H.default_caps ~lang
           ~show_title:false spec);
      y := !y + 2
    end;
    (* 2. Paused Runtimes & Exhausted Alerts *)
    if !y < bottom then begin
      let total_runtimes_n = List.length runtimes in
      let restricted_n =
        List.fold_left
          (fun acc (r : Wire_runtime.runtime_option) ->
            let http_bad =
              List.exists
                (fun (p : Wire_runtime.provider_probe_row) ->
                  String.equal p.runtime_id r.id)
                active_http_bad
            in
            if standing_restricts_readiness ~now_unix ~rt r.id || http_bad then
              acc + 1
            else acc)
          0 runtimes
      in
      let avail_n = Int.max 0 (total_runtimes_n - restricted_n) in
      let alerts_label =
        if paused_runtimes_n > 0 && total_runtimes_n > 0 then
          Say.resolve lang
            (Say.make
               ~ko:
                 (Printf.sprintf "일시 중지 · 한도 경고 (%d/%d · 가용 %d)"
                    paused_runtimes_n total_runtimes_n avail_n)
               ~en:
                 (Printf.sprintf "Paused & Alerts (%d/%d · %d avail)"
                    paused_runtimes_n total_runtimes_n avail_n))
        else if restricted_n > 0 && total_runtimes_n > 0 then
          Say.resolve lang
            (Say.make
               ~ko:
                 (Printf.sprintf "일시 중지 · 한도 경고 (가용 %d/%d)"
                    avail_n total_runtimes_n)
               ~en:
                 (Printf.sprintf "Paused & Alerts (%d/%d avail)"
                    avail_n total_runtimes_n))
        else
          Say.resolve lang
            (Say.make ~ko:"일시 중지 · 한도 경고" ~en:"Paused & Alerts")
      in
      H.draw_divider ~grid ~rect:content ~y:!y ~theme ~label:alerts_label ();
      incr y
    end;
    if cooldown_accts = [] && active_bad = [] && degraded_standings = [] then begin
      if !y < bottom then begin
        let tone, glyph, msg =
          if any_failed then
            ( Theme.Status_critical
            , Glyph.Live_failing
            , Say.resolve lang
                (Say.make ~ko:"프로바이더 상태 조회 실패"
                   ~en:"Provider health fetch failed") )
          else if any_loading && not all_observed then
            ( Theme.Status_active
            , Glyph.Transport_reconnecting
            , Say.resolve lang
                (Say.make ~ko:"프로바이더 헬스 불러오는 중..."
                   ~en:"Loading provider health...") )
          else if not all_observed then
            ( Theme.Status_historical
            , Glyph.Missing_unreported
            , Say.resolve lang
                (Say.make ~ko:"프로바이더 헬스 미관측"
                   ~en:"Provider health not yet observed") )
          else if any_stale then
            ( Theme.Status_attention
            , Glyph.Transport_stale
            , Say.resolve lang
                (Say.make ~ko:"프로바이더 헬스 갱신 지연"
                   ~en:"Provider health data stale") )
          else
            ( Theme.Status_ok
            , Glyph.Live_healthy
            , Say.resolve lang
                (Say.make ~ko:"일시 중지 없음 · 보고된 모든 계정 정상"
                   ~en:"No paused runtimes · all reported accounts healthy") )
        in
        ignore
          (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y ~max_w:content.w
             ~style:(H.status_style ~theme tone)
             (Glyph.to_utf8 glyph ^ " " ^ msg));
        incr y
      end
    end
    else begin
      let total_alert_rows =
        List.length other_degraded_standings
        + List.length quota_rest_groups
        + List.length cooldown_accts
        + List.length active_http_bad
      in
      let alert_budget = Int.max 1 (Int.min 6 (bottom - !y - 5)) in
      let has_overflow = total_alert_rows > alert_budget in
      let max_alerts =
        if has_overflow && alert_budget >= 2 then alert_budget - 1
        else alert_budget
      in
      let shown = ref 0 in
      List.iter
        (fun (rid, (st : Wire_runtime.runtime_standing)) ->
          if !y < bottom && !shown < max_alerts then begin
            let lbl = Wire_runtime.human_runtime_slot_label ~runtimes rid in
            let glyph, tone, detail =
              match st.credential_refused_at_unix with
              | Some _ ->
                  ( Glyph.Live_failing
                  , Theme.Status_critical
                  , Say.resolve lang (Say.make ~ko:"인증 거부" ~en:"Cred refused") )
              | None ->
                  if
                    st.rate_limited
                    && match st.rate_limit_resets_at_unix with
                       | None -> true
                       | Some u -> u > now_unix
                  then
                    let eta =
                      match st.rate_limit_resets_at_unix with
                      | Some ts -> " " ^ H.format_countdown ~now_unix ts
                      | None -> ""
                    in
                    ( Glyph.Live_paused
                    , Theme.Status_attention
                    , Say.resolve lang (Say.make ~ko:"속도 제한" ~en:"Rate limit")
                      ^ eta )
                  else
                    match st.failed_attempt_failure with
                    | Some f ->
                        (Glyph.Warning_triangle, Theme.Status_attention, f)
                    | None ->
                        ( Glyph.Live_paused
                        , Theme.Status_attention
                        , Say.resolve lang
                            (Say.make ~ko:"런타임 저하" ~en:"Degraded") )
            in
            Card.draw_left_rail ~bg ~tone grid ~x:content.x ~y:!y ~h:1 ~theme;
            ignore
              (H.put_clipped ~grid ~clip:content ~x:(content.x + 2) ~y:!y
                 ~max_w:(Int.max 0 (content.w - 2))
                 ~style:(H.status_style ~theme tone)
                 (Printf.sprintf "%s %s · %s"
                    (Glyph.to_utf8 glyph)
                    lbl detail));
            incr y;
            incr shown
          end)
        other_degraded_standings;
      let group_label_counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
      List.iter
        (fun (grp : quota_rest_provider_group) ->
          let base =
            Wire_runtime.human_provider_id_label ~runtimes grp.provider_id
          in
          let n =
            match Hashtbl.find_opt group_label_counts base with
            | Some k -> k
            | None -> 0
          in
          Hashtbl.replace group_label_counts base (n + 1))
        quota_rest_groups;
      List.iter
        (fun (grp : quota_rest_provider_group) ->
          if !y < bottom && !shown < max_alerts then begin
            let base_lbl =
              Wire_runtime.human_provider_id_label ~runtimes grp.provider_id
            in
            let disambig_suffix =
              match Hashtbl.find_opt group_label_counts base_lbl with
              | Some n when n > 1 ->
                  let suffix = provider_disambiguator grp.provider_id in
                  if String.equal suffix "" then "" else " #" ^ suffix
              | Some _ | None -> ""
            in
            let prov_lbl = base_lbl ^ disambig_suffix in
            let glyph, tone, cause_lbl =
              quota_rest_cause_presentation ~lang grp.primary_cause
            in
            let eta_s =
              match grp.soonest_until with
              | Some ts ->
                  let dur =
                    match format_cooldown_duration ~now_unix ts with
                    | Some d -> d
                    | None -> H.format_countdown ~now_unix ts
                  in
                  let est_prefix =
                    if grp.soonest_reset_stated then "" else "~"
                  in
                  let clock =
                    match format_local_release_clock ~tz_offset_sec ~now_unix ts with
                    | Some c -> Printf.sprintf " (%s)" c
                    | None -> ""
                  in
                  Printf.sprintf " · %s%s%s" est_prefix dur clock
              | None -> ""
            in
            let text_x = content.x + 2 in
            let text_w = Int.max 0 (content.w - 2) in
            let glyph_s = Glyph.to_utf8 glyph ^ " " in
            let ratio_s =
              Printf.sprintf " (%d/%d)" grp.paused_count grp.total_count
            in
            let right_detail = Printf.sprintf "%s%s" cause_lbl eta_s in
            let full_row =
              Printf.sprintf "%s%s%s · %s" glyph_s prov_lbl ratio_s right_detail
            in
            let row_text =
              if Grapheme.display_width full_row <= text_w then full_row
              else
                let fixed_w =
                  Grapheme.display_width glyph_s
                  + Grapheme.display_width ratio_s
                  + 3
                  + Grapheme.display_width right_detail
                in
                let max_prov_w = text_w - fixed_w in
                if max_prov_w >= 6 then
                  let fitted_prov =
                    let suf_w = Grapheme.display_width disambig_suffix in
                    if suf_w > 0 && max_prov_w >= suf_w + 4 then
                      Grapheme.truncate_to_width ~max_width:(max_prov_w - suf_w)
                        base_lbl
                      ^ disambig_suffix
                    else
                      Grapheme.truncate_to_width ~max_width:max_prov_w prov_lbl
                  in
                  Printf.sprintf "%s%s%s · %s" glyph_s fitted_prov ratio_s
                    right_detail
                else full_row
            in
            Card.draw_left_rail ~bg ~tone grid ~x:content.x ~y:!y ~h:1 ~theme;
            ignore
              (H.put_clipped ~grid ~clip:content ~x:text_x ~y:!y
                 ~max_w:text_w ~style:(H.status_style ~theme tone) row_text);
            incr y;
            incr shown
          end)
        quota_rest_groups;
      List.iter
        (fun (a : Wire_runtime.account_usage) ->
          if !y < bottom && !shown < max_alerts then begin
            let alias = Runtime_store.account_display_name ~lang rt a in
            let tone, detail =
              match a.cost_state with
              | Format_val.Exhausted_zero ->
                  ( Theme.Status_critical
                  , Format_val.format_cost Format_val.Exhausted_zero ~lang )
              | Format_val.Amount _ | Format_val.Subscription_zero
              | Format_val.Unreported -> (
                  match
                    List.find_opt is_window_exhausted (subscription_windows_of a)
                  with
                  | Some w ->
                      let eta =
                        match w.resets_at_unix with
                        | Some ts ->
                            " · "
                            ^ Say.resolve lang (Say.make ~ko:"리셋 " ~en:"rst ")
                            ^ H.format_countdown ~now_unix ts
                        | None -> ""
                      in
                      ( Theme.Status_attention
                      , Printf.sprintf "%s 100%%%s"
                          (compact_window_label w.kind)
                          eta )
                  | None ->
                      ( Theme.Status_attention
                      , Say.resolve lang (Say.make ~ko:"한도 도달" ~en:"limit hit")
                      ))
            in
            Card.draw_left_rail ~bg ~tone grid ~x:content.x ~y:!y ~h:1 ~theme;
            let text_x = content.x + 2 in
            let text_w = Int.max 0 (content.w - 2) in
            let adv =
              H.put_clipped ~grid ~clip:content ~x:text_x ~y:!y ~max_w:text_w
                ~style:(H.status_style ~theme ~attrs:Attr.bold tone)
                (Glyph.to_utf8 Glyph.Live_failing ^ " " ^ alias)
            in
            let rem_w = text_w - adv - 2 in
            if rem_w > 4 then
              ignore
                (H.put_right ~grid ~clip:content ~right_x:(Rect.right content)
                   ~y:!y ~max_w:rem_w ~style:(H.whisper_style ~theme ()) detail);
            incr y;
            incr shown
          end)
        cooldown_accts;
      List.iter
        (fun (p : Wire_runtime.provider_probe_row) ->
          if !y < bottom && !shown < max_alerts then begin
            let lbl = Wire_runtime.human_runtime_slot_label ~runtimes p.runtime_id in
            let reason =
              match p.http_status, p.error with
              | Some 429, _ -> "HTTP 429"
              | Some code, _ -> Printf.sprintf "HTTP %d" code
              | None, Some e -> e
              | None, None -> p.status
            in
            Card.draw_left_rail ~bg ~tone:Theme.Status_critical grid
              ~x:content.x ~y:!y ~h:1 ~theme;
            ignore
              (H.put_clipped ~grid ~clip:content ~x:(content.x + 2) ~y:!y
                 ~max_w:(Int.max 0 (content.w - 2))
                 ~style:(H.status_style ~theme Theme.Status_critical)
                 (Printf.sprintf "%s %s · %s"
                    (Glyph.to_utf8 Glyph.Live_failing)
                    lbl reason));
            incr y;
            incr shown
          end)
        active_http_bad;
      let hidden_alerts = Int.max 0 (total_alert_rows - !shown) in
      if hidden_alerts > 0 && !y < bottom - 4 then begin
        let more_txt =
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "+%d개 더" hidden_alerts)
               ~en:(Printf.sprintf "+%d more" hidden_alerts))
        in
        ignore
          (H.put_clipped ~grid ~clip:content ~x:(content.x + 2) ~y:!y
             ~max_w:(Int.max 0 (content.w - 2))
             ~style:(H.whisper_style ~theme ()) more_txt);
        incr y
      end
    end;
    (* 3. Failover Lane Reachability & 24h Telemetry Summary *)
    if !y < bottom then begin
      H.draw_divider ~grid ~rect:content ~y:!y ~theme
        ~label:
          (Say.resolve lang
             (Say.make ~ko:"레인 헬스 · 24h 호출 요약"
                ~en:"Lane Health & 24h Summary"))
        ();
      incr y
    end;
    if !y < bottom then begin
      let lanes_n =
        match Observed.to_option rt.runtime_resolved with
        | Some s -> List.length s.lanes
        | None -> 0
      in
      let total_p = List.length active_probes in
      let lane_lbl = Say.resolve lang (Say.make ~ko:"활성 레인" ~en:"Lanes") in
      let lane_val =
        if total_p > 0 then
          Printf.sprintf "%d · %d/%d %s" lanes_n active_ok total_p
            (Say.resolve lang (Say.make ~ko:"가용" ~en:"ok"))
        else Printf.sprintf "%d %s" lanes_n (Say.resolve lang (Say.make ~ko:"선언" ~en:"declared"))
      in
      let lane_tone =
        if total_p = 0 then Theme.Status_active
        else if active_bad = [] then Theme.Status_ok
        else if active_ok > 0 then Theme.Status_attention
        else Theme.Status_critical
      in
      let bar_w = 8 in
      let draw_bar = total_p > 0 && content.w >= 44 in
      let kv_max_w =
        if draw_bar then Int.max 0 (content.w - bar_w - 1) else content.w
      in
      H.put_kv ~grid ~clip:content ~x:content.x ~y:!y ~max_w:kv_max_w ~theme
        ~key_w:11 ~key:lane_lbl
        ~value_style:(H.status_style ~theme ~attrs:Attr.bold lane_tone)
        lane_val;
      if draw_bar then begin
        let bx = Rect.right content - bar_w in
        ignore
          (Chart.draw_ratio_bar_run ~clip:content grid ~x:bx ~y:!y ~width:bar_w
             ~theme ~bg ~unicode:true ~gradient:Chart.Gradient.Efficiency
             ~ratio:(float_of_int active_ok /. float_of_int total_p))
      end;
      incr y
    end;
    if !y < bottom then begin
      let cache_obs = Runtime_store.effective_cache_hit_pct rt in
      let spend_bd = Runtime_store.spend_24h_breakdown rt in
      let cache_s = Format_val.format_observed Format_val.Percent cache_obs ~lang in
      let spend_s =
        Format_val.format_observed Format_val.Usd spend_bd.total_usd ~lang
      in
      let spend_lbl =
        match spend_bd.source with
        | Runtime_store.Spend_provider_24h ->
            Say.resolve lang (Say.make ~ko:"프로바이더" ~en:"Prov")
        | Runtime_store.Spend_keeper_turns_24h ->
            Say.resolve lang (Say.make ~ko:"키퍼 귀속" ~en:"Keeper")
        | Runtime_store.Spend_unreported ->
            Say.resolve lang (Say.make ~ko:"지출" ~en:"Spend")
      in
      let val_style =
        match Observed.to_option cache_obs with
        | Some pct when pct >= 70.0 ->
            H.status_style ~theme ~attrs:Attr.bold Theme.Status_ok
        | Some pct when pct >= 40.0 ->
            H.status_style ~theme ~attrs:Attr.bold Theme.Status_attention
        | Some _ | None -> H.text_style ~theme ()
      in
      H.put_kv ~grid ~clip:content ~x:content.x ~y:!y ~max_w:content.w ~theme
        ~key_w:11
        ~key:(Say.resolve lang (Say.make ~ko:"24h 캐시" ~en:"24h Cache"))
        ~value_style:val_style
        (Printf.sprintf "%s · %s %s" cache_s spend_lbl spend_s);
      incr y
    end;
    if !y < bottom then begin
      let calls_txt =
        match Runtime_store.tool_series_totals rt with
        | Some (calls, fails, p95_opt) ->
            let p95_s =
              match p95_opt with
              | Some ms ->
                  " · p95 "
                  ^ Format_val.format_value Format_val.Milliseconds ms
              | None -> ""
            in
            let fail_s =
              if fails > 0 then
                Printf.sprintf " (%d %s)" fails
                  (Say.resolve lang (Say.make ~ko:"실패" ~en:"fail"))
              else ""
            in
            Printf.sprintf "%s %s%s%s"
              (Format_val.format_value Format_val.Count (float_of_int calls))
              (Say.resolve lang (Say.make ~ko:"호출" ~en:"calls"))
              fail_s p95_s
        | None -> Glyph.to_utf8 Glyph.Missing_absent
      in
      H.put_kv ~grid ~clip:content ~x:content.x ~y:!y ~max_w:content.w ~theme
        ~key_w:11
        ~key:(Say.resolve lang (Say.make ~ko:"24h 도구" ~en:"24h Tools"))
        calls_txt;
      incr y
    end;
    if !y < bottom then begin
      let probe_meta =
        match Observed.to_option rt.runtime_probe with
        | Some pr ->
            let age =
              match pr.cache_age_sec with
              | Some s -> Format_val.format_duration_s s
              | None -> Glyph.to_utf8 Glyph.Missing_absent
            in
            Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "최근 프로브 %s 전 · [r] 즉시 프로브" age)
                 ~en:(Printf.sprintf "Last probe %s ago · [r] probe now" age))
        | None ->
            Say.resolve lang
              (Say.make ~ko:"[r] 프로바이더 프로브 실행"
                 ~en:"[r] Run provider probe")
      in
      ignore
        (H.put_clipped ~grid ~clip:content ~x:content.x ~y:(bottom - 1)
           ~max_w:content.w ~style:(H.whisper_style ~theme ()) probe_meta)
    end

type credit_list_row =
  | Row_account of {
      acct : Wire_runtime.account_usage;
      tier : [ `Credit | `Sub | `Unreported ];
      store_idx : int;
    }
  | Row_unreported_toggle of {
      count : int;
      expanded : bool;
      preview_names : string;
      store_idx : int;
    }

let max_subscription_window_ratio (acct : Wire_runtime.account_usage) =
  match acct.state with
  | Wire_runtime.Account_reported ws ->
      List.fold_left
        (fun best (w : Wire_runtime.usage_window) ->
          let ratio_opt =
            match w.utilization with
            | Wire_runtime.Util_fraction f when Float.is_finite f ->
                Some (Float.max 0.0 (Float.min 1.0 f))
            | Wire_runtime.Util_percent p ->
                Some (Float.max 0.0 (Float.min 1.0 (float_of_int p /. 100.0)))
            | Wire_runtime.Util_fraction _
            | Wire_runtime.Util_usd _
            | Wire_runtime.Util_credit_balance _
            | Wire_runtime.Util_credit_unlimited
            | Wire_runtime.Util_credit_retracted ->
                None
          in
          match (best, ratio_opt) with
          | Some b, Some r -> Some (Float.max b r)
          | None, Some r -> Some r
          | Some b, None -> Some b
          | None, None -> None)
        None ws
  | Wire_runtime.Account_not_reported_since_start
  | Wire_runtime.Account_reported_no_windows _ ->
      None

let is_subscription_saturated (acct : Wire_runtime.account_usage) =
  match acct.cost_state with
  | Format_val.Subscription_zero -> (
      match max_subscription_window_ratio acct with
      | Some r when r >= 0.995 -> true
      | Some _ | None -> is_account_cooldown_or_exhausted acct)
  | Format_val.Amount _ | Format_val.Exhausted_zero | Format_val.Unreported ->
      false

let draw_credit_balances ~grid ~cache ~(rect : Rect.t) ~(theme : Theme.t) ~bp
    ~lang ~now_unix ~(rt : Runtime_store.t)
    (part : Runtime_store.partitioned_accounts)
    (obs : Wire_runtime.provider_usage_windows Observed.t) ~focused =
  let buckets = compute_quota_health_buckets part in
  let exhausted_n = buckets.exhausted in
  let sat_sub_n = buckets.cooldown in
  let reported_n =
    List.length part.exhausted_and_credits + List.length part.active_subscriptions
  in
  let badge =
    if exhausted_n > 0 && sat_sub_n > 0 then
      Some
        (H.make_badge ~glyph:Glyph.Live_failing ~tone:Theme.Status_critical
           (Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%d 소진 · %d 한도" exhausted_n sat_sub_n)
                 ~en:(Printf.sprintf "%d Exh · %d Full" exhausted_n sat_sub_n))))
    else if exhausted_n > 0 then
      Some
        (H.make_badge ~glyph:Glyph.Live_failing ~tone:Theme.Status_critical
           (Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%d 소진" exhausted_n)
                 ~en:(Printf.sprintf "%d Exhausted" exhausted_n))))
    else if sat_sub_n > 0 then
      Some
        (H.make_badge ~glyph:Glyph.Live_failing ~tone:Theme.Status_critical
           (Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%d 한도 소진" sat_sub_n)
                 ~en:(Printf.sprintf "%d Limit Full" sat_sub_n))))
    else
      Some
        (H.make_badge ~glyph:Glyph.Live_healthy ~tone:Theme.Status_ok
           (Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%d 활성" reported_n)
                 ~en:(Printf.sprintf "%d active" reported_n))))
  in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ?badge ~focused
         ~hotkey:
           (Say.resolve lang
              (match Runtime_store.active_setup_login_id rt with
              | Some _ ->
                  Say.make ~ko:"[u] 미보고 · [e] 로그인 입력"
                    ~en:"[u] Unreported · [e] Login Input"
              | None ->
                  Say.make ~ko:"[u] 미보고 · [e] 설정"
                    ~en:"[u] Unreported · [e] Settings"))
         ~footer_hint:
           (Say.resolve lang
              (Say.make ~ko:"$0 구독 ≠ $0 소진 ≠ ? 미보고"
                 ~en:"$0 Sub != $0 Exhausted != ? Unreported"))
         (Say.resolve lang
            (Say.make ~ko:"API 크레딧 잔액 · 계정 현황"
               ~en:"API Credit Balances & Accounts")))
  in
  if Rect.is_empty inner then ()
  else if
    part.exhausted_and_credits = []
    && part.active_subscriptions = []
    && part.unreported = []
  then
    H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp inner) ~theme
      ~lang ~filter_query:rt.filter_query obs
  else
    let visible = Runtime_store.visible_credit_accounts rt in
    let _ = visible in
    let idx = ref 0 in
    let rows_acc = ref [] in
    List.iter
      (fun acct ->
        rows_acc := Row_account { acct; tier = `Credit; store_idx = !idx } :: !rows_acc;
        incr idx)
      part.exhausted_and_credits;
    List.iter
      (fun acct ->
        rows_acc := Row_account { acct; tier = `Sub; store_idx = !idx } :: !rows_acc;
        incr idx)
      part.active_subscriptions;
    if part.unreported <> [] then begin
      let preview_names =
        part.unreported |> H.safe_take 3
        |> List.map (Runtime_store.account_display_name ~lang rt)
        |> String.concat ", "
      in
      let toggle_idx = !idx in
      rows_acc :=
        Row_unreported_toggle
          {
            count = List.length part.unreported;
            expanded = rt.show_unreported_accounts;
            preview_names;
            store_idx = toggle_idx;
          }
        :: !rows_acc;
      incr idx;
      if rt.show_unreported_accounts then
        List.iter
          (fun acct ->
            rows_acc :=
              Row_account { acct; tier = `Unreported; store_idx = !idx }
              :: !rows_acc;
            incr idx)
          part.unreported
    end;
    let rows_arr = Array.of_list (List.rev !rows_acc) in
    let total_rows = Array.length rows_arr in
    let sel_idx = H.clamp_index total_rows rt.selected_index in
    let truncated_rows = total_rows > inner.h && inner.h >= 2 in
    let list_h = if truncated_rows then inner.h - 1 else inner.h in
    let start_row, _ =
      Table.compute_viewport ~total_rows ~viewport_rows:list_h
        ~scroll:rt.scroll_offset ~selected:(Some sel_idx)
    in
    let pad_r = if inner.w >= 24 then 2 else 1 in
    for row_i = 0 to list_h - 1 do
      let vi = start_row + row_i in
      if vi < total_rows then begin
        let py = inner.y + row_i in
        let row_rect = Rect.make ~x:inner.x ~y:py ~w:inner.w ~h:1 in
        let text_x = inner.x + 2 in
        let right_edge = Rect.right inner - pad_r in
        let content_w = Int.max 0 (right_edge - text_x) in
        match rows_arr.(vi) with
        | Row_unreported_toggle { count; expanded; preview_names; store_idx } ->
            let is_sel = Int.equal store_idx sel_idx in
            let row_bg =
              if is_sel then H.selected_row_bg ~theme ~focused
              else theme.surface_1
            in
            if is_sel then
              H.paint_selected_row_bg ~grid ~clip:inner ~row_rect ~theme
                ~focused ();
            let caret =
              if expanded then Glyph.Expand_open else Glyph.Expand_closed
            in
            let label =
              if expanded then
                Say.resolve lang
                  (Say.make
                     ~ko:
                       (Printf.sprintf "%s 미보고 API 키 (%d개) · [u/Enter] 접기"
                          (Glyph.to_utf8 caret) count)
                     ~en:
                       (Printf.sprintf
                          "%s Unreported API keys (%d) · [u/Enter] collapse"
                          (Glyph.to_utf8 caret) count))
              else
                Say.resolve lang
                  (Say.make
                     ~ko:
                       (Printf.sprintf
                          "%s 미보고 API 키 (%d개) · [u/Enter] 펼치기"
                          (Glyph.to_utf8 caret) count)
                     ~en:
                       (Printf.sprintf
                          "%s Unreported API keys (%d) · [u/Enter] expand"
                          (Glyph.to_utf8 caret) count))
            in
            let style =
              if is_sel then
                H.row_text_style ~theme ~selected:true ~focused ~bg:row_bg
              else H.whisper_style ~theme ~bg:row_bg ()
            in
            let adv =
              H.put_clipped ~grid ~clip:row_rect ~x:text_x ~y:py ~max_w:content_w
                ~style label
            in
            if
              (not expanded)
              && (not (String.equal preview_names ""))
              && content_w - adv > 12
            then
              ignore
                (H.put_right ~grid ~clip:row_rect ~right_x:right_edge ~y:py
                   ~max_w:(content_w - adv - 2)
                   ~style:(H.whisper_style ~theme ~bg:row_bg ())
                   preview_names)
        | Row_account { acct; tier; store_idx } ->
            let is_sel = Int.equal store_idx sel_idx in
            let row_bg =
              if is_sel then H.selected_row_bg ~theme ~focused
              else theme.surface_1
            in
            let row_bg_c = Color.of_rgb row_bg in
            if is_sel then
              H.paint_selected_row_bg ~grid ~clip:inner ~row_rect ~theme
                ~focused ();
            let alias = Runtime_store.account_display_name ~lang rt acct in
            let max_sub_ratio = max_subscription_window_ratio acct in
            let sub_saturated = is_subscription_saturated acct in
            let cost_str =
              if sub_saturated then
                Say.resolve lang
                  (Say.make ~ko:"한도 소진 (구독)" ~en:"Limit Exhausted (Sub)")
              else Format_val.format_cost acct.cost_state ~lang
            in
            let tone, glyph =
              match acct.cost_state with
              | Format_val.Amount _ -> (Theme.Status_ok, Glyph.Live_healthy)
              | Format_val.Subscription_zero ->
                  if sub_saturated then
                    (Theme.Status_critical, Glyph.Live_failing)
                  else
                    (match max_sub_ratio with
                     | Some r when r >= 0.80 ->
                         (Theme.Status_attention, Glyph.Live_healthy)
                     | Some _ | None -> (Theme.Status_active, Glyph.Live_healthy))
              | Format_val.Exhausted_zero ->
                  (Theme.Status_critical, Glyph.Live_failing)
              | Format_val.Unreported ->
                  (Theme.Status_historical, Glyph.Missing_unreported)
            in
            let ratio_and_detail =
              match acct.cost_state with
              | Format_val.Subscription_zero -> (
                  match max_sub_ratio with
                  | Some r -> Some (r, Chart.Gradient.Thermal, cost_str)
                  | None -> None)
              | Format_val.Exhausted_zero ->
                  Some (1.0, Chart.Gradient.Thermal, cost_str)
              | Format_val.Amount _ | Format_val.Unreported -> (
                  match acct.state with
                  | Wire_runtime.Account_reported ws ->
                      List.find_map
                        (fun (w : Wire_runtime.usage_window) ->
                          match w.utilization with
                          | Wire_runtime.Util_credit_balance
                              { currency = _; total = Some tot; remaining }
                            when tot > 0.0 ->
                              let rem_ratio =
                                Float.max 0.0 (Float.min 1.0 (remaining /. tot))
                              in
                              Some
                                ( rem_ratio
                                , Chart.Gradient.Efficiency
                                , Printf.sprintf "%s / %s"
                                    (Format_val.format_value Format_val.Usd
                                       remaining)
                                    (Format_val.format_value Format_val.Usd tot) )
                          | Wire_runtime.Util_usd { used; limit = Some lim }
                            when lim > 0.0 ->
                              let used_ratio =
                                Float.max 0.0 (Float.min 1.0 (used /. lim))
                              in
                              Some
                                ( used_ratio
                                , Chart.Gradient.Thermal
                                , Printf.sprintf "%s / %s"
                                    (Format_val.format_value Format_val.Usd used)
                                    (Format_val.format_value Format_val.Usd lim) )
                          | Wire_runtime.Util_credit_balance _
                          | Wire_runtime.Util_usd _
                          | Wire_runtime.Util_fraction _
                          | Wire_runtime.Util_percent _
                          | Wire_runtime.Util_credit_unlimited
                          | Wire_runtime.Util_credit_retracted ->
                              None)
                        ws
                  | Wire_runtime.Account_not_reported_since_start
                  | Wire_runtime.Account_reported_no_windows _ ->
                      None)
            in
            let name_w = Int.max 12 (Int.min 26 (content_w * 46 / 100)) in
            Cell_grid.put_glyph ~clip:row_rect grid ~x:text_x ~y:py
              ~style:(H.status_style ~theme ~bg:row_bg tone)
              glyph;
            let name_style =
              match tier with
              | `Unreported ->
                  if is_sel then H.anchor_style ~theme ~bg:row_bg ()
                  else H.whisper_style ~theme ~bg:row_bg ()
              | `Credit | `Sub ->
                  if is_sel then H.anchor_style ~theme ~bg:row_bg ()
                  else if sub_saturated then
                    H.status_style ~theme ~bg:row_bg ~attrs:Attr.bold
                      Theme.Status_critical
                  else H.text_style ~theme ~bg:row_bg ()
            in
            ignore
              (H.put_clipped ~grid ~clip:row_rect ~x:(text_x + 2) ~y:py
                 ~max_w:(Int.max 0 (name_w - 2)) ~style:name_style alias);
            let val_x = text_x + name_w + 1 in
            let rem_w = right_edge - val_x in
            if rem_w > 0 then
              match ratio_and_detail with
              | Some (ratio, grad, detail_s) when rem_w >= 20 ->
                  let label_s =
                    match acct.cost_state with
                    | Format_val.Exhausted_zero -> cost_str
                    | Format_val.Subscription_zero -> cost_str
                    | Format_val.Amount _ | Format_val.Unreported -> detail_s
                  in
                  let lw = Grapheme.display_width label_s in
                  let bar_w = Int.max 6 (Int.min 14 (rem_w - lw - 2)) in
                  ignore
                    (Chart.draw_ratio_bar_run ~clip:row_rect grid ~x:val_x ~y:py
                       ~width:bar_w ~theme ~bg:row_bg_c ~unicode:true
                       ~gradient:grad ~ratio);
                  ignore
                    (H.put_right ~grid ~clip:row_rect ~right_x:right_edge ~y:py
                       ~max_w:(Int.max 0 (rem_w - bar_w - 1))
                       ~style:(H.status_style ~theme ~bg:row_bg ~attrs:Attr.bold tone)
                       label_s)
              | Some _ | None ->
                  let v_style =
                    match tier with
                    | `Unreported -> H.whisper_style ~theme ~bg:row_bg ()
                    | `Credit | `Sub ->
                        H.status_style ~theme ~bg:row_bg ~attrs:Attr.bold tone
                  in
                  ignore
                    (H.put_right ~grid ~clip:row_rect ~right_x:right_edge ~y:py
                       ~max_w:rem_w ~style:v_style cost_str)
      end
    done;
    if truncated_rows then begin
      let above_n = start_row in
      let below_n = Int.max 0 (total_rows - (start_row + list_h)) in
      let parts =
        (if above_n > 0 then
           [ Printf.sprintf "%s %d" (Glyph.to_utf8 Glyph.Delta_up) above_n ]
         else [])
        @
        if below_n > 0 then
          [
            Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%s %d개 더" (Glyph.to_utf8 Glyph.Delta_down) below_n)
                 ~en:(Printf.sprintf "%s %d more" (Glyph.to_utf8 Glyph.Delta_down) below_n));
          ]
        else []
      in
      let ov_txt = String.concat " · " parts in
      if not (String.equal ov_txt "") then
        ignore
          (H.put_right ~grid ~clip:inner ~right_x:(Rect.right inner - pad_r)
             ~y:(Rect.bottom inner - 1) ~max_w:(Int.max 0 (inner.w - 4))
             ~style:(H.accent_style ~theme ()) ov_txt)
    end
    else if total_rows + 4 <= inner.h && total_rows > 0 then begin
      (* Fill spare bottom space cleanly with Selected Account Quota Windows *)
      let det_y = inner.y + total_rows + 1 in
      let det_bot = Rect.bottom inner in
      let pad_x = Layout.card_pad_x bp in
      match rows_arr.(sel_idx) with
      | Row_account { acct; tier = (`Credit | `Sub); _ } ->
          let alias = Runtime_store.account_display_name ~lang rt acct in
          H.draw_divider ~grid ~rect:inner ~y:det_y ~theme ~pad_x
            ~label:
              (Printf.sprintf "%s · %s"
                 (Say.resolve lang (Say.make ~ko:"선택 계정 상세" ~en:"Selected Account"))
                 alias)
            ();
          let dy = ref (det_y + 1) in
          let content_x = inner.x + pad_x in
          let content_w = Int.max 0 (inner.w - (2 * pad_x)) in
          let right_x = Rect.right inner - pad_x in
          if !dy < det_bot then begin
            let prov_names =
              acct.providers
              |> List.map (fun (p : Wire_runtime.usage_provider_ref) -> p.display_name)
              |> H.safe_take 3 |> String.concat ", "
            in
            let status_s =
              if is_subscription_saturated acct then
                Say.resolve lang
                  (Say.make ~ko:"✕ 한도 소진 (구독)" ~en:"✕ Limit Exhausted (Sub)")
              else Format_val.format_cost acct.cost_state ~lang
            in
            H.put_kv ~grid ~clip:inner ~x:content_x ~y:!dy ~max_w:content_w
              ~theme ~key_w:10
              ~key:(Say.resolve lang (Say.make ~ko:"상태 · 범위" ~en:"State"))
              (Printf.sprintf "%s · %s (%s)" status_s acct.scope prov_names);
            incr dy
          end;
          (match acct.state with
           | Wire_runtime.Account_reported ws ->
               List.iter
                 (fun (w : Wire_runtime.usage_window) ->
                   if !dy < det_bot then begin
                     let wlbl = compact_window_label w.kind in
                     let util_s =
                       match w.utilization with
                       | Wire_runtime.Util_fraction f ->
                           Printf.sprintf "%.0f%%" (f *. 100.0)
                       | Wire_runtime.Util_percent p -> Printf.sprintf "%d%%" p
                       | Wire_runtime.Util_credit_balance { total = Some t; remaining; _ } ->
                           Printf.sprintf "%s / %s"
                             (Format_val.format_value Format_val.Usd remaining)
                             (Format_val.format_value Format_val.Usd t)
                       | Wire_runtime.Util_credit_balance { total = None; remaining; _ } ->
                           Format_val.format_value Format_val.Usd remaining
                       | Wire_runtime.Util_usd { used; limit = Some l } ->
                           Printf.sprintf "%s / %s"
                             (Format_val.format_value Format_val.Usd used)
                             (Format_val.format_value Format_val.Usd l)
                       | Wire_runtime.Util_usd { used; limit = None } ->
                           Format_val.format_value Format_val.Usd used
                       | Wire_runtime.Util_credit_unlimited ->
                           Say.resolve lang (Say.make ~ko:"무제한" ~en:"unlimited")
                       | Wire_runtime.Util_credit_retracted ->
                           Say.resolve lang (Say.make ~ko:"철회됨" ~en:"retracted")
                     in
                     let eta_s =
                       match w.resets_at_unix with
                       | Some ts ->
                           Say.resolve lang (Say.make ~ko:"리셋 " ~en:"rst ")
                           ^ H.format_countdown ~now_unix ts
                       | None -> ""
                     in
                     let tone =
                       if is_window_exhausted w then Theme.Status_critical
                       else Theme.Status_ok
                     in
                     H.put_kv ~grid ~clip:inner ~x:content_x ~y:!dy
                       ~max_w:content_w ~theme ~key_w:10 ~key:wlbl
                       ~value_style:(H.status_style ~theme tone) util_s;
                     if not (String.equal eta_s "") then
                       ignore
                         (H.put_right ~grid ~clip:inner ~right_x ~y:!dy
                            ~max_w:16 ~style:(H.whisper_style ~theme ()) eta_s);
                     incr dy
                   end)
                 ws
           | Wire_runtime.Account_not_reported_since_start
           | Wire_runtime.Account_reported_no_windows _ ->
               ())
      | Row_account { tier = `Unreported; _ } | Row_unreported_toggle _ -> ()
    end

let render_quotas_credits ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let rt = model.runtime in
  let now_unix = model.freshness.last_wall_unix in
  let part = Runtime_store.partition_accounts rt in
  let accounts = Runtime_store.filtered_accounts rt in
  let buckets = compute_quota_health_buckets part in
  let bar_rect, body_rect =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ a; b ] -> (a, b)
    | _ -> (Rect.empty, rect)
  in
  let summary_pills =
    [
      {
        H.label =
          Printf.sprintf "%d %s" buckets.total
            (Say.resolve lang (Say.make ~ko:"프로바이더" ~en:"Providers"));
        active = false;
        tone = Some Theme.Status_active;
        glyph = Some Glyph.Live_healthy;
      };
      {
        H.label =
          Printf.sprintf "%d %s" buckets.healthy
            (Say.resolve lang (Say.make ~ko:"정상" ~en:"OK"));
        active = false;
        tone = Some Theme.Status_ok;
        glyph = Some Glyph.Live_healthy;
      };
    ]
    @ (if buckets.cooldown > 0 then
         [
           {
             H.label =
               Printf.sprintf "%d %s" buckets.cooldown
                 (Say.resolve lang (Say.make ~ko:"일시 중지" ~en:"Paused"));
             active = buckets.exhausted = 0;
             tone = Some Theme.Status_attention;
             glyph = Some Glyph.Action_required;
           };
         ]
       else [])
    @ (if buckets.exhausted > 0 then
         [
           {
             H.label =
               Printf.sprintf "%d %s" buckets.exhausted
                 (Say.resolve lang (Say.make ~ko:"소진" ~en:"Exhausted"));
             active = true;
             tone = Some Theme.Status_critical;
             glyph = Some Glyph.Live_failing;
           };
         ]
       else [])
    @ [
        {
          H.label =
            Printf.sprintf "%d %s [u]" buckets.unreported
              (Say.resolve lang (Say.make ~ko:"미보고" ~en:"Unreported"));
          active = rt.show_unreported_accounts;
          tone = Some Theme.Status_historical;
          glyph =
            Some
              (if rt.show_unreported_accounts then Glyph.Expand_open
               else Glyph.Expand_closed);
        };
      ]
  in
  ignore
    (H.draw_pills ~grid ~rect:bar_rect ~theme
       ~right_hint:
         (Say.resolve lang (Say.make ~ko:"관측 전용" ~en:"Observation-only"))
       summary_pills);
  let left_rect, right_rect =
    Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.46
      ~top_ratio:0.48 bp body_rect
  in
  let sub_rows = collect_subscription_windows accounts in
  let top_sub_h =
    Layout.adaptive_list_height ~items:(List.length sub_rows) ~overhead:4
      ~min_h:5
      ~max_h:(Int.max 5 (left_rect.h * 52 / 100))
      ()
  in
  let sub_rect, health_rect =
    if left_rect.h >= 11 then
      match
        Layout.split_v_bp bp left_rect [ Layout.Fixed top_sub_h; Layout.Flex 1 ]
      with
      | [ a; b ] -> (a, b)
      | _ -> (left_rect, Rect.empty)
    else (left_rect, Rect.empty)
  in
  draw_subscription_windows ~grid ~cache ~rect:sub_rect ~theme ~bp ~lang
    ~now_unix ~rt sub_rows rt.usage_windows ~focused:(Model.pane_focused model 0);
  if not (Rect.is_empty health_rect) then
    draw_cooldown_health_summary ~grid ~cache ~rect:health_rect ~theme ~bp ~lang
      ~now_unix ~tz_offset_sec:model.tz_offset_sec ~rt part;
  draw_credit_balances ~grid ~cache ~rect:right_rect ~theme ~bp ~lang ~now_unix
    ~rt part rt.usage_windows ~focused:(Model.pane_focused model 1)

(* --- 2. Sub-Tab 2: Efficiency & Spend (4-KPI Strip + Real btop Braille Charts) --- *)

let series_stats samples =
  let cur = ref Observed.absent in
  let peak = ref None in
  let sum = ref 0.0 in
  let cnt = ref 0 in
  Array.iter
    (fun s ->
      match s with
      | Chart.Series.Value v when Float.is_finite v ->
          cur := Observed.value ~observed_at:Clock.Mono.zero v;
          peak :=
            (match !peak with Some p -> Some (Float.max p v) | None -> Some v);
          sum := !sum +. v;
          incr cnt
      | Chart.Series.Zero ->
          cur := Observed.value ~observed_at:Clock.Mono.zero 0.0;
          peak := (match !peak with Some p -> Some p | None -> Some 0.0);
          incr cnt
      | Chart.Series.Unread | Chart.Series.Absent | Chart.Series.Value _ -> ())
    samples;
  let peak_obs =
    match !peak with
    | Some p -> Observed.value ~observed_at:Clock.Mono.zero p
    | None -> Observed.absent
  in
  let avg_obs =
    if !cnt > 0 then
      Observed.value ~observed_at:Clock.Mono.zero (!sum /. float_of_int !cnt)
    else Observed.absent
  in
  (!cur, peak_obs, avg_obs)

let float_to_sample v =
  if not (Float.is_finite v) then Chart.Series.Absent
  else if v <= 0.0 then Chart.Series.Zero
  else Chart.Series.Value v

let draw_efficiency_kpi_strip ~grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp ~lang ~(model : Model.t) ~(rt : Runtime_store.t)
    (spend_rows : Runtime_store.keeper_spend_row list) =
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ~subtitle:"24h"
         (Say.resolve lang
            (Say.make ~ko:"효율 · 지출 요약" ~en:"Efficiency & Spend Summary")))
  in
  if Rect.is_empty inner then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let cols =
      Layout.split_h ~gap:1 inner
        [ Layout.Flex 1; Layout.Flex 1; Layout.Flex 1; Layout.Flex 1 ]
    in
    let pad = if Layout.equal_breakpoint bp Layout.Wide then 2 else 1 in
    let draw_cell idx cell ~label ~value ~val_style ~sub ?gauge_ratio () =
      if idx > 0 then
        Card.draw_v_hairline ~bg grid ~x:(cell.Rect.x - 1) ~y:inner.y ~h:inner.h
          ~theme;
      let c = Card.pad_inner ~pad_x:pad ~pad_y:0 cell in
      if not (Rect.is_empty c) then begin
        let y0 = c.y in
        ignore
          (H.put_clipped ~grid ~clip:c ~x:c.x ~y:y0 ~max_w:c.w
             ~style:(H.secondary_style ~theme ())
             label);
        if c.h >= 2 then begin
          let y1 = c.y + 1 in
          let vw =
            H.put_clipped ~grid ~clip:c ~x:c.x ~y:y1 ~max_w:c.w ~style:val_style
              value
          in
          let rem = c.w - vw - 1 in
          match gauge_ratio with
          | Some ratio when rem >= 8 ->
              let bw = Int.min 10 rem in
              ignore
                (Chart.draw_ratio_bar_run ~clip:c grid ~x:(Rect.right c - bw)
                   ~y:y1 ~width:bw ~theme ~bg ~unicode:true
                   ~gradient:Chart.Gradient.Efficiency ~ratio)
          | Some _ | None ->
              if rem >= 4 && not (String.equal sub "") then
                ignore
                  (H.put_right ~grid ~clip:c ~right_x:(Rect.right c) ~y:y1
                     ~max_w:rem ~style:(H.whisper_style ~theme ()) sub)
        end
        else
          ignore
            (H.put_right ~grid ~clip:c ~right_x:(Rect.right c) ~y:y0
               ~max_w:(Int.max 0 (c.w - Grapheme.display_width label - 1))
               ~style:val_style value)
      end
    in
    let cache_obs = Runtime_store.effective_cache_hit_pct rt in
    let cache_val = Format_val.format_observed Format_val.Percent cache_obs ~lang in
    let cache_style, cache_ratio =
      match Observed.to_option cache_obs with
      | Some pct ->
          let tone =
            if pct >= 70.0 then Theme.Status_ok
            else if pct >= 40.0 then Theme.Status_attention
            else Theme.Status_critical
          in
          ( H.status_style ~theme ~attrs:Attr.bold tone
          , Some (Float.max 0.0 (Float.min 1.0 (pct /. 100.0))) )
      | None -> (H.whisper_style ~theme (), None)
    in
    let spend_bd = Runtime_store.spend_24h_breakdown rt in
    let spend_val =
      Format_val.format_observed Format_val.Usd spend_bd.total_usd ~lang
    in
    let spend_label =
      match spend_bd.source with
      | Runtime_store.Spend_provider_24h ->
          Say.resolve lang
            (Say.make ~ko:"24h 프로바이더 지출" ~en:"24h Provider Spend")
      | Runtime_store.Spend_keeper_turns_24h ->
          Say.resolve lang
            (Say.make ~ko:"24h 키퍼 귀속 지출" ~en:"24h Keeper Spend")
      | Runtime_store.Spend_unreported ->
          Say.resolve lang (Say.make ~ko:"24h 총 지출" ~en:"24h Total Spend")
    in
    let spend_sub =
      match
        ( spend_bd.source
        , Observed.to_option spend_bd.keeper_attributed_usd )
      with
      | Runtime_store.Spend_provider_24h, Some kp_usd ->
          Printf.sprintf "%s %s"
            (Say.resolve lang (Say.make ~ko:"키퍼" ~en:"Kp"))
            (Format_val.format_value Format_val.Usd kp_usd)
      | Runtime_store.Spend_provider_24h, None ->
          Say.resolve lang (Say.make ~ko:"프로바이더" ~en:"Provider")
      | Runtime_store.Spend_keeper_turns_24h, _ ->
          Say.resolve lang (Say.make ~ko:"키퍼 귀속" ~en:"Keeper-only")
      | Runtime_store.Spend_unreported, _ -> "24h"
    in
    let calls_val, calls_sub =
      match Runtime_store.tool_series_totals rt with
      | Some (calls, fails, p95_opt) ->
          let p95_s =
            match p95_opt with
            | Some ms ->
                "p95 " ^ Format_val.format_value Format_val.Milliseconds ms
            | None ->
                if fails > 0 then Printf.sprintf "%d fail" fails else "24h"
          in
          ( Format_val.format_value Format_val.Count (float_of_int calls)
          , p95_s )
      | None -> (
          match Observed.to_option rt.models_metrics with
          | Some m ->
              let p95_s =
                match m.fleet_p95_latency_ms with
                | Some ms ->
                    "p95 " ^ Format_val.format_value Format_val.Milliseconds ms
                | None -> Printf.sprintf "%d err" m.total_error_entries
              in
              ( Format_val.format_value Format_val.Count
                  (float_of_int m.total_entries)
              , p95_s )
          | None -> (Glyph.to_utf8 Glyph.Missing_absent, ""))
    in
    let models_n =
      match Observed.to_option rt.models_metrics with
      | Some m -> List.length m.models
      | None -> (
          match Observed.to_option rt.runtime_metrics with
          | Some r -> List.length r.runtimes
          | None -> List.length (Runtime_store.runtime_options rt))
    in
    let active_roster =
      match Observed.to_option model.fleet.keepers with
      | Some ks -> ks
      | None -> []
    in
    let active_val, active_sub =
      if active_roster <> [] then
        let roster_tbl = Hashtbl.create (max 16 (List.length active_roster)) in
        List.iter
          (fun (k : Wire_fleet.keeper_summary) ->
            Hashtbl.replace roster_tbl k.name ())
          active_roster;
        let active_n = List.length active_roster in
        let retired_n =
          List.fold_left
            (fun acc (r : Runtime_store.keeper_spend_row) ->
              if Hashtbl.mem roster_tbl r.keeper then acc else acc + 1)
            0 spend_rows
        in
        let orgs = List.length (Fleet_store.company_groups model.fleet) in
        if retired_n > 0 then
          ( Printf.sprintf "%d %s · %d %s" active_n
              (Say.resolve lang (Say.make ~ko:"활성" ~en:"act"))
              retired_n
              (Say.resolve lang (Say.make ~ko:"이력" ~en:"hist"))
          , Printf.sprintf "%d %s · %d %s" models_n
              (Say.resolve lang (Say.make ~ko:"모델" ~en:"mdl"))
              orgs
              (Say.resolve lang (Say.make ~ko:"조직" ~en:"org")) )
        else
          ( Printf.sprintf "%d %s · %d %s" models_n
              (Say.resolve lang (Say.make ~ko:"모델" ~en:"mdl"))
              active_n
              (Say.resolve lang (Say.make ~ko:"활성" ~en:"act"))
          , if orgs > 0 then
              Say.resolve lang
                (Say.make ~ko:(Printf.sprintf "%d 조직" orgs)
                   ~en:(Printf.sprintf "%d orgs" orgs))
            else "" )
      else
        let keepers_n = List.length spend_rows in
        let cos = List.length (Runtime_store.company_spend_rollups rt) in
        ( Printf.sprintf "%d %s · %d %s" models_n
            (Say.resolve lang (Say.make ~ko:"모델" ~en:"mdl"))
            keepers_n
            (Say.resolve lang (Say.make ~ko:"키퍼" ~en:"kp"))
        , if cos > 0 then
            Say.resolve lang
              (Say.make ~ko:(Printf.sprintf "%d 조직" cos)
                 ~en:(Printf.sprintf "%d orgs" cos))
          else "" )
    in
    match cols with
    | [ c0; c1; c2; c3 ] ->
        draw_cell 0 c0
          ~label:(Say.resolve lang (Say.make ~ko:"24h 캐시 적중" ~en:"24h Cache Hit"))
          ~value:cache_val ~val_style:cache_style ~sub:"" ?gauge_ratio:cache_ratio ();
        draw_cell 1 c1
          ~label:spend_label
          ~value:spend_val ~val_style:(H.anchor_style ~theme ()) ~sub:spend_sub ();
        draw_cell 2 c2
          ~label:(Say.resolve lang (Say.make ~ko:"24h 호출 · p95" ~en:"24h Calls & p95"))
          ~value:calls_val ~val_style:(H.anchor_style ~theme ()) ~sub:calls_sub ();
        draw_cell 3 c3
          ~label:(Say.resolve lang (Say.make ~ko:"활성 모델 · 키퍼" ~en:"Models & Keepers"))
          ~value:active_val ~val_style:(H.anchor_style ~theme ()) ~sub:active_sub ()
    | _ -> ()

let is_observed_loading = function
  | Observed.Loading _ -> true
  | Observed.Value _ | Observed.Absent | Observed.Unreported | Observed.Failed _
    ->
      false

let build_cache_hit_samples ~(rt : Runtime_store.t) =
  let hourly = Runtime_store.cache_hit_series_24h rt in
  let has_hourly = List.exists (fun (_, p) -> Option.is_some p) hourly in
  if has_hourly then
    Array.of_list
      (List.map
         (fun (_, pct_opt) ->
           match pct_opt with
           | Some pct when Float.is_finite pct ->
               let clamped = Float.max 0.0 (Float.min 100.0 pct) in
               if clamped <= 0.0 then Chart.Series.Zero
               else Chart.Series.Value clamped
           | Some _ | None -> Chart.Series.Absent)
         hourly)
  else
    match Observed.to_option rt.efficiency with
    | Some eff when eff.velocity <> [] ->
        Array.of_list
          (List.map
             (fun (v : Wire_runtime.token_velocity_sample) ->
               match
                 ( Observed.to_option v.input_tok_per_min
                 , Observed.to_option v.cache_read_tok_per_min )
               with
               | Some inp, Some cr when inp > 0.0 ->
                   let pct =
                     Float.max 0.0 (Float.min 100.0 (cr /. inp *. 100.0))
                   in
                   if pct <= 0.0 then Chart.Series.Zero
                   else Chart.Series.Value pct
               | Some _, Some _ -> Chart.Series.Zero
               | None, _ | _, None -> Chart.Series.Absent)
             eff.velocity)
    | Some _ | None ->
        if is_observed_loading rt.models_metrics || is_observed_loading rt.efficiency
        then [| Chart.Series.Unread |]
        else [| Chart.Series.Absent |]

let max_sample_value (arr : Chart.Series.sample array) =
  Array.fold_left
    (fun acc s ->
      match s with
      | Chart.Series.Value v when Float.is_finite v && v > acc -> v
      | Chart.Series.Value _ | Chart.Series.Zero | Chart.Series.Absent
      | Chart.Series.Unread ->
          acc)
    0.0 arr

let render_efficiency_spend ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let rt =
    match Observed.to_option model.fleet.keepers with
    | Some ks when ks <> [] ->
        Runtime_store.sync_keeper_companies ks model.runtime
    | Some _ | None -> model.runtime
  in
  let spend_rows = Runtime_store.keeper_spend_rows rt in
  let kpi_h = if rect.h >= 24 then 4 else 3 in
  let charts_ratio = if rect.h >= 34 then 0.48 else 0.44 in
  let kpi_rect, charts_rect, bottom_rect =
    match
      Layout.split_v_bp bp rect
        [ Layout.Fixed kpi_h; Layout.Ratio charts_ratio; Layout.Flex 1 ]
    with
    | [ a; b; c ] -> (a, b, c)
    | _ -> (Rect.empty, rect, Rect.empty)
  in
  (* 1. Top 4-KPI Summary Strip *)
  draw_efficiency_kpi_strip ~grid ~cache ~rect:kpi_rect ~theme ~bp ~lang ~model
    ~rt spend_rows;
  (* 2. Middle Charts Band: 2 real btop Braille charts with ~show_title:false *)
  let cache_rect, dual_rect =
    if Layout.equal_breakpoint bp Layout.Wide then
      match
        Layout.split_h_bp bp charts_rect [ Layout.Ratio 0.48; Layout.Flex 1 ]
      with
      | [ l; r ] -> (l, r)
      | _ -> (charts_rect, Rect.empty)
    else if charts_rect.h >= 12 then
      match
        Layout.split_v_bp bp charts_rect [ Layout.Ratio 0.48; Layout.Flex 1 ]
      with
      | [ t; b ] -> (t, b)
      | _ -> (charts_rect, Rect.empty)
    else
      match
        Layout.split_h_bp bp charts_rect [ Layout.Ratio 0.50; Layout.Flex 1 ]
      with
      | [ l; r ] -> (l, r)
      | _ -> (charts_rect, Rect.empty)
  in
  (* Chart A: Prompt Cache Hit % (24h) *)
  let cache_pct_obs = Runtime_store.effective_cache_hit_pct rt in
  let cache_badge_txt =
    Format_val.format_observed Format_val.Percent cache_pct_obs ~lang
  in
  let cache_badge =
    match cache_pct_obs with
    | Observed.Value { data; _ } ->
        let tone =
          if data >= 70.0 then Theme.Status_ok
          else if data >= 40.0 then Theme.Status_attention
          else Theme.Status_critical
        in
        H.make_badge ~glyph:Glyph.Live_healthy ~tone cache_badge_txt
    | Observed.Loading _ ->
        H.make_badge ~glyph:Glyph.Transport_reconnecting
          ~tone:Theme.Status_active cache_badge_txt
    | Observed.Absent | Observed.Unreported ->
        H.make_badge ~tone:Theme.Status_historical cache_badge_txt
    | Observed.Failed _ ->
        H.make_badge ~glyph:Glyph.Live_failing ~tone:Theme.Status_critical
          cache_badge_txt
  in
  let cache_inner =
    Card.draw ~cache grid ~rect:cache_rect ~theme
      (H.card_spec ~badge:cache_badge ~subtitle:"0..100%"
         (Say.resolve lang
            (Say.make ~ko:"프롬프트 캐시 적중률 (24h %)"
               ~en:"Prompt Cache Hit Rate (24h %)")))
  in
  let cache_content = H.pad_content ~bp cache_inner in
  if not (Rect.is_empty cache_content) then begin
    let samples = build_cache_hit_samples ~rt in
    let s_cur, s_peak, avg = series_stats samples in
    let current =
      if Observed.is_value cache_pct_obs then cache_pct_obs else s_cur
    in
    let peak =
      match (s_peak, current) with
      | Observed.Value { data = p; observed_at }, Observed.Value { data = c; _ } ->
          Observed.value ~observed_at (Float.max p c)
      | ( Observed.Value _
        , ( Observed.Loading _
          | Observed.Absent
          | Observed.Unreported
          | Observed.Failed _ ) ) ->
          s_peak
      | ( ( Observed.Loading _
          | Observed.Absent
          | Observed.Unreported
          | Observed.Failed _ )
        , Observed.Value _ ) ->
          current
      | ( ( Observed.Loading _
          | Observed.Absent
          | Observed.Unreported
          | Observed.Failed _ )
        , ( Observed.Loading _
          | Observed.Absent
          | Observed.Unreported
          | Observed.Failed _ ) ) ->
          s_peak
    in
    let spec : Chart.Spec.t =
      {
        title = Say.make ~ko:"캐시 적중률" ~en:"Cache Hit";
        hotkey_hint = None;
        kind =
          Chart.Spec.Time_series
            {
              series =
                {
                  label = Say.literal "";
                  unit = Format_val.Percent;
                  gradient = Chart.Gradient.Efficiency;
                  samples;
                  current;
                  peak;
                  avg;
                  delta_pct = None;
                };
              scale = Chart.Scale.Fixed_bounds { floor = 0.0; ceiling = 100.0 };
              window = Chart.Time_window.Last_24h;
            };
      }
    in
    ignore
      (Chart.draw grid ~rect:cache_content ~theme ~caps:H.default_caps ~lang
         ~show_title:false spec)
  end;
  (* Chart B: Dual-Inverted Throughput / Velocity (24h) — independent Y axes *)
  let vel_kind = Runtime_store.velocity_series_24h rt in
  let dual_title, dual_subtitle, dual_scale, upper_series, lower_series =
    match vel_kind with
    | Runtime_store.Velocity_tokens pts ->
        let up = Array.of_list (List.map (fun (_, u, _) -> float_to_sample u) pts) in
        let dn = Array.of_list (List.map (fun (_, _, l) -> float_to_sample l) pts) in
        let uc, upk, uavg = series_stats up in
        let lc, lpk, lavg = series_stats dn in
        ( Say.make ~ko:"토큰 속도 (이중 반전)"
            ~en:"Token Velocity (Dual-Mirror)"
        , Say.make ~ko:"24h · tok" ~en:"24h · tok"
        , Chart.Scale.Synced_pair
        , {
            Chart.Series.label = Say.make ~ko:"입력/캐시" ~en:"Input/Cache";
            unit = Format_val.Tokens;
            gradient = Chart.Gradient.Cool_flow;
            samples = up;
            current = uc;
            peak = upk;
            avg = uavg;
            delta_pct = None;
          }
        , {
            Chart.Series.label = Say.make ~ko:"출력" ~en:"Output";
            unit = Format_val.Tokens;
            gradient = Chart.Gradient.Warm_flow;
            samples = dn;
            current = lc;
            peak = lpk;
            avg = lavg;
            delta_pct = None;
          } )
    | Runtime_store.Velocity_calls_and_spend pts ->
        let up = Array.of_list (List.map (fun (_, u, _) -> float_to_sample u) pts) in
        let dn_raw = Array.of_list (List.map (fun (_, _, l) -> float_to_sample l) pts) in
        let uc, upk, uavg = series_stats up in
        let lc, lpk, lavg = series_stats dn_raw in
        let max_u = max_sample_value up in
        let max_l = max_sample_value dn_raw in
        let top_max =
          Chart.Scale.nice_ceiling (if max_u > 0.0 then max_u else 1.0)
        in
        let bot_max = if max_l > 0.0 then max_l else 1.0 in
        let peak_usd =
          Format_val.format_observed Format_val.Usd lpk ~lang
        in
        let peak_unit = if Observed.is_value lpk then "/h" else "" in
        ( Say.make ~ko:"24h 처리량 · 비용 (이중 반전)"
            ~en:"24h Throughput & Cost (Dual-Mirror)"
        , Say.make
            ~ko:(Printf.sprintf "최대 %s%s" peak_usd peak_unit)
            ~en:(Printf.sprintf "peak %s%s" peak_usd peak_unit)
        , Chart.Scale.Dual_independent
            { top_min = 0.0; top_max; bot_min = 0.0; bot_max }
        , {
            Chart.Series.label = Say.make ~ko:"호출" ~en:"Calls";
            unit = Format_val.Count;
            gradient = Chart.Gradient.Cool_flow;
            samples = up;
            current = uc;
            peak = upk;
            avg = uavg;
            delta_pct = None;
          }
        , {
            Chart.Series.label = Say.make ~ko:"지출" ~en:"Spend";
            unit = Format_val.Usd;
            gradient = Chart.Gradient.Warm_flow;
            samples = dn_raw;
            current = lc;
            peak = lpk;
            avg = lavg;
            delta_pct = None;
          } )
    | Runtime_store.Velocity_tool_calls_and_p95 pts ->
        let up = Array.of_list (List.map (fun (_, u, _) -> float_to_sample u) pts) in
        let dn_raw = Array.of_list (List.map (fun (_, _, l) -> float_to_sample l) pts) in
        let uc, upk, uavg = series_stats up in
        let lc, lpk, lavg = series_stats dn_raw in
        let max_u = max_sample_value up in
        let max_l = max_sample_value dn_raw in
        let top_max =
          Chart.Scale.nice_ceiling (if max_u > 0.0 then max_u else 1.0)
        in
        let bot_max =
          Chart.Scale.nice_ceiling (if max_l > 0.0 then max_l else 1.0)
        in
        let peak_ms =
          Format_val.format_observed Format_val.Milliseconds lpk ~lang
        in
        ( Say.make ~ko:"24h 도구 부하 (이중 반전)"
            ~en:"24h Tool Load (Dual-Mirror)"
        , Say.make
            ~ko:(Printf.sprintf "최대 %s" peak_ms)
            ~en:(Printf.sprintf "peak %s" peak_ms)
        , Chart.Scale.Dual_independent
            { top_min = 0.0; top_max; bot_min = 0.0; bot_max }
        , {
            Chart.Series.label = Say.make ~ko:"호출" ~en:"Calls";
            unit = Format_val.Count;
            gradient = Chart.Gradient.Cool_flow;
            samples = up;
            current = uc;
            peak = upk;
            avg = uavg;
            delta_pct = None;
          }
        , {
            Chart.Series.label = Say.make ~ko:"지연 p95" ~en:"p95";
            unit = Format_val.Milliseconds;
            gradient = Chart.Gradient.Ai_flow;
            samples = dn_raw;
            current = lc;
            peak = lpk;
            avg = lavg;
            delta_pct = None;
          } )
    | Runtime_store.Velocity_empty ->
        let empty_sample =
          if
            is_observed_loading rt.models_metrics
            || is_observed_loading rt.efficiency
            || is_observed_loading rt.tool_series
          then [| Chart.Series.Unread |]
          else [| Chart.Series.Absent |]
        in
        let empty_s label unit gradient : Chart.Series.t =
          {
            label;
            unit;
            gradient;
            samples = empty_sample;
            current = Observed.absent;
            peak = Observed.absent;
            avg = Observed.absent;
            delta_pct = None;
          }
        in
        ( Say.make ~ko:"24h 처리량 · 지연 (이중 반전)"
            ~en:"24h Throughput & Latency (Dual-Mirror)"
        , Say.make ~ko:"24h" ~en:"24h"
        , Chart.Scale.Synced_pair
        , empty_s (Say.make ~ko:"입력/호출" ~en:"In/Calls") Format_val.Tokens
            Chart.Gradient.Cool_flow
        , empty_s (Say.make ~ko:"출력/지연" ~en:"Out/p95") Format_val.Tokens
            Chart.Gradient.Warm_flow )
  in
  let dual_inner =
    Card.draw ~cache grid ~rect:dual_rect ~theme
      (H.card_spec ~subtitle:(Say.resolve lang dual_subtitle)
         (Say.resolve lang dual_title))
  in
  let dual_content = H.pad_content ~bp dual_inner in
  if not (Rect.is_empty dual_content) then begin
    let spec : Chart.Spec.t =
      {
        title = dual_title;
        hotkey_hint = None;
        kind =
          Chart.Spec.Dual_inverted
            {
              upper = upper_series;
              lower = lower_series;
              scale = dual_scale;
              window = Chart.Time_window.Last_24h;
            };
      }
    in
    ignore
      (Chart.draw grid ~rect:dual_content ~theme ~caps:H.default_caps ~lang
         ~show_title:false spec)
  end;
  (* 3. Bottom Card: Company & Keeper Cost Efficiency Table with explicit window badge *)
  let active_roster_tbl : (string, unit) Hashtbl.t = Hashtbl.create 32 in
  let active_roster_loaded =
    match Observed.to_option model.fleet.keepers with
    | Some ks when ks <> [] ->
        List.iter
          (fun (k : Wire_fleet.keeper_summary) ->
            Hashtbl.replace active_roster_tbl k.name ())
          ks;
        true
    | Some _ | None -> false
  in
  let active_in_tbl, retired_in_tbl =
    if not active_roster_loaded then (List.length spend_rows, 0)
    else
      List.fold_left
        (fun (act, ret) (r : Runtime_store.keeper_spend_row) ->
          if Hashtbl.mem active_roster_tbl r.keeper then (act + 1, ret)
          else (act, ret + 1))
        (0, 0) spend_rows
  in
  let grouped_companies = Runtime_store.grouped_keeper_spend_rows rt in
  let group_count = List.length grouped_companies in
  let groups_subtitle =
    if group_count > 0 then
      Say.resolve lang
        (Say.make
           ~ko:(Printf.sprintf "%d개 조직 · 키퍼별 비용 효율" group_count)
           ~en:
             (Printf.sprintf "%d Groups & Per-Keeper Cost Efficiency"
                group_count))
    else
      Say.resolve lang
        (Say.make ~ko:"조직 · 키퍼별 비용 효율"
           ~en:"Groups & Per-Keeper Cost Efficiency")
  in
  let monthly_subtitle ~month ~days_covered =
    if active_roster_loaded && retired_in_tbl > 0 then
      Say.resolve lang
        (Say.make
           ~ko:
             (Printf.sprintf "%s (%dd) · %d 활성 · %d 이력" month
                days_covered active_in_tbl retired_in_tbl)
           ~en:
             (Printf.sprintf "%s (%dd) · %d active · %d retired" month
                days_covered active_in_tbl retired_in_tbl))
    else if group_count > 0 then
      Say.resolve lang
        (Say.make
           ~ko:(Printf.sprintf "%s (%dd) · %d개 조직" month days_covered group_count)
           ~en:
             (Printf.sprintf "%s (%dd) · %d Groups" month days_covered
                group_count))
    else
      Say.resolve lang
        (Say.make
           ~ko:(Printf.sprintf "%s (%dd) · 조직별 비용" month days_covered)
           ~en:(Printf.sprintf "%s (%dd) · Group Spend" month days_covered))
  in
  let tbl_badge, tbl_subtitle =
    match Runtime_store.keeper_spend_table_window rt with
    | Runtime_store.Spend_window_mtd { month; days_covered } ->
        let badge =
          H.make_badge ~tone:Theme.Status_ai
            (Say.resolve lang
               (Say.make ~ko:"월간 누계 (MTD)" ~en:"Month-to-Date (MTD)"))
        in
        (Some badge, monthly_subtitle ~month ~days_covered)
    | Runtime_store.Spend_window_month_complete { month; days_covered } ->
        let badge =
          H.make_badge ~tone:Theme.Status_ai
            (Say.resolve lang
               (Say.make ~ko:"월간 마감" ~en:"Month Complete"))
        in
        (Some badge, monthly_subtitle ~month ~days_covered)
    | Runtime_store.Spend_window_24h { window_minutes } ->
        let hrs = Int.max 1 (window_minutes / 60) in
        let badge =
          H.make_badge ~tone:Theme.Status_active
            (Say.resolve lang
               (Say.make
                  ~ko:(Printf.sprintf "%dh 키퍼 귀속" hrs)
                  ~en:(Printf.sprintf "%dh Keeper-Attributed" hrs)))
        in
        (Some badge, groups_subtitle)
    | Runtime_store.Spend_window_none -> (None, groups_subtitle)
  in
  let tbl_inner =
    Card.draw ~cache grid ~rect:bottom_rect ~theme
      (H.card_spec ~focused:(Model.body_has_focus model) ?badge:tbl_badge
         ~subtitle:tbl_subtitle
         (Say.resolve lang
            (Say.make ~ko:"회사 · 키퍼별 비용 효율 표"
               ~en:"Company & Keeper Cost Efficiency")))
  in
  if not (Rect.is_empty tbl_inner) then begin
    if spend_rows = [] then
      let obs_hint =
        if Observed.is_value rt.efficiency || Observed.is_value rt.keeper_costs
        then Observed.absent
        else rt.efficiency
      in
      H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp tbl_inner) ~theme
        ~lang obs_hint
    else
      let display_rows = Runtime_store.keeper_spend_display_rows rt in
      let total_spend_all =
        List.fold_left
          (fun acc (r : Runtime_store.keeper_spend_row) -> acc +. r.cost_usd)
          0.0 display_rows
      in
      let columns : Table.column list =
        [
          {
            id = "entity";
            header = Say.make ~ko:"회사 / 키퍼" ~en:"Company / Keeper";
            priority = 0;
            min_width = 18;
            max_width = None;
            weight = 3;
            align = Table.Left;
          };
          {
            id = "spend";
            header = Say.make ~ko:"비용 (USD)" ~en:"Cost USD";
            priority = 0;
            min_width = 9;
            max_width = Some 12;
            weight = 1;
            align = Table.Right;
          };
          {
            id = "calls";
            header = Say.make ~ko:"호출 / 턴" ~en:"Calls/Turns";
            priority = 2;
            min_width = 10;
            max_width = Some 14;
            weight = 1;
            align = Table.Right;
          };
          {
            id = "cache";
            header = Say.make ~ko:"캐시%" ~en:"Cache%";
            priority = 1;
            min_width = 7;
            max_width = Some 10;
            weight = 1;
            align = Table.Right;
          };
          {
            id = "efficiency";
            header = Say.make ~ko:"비용 효율" ~en:"Cost/Call";
            priority = 1;
            min_width = 14;
            max_width = Some 22;
            weight = 2;
            align = Table.Left;
          };
        ]
      in
      let table_rows =
        List.concat_map
          (fun (grp : Runtime_store.company_spend_group) ->
            let comp = grp.company in
            let tot_usd = grp.total_cost_usd in
            let members = grp.members in
            let tot_calls, tot_turns, cache_sum, cache_w =
              List.fold_left
                (fun (calls, turns, cs, cw)
                     (m : Runtime_store.keeper_spend_row) ->
                  let cs', cw' =
                    match Observed.to_option m.cache_hit_pct with
                    | Some pct when Float.is_finite pct ->
                        let w = Int.max 1 m.calls in
                        (cs +. (pct *. float_of_int w), cw + w)
                    | Some _ | None -> (cs, cw)
                  in
                  (calls + m.calls, turns + m.turns, cs', cw'))
                (0, 0, 0.0, 0) members
            in
            let comp_cache_cell =
              if cache_w > 0 then
                let pct = cache_sum /. float_of_int cache_w in
                let tone =
                  if pct >= 70.0 then Theme.Status_ok
                  else if pct >= 40.0 then Theme.Status_attention
                  else Theme.Status_critical
                in
                Table.text_cell
                  ~fg:(Color.of_rgb (Theme.status_color theme tone))
                  (Format_val.format_value Format_val.Percent pct)
              else
                Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                  ~attrs:Attr.italic
                  (Glyph.to_utf8 Glyph.Missing_absent)
            in
            let share_ratio =
              if total_spend_all > 0.0 then
                Float.max 0.0 (Float.min 1.0 (tot_usd /. total_spend_all))
              else 0.0
            in
            let comp_per_call =
              if tot_calls > 0 then
                Format_val.format_value Format_val.Usd
                  (tot_usd /. float_of_int tot_calls)
              else Glyph.to_utf8 Glyph.Missing_absent
            in
            let comp_row : Table.row =
              {
                id = "co:" ^ comp;
                cells =
                  [
                    ( "entity"
                    , Table.text_cell ~fg:(Color.of_rgb theme.accent)
                        ~attrs:Attr.bold
                        (Printf.sprintf "%s %s (%d)"
                           (Glyph.to_utf8 Glyph.Expand_open)
                           comp (List.length members)) );
                    ( "spend"
                    , Table.text_cell ~fg:(Color.of_rgb theme.text_bright)
                        ~attrs:Attr.bold
                        (Format_val.format_value Format_val.Usd tot_usd) );
                    ( "calls"
                    , Table.text_cell
                        (Printf.sprintf "%s / %dt"
                           (Format_val.format_value Format_val.Count
                              (float_of_int tot_calls))
                           tot_turns) );
                    ("cache", comp_cache_cell);
                    ( "efficiency"
                    , Table.Gauge
                        {
                          ratio = share_ratio;
                          gradient = Chart.Gradient.Thermal;
                          label = Some comp_per_call;
                        } );
                  ];
              }
            in
            let member_rows =
              List.map
                (fun (m : Runtime_store.keeper_spend_row) ->
                  let cache_cell =
                    match Observed.to_option m.cache_hit_pct with
                    | Some pct when Float.is_finite pct ->
                        let tone =
                          if pct >= 70.0 then Theme.Status_ok
                          else if pct >= 40.0 then Theme.Status_attention
                          else Theme.Status_critical
                        in
                        Table.text_cell
                          ~fg:(Color.of_rgb (Theme.status_color theme tone))
                          (Format_val.format_value Format_val.Percent pct)
                    | Some _ | None ->
                        Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                          ~attrs:Attr.italic
                          (Glyph.to_utf8 Glyph.Missing_absent)
                  in
                  let m_share =
                    if total_spend_all > 0.0 then
                      Float.max 0.0 (Float.min 1.0 (m.cost_usd /. total_spend_all))
                    else 0.0
                  in
                  let per_lbl =
                    match m.cost_per_turn_usd with
                    | Some c -> Format_val.format_value Format_val.Usd c
                    | None ->
                        if m.calls > 0 then
                          Format_val.format_value Format_val.Usd
                            (m.cost_usd /. float_of_int m.calls)
                        else Glyph.to_utf8 Glyph.Missing_absent
                  in
                  let is_retired =
                    active_roster_loaded
                    && not (Hashtbl.mem active_roster_tbl m.keeper)
                  in
                  let entity_cell =
                    if is_retired then
                      Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                        ~attrs:Attr.italic
                        ("  " ^ m.keeper
                         ^ Say.resolve lang
                             (Say.make ~ko:" (이력)" ~en:" (retired)"))
                    else Table.text_cell ("  " ^ m.keeper)
                  in
                  {
                    Table.id = "kp:" ^ m.keeper;
                    cells =
                      [
                        ("entity", entity_cell);
                        ( "spend"
                        , Table.text_cell
                            (Format_val.format_value Format_val.Usd m.cost_usd) );
                        ( "calls"
                        , Table.text_cell
                            (Printf.sprintf "%s / %dt"
                               (Format_val.format_value Format_val.Count
                                  (float_of_int m.calls))
                               m.turns) );
                        ("cache", cache_cell);
                        ( "efficiency"
                        , Table.Gauge
                            {
                              ratio = m_share;
                              gradient = Chart.Gradient.Thermal;
                              label = Some per_lbl;
                            } );
                      ];
                  })
                members
            in
            comp_row :: member_rows)
          grouped_companies
      in
      let selected_keeper_row_idx =
        let kp_len = List.length display_rows in
        if kp_len = 0 then None
        else
          let clamped = H.clamp_index kp_len rt.selected_index in
          match List.nth_opt display_rows clamped with
          | None -> None
          | Some target_kp ->
              let want_id = "kp:" ^ target_kp.keeper in
              let rec find i = function
                | [] -> None
                | (r : Table.row) :: rest ->
                    if String.equal r.id want_id then Some i
                    else find (i + 1) rest
              in
              find 0 table_rows
      in
      ignore
        (Table.draw grid ~rect:tbl_inner ~theme ~caps:H.default_caps ~lang
           ~col_gap:(Layout.table_col_gap bp) ~scroll:rt.scroll_offset
           ?selected:selected_keeper_row_idx ~focused:(Model.body_has_focus model)
           ~columns table_rows)
  end

(* --- 3. Sub-Tab 3: Failover Lanes (Visual Flow_down Cascade + Lane Inspector) --- *)

let probe_refresh_label ~lang = function
  | Wire_runtime.Probe_fresh ->
      Say.resolve lang (Say.make ~ko:"신선" ~en:"Fresh")
  | Wire_runtime.Probe_recent ->
      Say.resolve lang (Say.make ~ko:"최근 캐시" ~en:"Cached")
  | Wire_runtime.Probe_served_stale ->
      Say.resolve lang (Say.make ~ko:"캐시(갱신 중)" ~en:"Stale(refreshing)")
  | Wire_runtime.Probe_warming_up ->
      Say.resolve lang (Say.make ~ko:"워밍업" ~en:"Warming")

let format_failover_reason (p : Wire_runtime.provider_probe_row) =
  match p.http_status, p.error with
  | Some 429, _ -> "429 RateLimit"
  | Some 402, _ -> "402 Quota"
  | Some code, Some err -> Printf.sprintf "HTTP %d · %s" code err
  | Some code, None -> Printf.sprintf "HTTP %d" code
  | None, Some err -> err
  | None, None -> p.status

let fusion_observation_is_stale (model : Model.t) =
  Observed.is_stale model.runtime.fusion_runs
  || match model.freshness.observer with
     | Health.Live _ -> false
     | Health.Connecting | Health.Reconnecting _ | Health.Stale _
     | Health.Disconnected _ | Health.Workspace_mismatch _ -> true

let fusion_elapsed ~now_unix ~stale (run : Wire_runtime.fusion_run) =
  match run.status, run.finished_at_unix with
  | Wire_runtime.Fusion_running, _ when not stale ->
      H.format_age ~now_unix run.started_at_unix
  | (Wire_runtime.Fusion_completed | Wire_runtime.Fusion_failed _),
    Some finished when finished >= run.started_at_unix ->
      Format_val.format_duration_s (finished -. run.started_at_unix)
  | Wire_runtime.Fusion_running, _
  | (Wire_runtime.Fusion_completed | Wire_runtime.Fusion_failed _),
    (None | Some _) ->
      Glyph.to_utf8 Glyph.Missing_unreported

let render_failover_lanes ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let rt = model.runtime in
  let now_unix = model.freshness.last_wall_unix in
  let active_probes, outside_probes = Runtime_store.active_and_outside_probes rt in
  let lanes = Runtime_store.filtered_lanes rt in
  let runtimes =
    match Observed.to_option rt.runtime_resolved with
    | Some snap -> snap.runtimes
    | None -> []
  in
  let runtimes_tbl : (string, Wire_runtime.runtime_option) Hashtbl.t =
    Hashtbl.create 32
  in
  List.iter
    (fun (r : Wire_runtime.runtime_option) -> Hashtbl.replace runtimes_tbl r.id r)
    runtimes;
  let usage_windows = Observed.to_option rt.usage_windows in
  let active_ok =
    List.fold_left
      (fun acc p ->
        if is_probe_effectively_ok ~now_unix ~rt ~runtimes_tbl ~usage_windows p
        then acc + 1
        else acc)
      0 active_probes
  in
  let active_failed =
    List.fold_left
      (fun acc p ->
        if
          is_probe_effectively_failed ~now_unix ~rt ~runtimes_tbl ~usage_windows
            p
        then acc + 1
        else acc)
      0 active_probes
  in
  let outside_failed =
    List.fold_left
      (fun acc (p : Wire_runtime.provider_probe_row) ->
        match p.reachable with
        | Some false -> acc + 1
        | Some true | None -> acc)
      0 outside_probes
  in
  let probe_tbl : (string, Wire_runtime.provider_probe_row) Hashtbl.t =
    Hashtbl.create 64
  in
  List.iter
    (fun (p : Wire_runtime.provider_probe_row) ->
      Hashtbl.replace probe_tbl p.runtime_id p)
    active_probes;
  let ssot_tone, ssot_glyph =
    if active_probes = [] then (Theme.Status_active, Glyph.Live_healthy)
    else if active_failed = 0 then (Theme.Status_ok, Glyph.Live_healthy)
    else if active_ok > 0 then (Theme.Status_attention, Glyph.Warning_triangle)
    else (Theme.Status_critical, Glyph.Live_failing)
  in
  let header_rect, body_rect =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ a; b ] -> (a, b)
    | _ -> (Rect.empty, rect)
  in
  let probe_age_txt =
    match Observed.to_option rt.runtime_probe with
    | Some pr ->
        let age =
          match pr.cache_age_sec with
          | Some s -> " " ^ Format_val.format_duration_s s
          | None -> ""
        in
        probe_refresh_label ~lang pr.refresh_state ^ age
    | None -> Say.resolve lang (Say.make ~ko:"즉시 캐시" ~en:"Instant SSOT")
  in
  let extra_lane_pills =
    let standalone_pill =
      match Observed.to_option rt.standalone_lanes with
      | Some sl ->
          [
            {
              H.label =
                Printf.sprintf "Exact %d" (List.length sl.lanes);
              active = false;
              tone = Some Theme.Status_active;
              glyph = None;
            };
          ]
      | None -> []
    in
    let inv_pill =
      match Observed.to_option rt.lanes_inventory with
      | Some inv ->
          [
            {
              H.label =
                Printf.sprintf "All %d" (List.length inv.rows);
              active = false;
              tone = Some Theme.Status_historical;
              glyph = None;
            };
          ]
      | None -> []
    in
    let verif_pill =
      let tc =
        match Observed.to_option rt.verification_runs with
        | Some v -> v.count
        | None -> 0
      in
      let gc =
        match Observed.to_option rt.goal_verification_runs with
        | Some v -> v.count
        | None -> 0
      in
      if tc + gc > 0 then
        [
          {
            H.label = Printf.sprintf "Verif %d/%d" tc gc;
            active = false;
            tone = Some Theme.Status_ok;
            glyph = None;
          };
        ]
      else []
    in
    let preview_pill =
      match Observed.to_option rt.runtime_raw_preview with
      | Some pv ->
          [
            {
              H.label =
                if pv.ok && pv.can_save then "Preview OK"
                else "Preview ERR";
              active = true;
              tone =
                Some
                  (if pv.ok && pv.can_save then Theme.Status_ok
                   else Theme.Status_attention);
              glyph = None;
            };
          ]
      | None -> []
    in
    standalone_pill @ inv_pill @ verif_pill @ preview_pill
  in
  let narrow_header = header_rect.w < 120 in
  let probe_age_pills =
    if narrow_header then []
    else
      [
        {
          H.label = probe_age_txt;
          active = false;
          tone = Some Theme.Status_active;
          glyph = None;
        };
      ]
  in
  let external_probe_pills =
    if narrow_header && outside_failed = 0 && not rt.show_outside_lane_probes
    then
      [
        {
          H.label =
            Say.resolve lang
              (Say.make ~ko:"외부 0 [Space]" ~en:"Ext 0 [Space]");
          active = false;
          tone = Some Theme.Status_historical;
          glyph = None;
        };
      ]
    else
      [
        {
          H.label =
            Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "외부 프로브: %d 실패 [Space]" outside_failed)
                 ~en:(Printf.sprintf "External probes: %d failed [Space]" outside_failed));
          active = rt.show_outside_lane_probes;
          tone = Some Theme.Status_historical;
          glyph = Some Glyph.Historical_incident;
        };
      ]
  in
  let visible_extra_pills =
    if narrow_header then
      List.filter (fun (p : H.pill) -> p.active) extra_lane_pills
    else extra_lane_pills
  in
  let header_pills =
    [
      {
        H.label =
          Printf.sprintf "%s: %d · %d/%d %s"
            (Say.resolve lang (Say.make ~ko:"활성 레인" ~en:"Active Lanes"))
            (List.length lanes) active_ok (List.length active_probes)
            (Say.resolve lang (Say.make ~ko:"가용" ~en:"reachable"));
        active = true;
        tone = Some ssot_tone;
        glyph = Some ssot_glyph;
      };
    ]
    @ probe_age_pills @ external_probe_pills @ visible_extra_pills
  in
  ignore (H.draw_pills ~grid ~rect:header_rect ~theme header_pills);
  let left_rect, right_rect =
    if Model.is_zoomed_active model then
      (Rect.empty, body_rect)
    else
      Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.56
        ~top_ratio:0.54 bp body_rect
  in
  (* Left Card: Visual Flow_down Cascade Tree *)
  let cascade_inner =
    Card.draw ~cache grid ~rect:left_rect ~theme
      (H.card_spec ~focused:(Model.pane_focused model 0)
         ~hotkey:
           (Say.resolve lang
              (Say.make ~ko:"[n] 생성 · [e] 편집" ~en:"[n] New · [e] Edit"))
         (Say.resolve lang
            (Say.make ~ko:"페일오버 캐스케이드" ~en:"Failover Cascade")))
  in
  let pad_r = if cascade_inner.w >= 24 then 2 else 1 in
  if not (Rect.is_empty cascade_inner) then begin
    match rt.runtime_resolved with
    | Observed.Value _ when lanes <> [] ->
        let bottom = Rect.bottom cascade_inner in
        let sel_idx = H.clamp_index (List.length lanes) rt.selected_index in
        let reserve_ext =
          if rt.show_outside_lane_probes && outside_probes <> [] then
            Int.min 5 (1 + List.length outside_probes)
          else 0
        in
        let avail_h = Int.max 0 (cascade_inner.h - reserve_ext) in
        let visual_rows = ref [] in
        let sel_v_row = ref None in
        let sel_v_end = ref None in
        List.iteri
          (fun idx (lane : Wire_runtime.failover_lane) ->
            let is_sel = Int.equal idx sel_idx in
            let row_start = List.length !visual_rows in
            visual_rows := `Lane (lane, is_sel) :: !visual_rows;
            let slot_n = List.length lane.runtime_ids in
            List.iteri
              (fun si rid ->
                visual_rows := `Slot (si, slot_n, rid, is_sel) :: !visual_rows)
              lane.runtime_ids;
            if is_sel then begin
              sel_v_row := Some row_start;
              sel_v_end := Some (row_start + slot_n)
            end)
          lanes;
        let v_arr = Array.of_list (List.rev !visual_rows) in
        let total_v = Array.length v_arr in
        let start_v0, _ =
          Table.compute_viewport ~total_rows:total_v ~viewport_rows:avail_h
            ~scroll:rt.scroll_offset ~selected:!sel_v_row
        in
        let start_v =
          match !sel_v_row, !sel_v_end with
          | Some r0, Some r1 when avail_h > 0 && r1 >= start_v0 + avail_h ->
              let needed = Int.min r0 (Int.max 0 (r1 - avail_h + 1)) in
              Int.min (Int.max 0 (total_v - avail_h)) needed
          | _ -> start_v0
        in
        let y = ref cascade_inner.y in
        for row_i = 0 to avail_h - 1 do
          let v_idx = start_v + row_i in
          if v_idx < total_v then begin
            let py = cascade_inner.y + row_i in
            y := py + 1;
            let r_rect =
              Rect.make ~x:cascade_inner.x ~y:py ~w:cascade_inner.w ~h:1
            in
            let right_edge = Rect.right cascade_inner - pad_r in
            match v_arr.(v_idx) with
            | `Lane (lane, is_sel) ->
                let lane_focused = Model.pane_focused model 0 in
                let row_bg =
                  if is_sel then H.selected_row_bg ~theme ~focused:lane_focused
                  else theme.surface_1
                in
                if is_sel then
                  H.paint_selected_row_bg ~grid ~clip:cascade_inner
                    ~row_rect:r_rect ~theme ~focused:lane_focused ();
                let decl =
                  if lane.declared then ""
                  else
                    " · "
                    ^ Say.resolve lang (Say.make ~ko:"암묵" ~en:"implicit")
                in
                let caret =
                  if is_sel then Glyph.Expand_open else Glyph.Expand_open
                in
                let hdr = Printf.sprintf "%s %s" (Glyph.to_utf8 caret) lane.id in
                let meta =
                  Printf.sprintf "%d slots%s" (List.length lane.runtime_ids) decl
                in
                let meta_w = Grapheme.display_width meta in
                let left_max =
                  Int.max 8 (right_edge - (cascade_inner.x + 2) - meta_w - 2)
                in
                let lane_style =
                  if is_sel then
                    H.row_text_style ~theme ~selected:true ~focused:lane_focused
                      ~bg:row_bg
                  else H.accent_style ~theme ~bg:row_bg ~attrs:Attr.bold ()
                in
                ignore
                  (H.put_clipped ~grid ~clip:r_rect ~x:(cascade_inner.x + 2)
                     ~y:py ~max_w:left_max ~style:lane_style hdr);
                ignore
                  (H.put_right ~grid ~clip:r_rect ~right_x:right_edge ~y:py
                     ~max_w:meta_w ~style:(H.whisper_style ~theme ~bg:row_bg ())
                     meta)
            | `Slot (si, _slot_n, rid, parent_sel) ->
                let is_primary = si = 0 in
                let row_bg =
                  if is_primary && parent_sel then theme.surface_2
                  else theme.surface_1
                in
                if is_primary && parent_sel then
                  Cell_grid.fill_rect ~clip:cascade_inner grid ~rect:r_rect
                    ~style:(H.text_style ~theme ~bg:row_bg ()) ();
                let prov_id =
                  match Hashtbl.find_opt runtimes_tbl rid with
                  | Some r -> Some r.provider_id
                  | None -> None
                in
                let human_lbl =
                  Wire_runtime.human_runtime_slot_label ~runtimes rid
                in
                let quota_st =
                  match prov_id with
                  | Some pid ->
                      provider_quota_status ~now_unix ~provider:pid
                        (Observed.to_option rt.usage_windows)
                  | None -> Quota_ok
                in
                let standing_override =
                  standing_override_for ~now_unix ~lang ~rt rid
                in
                let status_g, status_tone, status_txt, rtt_txt =
                  match quota_st, standing_override with
                  | Quota_exhausted, _ ->
                      ( Glyph.Live_failing
                      , Theme.Status_critical
                      , Format_val.format_cost Format_val.Exhausted_zero ~lang
                      , "" )
                  | (Quota_ok | Quota_cooldown _), Some s -> s
                  | (Quota_ok | Quota_cooldown _), None ->
                  match (Hashtbl.find_opt probe_tbl rid, quota_st) with
                  | _, Quota_exhausted ->
                      ( Glyph.Live_failing
                      , Theme.Status_critical
                      , Format_val.format_cost Format_val.Exhausted_zero ~lang
                      , "" )
                  | Some pr, Quota_cooldown dur when pr.reachable = Some false -> (
                      match pr.http_status with
                      | Some 429 ->
                          ( Glyph.Live_paused
                          , Theme.Status_attention
                          , "Cooldown " ^ dur
                          , "429" )
                      | Some _ | None ->
                          ( Glyph.Live_failing
                          , Theme.Status_critical
                          , format_failover_reason pr
                          , "" ))
                  | Some pr, Quota_ok when pr.reachable = Some false -> (
                      match pr.http_status with
                      | Some 429 ->
                          ( Glyph.Live_paused
                          , Theme.Status_attention
                          , "Cooldown"
                          , "429" )
                      | Some _ | None ->
                          ( Glyph.Live_failing
                          , Theme.Status_critical
                          , format_failover_reason pr
                          , "" ))
                  | _, Quota_cooldown dur ->
                      ( Glyph.Live_paused
                      , Theme.Status_attention
                      , "Cooldown " ^ dur
                      , "" )
                  | Some pr, Quota_ok -> (
                      match pr.reachable with
                      | Some true ->
                          let lat =
                            match pr.latency_ms with
                            | Some ms ->
                                Format_val.format_value Format_val.Milliseconds
                                  ms
                            | None -> ""
                          in
                          ( (if is_primary then Glyph.Live_healthy
                             else Glyph.Live_idle)
                          , (if is_primary then Theme.Status_ok
                             else Theme.Status_active)
                          , (if is_primary then "Active" else "Ready")
                          , lat )
                      | Some false | None ->
                          ( Glyph.Live_idle
                          , Theme.Status_active
                          , (if is_primary then "Active" else "Ready")
                          , "" ))
                  | None, Quota_ok ->
                      ( (if is_primary then Glyph.Live_healthy
                         else Glyph.Live_idle)
                      , (if is_primary then Theme.Status_ok
                         else Theme.Status_active)
                      , (if is_primary then "Active" else "Ready")
                      , "" )
                in
                let x0 = cascade_inner.x + 2 in
                let conn_style =
                  Style.make ~fg:(Color.of_rgb theme.border_subtle)
                    ~bg:(Color.of_rgb row_bg) ()
                in
                if is_primary then
                  Cell_grid.put_ascii ~clip:r_rect grid ~x:x0 ~y:py
                    ~style:conn_style ' '
                else
                  Cell_grid.put_glyph ~clip:r_rect grid ~x:x0 ~y:py
                    ~style:conn_style Glyph.Flow_down;
                let idx_s = Printf.sprintf "%d" (si + 1) in
                ignore
                  (H.put_clipped ~grid ~clip:r_rect ~x:(x0 + 2) ~y:py ~max_w:2
                     ~style:(H.secondary_style ~theme ~bg:row_bg ())
                     idx_s);
                Cell_grid.put_glyph ~clip:r_rect grid ~x:(x0 + 4) ~y:py
                  ~style:(H.status_style ~theme ~bg:row_bg status_tone)
                  status_g;
                let right_cluster =
                  if String.equal rtt_txt "" then status_txt
                  else Printf.sprintf "%s  %s" status_txt rtt_txt
                in
                let rc_w = Grapheme.display_width right_cluster in
                let lbl_x = x0 + 6 in
                let lbl_w = Int.max 6 (right_edge - lbl_x - rc_w - 2) in
                let lbl_style =
                  if is_primary then H.anchor_style ~theme ~bg:row_bg ()
                  else H.text_style ~theme ~bg:row_bg ()
                in
                ignore
                  (H.put_clipped ~grid ~clip:r_rect ~x:lbl_x ~y:py ~max_w:lbl_w
                     ~style:lbl_style human_lbl);
                ignore
                  (H.put_right ~grid ~clip:r_rect ~right_x:right_edge ~y:py
                     ~max_w:rc_w
                     ~style:
                       (H.status_style ~theme ~bg:row_bg
                          ~attrs:(if is_primary then Attr.bold else Attr.none)
                          status_tone)
                     right_cluster)
          end
        done;
        if reserve_ext > 0 && !y < bottom then begin
          let pad_x = Layout.card_pad_x bp in
          H.draw_divider ~grid ~rect:cascade_inner ~y:!y ~theme ~pad_x
            ~label:
              (Say.resolve lang
                 (Say.make ~ko:"레인 외부 프로브 (SSOT 격리)"
                    ~en:"Outside-Lane Probes (SSOT isolated)"))
            ();
          incr y;
          List.iter
            (fun (pr : Wire_runtime.provider_probe_row) ->
              if !y < bottom then begin
                let hlbl =
                  Wire_runtime.human_runtime_slot_label ~runtimes pr.runtime_id
                in
                let txt =
                  Printf.sprintf "%s %s · %s"
                    (Glyph.to_utf8 Glyph.Historical_incident)
                    hlbl (format_failover_reason pr)
                in
                ignore
                  (H.put_clipped ~grid ~clip:cascade_inner
                     ~x:(cascade_inner.x + pad_x) ~y:!y
                     ~max_w:(Int.max 0 (cascade_inner.w - (2 * pad_x)))
                     ~style:(H.status_style ~theme Theme.Status_historical)
                     txt);
                incr y
              end)
            (H.safe_take (bottom - !y) outside_probes)
        end
    | Observed.Value _ ->
        H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp cascade_inner) ~theme
          (Say.resolve lang
             (if String.equal (String.trim rt.filter_query) "" then
                Say.make ~ko:"선언된 페일오버 레인 없음"
                  ~en:"No failover lanes declared"
              else
                Say.make ~ko:"필터에 일치하는 레인 없음"
                  ~en:"No failover lanes match filter"))
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp cascade_inner)
          ~theme ~lang obs
  end;
  (* Right Column: Top = Selected Lane Inspector & Health, Bottom = Unified Exact + Fusion *)
  let insp_rect, runs_rect =
    match
      Layout.split_v_bp bp right_rect [ Layout.Ratio 0.52; Layout.Flex 1 ]
    with
    | [ a; b ] -> (a, b)
    | _ -> (right_rect, Rect.empty)
  in
  let sel_lane = Runtime_store.selected_lane rt in
  let setup_hint =
    let inv_part =
      match Observed.to_option rt.setup_inventory with
      | Some inv ->
          let supported_n =
            List.fold_left
              (fun acc (i : Wire_runtime.setup_integration) ->
                match Wire_runtime.classify_setup_support i.setup_support with
                | Wire_runtime.Setup_unsupported -> acc
                | Wire_runtime.Setup_supported _ -> acc + 1)
              0 inv.integrations
          in
          Printf.sprintf "%d setup" supported_n
      | None -> ""
    in
    let login_part =
      match rt.setup_login_receipt with
      | Some r -> Printf.sprintf "login:%s(%s)" r.integration_id r.status
      | None -> ""
    in
    let extra =
      [ inv_part; login_part ]
      |> List.filter (fun s -> not (String.equal s ""))
      |> String.concat " · "
    in
    let keys =
      Say.resolve lang
        (Say.make ~ko:"[a]배정 [K]키 [l]로그인" ~en:"[a]Assign [K]Key [l]Login")
    in
    if String.equal extra "" then keys else extra ^ " · " ^ keys
  in
  let insp_focused = Model.detail_pane_focused ~detail_index:1 model in
  let insp_badge =
    if insp_focused || model.infra.show_raw_json then
      Some
        (H.make_badge
           ~tone:
             (if model.infra.show_raw_json then Theme.Status_active
              else Theme.Status_historical)
           (if model.infra.show_raw_json then "[Space] Json_tree ON"
            else "[Space] Json_tree"))
    else None
  in
  let insp_inner =
    Card.draw ~cache grid ~rect:insp_rect ~theme
      (H.card_spec ~focused:insp_focused ?badge:insp_badge
         ?subtitle:(Option.map (fun (l : Wire_runtime.failover_lane) -> l.id) sel_lane)
         ~hotkey:setup_hint
         (Say.resolve lang
            (Say.make ~ko:"선택 레인 상세 · 헬스" ~en:"Selected Lane Health")))
  in
  if not (Rect.is_empty insp_inner) then begin
    match sel_lane with
    | None ->
        H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp insp_inner)
          ~theme ~lang ~filter_query:rt.filter_query rt.runtime_resolved
    | Some lane when model.infra.show_raw_json ->
        let json =
          `Assoc
            [
              ("id", `String lane.id);
              ("declared", `Bool lane.declared);
              ( "runtime_ids"
              , `List (List.map (fun s -> `String s) lane.runtime_ids) );
            ]
        in
        let lines = Json_tree.flatten ~max_depth:4 ~redact_secrets:true json in
        ignore
          (Json_tree.draw grid ~rect:(H.pad_content ~bp insp_inner) ~theme
             ~scroll:rt.detail_scroll_offset lines)
    | Some lane ->
        let slot_quota_st rid =
          match Hashtbl.find_opt runtimes_tbl rid with
          | Some r ->
              provider_quota_status ~now_unix ~provider:r.provider_id
                (Observed.to_option rt.usage_windows)
          | None -> Quota_ok
        in
        let slot_n = List.length lane.runtime_ids in
        let reach_n =
          List.fold_left
            (fun acc rid ->
              if standing_restricts_readiness ~now_unix ~rt rid then acc
              else
                match slot_quota_st rid with
                | Quota_cooldown _ | Quota_exhausted -> acc
                | Quota_ok -> (
                    match Hashtbl.find_opt probe_tbl rid with
                    | Some { reachable = Some true; _ } -> acc + 1
                    | Some { reachable = Some false | None; _ } | None -> acc))
            0 lane.runtime_ids
        in
        let primary_rid = match lane.runtime_ids with r :: _ -> r | [] -> "" in
        let primary_lbl =
          Wire_runtime.human_runtime_slot_label ~runtimes primary_rid
        in
        let pad_x = Layout.card_pad_x bp in
        let band_h = if insp_inner.h >= 6 then 2 else 1 in
        Card.draw_section_band ~pad_x grid
          ~rect:(Rect.make ~x:insp_inner.x ~y:insp_inner.y ~w:insp_inner.w ~h:band_h)
          ~theme ~left_title:lane.id
          ~right_meta:(Printf.sprintf "%d/%d %s" reach_n slot_n
                         (Say.resolve lang (Say.make ~ko:"가용" ~en:"ok")))
          ?subtitle:
            (if band_h >= 2 then
               Some
                 (Printf.sprintf "%s %s"
                    (Say.resolve lang (Say.make ~ko:"기본 슬롯:" ~en:"Primary:"))
                    primary_lbl)
             else None)
          ();
        let body_area =
          Rect.make ~x:insp_inner.x ~y:(insp_inner.y + band_h) ~w:insp_inner.w
            ~h:(Int.max 0 (insp_inner.h - band_h))
          |> H.pad_content ~bp
        in
        if not (Rect.is_empty body_area) then begin
          let y = ref body_area.y and bot = Rect.bottom body_area in
          if !y < bot then begin
            let g_rect = Rect.make ~x:body_area.x ~y:!y ~w:body_area.w ~h:1 in
            let g_spec : Chart.Spec.t =
              {
                title = Say.make ~ko:"가용률" ~en:"Avail";
                hotkey_hint = None;
                kind =
                  Chart.Spec.Ratio_gauge
                    {
                      used =
                        Observed.value ~observed_at:Clock.Mono.zero
                          (float_of_int reach_n);
                      limit =
                        Observed.value ~observed_at:Clock.Mono.zero
                          (float_of_int (Int.max 1 slot_n));
                      unit = Format_val.Count;
                      gradient = Chart.Gradient.Efficiency;
                      reset_hint = None;
                    };
              }
            in
            ignore
              (Chart.draw grid ~rect:g_rect ~theme ~caps:H.default_caps ~lang
                 ~show_title:false g_spec);
            incr y
          end;
          if body_area.h >= 6 && !y < bot then incr y;
          if !y < bot then begin
            H.draw_divider ~grid ~rect:body_area ~y:!y ~theme
              ~label:(Say.resolve lang (Say.make ~ko:"슬롯 프로브" ~en:"Slot Probes"))
              ();
            incr y
          end;
          (* Each slot names the account its provider runs on, so two slots
             of one model on different logins read apart. *)
          let slot_account rid =
            match
              (Hashtbl.find_opt runtimes_tbl rid, Observed.to_option rt.setup_inventory)
            with
            | Some r, Some inv ->
                List.find_map
                  (fun (row : Wire_runtime.setup_account_email) ->
                    if String.equal row.integration_id r.provider_id then
                      Some (Wire_runtime.setup_account_line row.account)
                    else None)
                  inv.account_emails
            | (Some _ | None), _ -> None
          in
          let avail_slot_rows = Int.max 1 (bot - !y) in
          let slot_skip =
            Int.min
              (Int.max 0 (slot_n - avail_slot_rows))
              (Int.max 0 rt.detail_scroll_offset)
          in
          List.iteri
            (fun local_idx rid ->
              let idx = slot_skip + local_idx in
              if !y < bot then begin
                let lbl =
                  let slot = Wire_runtime.human_runtime_slot_label ~runtimes rid in
                  match slot_account rid with
                  | Some account -> slot ^ " · " ^ account
                  | None -> slot
                in
                let transport_s =
                  match Hashtbl.find_opt runtimes_tbl rid with
                  | Some { transport = Some t; _ } -> String.uppercase_ascii t
                  | Some { transport = None; _ } | None -> "—"
                in
                let st_g, st_tone, st_val =
                  match
                    ( slot_quota_st rid
                    , standing_override_for ~now_unix ~lang ~rt rid )
                  with
                  | Quota_exhausted, _ ->
                      ( Glyph.Live_failing
                      , Theme.Status_critical
                      , Format_val.format_cost Format_val.Exhausted_zero ~lang )
                  | (Quota_ok | Quota_cooldown _), Some (g, tone, txt, _) ->
                      (g, tone, txt)
                  | Quota_cooldown dur, None ->
                      ( Glyph.Live_paused
                      , Theme.Status_attention
                      , "Cooldown " ^ dur )
                  | Quota_ok, None -> (
                      match Hashtbl.find_opt probe_tbl rid with
                      | Some pr -> (
                          match pr.reachable with
                          | Some true ->
                              let lat =
                                match pr.latency_ms with
                                | Some ms ->
                                    Format_val.format_value
                                      Format_val.Milliseconds ms
                                | None -> "ok"
                              in
                              (Glyph.Live_healthy, Theme.Status_ok, lat)
                          | Some false ->
                              ( Glyph.Live_failing
                              , Theme.Status_critical
                              , format_failover_reason pr )
                          | None -> (Glyph.Live_idle, Theme.Status_active, pr.status))
                      | None -> (Glyph.Live_idle, Theme.Status_historical, "—"))
                in
                let right_s = Printf.sprintf "%s · %s" transport_s st_val in
                let rw = Grapheme.display_width right_s in
                let sx = if body_area.w >= 28 then body_area.x + 2 else body_area.x in
                let sw = Rect.right body_area - sx in
                let lw = Int.max 8 (sw - rw - 2) in
                ignore
                  (H.put_clipped ~grid ~clip:body_area ~x:sx ~y:!y
                     ~max_w:lw ~style:(H.text_style ~theme ())
                     (Printf.sprintf "%d %s %s" (idx + 1) (Glyph.to_utf8 st_g) lbl));
                ignore
                  (H.put_right ~grid ~clip:body_area ~right_x:(Rect.right body_area)
                     ~y:!y ~max_w:rw ~style:(H.status_style ~theme st_tone)
                     right_s);
                incr y
              end)
            (Store_scroll.drop slot_skip lane.runtime_ids)
        end
  end;
  (* Bottom Right Card: Unified Exact Output + Fusion Panel Fan-Out *)
  let runs_subtitle =
    match Observed.to_option rt.board_attention_quarantines with
    | Some (kp, q) when q.count > 0 ->
        Some (Printf.sprintf "quarantine:%s(%d)" kp q.count)
    | Some _ | None -> None
  in
  let runs_inner =
    Card.draw ~cache grid ~rect:runs_rect ~theme
      (H.card_spec ?subtitle:runs_subtitle
         ~hotkey:
           (Say.resolve lang
              (Say.make ~ko:"[D] Exact 상세 · [f] 퓨전"
                 ~en:"[D] Exact Detail · [f] Fusion"))
         (Say.resolve lang
            (Say.make ~ko:"Exact · Fusion 실행 이력"
               ~en:"Exact & Fusion Runs")))
  in
  let runs_content = H.pad_content ~bp runs_inner in
  if not (Rect.is_empty runs_content) then begin
    let y = ref runs_content.y and bot = Rect.bottom runs_content in
    if !y < bot then begin
      H.draw_divider ~grid ~rect:runs_content ~y:!y ~theme
        ~label:(Say.resolve lang (Say.make ~ko:"Exact 출력" ~en:"Exact Lanes"))
        ();
      incr y
    end;
    (match rt.exact_lane_runs with
     | Observed.Value { data = runs; _ } when runs <> [] ->
         let run_note (r : Wire_runtime.exact_lane_run) =
           match r.status with
           | Wire_runtime.Exact_output
               (Wire_runtime.Exact_failed { code; detail }) ->
               Some (code ^ " · " ^ detail)
           | Wire_runtime.Exact_output
               ( Wire_runtime.Exact_running | Wire_runtime.Exact_succeeded
               | Wire_runtime.Exact_cancelled
               | Wire_runtime.Exact_completion_persistence_failed
               | Wire_runtime.Exact_completion_durability_unknown )
           | Wire_runtime.Task_verification _ | Wire_runtime.Goal_verification _
             ->
               r.subject_id
         in
         let dedup_runs (xs : Wire_runtime.exact_lane_run list) =
           let order = ref [] in
           let tbl : (string, Wire_runtime.exact_lane_run * int) Hashtbl.t =
             Hashtbl.create 16
           in
           List.iter
             (fun (r : Wire_runtime.exact_lane_run) ->
               let key =
                 Printf.sprintf "%s\x00%s\x00%s" r.lane
                   (Wire_runtime.lane_run_status_label r.status)
                   (match run_note r with Some s -> s | None -> "")
               in
               match Hashtbl.find_opt tbl key with
               | None ->
                   order := key :: !order;
                   Hashtbl.add tbl key (r, 1)
               | Some (prev, cnt) ->
                   let best =
                     if r.started_at_unix > prev.started_at_unix then r else prev
                   in
                   Hashtbl.replace tbl key (best, cnt + 1))
             xs;
           List.rev !order |> List.filter_map (fun k -> Hashtbl.find_opt tbl k)
         in
         (* A verdict (rejected) or a replaced run (superseded, deferred) is
            the lane working; only a run that broke is critical. *)
         let exact_status_display (status : Wire_runtime.lane_run_status) =
           match status with
           | Wire_runtime.Exact_output Wire_runtime.Exact_succeeded
           | Wire_runtime.Task_verification Wire_runtime.Task_review_approved
           | Wire_runtime.Goal_verification
               (Wire_runtime.Goal_review_reviewed
               | Wire_runtime.Goal_review_committed) ->
               (Glyph.Live_healthy, Theme.Status_ok)
           | Wire_runtime.Exact_output Wire_runtime.Exact_running
           | Wire_runtime.Task_verification
               ( Wire_runtime.Task_review_running
               | Wire_runtime.Task_review_execution_pending )
           | Wire_runtime.Goal_verification Wire_runtime.Goal_review_running ->
               (Glyph.Live_working, Theme.Status_active)
           | Wire_runtime.Exact_output Wire_runtime.Exact_cancelled
           | Wire_runtime.Task_verification
               ( Wire_runtime.Task_review_cancelled
               | Wire_runtime.Task_review_not_reviewed
               | Wire_runtime.Task_review_superseded )
           | Wire_runtime.Goal_verification
               ( Wire_runtime.Goal_review_cancelled
               | Wire_runtime.Goal_review_superseded
               | Wire_runtime.Goal_review_deferred ) ->
               (Glyph.Live_paused, Theme.Status_historical)
           | Wire_runtime.Exact_output
               Wire_runtime.Exact_completion_durability_unknown
           | Wire_runtime.Task_verification
               ( Wire_runtime.Task_review_rejected
               | Wire_runtime.Task_review_infrastructure_unavailable
               | Wire_runtime.Task_review_execution_repair_required ) ->
               (Glyph.Warning_triangle, Theme.Status_attention)
           | Wire_runtime.Exact_output
               ( Wire_runtime.Exact_failed _
               | Wire_runtime.Exact_completion_persistence_failed )
           | Wire_runtime.Task_verification
               ( Wire_runtime.Task_review_commit_failed
               | Wire_runtime.Task_review_raised )
           | Wire_runtime.Goal_verification Wire_runtime.Goal_review_raised ->
               (Glyph.Live_failing, Theme.Status_critical)
         in
         let max_exact = Int.max 1 ((bot - !y) / 2) in
         List.iter
           (fun ((r : Wire_runtime.exact_lane_run), count) ->
             if !y < bot then begin
               let g, tone = exact_status_display r.status in
               let age = H.format_age ~now_unix r.started_at_unix in
               let cnt_s = if count > 1 then Printf.sprintf " ×%d" count else "" in
               let sum = match run_note r with Some s -> " · " ^ s | None -> "" in
               let left_s =
                 Printf.sprintf "%s %s [%s]%s%s" (Glyph.to_utf8 g) r.lane
                   (Wire_runtime.lane_run_status_label r.status)
                   cnt_s sum
               in
               let aw = Grapheme.display_width age in
               ignore
                 (H.put_clipped ~grid ~clip:runs_content ~x:runs_content.x ~y:!y
                    ~max_w:(Int.max 6 (runs_content.w - aw - 2))
                    ~style:(H.status_style ~theme tone) left_s);
               ignore
                 (H.put_right ~grid ~clip:runs_content
                    ~right_x:(Rect.right runs_content) ~y:!y ~max_w:aw
                    ~style:(H.whisper_style ~theme ()) age);
               incr y
             end)
           (H.safe_take max_exact (dedup_runs runs))
     | Observed.Value _ ->
         if !y < bot then begin
           ignore
             (H.put_clipped ~grid ~clip:runs_content ~x:runs_content.x ~y:!y
                ~max_w:runs_content.w ~style:(H.whisper_style ~theme ())
                (Say.resolve lang
                   (Say.make ~ko:"최근 Exact 실행 없음" ~en:"No recent Exact runs")));
           incr y
         end
     | ( Observed.Loading _
       | Observed.Absent
       | Observed.Unreported
       | Observed.Failed _ ) as obs ->
         if !y < bot then begin
           H.draw_observed_placeholder ~grid
             ~rect:(Rect.make ~x:runs_content.x ~y:!y ~w:runs_content.w ~h:1)
             ~theme ~lang obs;
           incr y
         end);
    if !y < bot then begin
      H.draw_divider ~grid ~rect:runs_content ~y:!y ~theme
        ~label:(Say.resolve lang (Say.make ~ko:"Fusion 팬아웃" ~en:"Fusion Fan-Out"))
        ();
      incr y
    end;
    let stale = fusion_observation_is_stale model in
    match rt.fusion_runs with
    | Observed.Value { data = runs; _ } when runs <> [] ->
        List.iter
          (fun (f : Wire_runtime.fusion_run) ->
            if !y < bot then begin
              let g, tone, st_lbl =
                match f.status with
                | Wire_runtime.Fusion_running when stale ->
                    (Glyph.Transport_stale, Theme.Status_attention, "Last observed")
                | Wire_runtime.Fusion_running ->
                    (Glyph.Live_working, Theme.Status_active, "Running · " ^ f.stage)
                | Wire_runtime.Fusion_completed ->
                    (Glyph.Live_healthy, Theme.Status_ok, "Completed")
                | Wire_runtime.Fusion_failed { code; error } ->
                    ( Glyph.Live_failing
                    , Theme.Status_critical
                    , Printf.sprintf "Failed (%s: %s)" code error )
              in
              let topo = Wire_runtime.fusion_topology_to_string f.topology in
              let dec = match f.decision with Some d -> " · " ^ d | None -> "" in
              let age = fusion_elapsed ~now_unix ~stale f in
              let aw = Grapheme.display_width age in
              let left_s =
                Printf.sprintf "%s %s [%s/%s] %s%s" (Glyph.to_utf8 g) f.keeper
                  f.preset topo st_lbl dec
              in
              ignore
                (H.put_clipped ~grid ~clip:runs_content ~x:runs_content.x ~y:!y
                   ~max_w:(Int.max 6 (runs_content.w - aw - 2))
                   ~style:(H.status_style ~theme tone) left_s);
              ignore
                (H.put_right ~grid ~clip:runs_content
                   ~right_x:(Rect.right runs_content) ~y:!y ~max_w:aw
                   ~style:(H.whisper_style ~theme ()) age);
              incr y
            end)
          runs
    | Observed.Value _ ->
        if !y < bot then
          ignore
            (H.put_clipped ~grid ~clip:runs_content ~x:runs_content.x ~y:!y
               ~max_w:runs_content.w ~style:(H.whisper_style ~theme ())
               (Say.resolve lang
                   (if stale then
                      Say.make ~ko:"마지막으로 확인한 실행은 없습니다"
                        ~en:"No runs in the last observation"
                    else
                      Say.make ~ko:"최근 Fusion 실행 없음" ~en:"No recent Fusion runs")))
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        if !y < bot then
          H.draw_observed_placeholder ~grid
            ~rect:(Rect.make ~x:runs_content.x ~y:!y ~w:runs_content.w ~h:1)
            ~theme ~lang obs
  end

(* --- 4. Sub-Tab 4: Fusion (1st-class sub-tab) --- *)

let render_fusion ~(model : Model.t) ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp grid =
  let lang = model.lang in
  let rt = model.runtime in
  let now_unix = model.freshness.last_wall_unix in
  let runs = Runtime_store.filtered_fusion_runs rt in
  let stale = fusion_observation_is_stale model in
  let bar_rect, body_rect =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ a; b ] -> (a, b)
    | _ -> (Rect.empty, rect)
  in
  let running_n =
    List.fold_left
      (fun acc (f : Wire_runtime.fusion_run) ->
        match f.status with
        | Wire_runtime.Fusion_running -> acc + 1
        | Wire_runtime.Fusion_completed | Wire_runtime.Fusion_failed _ -> acc)
      0 runs
  in
  let preset_pill =
    if rt.fusion_config_auth_denied then
      [
        {
          H.label = "Presets: CanAdmin";
          active = false;
          tone = Some Theme.Status_attention;
          glyph = Some Glyph.Warning_triangle;
        };
      ]
    else
      match Observed.to_option rt.fusion_config with
      | Some cfg ->
          [
            {
              H.label =
                Printf.sprintf "Presets (%d · %s)" (List.length cfg.presets)
                  cfg.default_preset;
              active = false;
              tone = Some Theme.Status_active;
              glyph = None;
            };
          ]
      | None -> []
  in
  let run_label, run_tone, run_glyph =
    let say ~ko ~en = Say.resolve lang (Say.make ~ko ~en) in
    match rt.fusion_runs with
    | Observed.Value _ when stale ->
        (say ~ko:"Fusion 마지막 관측" ~en:"Fusion last observed",
         Theme.Status_attention, Glyph.Transport_stale)
    | Observed.Value _ ->
        (Printf.sprintf "%s (%d · %d %s)"
           (say ~ko:"퓨전 실행" ~en:"Fusion Runs")
           (List.length runs) running_n (say ~ko:"진행 중" ~en:"active"),
         (if running_n > 0 then Theme.Status_active else Theme.Status_ok),
         (if running_n > 0 then Glyph.Live_working else Glyph.Live_healthy))
    | Observed.Loading _ ->
        (say ~ko:"Fusion 이력 조회 중" ~en:"Loading Fusion runs",
         Theme.Status_historical, Glyph.Transport_reconnecting)
    | Observed.Failed _ ->
        (say ~ko:"Fusion 이력 조회 실패" ~en:"Fusion fetch failed",
         Theme.Status_critical, Glyph.Live_failing)
    | Observed.Absent | Observed.Unreported ->
        (say ~ko:"Fusion 이력 미확인" ~en:"Fusion runs unobserved",
         Theme.Status_historical, Glyph.Missing_unreported)
  in
  let exact_pill runs =
    {
      H.label =
        Printf.sprintf "%s (%d)"
          (Say.resolve lang (Say.make ~ko:"Exact 레인" ~en:"Exact Lanes"))
          (List.length runs);
      active = false;
      tone = Some Theme.Status_historical;
      glyph = None;
    }
  in
  let pills =
    [ { H.label = run_label; active = true; tone = Some run_tone;
        glyph = Some run_glyph } ]
    @ (Observed.to_option rt.exact_lane_runs |> Option.map exact_pill |> Option.to_list)
    @ preset_pill
  in
  let zoomed_fusion = Model.is_zoomed_active model in
  ignore
    (H.draw_pills ~grid ~rect:bar_rect ~theme
       ~right_hint:
         (Say.resolve lang
            (if zoomed_fusion then
               Say.make ~ko:"[Enter/e] 보드 증거 · [f] 실행"
                 ~en:"[Enter/e] Evidence · [f] Launch"
             else
               Say.make
                 ~ko:"[Enter/z] 확대 · [e] 보드 증거 · [f] 실행 · [Tab] 스크롤"
                 ~en:"[Enter/z] Zoom · [e] Evidence · [f] Launch · [Tab] Scroll"))
       pills);
  let left_rect, right_rect =
    if zoomed_fusion then
      (Rect.empty, body_rect)
    else
      Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.44
        ~top_ratio:0.46 bp body_rect
  in
  let left_inner =
    Card.draw ~cache grid ~rect:left_rect ~theme
      (H.card_spec ~focused:(Model.pane_focused model 0)
         ~hotkey:(Say.resolve lang (Say.make ~ko:"[Enter/z] 확대 · [f] 실행" ~en:"[Enter/z] Zoom · [f] Launch"))
         (Say.resolve lang (Say.make ~ko:"Fusion 팬아웃 목록" ~en:"Fusion Panel Runs")))
  in
  if not (Rect.is_empty left_inner) then begin
    match rt.fusion_runs with
    | Observed.Value _ when runs <> [] ->
        let columns : Table.column list =
          [
            {
              id = "st";
              header = Say.make ~ko:"상태" ~en:"St";
              priority = 0;
              min_width = 7;
              max_width = Some 10;
              weight = 1;
              align = Table.Left;
            };
            {
              id = "keeper";
              header = Say.make ~ko:"키퍼" ~en:"Keeper";
              priority = 0;
              min_width = 12;
              max_width = Some 20;
              weight = 2;
              align = Table.Left;
            };
            {
              id = "preset";
              header = Say.make ~ko:"프리셋/토폴로지" ~en:"Preset/Topo";
              priority = 1;
              min_width = 12;
              max_width = None;
              weight = 3;
              align = Table.Left;
            };
            {
              id = "stage";
              header = Say.make ~ko:"단계" ~en:"Stage";
              priority = 2;
              min_width = 8;
              max_width = Some 14;
              weight = 1;
              align = Table.Left;
            };
            {
              id = "age";
              header = Say.make ~ko:"경과/소요" ~en:"Elapsed";
              priority = 2;
              min_width = 5;
              max_width = Some 8;
              weight = 1;
              align = Table.Right;
            };
          ]
        in
        let rows =
          List.map
            (fun (f : Wire_runtime.fusion_run) ->
              let g, tone, st_lbl =
                match f.status with
                | Wire_runtime.Fusion_running when stale ->
                    (Glyph.Transport_stale, Theme.Status_attention, "Last")
                | Wire_runtime.Fusion_running ->
                    (Glyph.Live_working, Theme.Status_active, "Run")
                | Wire_runtime.Fusion_completed ->
                    (Glyph.Live_healthy, Theme.Status_ok, "Done")
                | Wire_runtime.Fusion_failed _ ->
                    (Glyph.Live_failing, Theme.Status_critical, "Fail")
              in
              let pt =
                Printf.sprintf "%s / %s" f.preset
                  (Wire_runtime.fusion_topology_to_string f.topology)
              in
              let elapsed = fusion_elapsed ~now_unix ~stale f in
              {
                Table.id = f.run_id;
                cells =
                  [
                    ( "st"
                    , Table.Badge
                        { glyph = Some g; text = st_lbl; tone } );
                    ("keeper", Table.text_cell f.keeper);
                    ("preset", Table.text_cell pt);
                    ( "stage"
                    , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                        f.stage );
                    ( "age"
                    , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                        elapsed );
                  ];
              })
            runs
        in
        let sel = H.clamp_index (List.length runs) rt.fusion_selected_index in
        ignore
          (Table.draw grid ~rect:left_inner ~theme ~caps:H.default_caps ~lang
             ~col_gap:(Layout.table_col_gap bp) ~scroll:rt.fusion_scroll_offset
             ~selected:sel ~focused:(Model.pane_focused model 0) ~columns rows)
    | Observed.Value _ ->
        H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp left_inner) ~theme
          ~hint:
            (Say.resolve lang
               (Say.make ~ko:"[f] 키를 눌러 새 퓨전 패널을 실행하세요"
                  ~en:"Press [f] to launch a new Fusion panel"))
          (Say.resolve lang
             (if stale then
                Say.make ~ko:"마지막으로 확인한 실행은 없습니다"
                  ~en:"No runs in the last observation"
              else
                Say.make ~ko:"최근 Fusion 실행 이력이 없습니다"
                  ~en:"No recent Fusion runs"))
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp left_inner)
          ~theme ~lang obs
  end;
  let det_inner =
    Card.draw ~cache grid ~rect:right_rect ~theme
      (H.card_spec ~focused:(Model.detail_pane_focused ~detail_index:1 model)
         ~hotkey:
           (Say.resolve lang
              (if zoomed_fusion then
                 Say.make ~ko:"[Enter/e] 보드 증거 · [z/Esc] 확대 해제"
                   ~en:"[Enter/e] Evidence · [z/Esc] Unzoom"
               else
                 Say.make ~ko:"[Enter/z] 확대 · [e] 증거"
                   ~en:"[Enter/z] Zoom · [e] Evidence"))
         (Say.resolve lang (Say.make ~ko:"Fusion 파이프라인 상세" ~en:"Fusion Pipeline Detail")))
  in
  if not (Rect.is_empty det_inner) then begin
    let c = H.pad_content ~bp det_inner in
    match Runtime_store.selected_fusion_run rt with
    | None ->
        H.draw_empty_notice ~grid ~rect:c ~theme
          (Say.resolve lang
             (Say.make ~ko:"Fusion 실행을 선택하세요" ~en:"Select a Fusion run"))
    | Some f ->
        let lines =
          Update_nav.fusion_detail_lines ~width:c.w model ~run_id:f.run_id
        in
        let max_s = Int.max 0 (List.length lines - Int.max 1 c.h) in
        let scroll = Int.min max_s (Int.max 0 rt.detail_scroll_offset) in
        let bg = Color.of_rgb theme.surface_1 in
        List.iteri
          (fun i (ln : Update_nav.styled_line) ->
            let py = c.y + i in
            if py < Rect.bottom c then
              let put st =
                ignore
                  (H.put_clipped ~grid ~clip:c ~x:c.x ~y:py ~max_w:c.w ~style:st
                     ln.text)
              in
              match ln.tone with
              | Update_nav.Line_section ->
                  let lbl =
                    Option.value (Card.legacy_rule_label ln.text)
                      ~default:ln.text
                  in
                  Card.draw_hairline ~pad_x:0 ~bg ~label:lbl grid ~rect:c ~y:py
                    ~theme
              | Update_nav.Line_warn ->
                  put
                    (H.status_style ~theme ~attrs:Attr.bold
                       Theme.Status_attention)
              | Update_nav.Line_accent ->
                  put (H.accent_style ~theme ~attrs:Attr.bold ())
              | Update_nav.Line_error ->
                  put
                    (H.status_style ~theme ~attrs:Attr.bold
                       Theme.Status_critical)
              | Update_nav.Line_ok ->
                  put (H.status_style ~theme ~attrs:Attr.bold Theme.Status_ok)
              | Update_nav.Line_plain | Update_nav.Line_selected ->
                  put (H.text_style ~theme ()))
          (Store_scroll.drop scroll lines |> H.safe_take c.h)
  end

(* --- 5. Sub-Tab 5: Tools & Usage (3 Switchable Sub-Views + Live P0 Wire Fix) --- *)

let format_bucket_ts ~tz_offset_sec ~bucket_width ts_unix =
  let secs = int_of_float (Float.floor (ts_unix +. float_of_int tz_offset_sec)) in
  let day_secs = ((secs mod 86400) + 86400) mod 86400 in
  match bucket_width with
  | `Hour ->
      let hh = day_secs / 3600 in
      let mm = (day_secs mod 3600) / 60 in
      Printf.sprintf "%02d:%02d" hh mm
  | `Day ->
      (* Civil date from Unix days (Howard Hinnant's algorithm, pure integer math) *)
      let z = (secs - day_secs) / 86400 + 719468 in
      let era = (if z >= 0 then z else z - 146096) / 146097 in
      let doe = z - (era * 146097) in
      let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
      let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
      let mp = ((5 * doy) + 2) / 153 in
      let d = doy - (((153 * mp) + 2) / 5) + 1 in
      let m = mp + (if mp < 10 then 3 else -9) in
      Printf.sprintf "%02d-%02d" m d

let draw_tool_series_analytics ~table_focused ~grid ~cache
    ~(rect : Rect.t) ~(theme : Theme.t) ~bp ~(model : Model.t)
    ~(series : Wire_runtime.tool_series)
    ~(summary : Wire_runtime.tool_series_summary option) ~show_err_classes =
  let lang = model.lang in
  let rt = model.runtime in
  let buckets = series.buckets in
  let total_calls, total_fail, total_def, p50_opt, p95_opt =
    match summary with
    | Some s ->
        (s.total_calls, s.total_failures, s.total_deferred, s.p50_ms, s.p95_ms)
    | None ->
        let c, f, d, max_p95 =
          List.fold_left
            (fun (c, f, d, mp) (b : Wire_runtime.tool_series_bucket) ->
              match b.activity with
              | Wire_runtime.Series_idle -> (c, f, d, mp)
              | Wire_runtime.Series_active { calls; failures; deferred; p95_ms } ->
                  (c + calls, f + failures, d + deferred, Float.max mp p95_ms))
            (0, 0, 0, 0.0) buckets
        in
        (c, f, d, None, if max_p95 > 0.0 then Some max_p95 else None)
  in
  let fail_pct =
    if total_calls > 0 then
      float_of_int total_fail /. float_of_int total_calls *. 100.0
    else 0.0
  in
  let strip_rect, main_rect =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ a; b ] -> (a, b)
    | _ -> (Rect.empty, rect)
  in
  let win_pills =
    List.map
      (fun w ->
        {
          H.label = Runtime_store.tools_window_label w;
          active = Runtime_store.equal_tools_window rt.tools_window w;
          tone = Some Theme.Status_active;
          glyph = None;
        })
      [
        Runtime_store.Tools_win_24h;
        Runtime_store.Tools_win_7d;
        Runtime_store.Tools_win_14d;
      ]
  in
  let p50_s =
    match p50_opt with
    | Some v -> Format_val.format_value Format_val.Milliseconds v
    | None -> "—"
  in
  let p95_s =
    match p95_opt with
    | Some v -> Format_val.format_value Format_val.Milliseconds v
    | None -> "—"
  in
  let totals_hint =
    Printf.sprintf "[w] · %d calls · %d fail (%.1f%%) · %d def · p50 %s · p95 %s"
      total_calls total_fail fail_pct total_def p50_s p95_s
  in
  ignore
    (H.draw_pills ~grid ~rect:strip_rect ~theme ~right_hint:totals_hint
       win_pills);
  let charts_h = if main_rect.h >= 22 then 9 else if main_rect.h >= 14 then 6 else 0 in
  let charts_rect, bottom_rect =
    if charts_h > 0 then
      match
        Layout.split_v_bp bp main_rect
          [ Layout.Fixed charts_h; Layout.Flex 1 ]
      with
      | [ a; b ] -> (a, b)
      | _ -> (Rect.empty, main_rect)
    else (Rect.empty, main_rect)
  in
  let chart_win =
    match rt.tools_window with
    | Runtime_store.Tools_win_24h -> Chart.Time_window.Last_24h
    | Runtime_store.Tools_win_7d -> Chart.Time_window.Last_7d
    | Runtime_store.Tools_win_14d -> Chart.Time_window.Last_14d
  in
  if not (Rect.is_empty charts_rect) then begin
    let mk_samples extract =
      Array.of_list
        (List.map
           (fun (b : Wire_runtime.tool_series_bucket) ->
             match b.activity with
             | Wire_runtime.Series_idle -> Chart.Series.Zero
             | Wire_runtime.Series_active { calls; failures; deferred; p95_ms } ->
                 let v = extract ~calls ~failures ~deferred ~p95_ms in
                 if v <= 0.0 then Chart.Series.Zero else Chart.Series.Value v)
           buckets)
    in
    let calls_s = mk_samples (fun ~calls ~failures:_ ~deferred:_ ~p95_ms:_ -> float_of_int calls) in
    let fail_s = mk_samples (fun ~calls:_ ~failures ~deferred:_ ~p95_ms:_ -> float_of_int failures) in
    let p95_s_arr = mk_samples (fun ~calls:_ ~failures:_ ~deferred:_ ~p95_ms -> p95_ms) in
    let draw_curve_card ~rect:cr ~title ~unit ~gradient samples =
      let inner =
        Card.draw ~cache grid ~rect:cr ~theme (H.card_spec (Say.resolve lang title))
      in
      let content = H.pad_content ~bp inner in
      if not (Rect.is_empty content) then begin
        let cur, peak, avg = series_stats samples in
        let spec : Chart.Spec.t =
          {
            title;
            hotkey_hint = None;
            kind =
              Chart.Spec.Time_series
                {
                  series =
                    {
                      label = title;
                      unit;
                      gradient;
                      samples;
                      current = cur;
                      peak;
                      avg;
                      delta_pct = None;
                    };
                  scale = Chart.Scale.Auto_ceil { floor = 0.0; nice_step = true };
                  window = chart_win;
                };
          }
        in
        ignore
          (Chart.draw grid ~rect:content ~theme ~caps:H.default_caps ~lang
             ~show_title:false spec)
      end
    in
    if charts_rect.w >= 90 then
      match
        Layout.split_h_bp bp charts_rect
          [ Layout.Flex 1; Layout.Flex 1; Layout.Flex 1 ]
      with
      | [ c1; c2; c3 ] ->
          draw_curve_card ~rect:c1
            ~title:(Say.make ~ko:"호출량" ~en:"Calls")
            ~unit:Format_val.Count ~gradient:Chart.Gradient.Cool_flow calls_s;
          draw_curve_card ~rect:c2
            ~title:(Say.make ~ko:"실패" ~en:"Failed")
            ~unit:Format_val.Count ~gradient:Chart.Gradient.Warm_flow fail_s;
          draw_curve_card ~rect:c3
            ~title:(Say.make ~ko:"지연 p95" ~en:"Latency p95")
            ~unit:Format_val.Milliseconds ~gradient:Chart.Gradient.Thermal
            p95_s_arr
      | _ -> ()
    else
      match Layout.split_h_bp bp charts_rect [ Layout.Flex 1; Layout.Flex 1 ] with
      | [ c1; c2 ] ->
          draw_curve_card ~rect:c1
            ~title:(Say.make ~ko:"호출량" ~en:"Calls")
            ~unit:Format_val.Count ~gradient:Chart.Gradient.Cool_flow calls_s;
          draw_curve_card ~rect:c2
            ~title:(Say.make ~ko:"지연 p95" ~en:"Latency p95")
            ~unit:Format_val.Milliseconds ~gradient:Chart.Gradient.Thermal
            p95_s_arr
      | _ -> ()
  end;
  let tbl_rect, err_rect =
    if show_err_classes && bottom_rect.w >= 86 then
      match
        Layout.split_h_bp bp bottom_rect [ Layout.Ratio 0.62; Layout.Flex 1 ]
      with
      | [ l; r ] -> (l, r)
      | _ -> (bottom_rect, Rect.empty)
    else (bottom_rect, Rect.empty)
  in
  let tbl_inner =
    Card.draw ~cache grid ~rect:tbl_rect ~theme
      (H.card_spec ~focused:table_focused
         (Say.resolve lang
            (Say.make ~ko:"시간대별 도구 호출 버킷 (최신순)"
               ~en:"Bucket Breakdown (Newest First)")))
  in
  if not (Rect.is_empty tbl_inner) then begin
    let newest_first = List.rev buckets in
    let max_calls =
      List.fold_left
        (fun acc (b : Wire_runtime.tool_series_bucket) ->
          match b.activity with
          | Wire_runtime.Series_idle -> acc
          | Wire_runtime.Series_active { calls; _ } -> Int.max acc calls)
        1 newest_first
    in
    let bucket_hdr =
      match series.bucket_width with
      | `Hour -> Say.make ~ko:"시각" ~en:"HOUR"
      | `Day -> Say.make ~ko:"날짜" ~en:"DAY"
    in
    let columns : Table.column list =
      [
        {
          id = "ts";
          header = bucket_hdr;
          priority = 0;
          min_width = 6;
          max_width = Some 8;
          weight = 1;
          align = Table.Left;
        };
        {
          id = "calls";
          header = Say.literal "CALLS";
          priority = 0;
          min_width = 6;
          max_width = Some 8;
          weight = 1;
          align = Table.Right;
        };
        {
          id = "failed";
          header = Say.literal "FAILED";
          priority = 1;
          min_width = 6;
          max_width = Some 8;
          weight = 1;
          align = Table.Right;
        };
        {
          id = "fpct";
          header = Say.literal "FAIL%";
          priority = 1;
          min_width = 6;
          max_width = Some 8;
          weight = 1;
          align = Table.Right;
        };
        {
          id = "p95";
          header = Say.literal "P95";
          priority = 1;
          min_width = 7;
          max_width = Some 10;
          weight = 1;
          align = Table.Right;
        };
        {
          id = "load";
          header = Say.literal "LOAD";
          priority = 2;
          min_width = 10;
          max_width = Some 18;
          weight = 2;
          align = Table.Left;
        };
      ]
    in
    let rows =
      List.mapi
        (fun idx (b : Wire_runtime.tool_series_bucket) ->
          let ts_s =
            format_bucket_ts ~tz_offset_sec:model.tz_offset_sec
              ~bucket_width:series.bucket_width b.start_unix
          in
          let c, f, p95_s, fp_s, fp_fg, ratio =
            match b.activity with
            | Wire_runtime.Series_idle ->
                ("0", "0", "—", "0.0%", Some (Color.of_rgb theme.text_muted), 0.0)
            | Wire_runtime.Series_active { calls; failures; p95_ms; _ } ->
                let fp =
                  if calls > 0 then
                    float_of_int failures /. float_of_int calls *. 100.0
                  else 0.0
                in
                let fg =
                  if fp >= 10.0 then Some (Color.of_rgb theme.status_critical)
                  else if fp > 0.0 then Some (Color.of_rgb theme.status_attention)
                  else Some (Color.of_rgb theme.text_muted)
                in
                ( Int.to_string calls
                , Int.to_string failures
                , Format_val.format_value Format_val.Milliseconds p95_ms
                , Printf.sprintf "%.1f%%" fp
                , fg
                , float_of_int calls /. float_of_int max_calls )
          in
          {
            Table.id = Int.to_string idx;
            cells =
              [
                ("ts", Table.text_cell ~fg:(Color.of_rgb theme.text_secondary) ts_s);
                ("calls", Table.text_cell c);
                ("failed", Table.text_cell ?fg:fp_fg f);
                ("fpct", Table.text_cell ?fg:fp_fg fp_s);
                ("p95", Table.text_cell p95_s);
                ( "load"
                , Table.Gauge
                    { ratio; gradient = Chart.Gradient.Cool_flow; label = None } );
              ];
          })
        newest_first
    in
    ignore
      (Table.draw grid ~rect:tbl_inner ~theme ~caps:H.default_caps ~lang
         ~focused:table_focused ~col_gap:(Layout.table_col_gap bp)
         ~scroll:rt.scroll_offset ~columns rows)
  end;
  if not (Rect.is_empty err_rect) then begin
    let err_inner =
      Card.draw ~cache grid ~rect:err_rect ~theme
        (H.card_spec
           (Say.resolve lang
              (Say.make ~ko:"오류 분류 (4+2 클래스)" ~en:"Failure Classes")))
    in
    let ec = H.pad_content ~bp err_inner in
    if not (Rect.is_empty ec) then begin
      let fc_opt =
        match summary with
        | Some s ->
            let fc = s.failure_classes in
            Some
              ( fc.policy_rejection
              , fc.workflow_rejection
              , fc.dependency_unavailable
              , fc.runtime_failure
              , fc.operator_cancelled
              , fc.unclassified )
        | None -> (
            match Observed.to_option model.infra.sandboxes with
            | Some sb ->
                let fc = sb.fleet_metrics_24h.failure_classes in
                Some
                  ( fc.policy_rejection
                  , fc.workflow_rejection
                  , fc.dependency_unavailable
                  , fc.runtime_failure
                  , 0
                  , 0 )
            | None -> None)
      in
      match fc_opt with
      | None ->
          H.draw_observed_placeholder ~grid ~rect:ec ~theme ~lang
            model.infra.sandboxes
      | Some (pr, wr, du, rf, oc, uc) ->
          let y = ref ec.y and bot = Rect.bottom ec in
          if !y + 2 <= bot then begin
            let bar_r = Rect.make ~x:ec.x ~y:!y ~w:ec.w ~h:2 in
            let spec : Chart.Spec.t =
              {
                title = Say.make ~ko:"오류 분류" ~en:"Failure Classes";
                hotkey_hint = None;
                kind =
                  Chart.Spec.Stacked_bar
                    {
                      segments =
                        [
                          (Say.literal "policy", float_of_int pr, Theme.Status_attention);
                          (Say.literal "workflow", float_of_int wr, Theme.Status_active);
                          (Say.literal "dep_unavail", float_of_int du, Theme.Status_historical);
                          (Say.literal "runtime", float_of_int rf, Theme.Status_critical);
                        ];
                      total_label =
                        Say.literal
                          (Printf.sprintf "%d err" (pr + wr + du + rf + oc + uc));
                      unit = Format_val.Count;
                    };
              }
            in
            ignore
              (Chart.draw grid ~rect:bar_r ~theme ~caps:H.default_caps ~lang
                 ~show_title:false spec);
            y := !y + 3
          end;
          let items =
            [
              ("policy_rejection", pr, Theme.Status_attention);
              ("workflow_rejection", wr, Theme.Status_active);
              ("dependency_unavailable", du, Theme.Status_historical);
              ("runtime_failure", rf, Theme.Status_critical);
              ("operator_cancelled", oc, Theme.Status_historical);
              ("unclassified", uc, Theme.Status_historical);
            ]
          in
          List.iter
            (fun (lbl, cnt, tone) ->
              if !y < bot then begin
                H.put_kv ~grid ~clip:ec ~x:ec.x ~y:!y ~max_w:ec.w ~theme
                  ~key_w:22 ~key:lbl ~value_style:(H.status_style ~theme tone)
                  (Int.to_string cnt);
                incr y
              end)
            items
    end
  end

let render_tools_catalog_tree ~grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp ~(model : Model.t) =
  let lang = model.lang in
  let rt = model.runtime in
  let groups = Runtime_store.grouped_tools_catalog rt in
  let display_entries = Runtime_store.tools_catalog_display_entries rt in
  let dash_opt = Observed.to_option rt.tools_dashboard in
  let sub_s =
    match dash_opt with
    | Some d ->
        Printf.sprintf "%d reg · %d called · %d total%s" d.registered_count
          d.distinct_tools_called d.total_calls
          (match d.volume_gc_summary with Some g -> " · " ^ g | None -> "")
    | None -> Printf.sprintf "%d tools" (List.length display_entries)
  in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ~focused:(Model.body_has_focus model) ~subtitle:sub_s
         ~hotkey:
           (Say.resolve lang
              (Say.make ~ko:"[Enter] 도구 상세 · [/] 필터"
                 ~en:"[Enter] Tool Dive · [/] Filter"))
         (Say.resolve lang
            (Say.make ~ko:"도구 카탈로그 트리 (도메인 → 패밀리 → 도구)"
               ~en:"Tools Catalog Tree (Domain → Family → Tool)")))
  in
  if not (Rect.is_empty inner) then begin
    if display_entries = [] then
      H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp inner) ~theme
        ~lang ~filter_query:rt.filter_query rt.tools_dashboard
    else
      let columns : Table.column list =
        [
          {
            id = "tool";
            header = Say.make ~ko:"도구" ~en:"Tool";
            priority = 0;
            min_width = 18;
            max_width = None;
            weight = 4;
            align = Table.Left;
          };
          {
            id = "calls";
            header = Say.make ~ko:"호출" ~en:"Calls";
            priority = 0;
            min_width = 6;
            max_width = Some 9;
            weight = 1;
            align = Table.Right;
          };
          {
            id = "fail";
            header = Say.literal "Fail%";
            priority = 1;
            min_width = 6;
            max_width = Some 8;
            weight = 1;
            align = Table.Right;
          };
          {
            id = "p95";
            header = Say.literal "P95";
            priority = 1;
            min_width = 7;
            max_width = Some 10;
            weight = 1;
            align = Table.Right;
          };
          {
            id = "direct";
            header = Say.make ~ko:"직접" ~en:"Direct";
            priority = 2;
            min_width = 6;
            max_width = Some 7;
            weight = 1;
            align = Table.Center;
          };
          {
            id = "surf";
            header = Say.make ~ko:"표면" ~en:"Surfaces";
            priority = 2;
            min_width = 10;
            max_width = Some 22;
            weight = 2;
            align = Table.Left;
          };
        ]
      in
      let sel_tool_name =
        match Runtime_store.selected_tool_catalog_entry rt with
        | Some t -> Some t.name
        | None -> None
      in
      let rows_acc = ref [] in
      let selected_row_idx = ref None in
      let push r = rows_acc := r :: !rows_acc in
      List.iter
        (fun (dg : Runtime_store.tool_domain_group) ->
          push
            {
              Table.id = "dom:" ^ dg.domain;
              cells =
                [
                  ( "tool"
                  , Table.text_cell ~fg:(Color.of_rgb theme.accent)
                      ~attrs:Attr.bold
                      (Printf.sprintf "%s %s" (Glyph.to_utf8 Glyph.Expand_open)
                         (String.uppercase_ascii dg.domain)) );
                  ( "calls"
                  , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                      (Int.to_string dg.total_calls) );
                ];
            };
          List.iter
            (fun (fg : Runtime_store.tool_family_group) ->
              if List.length dg.families > 1 then
                push
                  {
                    Table.id = "fam:" ^ dg.domain ^ ":" ^ fg.family;
                    cells =
                      [
                        ( "tool"
                        , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                            ~attrs:Attr.bold
                            (Printf.sprintf "  %s %s (%d)"
                               (Glyph.to_utf8 Glyph.Tree_tee) fg.family
                               (List.length fg.tools)) );
                      ];
                  };
              List.iter
                (fun (t : Wire_runtime.tool_catalog_entry) ->
                  let row_idx = List.length !rows_acc in
                  (match sel_tool_name with
                   | Some sn when String.equal sn t.name ->
                       selected_row_idx := Some row_idx
                   | _ -> ());
                  let calls_s =
                    Format_val.format_observed Format_val.Count
                      (Observed.map float_of_int t.calls_count)
                      ~lang
                  in
                  let fail_fg =
                    match Observed.to_option t.failure_rate_pct with
                    | Some f when f >= 10.0 -> Some (Color.of_rgb theme.status_critical)
                    | Some f when f > 0.0 -> Some (Color.of_rgb theme.status_attention)
                    | Some _ | None -> Some (Color.of_rgb theme.text_muted)
                  in
                  let p95_s =
                    match t.p95_ms with
                    | Some v -> Format_val.format_value Format_val.Milliseconds v
                    | None -> Glyph.to_utf8 Glyph.Missing_absent
                  in
                  let direct_cell =
                    match t.direct_call_allowed with
                    | Some true ->
                        Table.Badge
                          { glyph = None; text = "yes"; tone = Theme.Status_ok }
                    | Some false ->
                        Table.Badge
                          { glyph = None; text = "no"; tone = Theme.Status_historical }
                    | None ->
                        Table.text_cell ~fg:(Color.of_rgb theme.text_muted) "—"
                  in
                  let surf_s =
                    if t.surfaces = [] then "—"
                    else String.concat "," (H.safe_take 3 t.surfaces)
                  in
                  push
                    {
                      Table.id = "tool:" ^ t.name;
                      cells =
                        [
                          ("tool", Table.text_cell ("    " ^ t.name));
                          ("calls", Table.text_cell calls_s);
                          ( "fail"
                          , Table.text_cell ?fg:fail_fg
                              (Format_val.format_observed Format_val.Percent
                                 t.failure_rate_pct ~lang) );
                          ("p95", Table.text_cell p95_s);
                          ("direct", direct_cell);
                          ( "surf"
                          , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                              surf_s );
                        ];
                    })
                fg.tools)
            dg.families)
        groups;
      let rows = List.rev !rows_acc in
      ignore
        (Table.draw grid ~rect:inner ~theme ~caps:H.default_caps ~lang
           ~col_gap:(Layout.table_col_gap bp)
           ~scroll:rt.tools_catalog_scroll_offset ?selected:!selected_row_idx
           ~focused:(Model.body_has_focus model) ~columns rows)
  end

let render_tools_keeper_skills ~grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp ~(model : Model.t) =
  let lang = model.lang in
  let rt = model.runtime in
  let keeper_names =
    match Observed.to_option model.fleet.keepers with
    | Some ks -> List.map (fun (k : Wire_fleet.keeper_summary) -> k.name) ks
    | None -> []
  in
  let sel_keeper =
    Runtime_store.selected_tools_surface_keeper ~keeper_names rt
  in
  let left_rect, right_rect =
    if Model.is_zoomed_active model then
      (Rect.empty, rect)
    else
      Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.52
        ~top_ratio:0.50 bp rect
  in
  let k_sub =
    match sel_keeper with Some k -> "@" ^ k | None -> "—"
  in
  let left_inner =
    Card.draw ~cache grid ~rect:left_rect ~theme
      (H.card_spec ~focused:(Model.pane_focused model 0) ~subtitle:k_sub
         ~hotkey:(Say.resolve lang (Say.make ~ko:"< / > 키퍼 전환" ~en:"< / > Keeper"))
         (Say.resolve lang
            (Say.make ~ko:"키퍼 유효 도구 표면" ~en:"Effective Keeper Surface")))
  in
  let lc = H.pad_content ~bp left_inner in
  if not (Rect.is_empty lc) then begin
    let y = ref lc.y and bot = Rect.bottom lc in
    match Observed.to_option rt.tools_dashboard with
    | None ->
        H.draw_observed_placeholder ~grid ~rect:lc ~theme ~lang rt.tools_dashboard
    | Some dash -> (
        (match dash.effective_keeper_surface with
         | None ->
             H.draw_empty_notice ~grid ~rect:lc ~theme
               (Say.resolve lang
                  (Say.make ~ko:"< / > 키퍼를 선택하면 유효 도구 표면이 조회됩니다"
                     ~en:"Use < / > to select a keeper for effective tool surface"))
         | Some (Wire_runtime.Keeper_surface_unavailable { keeper_name; reason; detail }) ->
             Card.draw_left_rail ~tone:Theme.Status_attention grid ~x:lc.x ~y:!y
               ~h:(Int.min 2 (bot - !y)) ~theme;
             ignore
               (H.put_clipped ~grid ~clip:lc ~x:(lc.x + 2) ~y:!y
                  ~max_w:(Int.max 0 (lc.w - 2))
                  ~style:(H.status_style ~theme ~attrs:Attr.bold Theme.Status_attention)
                  (Printf.sprintf "@%s unavailable: %s" keeper_name reason));
             incr y;
             if !y < bot then
               ignore
                 (H.put_clipped ~grid ~clip:lc ~x:(lc.x + 2) ~y:!y
                    ~max_w:(Int.max 0 (lc.w - 2))
                    ~style:(H.whisper_style ~theme ()) detail)
         | Some
             (Wire_runtime.Keeper_surface_available
                {
                  keeper_name;
                  runtime_id;
                  tool_delivery;
                  tool_surface_bytes;
                  skill_tool_surface_bytes;
                  skill_discovery_bytes;
                  skill_body_bytes;
                  tool_surface_sha256;
                  tools;
                  skills_left_out;
                  lane_addon_conflicts;
                }) ->
             let put_kv k v =
               if !y < bot then begin
                 H.put_kv ~grid ~clip:lc ~x:lc.x ~y:!y ~max_w:lc.w ~theme
                   ~key_w:12 ~key:k v;
                 incr y
               end
             in
             put_kv "Keeper" (Printf.sprintf "@%s · %s" keeper_name runtime_id);
             put_kv "Delivery"
               (Printf.sprintf "%s · sha %s" tool_delivery
                  (match tool_surface_sha256 with
                   | Some s -> H.short_hash ~len:10 s
                   | None -> "—"));
             put_kv "Budgets"
               (Printf.sprintf "tools %s · sk_tools %s · disc %s · body %s"
                  (Format_val.format_value Format_val.Bytes (float_of_int tool_surface_bytes))
                  (Format_val.format_value Format_val.Bytes (float_of_int skill_tool_surface_bytes))
                  (Format_val.format_value Format_val.Bytes (float_of_int skill_discovery_bytes))
                  (Format_val.format_value Format_val.Bytes (float_of_int skill_body_bytes)));
             if skills_left_out <> [] && !y < bot then begin
               Card.draw_left_rail ~tone:Theme.Status_attention grid ~x:lc.x
                 ~y:!y ~h:1 ~theme;
               ignore
                 (H.put_clipped ~grid ~clip:lc ~x:(lc.x + 2) ~y:!y
                    ~max_w:(Int.max 0 (lc.w - 2))
                    ~style:(H.status_style ~theme Theme.Status_attention)
                    ("Left out: " ^ String.concat ", " skills_left_out));
               incr y
             end;
             if lane_addon_conflicts <> [] && !y < bot then begin
               Card.draw_left_rail ~tone:Theme.Status_critical grid ~x:lc.x ~y:!y
                 ~h:1 ~theme;
               ignore
                 (H.put_clipped ~grid ~clip:lc ~x:(lc.x + 2) ~y:!y
                    ~max_w:(Int.max 0 (lc.w - 2))
                    ~style:(H.status_style ~theme Theme.Status_critical)
                    ("Conflicts: " ^ String.concat ", " lane_addon_conflicts));
               incr y
             end;
             (match (dash.volume_gc_summary, dash.keeper_cleanup_summary) with
              | Some g, Some c when !y < bot ->
                  put_kv "Maintenance" (g ^ " · " ^ c)
              | Some g, None when !y < bot -> put_kv "Volume GC" g
              | None, Some c when !y < bot -> put_kv "Cleanup" c
              | _ -> ());
             if lc.h >= 8 && !y < bot then incr y;
             if !y < bot then begin
               H.draw_divider ~grid ~rect:lc ~y:!y ~theme
                 ~label:(Printf.sprintf "Effective Tools (%d)" (List.length tools))
                 ();
               incr y
             end;
             let skip =
               Int.min
                 (Int.max 0 (List.length tools - Int.max 1 (bot - !y)))
                 (Int.max 0 rt.scroll_offset)
             in
             let tx = if lc.w >= 28 then lc.x + 2 else lc.x in
             let tw = Rect.right lc - tx in
             List.iter
               (fun (et : Wire_runtime.effective_keeper_tool_entry) ->
                 if !y < bot then begin
                   let ow = Grapheme.display_width et.origin in
                   ignore
                     (H.put_clipped ~grid ~clip:lc ~x:tx ~y:!y
                        ~max_w:(Int.max 8 (tw - ow - 2))
                        ~style:(H.text_style ~theme ()) et.name);
                   ignore
                     (H.put_right ~grid ~clip:lc ~right_x:(Rect.right lc) ~y:!y
                        ~max_w:ow ~style:(H.whisper_style ~theme ()) et.origin);
                   incr y
                 end)
               (Store_scroll.drop skip tools))
    )
  end;
  let right_inner =
    Card.draw ~cache grid ~rect:right_rect ~theme
      (H.card_spec ~focused:(Model.detail_pane_focused ~detail_index:1 model)
         ~hotkey:
           (Say.resolve lang
              (Say.make
                 ~ko:"[Enter] 열람 · [n] 생성 · [e] 편집 · [x] 삭제 · [R] 갱신"
                 ~en:"[Enter] Read · [n] New · [e] Edit · [x] Del · [R] Refresh"))
         (Say.resolve lang
            (Say.make ~ko:"스킬 프로파일 · 그림자 · 거절"
               ~en:"Skills Profiles, Shadows & Rejections")))
  in
  let rc = H.pad_content ~bp right_inner in
  if not (Rect.is_empty rc) then begin
    match rt.skills with
    | Observed.Value { data = sk; _ } ->
        let filtered_sf = Runtime_store.filtered_skill_surfaces rt in
        let y = ref rc.y and bot = Rect.bottom rc in
        if !y < bot then begin
          let rev_s =
            match sk.snapshot_revision with Some r -> " · rev " ^ r | None -> ""
          in
          ignore
            (H.put_clipped ~grid ~clip:rc ~x:rc.x ~y:!y ~max_w:rc.w
               ~style:(H.anchor_style ~theme ())
               (Printf.sprintf "State: %s%s · %d skills · %d shadows · %d rejected"
                  sk.state rev_s (List.length filtered_sf)
                  (List.length sk.shadows) (List.length sk.rejections)));
          incr y
        end;
        if sk.rejections <> [] && !y < bot then begin
          Card.draw_left_rail ~tone:Theme.Status_critical grid ~x:rc.x ~y:!y
            ~h:1 ~theme;
          ignore
            (H.put_clipped ~grid ~clip:rc ~x:(rc.x + 2) ~y:!y
               ~max_w:(Int.max 0 (rc.w - 2))
               ~style:(H.status_style ~theme Theme.Status_critical)
               ("Rejected: "
                ^ H.redact_secrets_in_text
                    (String.concat "; " (H.safe_take 3 sk.rejections))));
          incr y
        end;
        if sk.shadows <> [] && !y < bot then begin
          Card.draw_left_rail ~tone:Theme.Status_attention grid ~x:rc.x ~y:!y
            ~h:1 ~theme;
          ignore
            (H.put_clipped ~grid ~clip:rc ~x:(rc.x + 2) ~y:!y
               ~max_w:(Int.max 0 (rc.w - 2))
               ~style:(H.status_style ~theme Theme.Status_attention)
               ("Shadowed: " ^ String.concat ", " (H.safe_take 4 sk.shadows)));
          incr y
        end;
        if rc.h >= 8 && !y < bot then incr y;
        if !y < bot then begin
          H.draw_divider ~grid ~rect:rc ~y:!y ~theme
            ~label:(Say.resolve lang (Say.make ~ko:"스킬 목록" ~en:"Skill Surfaces"))
            ();
          incr y
        end;
        let sel_idx =
          Int.max 0 (Int.min (List.length filtered_sf - 1) rt.skill_selected_index)
        in
        let skip =
          Int.min
            (Int.max 0 (List.length filtered_sf - Int.max 1 (bot - !y)))
            (Int.max 0 rt.skill_scroll_offset)
        in
        let pane1_focused =
          Model.detail_pane_focused ~detail_index:1 model
        in
        List.iteri
          (fun rel_i (sf : Wire_runtime.skill_surface_entry) ->
            let abs_i = skip + rel_i in
            if !y < bot then begin
              let is_sel = Int.equal abs_i sel_idx in
              let kind_tone =
                match Wire_runtime.classify_skill_surface_kind sf.kind with
                | Wire_runtime.Skill_composition -> Theme.Status_ai
                | Wire_runtime.Skill_instruction -> Theme.Status_ok
                | Wire_runtime.Skill_kind_other _ -> Theme.Status_attention
              in
              let prefix =
                if is_sel && pane1_focused then "▸ "
                else if is_sel then "· "
                else "  "
              in
              let tag = Printf.sprintf "%s[%s] " prefix sf.kind in
              let adv =
                H.put_clipped ~grid ~clip:rc ~x:rc.x ~y:!y ~max_w:17
                  ~style:(H.status_style ~theme ~attrs:Attr.bold kind_tone) tag
              in
              let extra =
                match (sf.error, sf.summary) with
                | Some e, _ -> " · err: " ^ H.redact_secrets_in_text e
                | None, Some s ->
                    " · " ^ H.redact_secrets_in_text (H.sanitize_single_line s)
                | None, None -> ""
              in
              let row_style =
                if is_sel && pane1_focused then
                  H.accent_style ~theme ~attrs:Attr.bold ()
                else H.text_style ~theme ()
              in
              ignore
                (H.put_clipped ~grid ~clip:rc ~x:(rc.x + adv) ~y:!y
                   ~max_w:(Int.max 0 (rc.w - adv))
                   ~style:row_style (sf.reference ^ extra));
              incr y
            end)
          (Store_scroll.drop skip filtered_sf)
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        H.draw_observed_placeholder ~grid ~rect:rc ~theme ~lang obs
  end

let render_tools_usage ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let rt = model.runtime in
  let bar_rect, body_rect =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ a; b ] -> (a, b)
    | _ -> (Rect.empty, rect)
  in
  let pills =
    [
      {
        H.label = Say.resolve lang (Say.make ~ko:"사용량 추이" ~en:"Usage Calls");
        active =
          Runtime_store.equal_tools_subview rt.tools_subview
            Runtime_store.Tools_usage_calls;
        tone = Some Theme.Status_active;
        glyph = Some Glyph.Live_healthy;
      };
      {
        H.label = Say.resolve lang (Say.make ~ko:"카탈로그 트리" ~en:"Catalog Tree");
        active =
          Runtime_store.equal_tools_subview rt.tools_subview
            Runtime_store.Tools_catalog_tree;
        tone = Some Theme.Status_ok;
        glyph = None;
      };
      {
        H.label =
          Say.resolve lang
            (Say.make ~ko:"키퍼 표면 · 스킬" ~en:"Keeper Surface & Skills");
        active =
          Runtime_store.equal_tools_subview rt.tools_subview
            Runtime_store.Tools_keeper_skills;
        tone = Some Theme.Status_ai;
        glyph = None;
      };
      {
        H.label =
          Say.resolve lang
            (Say.make ~ko:"품질 · 게이트 · 대기" ~en:"Quality · Gate · Waiting");
        active =
          Runtime_store.equal_tools_subview rt.tools_subview
            Runtime_store.Tools_quality_gate;
        tone = Some Theme.Status_attention;
        glyph = None;
      };
      {
        H.label =
          Say.resolve lang
            (Say.make ~ko:"프롬프트 · 프리셋 · 파라미터"
               ~en:"Prompts · Presets · Params");
        active =
          Runtime_store.equal_tools_subview rt.tools_subview
            Runtime_store.Tools_prompts_presets;
        tone = Some Theme.Status_ai;
        glyph = None;
      };
    ]
  in
  ignore
    (H.draw_pills ~grid ~rect:bar_rect ~theme
       ~right_hint:
         (Say.resolve lang
            (Say.make ~ko:"[v] 하위뷰 · [w] 기간 · < / > 키퍼 · /exec"
               ~en:"[v] View · [w] Window · < / > Keeper · /exec"))
       pills);
  match rt.tools_subview with
  | Runtime_store.Tools_usage_calls -> (
      match (Observed.to_option rt.tool_series_summary, Observed.to_option rt.tool_series) with
      | Some s, _ ->
          draw_tool_series_analytics ~table_focused:(Model.body_has_focus model)
            ~grid ~cache ~rect:body_rect ~theme ~bp ~model ~series:s.series
            ~summary:(Some s) ~show_err_classes:true
      | None, Some series ->
          draw_tool_series_analytics ~table_focused:(Model.body_has_focus model)
            ~grid ~cache ~rect:body_rect ~theme ~bp ~model ~series ~summary:None
            ~show_err_classes:true
      | None, None ->
          let inner =
            Card.draw ~cache grid ~rect:body_rect ~theme
              (H.card_spec
                 (Say.resolve lang (Say.make ~ko:"도구 사용량" ~en:"Tool Usage")))
          in
          H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp inner)
            ~theme ~lang rt.tool_series)
  | Runtime_store.Tools_catalog_tree ->
      render_tools_catalog_tree ~grid ~cache ~rect:body_rect ~theme ~bp ~model
  | Runtime_store.Tools_keeper_skills ->
      render_tools_keeper_skills ~grid ~cache ~rect:body_rect ~theme ~bp ~model
  | Runtime_store.Tools_quality_gate ->
      let left_rect, right_rect =
        if Model.is_zoomed_active model then
          (Rect.empty, body_rect)
        else
          Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.52
            ~top_ratio:0.50 bp body_rect
      in
      let left_inner =
        Card.draw ~cache grid ~rect:left_rect ~theme
          (H.card_spec ~focused:(Model.pane_focused model 0)
             ~hotkey:
               (Say.resolve lang
                  (Say.make ~ko:"[j/k] 스크롤 · [r] 새로고침"
                     ~en:"[j/k] Scroll · [r] Refresh"))
             (Say.resolve lang
                (Say.make ~ko:"도구 호출 품질 (Tool Quality)"
                   ~en:"Tool Call Quality")))
      in
      let lc = H.pad_content ~bp left_inner in
      if not (Rect.is_empty lc) then begin
        match Observed.to_option rt.tool_quality with
        | None ->
            H.draw_observed_placeholder ~grid ~rect:lc ~theme ~lang
              rt.tool_quality
        | Some tq ->
            let plain s = (Update_nav.Line_plain, s) in
            let sec s = (Update_nav.Line_section, s) in
            let lines =
              [
                plain
                  (Printf.sprintf
                     "Total=%d · OK=%d (%.1f%%) · Fail=%d · Deferred=%d · Unsettled=%d · Malformed=%d"
                     tq.total tq.success tq.success_rate tq.failure tq.deferred
                     tq.unsettled tq.malformed);
                plain
                  (Printf.sprintf "Sample=%s · Updated=%s" tq.sampling_mode
                     tq.generated_at);
                plain "";
                sec
                  (Say.resolve lang
                     (Say.make
                        ~ko:"── 상위 도구 (호출수 · 성공률 · 평균ms · 절단)"
                        ~en:"── Top Tools (calls · ok% · avg_ms · trunc)"));
              ]
              @ List.map
                  (fun (r : Wire_runtime.tool_quality_tool_row) ->
                    plain
                      (Printf.sprintf "  %-28s %5d  %5.1f%%  %6.0fms  trunc=%d"
                         r.name r.calls r.success_pct r.avg_ms
                         r.output_truncated_count))
                  (H.safe_take 20 tq.by_tool)
              @ (if tq.failure_categories = [] then []
                 else
                   plain ""
                   :: sec
                        (Say.resolve lang
                           (Say.make ~ko:"── 실패 범주 (Failure Categories)"
                              ~en:"── Failure Categories"))
                   :: List.map
                        (fun (fc : Wire_runtime.tool_quality_failure_cat) ->
                          plain
                            (Printf.sprintf "  [%4d] %s" fc.count
                               (H.redact_secrets_in_text fc.category)))
                        (H.safe_take 12 tq.failure_categories))
              @ (if tq.by_keeper = [] then []
                 else
                   plain ""
                   :: sec
                        (Say.resolve lang
                           (Say.make ~ko:"── 키퍼별 성공률" ~en:"── By Keeper"))
                   :: List.map
                        (fun (rk : Wire_runtime.tool_quality_rate_row) ->
                          plain
                            (Printf.sprintf "  @%-22s %5d  %5.1f%%" rk.name
                               rk.calls rk.success_pct))
                        (H.safe_take 10 tq.by_keeper))
            in
            let skip =
              Int.max 0
                (Int.min (Int.max 0 (List.length lines - lc.h)) rt.scroll_offset)
            in
            let bg = Color.of_rgb theme.surface_1 in
            let st_primary = Typography.primary ~bg theme in
            List.iteri
              (fun idx (tone, line) ->
                if idx >= skip && idx - skip < lc.h then
                  let py = lc.y + idx - skip in
                  match tone with
                  | Update_nav.Line_section ->
                      let lbl =
                        Option.value (Card.legacy_rule_label line)
                          ~default:(String.trim line)
                      in
                      Card.draw_hairline ~pad_x:0 ~bg ~label:lbl grid ~rect:lc
                        ~y:py ~theme
                  | Update_nav.Line_accent ->
                      ignore
                        (Cell_grid.put_text ~clip:lc grid ~x:lc.x ~y:py
                           ~style:(Typography.accent ~bg theme)
                           (Grapheme.truncate_to_width ~max_width:lc.w line))
                  | Update_nav.Line_plain
                  | Update_nav.Line_selected
                  | Update_nav.Line_ok
                  | Update_nav.Line_warn
                  | Update_nav.Line_error ->
                      ignore
                        (Cell_grid.put_text ~clip:lc grid ~x:lc.x ~y:py
                           ~style:st_primary
                           (Grapheme.truncate_to_width ~max_width:lc.w line)))
              lines
      end;
      let keeper_names =
        match Observed.to_option model.fleet.keepers with
        | Some ks ->
            List.map (fun (k : Wire_fleet.keeper_summary) -> k.name) ks
        | None -> []
      in
      let sel_keeper =
        Runtime_store.selected_tools_surface_keeper ~keeper_names rt
      in
      let right_sub =
        match sel_keeper with Some k -> Some ("@" ^ k) | None -> None
      in
      let right_inner =
        Card.draw ~cache grid ~rect:right_rect ~theme
          (H.card_spec ?subtitle:right_sub
             ~focused:(Model.detail_pane_focused ~detail_index:1 model)
             ~hotkey:
               (Say.resolve lang
                  (Say.make ~ko:"< / > 키퍼 · [j/k] 스크롤"
                     ~en:"< / > Keeper · [j/k] Scroll"))
             (Say.resolve lang
                (Say.make ~ko:"게이트 거부 · 키퍼 대기 인벤토리"
                   ~en:"Gate Rejections · Keeper Waiting")))
      in
      let rc = H.pad_content ~bp right_inner in
      if not (Rect.is_empty rc) then begin
        let plain s = (Update_nav.Line_plain, s) in
        let sec s = (Update_nav.Line_section, s) in
        let gate_lines =
          match rt.gate_tool_events with
          | Observed.Loading _ ->
              [
                plain
                  (Say.resolve lang
                     (Say.make ~ko:"게이트 도구 이벤트 불러오는 중…"
                        ~en:"Loading gate tool events…"));
              ]
          | Observed.Failed { reason; _ } ->
              [
                plain
                  (Say.resolve lang
                     (Say.make ~ko:"게이트 도구 이벤트 오류: "
                        ~en:"Gate tool events error: ")
                  ^ H.redact_secrets_in_text reason);
              ]
          | Observed.Absent ->
              [
                plain
                  (Say.resolve lang
                     (Say.make ~ko:"게이트 도구 이벤트 엔드포인트 없음 (404)"
                        ~en:"Gate tool events endpoint absent (404)"));
              ]
          | Observed.Unreported ->
              [
                plain
                  (Say.resolve lang
                     (Say.make ~ko:"게이트 도구 이벤트: 미보고"
                        ~en:"Gate tool events: unreported"));
              ]
          | Observed.Value { data = ev; _ } ->
              let q_line =
                match (ev.queue_summary, ev.queue_error) with
                | Some qs, _ ->
                    let fmt_opt = function
                      | Some v -> Printf.sprintf "%.1fs" v
                      | None -> "—"
                    in
                    Printf.sprintf
                      "Queue depth=%d · p50=%s · p95=%s · oldest=%s (win=%dm)"
                      qs.depth (fmt_opt qs.p50_wait_sec)
                      (fmt_opt qs.p95_wait_sec)
                      (fmt_opt qs.oldest_pending_sec) ev.window_minutes
                | None, Some err ->
                    "Queue unavailable: " ^ H.redact_secrets_in_text err
                | None, None ->
                    Printf.sprintf "Queue: unreported (win=%dm)"
                      ev.window_minutes
              in
              plain q_line
              :: (if ev.tool_rejections = [] then
                    [
                      plain
                        (Say.resolve lang
                           (Say.make ~ko:"  최근 거부된 도구 호출 없음"
                              ~en:"  No recent tool rejections"));
                    ]
                  else
                    sec
                      (Say.resolve lang
                         (Say.make ~ko:"── 도구 거부 상위"
                            ~en:"── Top Tool Rejections"))
                    :: List.map
                         (fun (r : Wire_work.gate_tool_rejection_row) ->
                           plain
                             (Printf.sprintf "  [%3d] %s · %s" r.count r.tool
                                (H.redact_secrets_in_text r.reason)))
                         (H.safe_take 12 ev.tool_rejections))
        in
        let wait_lines =
          match sel_keeper with
          | None -> []
          | Some keeper -> (
              plain ""
              :: sec
                   (Say.resolve lang
                      (Say.make
                         ~ko:("── 대기 인벤토리 (@" ^ keeper ^ ")")
                         ~en:("── Waiting Inventory (@" ^ keeper ^ ")")))
              ::
              match rt.keeper_waiting_inventory with
              | Observed.Value { data = k, inv; _ }
                when String.equal k keeper ->
                  let hdr =
                    let oldest_s =
                      match inv.oldest_age_seconds with
                      | Some s -> Printf.sprintf "%.0fs" s
                      | None -> "—"
                    in
                    plain
                      (Printf.sprintf
                         "  rows=%d/%d · waiting_keepers=%d · oldest=%s"
                         inv.row_count inv.total_row_count
                         inv.waiting_keeper_count oldest_s)
                  in
                  if inv.rows = [] then
                    [
                      hdr;
                      plain
                        (Say.resolve lang
                           (Say.make ~ko:"  대기 중인 항목 없음 (유휴)"
                              ~en:"  No waiting items (idle)"));
                    ]
                  else
                    hdr
                    :: List.map
                         (fun (w : Wire_runtime.keeper_waiting_row) ->
                           plain
                             (Printf.sprintf "  [%s] %s — %s (%s)" w.source
                                w.waiting_on
                                (H.redact_secrets_in_text w.what)
                                (H.redact_secrets_in_text w.next_action)))
                         (H.safe_take 20 inv.rows)
              | Observed.Loading _ ->
                  [
                    plain
                      (Say.resolve lang
                         (Say.make ~ko:"  대기 인벤토리 불러오는 중…"
                            ~en:"  Loading waiting inventory…"));
                  ]
              | Observed.Failed { reason; _ } ->
                  [
                    plain
                      (Say.resolve lang
                         (Say.make ~ko:"  대기 인벤토리 오류: "
                            ~en:"  Waiting inventory error: ")
                      ^ H.redact_secrets_in_text reason);
                  ]
              | Observed.Absent ->
                  [
                    plain
                      (Say.resolve lang
                         (Say.make ~ko:"  대기 인벤토리 미지원 (404)"
                            ~en:"  Waiting inventory absent (404)"));
                  ]
              | Observed.Value _ | Observed.Unreported ->
                  [
                    plain
                      (Say.resolve lang
                         (Say.make ~ko:"  대기 인벤토리 미보고"
                            ~en:"  Waiting inventory unreported"));
                  ])
        in
        let all_lines = gate_lines @ wait_lines in
        let skip =
          Int.max 0
            (Int.min (Int.max 0 (List.length all_lines - rc.h))
               rt.detail_scroll_offset)
        in
        let bg = Color.of_rgb theme.surface_1 in
        let st_primary = Typography.primary ~bg theme in
        List.iteri
          (fun idx (tone, line) ->
            if idx >= skip && idx - skip < rc.h then
              let py = rc.y + idx - skip in
              match tone with
              | Update_nav.Line_section ->
                  let lbl =
                    Option.value (Card.legacy_rule_label line)
                      ~default:(String.trim line)
                  in
                  Card.draw_hairline ~pad_x:0 ~bg ~label:lbl grid ~rect:rc
                    ~y:py ~theme
              | Update_nav.Line_accent ->
                  ignore
                    (Cell_grid.put_text ~clip:rc grid ~x:rc.x ~y:py
                       ~style:(Typography.accent ~bg theme)
                       (Grapheme.truncate_to_width ~max_width:rc.w line))
              | Update_nav.Line_plain
              | Update_nav.Line_selected
              | Update_nav.Line_ok
              | Update_nav.Line_warn
              | Update_nav.Line_error ->
                  ignore
                    (Cell_grid.put_text ~clip:rc grid ~x:rc.x ~y:py
                       ~style:st_primary
                       (Grapheme.truncate_to_width ~max_width:rc.w line)))
          all_lines
      end
  | Runtime_store.Tools_prompts_presets ->
      let left_rect, right_rect =
        if Model.is_zoomed_active model then
          (Rect.empty, body_rect)
        else
          Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.46
            ~top_ratio:0.48 bp body_rect
      in
      let sec_title =
        match rt.pp_section with
        | Runtime_store.Sec_prompts ->
            Say.resolve lang (Say.make ~ko:"프롬프트 레지스트리" ~en:"Prompts Registry")
        | Runtime_store.Sec_presets ->
            Say.resolve lang (Say.make ~ko:"프롬프트 프리셋" ~en:"Prompt Presets")
        | Runtime_store.Sec_params ->
            Say.resolve lang (Say.make ~ko:"런타임 파라미터" ~en:"Runtime Params")
        | Runtime_store.Sec_async_requests ->
            Say.resolve lang (Say.make ~ko:"비동기 요청 브로커" ~en:"Async Requests")
      in
      let left_hotkey =
        match rt.pp_section with
        | Runtime_store.Sec_prompts ->
            Say.resolve lang
              (Say.make ~ko:"< / > 섹션 · [e] 오버라이드 · [x] 해제"
                 ~en:"< / > Section · [e] Override · [x] Clear")
        | Runtime_store.Sec_presets ->
            Say.resolve lang
              (Say.make ~ko:"< / > 섹션 · [n] 생성 · [a] 복원 · [x] 삭제"
                 ~en:"< / > Section · [n] New · [a] Restore · [x] Del")
        | Runtime_store.Sec_params ->
            Say.resolve lang
              (Say.make ~ko:"< / > 섹션 · [e] 설정 · [x] 기본값"
                 ~en:"< / > Section · [e] Set · [x] Clear")
        | Runtime_store.Sec_async_requests ->
            Say.resolve lang
              (Say.make ~ko:"< / > 섹션 · [r] 새로고침"
                 ~en:"< / > Section · [r] Refresh")
      in
      let left_inner =
        Card.draw ~cache grid ~rect:left_rect ~theme
          (H.card_spec ~focused:(Model.pane_focused model 0)
             ~hotkey:left_hotkey sec_title)
      in
      let lc = H.pad_content ~bp left_inner in
      if not (Rect.is_empty lc) then begin
        let sec_bar, list_r =
          match Layout.split_v lc [ Layout.Fixed 1; Layout.Flex 1 ] with
          | [ a; b ] -> (a, b)
          | _ -> (Rect.empty, lc)
        in
        let sec_pills =
          [
            {
              H.label = Say.resolve lang (Say.make ~ko:"프롬프트" ~en:"Prompts");
              active =
                Runtime_store.equal_prompts_presets_section rt.pp_section
                  Runtime_store.Sec_prompts;
              tone = Some Theme.Status_active;
              glyph = None;
            };
            {
              H.label = Say.resolve lang (Say.make ~ko:"프리셋" ~en:"Presets");
              active =
                Runtime_store.equal_prompts_presets_section rt.pp_section
                  Runtime_store.Sec_presets;
              tone = Some Theme.Status_ai;
              glyph = None;
            };
            {
              H.label = Say.resolve lang (Say.make ~ko:"파라미터" ~en:"Params");
              active =
                Runtime_store.equal_prompts_presets_section rt.pp_section
                  Runtime_store.Sec_params;
              tone = Some Theme.Status_ok;
              glyph = None;
            };
            {
              H.label = Say.resolve lang (Say.make ~ko:"비동기" ~en:"Async");
              active =
                Runtime_store.equal_prompts_presets_section rt.pp_section
                  Runtime_store.Sec_async_requests;
              tone = Some Theme.Status_attention;
              glyph = None;
            };
          ]
        in
        ignore (H.draw_pills ~grid ~rect:sec_bar ~theme sec_pills);
        let bg = Color.of_rgb theme.surface_1 in
        let pane0_focused = Model.pane_focused model 0 in
        let draw_list_rows rows =
          if rows = [] then
            ignore
              (H.put_clipped ~grid ~clip:list_r ~x:list_r.x ~y:list_r.y
                 ~max_w:list_r.w ~style:(Typography.whisper ~bg theme)
                 (Say.resolve lang (Say.make ~ko:"항목 없음" ~en:"No entries")))
          else
            let sel = Int.max 0 (Int.min (List.length rows - 1) rt.pp_selected_index) in
            let skip =
              Int.min
                (Int.max 0 (List.length rows - Int.max 1 list_r.h))
                (Int.max 0 rt.pp_scroll_offset)
            in
            List.iteri
              (fun rel_i (badge, text, tone_opt) ->
                let y = list_r.y + rel_i in
                if y < Rect.bottom list_r then begin
                  let abs_i = skip + rel_i in
                  let is_sel = Int.equal abs_i sel in
                  let prefix =
                    if is_sel && pane0_focused then "▸ "
                    else if is_sel then "· "
                    else "  "
                  in
                  let b_style =
                    match tone_opt with
                    | Some tone -> H.status_style ~theme ~attrs:Attr.bold tone
                    | None -> Typography.whisper ~bg theme
                  in
                  let adv =
                    H.put_clipped ~grid ~clip:list_r ~x:list_r.x ~y ~max_w:14
                      ~style:b_style (prefix ^ badge ^ " ")
                  in
                  let row_st =
                    if is_sel && pane0_focused then
                      H.accent_style ~theme ~attrs:Attr.bold ()
                    else Typography.primary ~bg theme
                  in
                  ignore
                    (H.put_clipped ~grid ~clip:list_r ~x:(list_r.x + adv) ~y
                       ~max_w:(Int.max 0 (list_r.w - adv)) ~style:row_st text)
                end)
              (Store_scroll.drop skip rows)
        in
        match rt.pp_section with
        | Runtime_store.Sec_prompts -> (
            match rt.prompts_catalog with
            | Observed.Value { data = cat; _ } ->
                let items = Runtime_store.filtered_prompts rt in
                let prompt_rows =
                  List.map
                    (fun (p : Wire_runtime.prompt_item) ->
                      let b = if p.has_override then "[OVR]" else "[DEF]" in
                      let tone =
                        if p.has_override then Some Theme.Status_attention
                        else Some Theme.Status_ok
                      in
                      (b, Printf.sprintf "%s (%dB)" p.key p.char_count, tone))
                    items
                in
                let held_rows =
                  List.map
                    (fun (h : Wire_runtime.prompt_held_back) ->
                      ( "[HELD]"
                      , Printf.sprintf "%s (%dB: %s)" h.key h.bytes
                          (H.redact_secrets_in_text h.reason)
                      , Some Theme.Status_critical ))
                    cat.held_back
                in
                draw_list_rows (prompt_rows @ held_rows)
            | ( Observed.Loading _
              | Observed.Absent
              | Observed.Unreported
              | Observed.Failed _ ) as obs ->
                H.draw_observed_placeholder ~grid ~rect:list_r ~theme ~lang obs)
        | Runtime_store.Sec_presets -> (
            match rt.presets_listing with
            | Observed.Value { data = listing; _ } ->
                let items = Runtime_store.filtered_presets rt in
                let preset_rows =
                  List.map
                    (fun (p : Wire_runtime.preset_manifest) ->
                      ( Printf.sprintf "[%d/%d]" p.override_count
                          (List.length p.keepers)
                      , p.name
                        ^ (if String.equal (String.trim p.description) "" then ""
                           else " · " ^ H.redact_secrets_in_text p.description)
                      , Some Theme.Status_ai ))
                    items
                in
                let unreadable_rows =
                  List.map
                    (fun (u : Wire_runtime.preset_unreadable) ->
                      ( "[ERR]"
                      , Printf.sprintf "%s: %s" u.name
                          (H.redact_secrets_in_text u.reason)
                      , Some Theme.Status_critical ))
                    listing.unreadable
                in
                draw_list_rows (preset_rows @ unreadable_rows)
            | ( Observed.Loading _
              | Observed.Absent
              | Observed.Unreported
              | Observed.Failed _ ) as obs ->
                H.draw_observed_placeholder ~grid ~rect:list_r ~theme ~lang obs)
        | Runtime_store.Sec_params -> (
            match rt.runtime_params with
            | Observed.Value _ ->
                let items = Runtime_store.filtered_runtime_params rt in
                draw_list_rows
                  (List.map
                     (fun (p : Wire_runtime.runtime_param_item) ->
                       let b = if p.has_override then "[SET]" else "[DEF]" in
                       let tone =
                         if p.has_override then Some Theme.Status_attention
                         else Some Theme.Status_ok
                       in
                       let val_s =
                         H.redact_secrets_in_text (Yojson.Safe.to_string p.current)
                       in
                       (b, Printf.sprintf "%s = %s" p.key val_s, tone))
                     items)
            | ( Observed.Loading _
              | Observed.Absent
              | Observed.Unreported
              | Observed.Failed _ ) as obs ->
                H.draw_observed_placeholder ~grid ~rect:list_r ~theme ~lang obs)
        | Runtime_store.Sec_async_requests -> (
            match rt.async_requests with
            | Observed.Value _ ->
                let items = Runtime_store.filtered_async_requests rt in
                draw_list_rows
                  (List.map
                     (fun (r : Wire_runtime.async_request_row) ->
                       let tone =
                         match r.ok with
                         | Some true -> Some Theme.Status_ok
                         | Some false -> Some Theme.Status_critical
                         | None -> Some Theme.Status_attention
                       in
                       ( "[" ^ r.status ^ "]"
                       , Printf.sprintf "@%s · %s" r.keeper_name r.request_id
                       , tone ))
                     items)
            | ( Observed.Loading _
              | Observed.Absent
              | Observed.Unreported
              | Observed.Failed _ ) as obs ->
                H.draw_observed_placeholder ~grid ~rect:list_r ~theme ~lang obs)
      end;
      let right_inner =
        Card.draw ~cache grid ~rect:right_rect ~theme
          (H.card_spec ~focused:(Model.detail_pane_focused ~detail_index:1 model)
             (Say.resolve lang
                (Say.make ~ko:"상세 인스펙터" ~en:"Detail Inspector")))
      in
      let rc = H.pad_content ~bp right_inner in
      if not (Rect.is_empty rc) then begin
        let plain s = (Update_nav.Line_plain, s) in
        let sec s = (Update_nav.Line_section, s) in
        let detail_lines =
          match rt.pp_section with
          | Runtime_store.Sec_prompts -> (
              match Runtime_store.selected_prompt_item rt with
              | None ->
                  [
                    plain
                      (Say.resolve lang
                         (Say.make ~ko:"선택된 프롬프트가 없습니다"
                            ~en:"No prompt selected"));
                  ]
              | Some p ->
                  let vars =
                    if p.template_variables = [] then "none"
                    else String.concat ", " p.template_variables
                  in
                  let hdr =
                    [
                      plain
                        (Printf.sprintf "Key: %s · Source: %s%s" p.key p.source
                           (if p.override_default_moved then " [DEFAULT MOVED]"
                            else ""));
                      plain
                        (Printf.sprintf "Category: %s · Surface: %s · Vars: %s"
                           p.category p.operator_surface vars);
                      plain ("Description: " ^ H.redact_secrets_in_text p.description);
                      sec "── Effective Prompt Body";
                    ]
                  in
                  hdr
                  @ List.map plain
                      (String.split_on_char '\n'
                         (H.redact_secrets_in_text p.effective)))
          | Runtime_store.Sec_presets -> (
              match Runtime_store.selected_preset_manifest rt with
              | None ->
                  [
                    plain
                      (Say.resolve lang
                         (Say.make ~ko:"선택된 프리셋이 없습니다 ([n]으로 생성)"
                            ~en:"No preset selected (press [n] to create)"));
                  ]
              | Some pm ->
                  let base =
                    [
                      plain (Printf.sprintf "Preset: %s (%s)" pm.name pm.created_at);
                      plain ("Description: " ^ H.redact_secrets_in_text pm.description);
                      plain
                        (Printf.sprintf
                           "Overrides: %d · Keepers: %d · Assignments: %d · Lanes: %d"
                           pm.override_count (List.length pm.keepers)
                           pm.assignment_count pm.lane_count);
                    ]
                  in
                  let extra =
                    match Runtime_store.preset_detail_for ~name:pm.name rt with
                    | None -> (
                        match rt.preset_detail with
                        | Observed.Loading _ ->
                            [
                              plain "";
                              plain
                                (Say.resolve lang
                                   (Say.make ~ko:"프리셋 상세 불러오는 중…"
                                      ~en:"Loading preset detail…"));
                            ]
                        | Observed.Failed { reason; _ } ->
                            [
                              plain "";
                              plain
                                (Say.resolve lang
                                   (Say.make
                                      ~ko:("프리셋 상세 조회 실패: " ^ H.redact_secrets_in_text reason)
                                      ~en:("Preset detail failed: " ^ H.redact_secrets_in_text reason)));
                            ]
                        | Observed.Value _
                        | Observed.Absent
                        | Observed.Unreported ->
                            [
                              plain "";
                              plain
                                (Say.resolve lang
                                   (Say.make ~ko:"[Enter]를 눌러 상세 diff 로드"
                                      ~en:"Press [Enter] to load full preset diff"));
                            ])
                    | Some d ->
                        [
                          sec "── Saved Settings & Default Comparison";
                          plain
                            (Printf.sprintf "  saved_settings: %s%s"
                               d.saved_settings_status
                               (match d.saved_settings_reason with
                               | Some r -> " (" ^ H.redact_secrets_in_text r ^ ")"
                               | None -> ""));
                          plain
                            (Printf.sprintf "  default_prompts: %s (%d changes)"
                               d.default_prompts_status
                               d.default_prompts_changes_count);
                          plain ("  directory: " ^ d.directory);
                          sec
                            ("── Prompt Overrides: "
                            ^ (if d.override_keys = [] then "none"
                               else String.concat ", " d.override_keys));
                          sec
                            ("── Keeper Instructions: "
                            ^ (if d.keeper_files = [] then "none"
                               else String.concat ", " d.keeper_files));
                          sec
                            ("── Exact Lanes: "
                            ^ (if d.lane_ids = [] then "none"
                               else String.concat ", " d.lane_ids));
                        ]
                        @ List.map
                            (fun (k, r) ->
                              plain (Printf.sprintf "  assign @%s -> %s" k r))
                            (H.safe_take 12 d.assignments)
                  in
                  base @ extra)
          | Runtime_store.Sec_params -> (
              match Runtime_store.selected_runtime_param rt with
              | None ->
                  [
                    plain
                      (Say.resolve lang
                         (Say.make ~ko:"선택된 파라미터가 없습니다"
                            ~en:"No runtime parameter selected"));
                  ]
              | Some p ->
                  [
                    plain
                      (Printf.sprintf "Param: %s (%s)" p.key
                         (if p.has_override then "overridden" else "default"));
                    plain
                      ("Current: "
                      ^ H.redact_secrets_in_text (Yojson.Safe.to_string p.current));
                    plain
                      ("Default: "
                      ^ H.redact_secrets_in_text (Yojson.Safe.to_string p.default));
                    plain ("Type: " ^ Option.value p.value_type ~default:"unknown");
                    plain
                      ("Choices: "
                      ^ (if p.choices = [] then "free-form"
                         else String.concat ", " p.choices));
                    plain
                      ("Description: "
                      ^ H.redact_secrets_in_text
                          (Option.value p.description ~default:"—"));
                  ])
          | Runtime_store.Sec_async_requests -> (
              let summary_hdr =
                match Observed.to_option rt.async_requests with
                | Some snap ->
                    [
                      plain
                        (Printf.sprintf
                           "Broker: %s · active=%d · runtime_owned=%d · unknown=%d · errors=%d"
                           snap.status snap.active snap.runtime_owned
                           snap.ownership_unknown snap.record_errors_count);
                    ]
                    @ (match snap.error_detail with
                      | Some e -> [ plain ("Error: " ^ H.redact_secrets_in_text e) ]
                      | None -> [])
                | None -> []
              in
              let sel_lines =
                match Runtime_store.selected_async_request rt with
                | None ->
                    [
                      plain
                        (Say.resolve lang
                           (Say.make ~ko:"활성 비동기 요청 없음"
                              ~en:"No active async requests"));
                    ]
                | Some r ->
                    [
                      sec "── Request Detail";
                      plain ("Request ID: " ^ r.request_id);
                      plain
                        (Printf.sprintf "Keeper: @%s · Submitted By: %s"
                           r.keeper_name r.submitted_by);
                      plain
                        (Printf.sprintf "Status: %s · Ownership: %s" r.status
                           (Option.value r.worker_ownership ~default:"—"));
                      plain
                        (Printf.sprintf "Elapsed: %s · Ok: %s"
                           (match r.elapsed_sec with
                           | Some s -> Printf.sprintf "%.1fs" s
                           | None -> "—")
                           (match r.ok with
                           | Some true -> "true"
                           | Some false -> "false"
                           | None -> "pending"));
                    ]
                    @ (match r.result_preview with
                      | Some pv ->
                          sec "── Result Preview"
                          :: List.map plain
                               (String.split_on_char '\n'
                                  (H.redact_secrets_in_text pv))
                      | None -> [])
              in
              summary_hdr @ sel_lines)
        in
        let skip =
          Int.max 0
            (Int.min
               (Int.max 0 (List.length detail_lines - rc.h))
               rt.detail_scroll_offset)
        in
        let bg = Color.of_rgb theme.surface_1 in
        let st_primary = Typography.primary ~bg theme in
        List.iteri
          (fun idx (tone, line) ->
            if idx >= skip && idx - skip < rc.h then
              let py = rc.y + idx - skip in
              match tone with
              | Update_nav.Line_section ->
                  let lbl =
                    Option.value (Card.legacy_rule_label line)
                      ~default:(String.trim line)
                  in
                  Card.draw_hairline ~pad_x:0 ~bg ~label:lbl grid ~rect:rc
                    ~y:py ~theme
              | Update_nav.Line_accent ->
                  ignore
                    (Cell_grid.put_text ~clip:rc grid ~x:rc.x ~y:py
                       ~style:(Typography.accent ~bg theme)
                       (Grapheme.truncate_to_width ~max_width:rc.w line))
              | Update_nav.Line_plain
              | Update_nav.Line_selected
              | Update_nav.Line_ok
              | Update_nav.Line_warn
              | Update_nav.Line_error ->
                  ignore
                    (Cell_grid.put_text ~clip:rc grid ~x:rc.x ~y:py
                       ~style:st_primary
                       (Grapheme.truncate_to_width ~max_width:rc.w line)))
          detail_lines
      end

(* --- 6. Sub-Tab 6: Connectors & MCP Clients (Dedicated 2-Pane Screen) --- *)

let connector_status_display ~lang = function
  | Wire_runtime.Connector_connected ->
      ( Glyph.Live_healthy
      , Theme.Status_ok
      , Say.resolve lang (Say.make ~ko:"연결됨" ~en:"Connected") )
  | Wire_runtime.Connector_connected_unavailable ->
      ( Glyph.Warning_triangle
      , Theme.Status_attention
      , Say.resolve lang (Say.make ~ko:"응답 불가" ~en:"Unavailable") )
  | Wire_runtime.Connector_disconnected ->
      ( Glyph.Live_idle
      , Theme.Status_historical
      , Say.resolve lang (Say.make ~ko:"연결 해제" ~en:"Disconnected") )
  | Wire_runtime.Connector_offline ->
      ( Glyph.Live_failing
      , Theme.Status_critical
      , Say.resolve lang (Say.make ~ko:"오프라인" ~en:"Offline") )
  | Wire_runtime.Connector_stale ->
      ( Glyph.Transport_stale
      , Theme.Status_attention
      , Say.resolve lang (Say.make ~ko:"오래됨" ~en:"Stale") )

let render_connectors ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let rt = model.runtime in
  let left_rect, right_rect =
    Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.50
      ~top_ratio:0.52 bp rect
  in
  let sel_conn_names_sub =
    match Runtime_store.selected_connector rt with
    | Some c -> (
        match
          Runtime_store.connector_channel_names ~connector_id:c.connector_id rt
        with
        | [] -> None
        | ns ->
            let preview =
              ns |> H.safe_take 3
              |> List.map (fun (m : Wire_runtime.connector_name_mapping) ->
                     "#" ^ m.name)
              |> String.concat ", "
            in
            Some
              (Printf.sprintf "%d named: %s" (List.length ns) preview))
    | None -> None
  in
  let left_inner =
    Card.draw ~cache grid ~rect:left_rect ~theme
      (H.card_spec ?subtitle:sel_conn_names_sub ~focused:(Model.pane_focused model 0)
         ~hotkey:
           (Say.resolve lang
              (Say.make
                 ~ko:"[n] 바인드 ([←→] 이름) · [U] 언바인드 · [e] 설정 · [r] 새로고침"
                 ~en:"[n] Bind ([←→] names) · [U] Unbind · [e] Settings · [r] Refresh"))
         (Say.resolve lang
            (Say.make ~ko:"채널 게이트 커넥터" ~en:"Channel Gate Connectors")))
  in
  if not (Rect.is_empty left_inner) then begin
    let cs = Runtime_store.filtered_connectors rt in
    match rt.connectors with
    | Observed.Value _ when cs <> [] ->
        let columns : Table.column list =
          [
            {
              id = "st";
              header = Say.make ~ko:"상태" ~en:"Status";
              priority = 0;
              min_width = 9;
              max_width = Some 14;
              weight = 2;
              align = Table.Left;
            };
            {
              id = "name";
              header = Say.make ~ko:"커넥터" ~en:"Connector";
              priority = 0;
              min_width = 12;
              max_width = None;
              weight = 3;
              align = Table.Left;
            };
            {
              id = "ch";
              header = Say.make ~ko:"채널" ~en:"Channel";
              priority = 1;
              min_width = 8;
              max_width = Some 20;
              weight = 2;
              align = Table.Left;
            };
            {
              id = "bind";
              header = Say.make ~ko:"바인딩" ~en:"Binds";
              priority = 1;
              min_width = 5;
              max_width = Some 7;
              weight = 1;
              align = Table.Right;
            };
          ]
        in
        let rows =
          List.map
            (fun (c : Wire_runtime.connector_row) ->
              let g, tone, st = connector_status_display ~lang c.connection in
              let ch_names =
                Runtime_store.connector_channel_names
                  ~connector_id:c.connector_id rt
              in
              let ch =
                match c.channel with
                | Some s -> (
                    match
                      List.find_opt
                        (fun (m : Wire_runtime.connector_name_mapping) ->
                          String.equal m.id s)
                        ch_names
                    with
                    | Some m -> Printf.sprintf "#%s (%s)" m.name s
                    | None ->
                        if String.starts_with ~prefix:"#" s then s else "#" ^ s)
                | None -> (
                    match ch_names with
                    | [] -> Glyph.to_utf8 Glyph.Missing_absent
                    | first :: _ ->
                        Printf.sprintf "#%s (+%d)" first.name
                          (Int.max 0 (List.length ch_names - 1)))
              in
              let name_s =
                match c.error with
                | Some e -> Printf.sprintf "%s (%s)" c.display_name e
                | None -> c.display_name
              in
              {
                Table.id = c.connector_id;
                cells =
                  [
                    ("st", Table.Badge { glyph = Some g; text = st; tone });
                    ("name", Table.text_cell name_s);
                    ( "ch"
                    , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary) ch );
                    ("bind", Table.text_cell (Int.to_string c.binding_count));
                  ];
              })
            cs
        in
        let sel = H.clamp_index (List.length cs) rt.connector_selected_index in
        ignore
          (Table.draw grid ~rect:left_inner ~theme ~caps:H.default_caps ~lang
             ~col_gap:(Layout.table_col_gap bp)
             ~scroll:rt.connector_scroll_offset ~selected:sel
             ~focused:(Model.pane_focused model 0) ~columns rows)
    | Observed.Value _ ->
        H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp left_inner) ~theme
          ~hint:
            (Say.resolve lang
               (Say.make ~ko:"[n] 키로 새 채널 커넥터를 바인드하세요"
                  ~en:"Press [n] to bind a channel connector"))
          (Say.resolve lang
             (Say.make ~ko:"등록된 채널 커넥터 없음" ~en:"No channel connectors"))
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp left_inner)
          ~theme ~lang obs
  end;
  let right_inner =
    Card.draw ~cache grid ~rect:right_rect ~theme
      (H.card_spec
         ~badge:
           (H.make_badge ~glyph:Glyph.Live_idle ~tone:Theme.Status_historical
              "SNAPSHOT · [r]")
         ~focused:(Model.pane_focused model 1)
         (Say.resolve lang
            (Say.make ~ko:"MCP 클라이언트 · 브라우저 레인"
               ~en:"MCP Clients & Browser Lane")))
  in
  if not (Rect.is_empty right_inner) then begin
    let summary_h = if right_inner.h >= 8 then 3 else 0 in
    let mcp_rect =
      Rect.make ~x:right_inner.x ~y:right_inner.y ~w:right_inner.w
        ~h:(Int.max 0 (right_inner.h - summary_h))
    in
    let clients = Runtime_store.filtered_mcp_clients rt in
    (match rt.mcp_clients with
     | Observed.Value _ when clients <> [] ->
         let columns : Table.column list =
           [
             {
               id = "name";
               header = Say.make ~ko:"클라이언트" ~en:"Client";
               priority = 0;
               min_width = 12;
               max_width = None;
               weight = 3;
               align = Table.Left;
             };
             {
               id = "type";
               header = Say.make ~ko:"유형" ~en:"Type";
               priority = 1;
               min_width = 8;
               max_width = Some 14;
               weight = 1;
               align = Table.Left;
             };
             {
               id = "st";
               header = Say.make ~ko:"상태" ~en:"Status";
               priority = 0;
               min_width = 7;
               max_width = Some 10;
               weight = 1;
               align = Table.Left;
             };
             {
               id = "keeper";
               header = Say.make ~ko:"키퍼" ~en:"Keeper";
               priority = 1;
               min_width = 8;
               max_width = Some 16;
               weight = 2;
               align = Table.Left;
             };
             {
               id = "caps";
               header = Say.literal "Caps";
               priority = 2;
               min_width = 4;
               max_width = Some 6;
               weight = 1;
               align = Table.Right;
             };
           ]
         in
         let rows =
           List.map
             (fun (cl : Wire_runtime.mcp_client_row) ->
               let kp =
                 match cl.keeper_name with
                 | Some k -> "@" ^ k
                 | None -> Glyph.to_utf8 Glyph.Missing_absent
               in
               {
                 Table.id = cl.name;
                 cells =
                   [
                     ("name", Table.text_cell cl.name);
                     ( "type"
                     , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                         cl.agent_type );
                     ( "st"
                     , Table.Badge
                         {
                           glyph = Some Glyph.Live_healthy;
                           text = cl.status;
                           tone = Theme.Status_ok;
                         } );
                     ("keeper", Table.text_cell kp);
                     ( "caps"
                     , Table.text_cell
                         (Int.to_string (List.length cl.capabilities)) );
                   ];
               })
             clients
         in
         let sel =
           H.clamp_index (List.length clients) rt.mcp_client_selected_index
         in
         ignore
           (Table.draw grid ~rect:mcp_rect ~theme ~caps:H.default_caps ~lang
              ~col_gap:(Layout.table_col_gap bp)
              ~scroll:rt.mcp_client_scroll_offset ~selected:sel
              ~focused:(Model.pane_focused model 1) ~columns rows)
     | Observed.Value _ ->
         H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp mcp_rect) ~theme
           (Say.resolve lang
              (Say.make ~ko:"연결된 MCP 클라이언트 없음"
                 ~en:"No connected MCP clients"))
     | ( Observed.Loading _
       | Observed.Absent
       | Observed.Unreported
       | Observed.Failed _ ) as obs ->
         H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp mcp_rect)
           ~theme ~lang obs);
    if summary_h > 0 then begin
      let sum_r =
        Rect.make ~x:right_inner.x ~y:(right_inner.y + mcp_rect.h)
          ~w:right_inner.w ~h:summary_h
        |> H.pad_content ~bp
      in
      let y = ref sum_r.y and bot = Rect.bottom sum_r in
      if !y < bot then begin
        H.draw_divider ~grid ~rect:sum_r ~y:!y ~theme
          ~label:
            (Say.resolve lang
               (Say.make ~ko:"브라우저 · 애드온 요약"
                  ~en:"Browser & Addons Summary"))
          ();
        incr y
      end;
      (match Observed.to_option rt.browser_lane with
       | Some bl when !y < bot ->
           let g, tone =
             if bl.ok && bl.available then (Glyph.Live_healthy, Theme.Status_ok)
             else if bl.available then
               (Glyph.Warning_triangle, Theme.Status_attention)
             else (Glyph.Live_idle, Theme.Status_historical)
           in
           let line =
             Printf.sprintf "%s Browser avail=%b · clients=%d · issues=%d · auto=%b"
               (Glyph.to_utf8 g) bl.available bl.client_count bl.issue_count
               bl.automatic_browse_ok
           in
           ignore
             (H.put_clipped ~grid ~clip:sum_r ~x:sum_r.x ~y:!y ~max_w:sum_r.w
                ~style:(H.status_style ~theme tone) line);
           incr y
       | Some _ | None -> ());
      (match Observed.to_option rt.lane_addons with
       | Some la when !y < bot ->
           let live_n =
             List.fold_left
               (fun acc (i : Wire_runtime.addon_instance) ->
                 match i.runtime_presence with
                 | Wire_runtime.Addon_live -> acc + 1
                 | Wire_runtime.Addon_retained -> acc)
               0 la.instances
           in
           ignore
             (H.put_clipped ~grid ~clip:sum_r ~x:sum_r.x ~y:!y ~max_w:sum_r.w
                ~style:(H.secondary_style ~theme ())
                (Printf.sprintf "Addons: %d live / %d total · [→] %s" live_n
                   (List.length la.instances)
                   (Say.resolve lang
                      (Say.make ~ko:"애드온 · 브라우저" ~en:"Addons & Browser"))))
       | Some _ | None -> ())
    end
  end

(* --- 5. Addons & Browser Dedicated Runtime Table --- *)

let addon_phase_badge = function
  | Wire_runtime.Addon_observing -> ("OBS", Theme.Status_ok)
  | Wire_runtime.Addon_attached -> ("ATT", Theme.Status_active)
  | Wire_runtime.Addon_detaching -> ("DETG", Theme.Status_attention)
  | Wire_runtime.Addon_detached -> ("DET", Theme.Status_historical)
  | Wire_runtime.Addon_failed -> ("FAIL", Theme.Status_critical)
  | Wire_runtime.Addon_phase_other s ->
      (String.uppercase_ascii (Grapheme.truncate_to_width ~max_width:6 s),
       Theme.Status_historical)

let render_addons_browser ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let rt = model.runtime in
  let addons = Runtime_store.filtered_addon_instances rt in
  let clients = Runtime_store.filtered_browser_clients rt in
  let tabs = Runtime_store.filtered_browser_tabs rt in
  let live_addons =
    List.fold_left
      (fun acc (inst : Wire_runtime.addon_instance) ->
        match inst.runtime_presence with
        | Wire_runtime.Addon_live -> acc + 1
        | Wire_runtime.Addon_retained -> acc)
      0 addons
  in
  let decl_count =
    match Observed.to_option rt.lane_addons with
    | Some snap -> List.length snap.declarations
    | None -> 0
  in
  let browser_issues =
    match Observed.to_option rt.browser_lane with
    | Some bl -> bl.issues
    | None -> []
  in
  let bar_rect, body_rect =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ a; b ] -> (a, b)
    | _ -> (Rect.empty, rect)
  in
  let addon_asks_pill =
    match Observed.to_option rt.lane_addon_asks with
    | Some (_ :: _ as xs) ->
        [
          {
            H.label =
              Printf.sprintf "%s %d"
                (Say.resolve lang (Say.make ~ko:"애드온 질문" ~en:"Addon Asks"))
                (List.length xs);
            active = true;
            tone = Some Theme.Status_attention;
            glyph = Some Glyph.Warning_triangle;
          };
        ]
    | Some [] | None -> []
  in
  let pills =
    [
      {
        H.label =
          Printf.sprintf "%s %d/%d (%d decl)"
            (Say.resolve lang (Say.make ~ko:"애드온" ~en:"Addons"))
            live_addons (List.length addons) decl_count;
        active = (not rt.addon_catalog_mode) && Model.pane_focused model 0;
        tone = Some (if live_addons > 0 then Theme.Status_ok else Theme.Status_historical);
        glyph = Some (if live_addons > 0 then Glyph.Live_healthy else Glyph.Live_idle);
      };
      {
        H.label =
          Printf.sprintf "%s %d · %s %d"
            (Say.resolve lang (Say.make ~ko:"브라우저" ~en:"Browser"))
            (List.length clients)
            (Say.resolve lang (Say.make ~ko:"탭" ~en:"Tabs"))
            (List.length tabs);
        active = (not rt.addon_catalog_mode) && Model.pane_focused model 1;
        tone = Some (if clients <> [] then Theme.Status_active else Theme.Status_historical);
        glyph = None;
      };
      {
        H.label =
          Say.resolve lang
            (Say.make ~ko:"[p] 패키지 카탈로그" ~en:"[p] Package Catalog");
        active = rt.addon_catalog_mode;
        tone = Some Theme.Status_ai;
        glyph = None;
      };
    ]
    @ addon_asks_pill
    @
    if browser_issues <> [] then
      [
        {
          H.label =
            Printf.sprintf "%s %d"
              (Say.resolve lang (Say.make ~ko:"이슈" ~en:"Issues"))
              (List.length browser_issues);
          active = true;
          tone = Some Theme.Status_attention;
          glyph = Some Glyph.Warning_triangle;
        };
      ]
    else []
  in
  let zoomed_catalog = rt.addon_catalog_mode && Model.is_zoomed_active model in
  ignore
    (H.draw_pills ~grid ~rect:bar_rect ~theme
       ~right_hint:
         (if zoomed_catalog then
            Say.resolve lang
              (Say.make ~ko:"[↑↓] 스크롤 · [p] 런타임 복귀"
                 ~en:"[↑↓] Scroll · [p] Runtime view")
          else if rt.addon_catalog_mode then
            Say.resolve lang
              (Say.make ~ko:"[Enter] 열기/미리보기 · [Tab] 좌/우 · [p] 런타임 복귀"
                 ~en:"[Enter] Open/Preview · [Tab] Pane · [p] Runtime view")
          else
            Say.resolve lang
              (Say.make ~ko:"[n] 부착 · [c] 실행/조작 · [O] 관측/씬 · [p] 카탈로그"
                 ~en:"[n] Attach · [c] Act/Interact · [O] Obs/Scene · [p] Catalog"))
       pills);
  let left_rect, right_rect =
    if zoomed_catalog
    then (Rect.empty, body_rect)
    else
      Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.52
        ~top_ratio:0.50 bp body_rect
  in
  if rt.addon_catalog_mode then begin
    let entries = Runtime_store.filtered_addon_catalog_entries rt in
    let dir_sub =
      match Observed.to_option rt.addon_package_catalog with
      | Some cat -> Some cat.directory
      | None -> None
    in
    let cat_inner =
      Card.draw ~cache grid ~rect:left_rect ~theme
        (H.card_spec ?subtitle:dir_sub ~focused:(Model.pane_focused model 0)
           ~hotkey:
             (Say.resolve lang
                (Say.make ~ko:"[Enter] 열기/미리보기 · [p] 런타임"
                   ~en:"[Enter] Open/Preview · [p] Runtime"))
           (Say.resolve lang
              (Say.make ~ko:"애드온 패키지 카탈로그" ~en:"Addon Package Catalog")))
    in
    if not (Rect.is_empty cat_inner) then begin
      match rt.addon_package_catalog with
      | Observed.Value _ when entries <> [] ->
          let columns : Table.column list =
            [
              {
                id = "kind";
                header = Say.make ~ko:"유형" ~en:"Kind";
                priority = 1;
                min_width = 4;
                max_width = Some 6;
                weight = 1;
                align = Table.Left;
              };
              {
                id = "cat";
                header = Say.make ~ko:"분류" ~en:"Category";
                priority = 1;
                min_width = 8;
                max_width = Some 16;
                weight = 1;
                align = Table.Left;
              };
              {
                id = "name";
                header = Say.make ~ko:"패키지 / 폴더" ~en:"Package / Folder";
                priority = 0;
                min_width = 16;
                max_width = None;
                weight = 3;
                align = Table.Left;
              };
              {
                id = "desc";
                header = Say.make ~ko:"설명" ~en:"Description";
                priority = 2;
                min_width = 12;
                max_width = None;
                weight = 2;
                align = Table.Left;
              };
            ]
          in
          let rows =
            List.mapi
              (fun idx entry ->
                match entry with
                | Wire_runtime.Catalog_folder { path } ->
                    {
                      Table.id = Printf.sprintf "dir:%d:%s" idx path;
                      cells =
                        [
                          ( "kind"
                          , Table.Badge
                              {
                                glyph = None;
                                text = "DIR";
                                tone = Theme.Status_active;
                              } );
                          ("cat", Table.text_cell "folder");
                          ("name", Table.text_cell path);
                          ("desc", Table.text_cell "[Enter] browse");
                        ];
                    }
                | Wire_runtime.Catalog_package
                    { manifest_path; title; revision; description; ui_category } ->
                    let cat_s = Option.value ~default:"addon" ui_category in
                    let desc_s =
                      Option.value ~default:manifest_path description
                    in
                    {
                      Table.id = Printf.sprintf "pkg:%s" manifest_path;
                      cells =
                        [
                          ( "kind"
                          , Table.Badge
                              {
                                glyph = None;
                                text = "PKG";
                                tone = Theme.Status_ok;
                              } );
                          ( "cat"
                          , Table.text_cell
                              ~fg:(Color.of_rgb theme.text_secondary) cat_s );
                          ( "name"
                          , Table.text_cell
                              (Printf.sprintf "%s @ %s" title revision) );
                          ("desc", Table.text_cell (H.sanitize_single_line desc_s));
                        ];
                    }
                | Wire_runtime.Catalog_issue { path; message } ->
                    {
                      Table.id = Printf.sprintf "iss:%d:%s" idx path;
                      cells =
                        [
                          ( "kind"
                          , Table.Badge
                              {
                                glyph = Some Glyph.Warning_triangle;
                                text = "ERR";
                                tone = Theme.Status_critical;
                              } );
                          ("cat", Table.text_cell "issue");
                          ("name", Table.text_cell path);
                          ( "desc"
                          , Table.text_cell (H.sanitize_single_line message) );
                        ];
                    })
              entries
          in
          let sel =
            H.clamp_index (List.length entries) rt.addon_catalog_selected_index
          in
          ignore
            (Table.draw grid ~rect:cat_inner ~theme ~caps:H.default_caps ~lang
               ~col_gap:(Layout.table_col_gap bp)
               ~scroll:rt.addon_catalog_scroll_offset ~selected:sel
               ~focused:(Model.pane_focused model 0) ~columns rows)
      | Observed.Value _ ->
          H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp cat_inner) ~theme
            (Say.resolve lang
               (Say.make ~ko:"일치하는 애드온 패키지 없음"
                  ~en:"No addon packages found"))
      | ( Observed.Loading _
        | Observed.Absent
        | Observed.Unreported
        | Observed.Failed _ ) as obs ->
          H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp cat_inner)
            ~theme ~lang obs
    end;
    let prev_inner =
      Card.draw ~cache grid ~rect:right_rect ~theme
        (H.card_spec ~focused:(Model.detail_pane_focused ~detail_index:1 model)
           ~hotkey:
             (Say.resolve lang
                (if Model.is_zoomed_active model then
                   Say.make ~ko:"[↑↓] 스크롤 · [p] 런타임"
                     ~en:"[↑↓] Scroll · [p] Runtime"
                 else
                   Say.make ~ko:"[→/Tab] 스크롤 · [↑↓] 이동 · [p] 런타임"
                     ~en:"[→/Tab] Scroll · [↑↓] Move · [p] Runtime"))
           (Say.resolve lang
              (Say.make ~ko:"패키지 미리보기" ~en:"Package Preview")))
    in
    let rc = H.pad_content ~bp prev_inner in
    if not (Rect.is_empty rc) then begin
      match Runtime_store.selected_addon_catalog_entry rt with
      | Some (Wire_runtime.Catalog_package { manifest_path; title; _ }) -> (
          match Runtime_store.addon_preview_for ~manifest_path rt with
          | Some preview ->
              let lines =
                Update_nav.addon_catalog_preview_lines ~width:rc.w preview
              in
              let max_skip = Int.max 0 (List.length lines - rc.h) in
              let skip = Int.min max_skip (Int.max 0 rt.detail_scroll_offset) in
              let y = ref rc.y and bot = Rect.bottom rc in
              List.iter
                (fun (ln : Update_nav.styled_line) ->
                  if !y < bot then begin
                    let st =
                      match ln.tone with
                      | Update_nav.Line_section | Update_nav.Line_accent ->
                          H.accent_style ~theme ~attrs:Attr.bold ()
                      | Update_nav.Line_error ->
                          H.status_style ~theme Theme.Status_critical
                      | Update_nav.Line_warn ->
                          H.status_style ~theme Theme.Status_attention
                      | Update_nav.Line_ok ->
                          H.status_style ~theme Theme.Status_ok
                      | Update_nav.Line_selected | Update_nav.Line_plain ->
                          H.text_style ~theme ()
                    in
                    ignore
                      (H.put_clipped ~grid ~clip:rc ~x:rc.x ~y:!y ~max_w:rc.w
                         ~style:st ln.text);
                    incr y
                  end)
                (Store_scroll.drop skip lines)
          | None -> (
              match rt.addon_package_preview with
              | (Observed.Loading _ | Observed.Failed _) as obs ->
                  H.draw_observed_placeholder ~grid ~rect:rc ~theme ~lang obs
              | Observed.Value _ | Observed.Absent | Observed.Unreported ->
                  H.draw_empty_notice ~grid ~rect:rc ~theme
                    (Printf.sprintf "%s · %s" title
                       (Say.resolve lang
                          (Say.make ~ko:"[Enter] 패키지 미리보기 조회"
                             ~en:"Press [Enter] to load package preview")))))
      | Some (Wire_runtime.Catalog_folder { path }) ->
          H.draw_empty_notice ~grid ~rect:rc ~theme
            (Printf.sprintf "Folder: %s · %s" path
               (Say.resolve lang
                  (Say.make ~ko:"[Enter] 디렉터리 열기"
                     ~en:"Press [Enter] to browse directory")))
      | Some (Wire_runtime.Catalog_issue { path; message }) ->
          H.draw_empty_notice ~grid ~rect:rc ~theme
            (Printf.sprintf "%s · %s" path message)
      | None ->
          H.draw_observed_placeholder ~grid ~rect:rc ~theme ~lang
            ~filter_query:rt.filter_query rt.addon_package_catalog
    end
  end
  else begin
  (* Left pane (pane 0): Addon Lanes Table + selected detail strip *)
  let observer_glyph, observer_label, observer_tone =
    Masc_tui_screens_core.Render_util.freshness_pill ~model ~compact:false
  in
  let left_inner =
    Card.draw ~cache grid ~rect:left_rect ~theme
      (H.card_spec ~focused:(Model.pane_focused model 0)
         ~badge:
           (H.make_badge ~glyph:observer_glyph ~tone:observer_tone observer_label)
         ~hotkey:
           (Say.resolve lang
              (Say.make
                 ~ko:"[n] 연결 · [e] 액션 · [c] 응답/실행 · [O] 관측 · [D] 슬라이스 · [x] 분리"
                 ~en:"[n] Attach · [e] Action · [c] Ask/Act · [O] Obs · [D] Slice · [x] Detach"))
         (Say.resolve lang (Say.make ~ko:"애드온 레인" ~en:"Addon Lanes")))
  in
  if not (Rect.is_empty left_inner) then begin
    let detail_h =
      if left_inner.h >= 12 && Option.is_some (Runtime_store.selected_addon_instance rt)
      then 5
      else if left_inner.h >= 10 && Option.is_some (Runtime_store.selected_addon_instance rt)
      then 4
      else 0
    in
    let tbl_rect =
      Rect.make ~x:left_inner.x ~y:left_inner.y ~w:left_inner.w
        ~h:(Int.max 0 (left_inner.h - detail_h))
    in
    (match rt.lane_addons with
     | Observed.Value _ when addons <> [] ->
         let columns : Table.column list =
           [
             {
               id = "addon";
               header = Say.make ~ko:"애드온" ~en:"Addon";
               priority = 0;
               min_width = 14;
               max_width = None;
               weight = 3;
               align = Table.Left;
             };
             {
               id = "pres";
               header = Say.make ~ko:"상태" ~en:"Pres";
               priority = 1;
               min_width = 5;
               max_width = Some 8;
               weight = 1;
               align = Table.Left;
             };
             {
               id = "phase";
               header = Say.make ~ko:"단계" ~en:"Phase";
               priority = 1;
               min_width = 5;
               max_width = Some 7;
               weight = 1;
               align = Table.Left;
             };
             {
               id = "exec";
               header = Say.make ~ko:"실행" ~en:"Exec";
               priority = 2;
               min_width = 6;
               max_width = Some 10;
               weight = 1;
               align = Table.Left;
             };
             {
               id = "obs";
               header = Say.make ~ko:"관측/행" ~en:"Obs#/Rows";
               priority = 2;
               min_width = 8;
               max_width = Some 12;
               weight = 1;
               align = Table.Right;
             };
             {
               id = "decl";
               header = Say.make ~ko:"선언" ~en:"Decl";
               priority = 3;
               min_width = 7;
               max_width = Some 12;
               weight = 1;
               align = Table.Left;
             };
           ]
         in
         let rows =
           List.map
             (fun (inst : Wire_runtime.addon_instance) ->
               let pres_lbl, pres_tone =
                 match inst.runtime_presence with
                 | Wire_runtime.Addon_live -> ("LIVE", Theme.Status_ok)
                 | Wire_runtime.Addon_retained -> ("RETAIN", Theme.Status_historical)
               in
               let ph_lbl, ph_tone = addon_phase_badge inst.phase in
               let exec_txt =
                 match inst.execution_kind with
                 | Some "host_process" -> "host"
                 | Some "container" -> "container"
                 | Some s -> s
                 | None -> Glyph.to_utf8 Glyph.Missing_absent
               in
               let obs_txt =
                 Printf.sprintf "#%d/%d%s" inst.observation_seq inst.rows_count
                   (if inst.observation_pending then "*" else "")
               in
               let decl_txt =
                 match Runtime_store.declaration_for_addon inst rt with
                 | Some d ->
                     Printf.sprintf "%s/%s"
                       (if d.enabled then "on" else "off")
                       d.application_kind
                 | None -> Glyph.to_utf8 Glyph.Missing_absent
               in
               let title_s =
                 if String.equal inst.title inst.addon_id then inst.title
                 else Printf.sprintf "%s (%s)" inst.title inst.addon_id
               in
               {
                 Table.id = inst.instance_id;
                 cells =
                   [
                     ("addon", Table.text_cell title_s);
                     ( "pres"
                     , Table.Badge
                         { glyph = None; text = pres_lbl; tone = pres_tone } );
                     ( "phase"
                     , Table.Badge
                         { glyph = None; text = ph_lbl; tone = ph_tone } );
                     ( "exec"
                     , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                         exec_txt );
                     ("obs", Table.text_cell obs_txt);
                     ( "decl"
                     , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                         decl_txt );
                   ];
               })
             addons
         in
         let sel = H.clamp_index (List.length addons) rt.addon_selected_index in
         ignore
           (Table.draw grid ~rect:tbl_rect ~theme ~caps:H.default_caps ~lang
              ~col_gap:(Layout.table_col_gap bp) ~scroll:rt.addon_scroll_offset
              ~selected:sel ~focused:(Model.pane_focused model 0) ~columns rows)
     | Observed.Value _ ->
         H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp tbl_rect) ~theme
           (Say.resolve lang
              (if String.equal (String.trim rt.filter_query) "" then
                 Say.make ~ko:"실행 중인 애드온 레인 없음"
                   ~en:"No addon lanes observed"
               else
                 Say.make ~ko:"필터에 일치하는 애드온 없음"
                   ~en:"No addon lanes match filter"))
     | ( Observed.Loading _
       | Observed.Absent
       | Observed.Unreported
       | Observed.Failed _ ) as obs ->
         H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp tbl_rect)
           ~theme ~lang obs);
    if detail_h > 0 then begin
      match Runtime_store.selected_addon_instance rt with
      | None -> ()
      | Some inst ->
          let det_r =
            Rect.make ~x:left_inner.x ~y:(left_inner.y + tbl_rect.h)
              ~w:left_inner.w ~h:detail_h
            |> H.pad_content ~bp
          in
          let y = ref det_r.y and bot = Rect.bottom det_r in
          if !y < bot then begin
            H.draw_divider ~grid ~rect:det_r ~y:!y ~theme
              ~label:inst.instance_id ();
            incr y
          end;
          if !y < bot then begin
            let vis_s =
              match inst.visibility_kind, inst.visibility_keeper with
              | Some k, Some kp -> Printf.sprintf "%s:@%s" k kp
              | Some k, None -> k
              | None, _ -> Glyph.to_utf8 Glyph.Missing_absent
            in
            let host_s =
              match inst.host_cycles, inst.host_issue_kind with
              | Some c, Some iss ->
                  Printf.sprintf "cycles=%d wait=%d issue=%s" c
                    inst.host_waiting_count iss
              | Some c, None ->
                  Printf.sprintf "cycles=%d wait=%d" c inst.host_waiting_count
              | None, _ -> Glyph.to_utf8 Glyph.Missing_absent
            in
            let line =
              Printf.sprintf "vis=%s · host[%s]%s" vis_s host_s
                (match inst.resolved_image with
                | Some img -> " · img=" ^ H.short_hash ~len:14 img
                | None -> "")
            in
            ignore
              (H.put_clipped ~grid ~clip:det_r ~x:det_r.x ~y:!y ~max_w:det_r.w
                 ~style:(H.secondary_style ~theme ()) line);
            incr y
          end;
          if !y < bot then begin
            let acts =
              if inst.action_names = [] then
                Say.resolve lang (Say.make ~ko:"액션 스키마 없음" ~en:"no action_schema")
              else String.concat ", " inst.action_names
            in
            H.put_kv ~grid ~clip:det_r ~x:det_r.x ~y:!y ~max_w:det_r.w ~theme
              ~key_w:8 ~key:"Actions" acts;
            incr y
          end;
          if !y < bot then begin
            let op_status =
              let rec_part =
                match Observed.to_option rt.addon_last_action_receipt with
                | Some r ->
                    let d =
                      match r.detail with
                      | Some s -> " · " ^ H.redact_secrets_in_text s
                      | None -> ""
                    in
                    Printf.sprintf "act=%s(%s)%s" r.state r.request_id d
                | None -> ""
              in
              let slice_part =
                match Observed.to_option rt.addon_slice with
                | Some sl -> Printf.sprintf "slice=%d rows" sl.row_count
                | None -> ""
              in
              let ask_part =
                match Observed.to_option rt.lane_addon_asks with
                | Some (_ :: _ as xs) ->
                    Printf.sprintf "asks=%d" (List.length xs)
                | Some [] | None -> ""
              in
              [ rec_part; slice_part; ask_part ]
              |> List.filter (fun s -> not (String.equal s ""))
              |> String.concat " · "
            in
            if not (String.equal op_status "") then
              H.put_kv ~grid ~clip:det_r ~x:det_r.x ~y:!y ~max_w:det_r.w ~theme
                ~key_w:8 ~key:"Op" op_status
          end
    end
  end;
  (* Right pane (pane 1): Browser Lane Clients (top) + Per-Tab Listing (bottom) *)
  let right_focus_tag =
    let base =
      match rt.browser_right_focus with
      | `Clients -> Say.resolve lang (Say.make ~ko:"클라이언트 포커스" ~en:"Clients focus")
      | `Tabs -> Say.resolve lang (Say.make ~ko:"탭 포커스" ~en:"Tabs focus")
    in
    let sel_tab_id =
      Option.map (fun (tb : Wire_runtime.browser_tab_row) -> tb.id)
        (Runtime_store.selected_browser_tab rt)
    in
    let tab_matches tid =
      match sel_tab_id with
      | Some cur -> Int.equal cur tid
      | None -> true
    in
    let candidates =
      (match rt.browser_last_receipt with
      | Observed.Value { observed_at; data = r; _ } ->
          let tag = if r.ok then "ok" else "err" in
          [ (observed_at, Printf.sprintf "op:%s %s" tag (H.redact_secrets_in_text r.summary)) ]
      | Observed.Loading _ | Observed.Absent | Observed.Unreported | Observed.Failed _ -> [])
      @ (match rt.browser_scene with
        | Observed.Value { observed_at; data = tid, sc; _ } when tab_matches tid ->
            [ (observed_at, Printf.sprintf "scene:#%d (%d nodes)" tid (List.length sc.nodes)) ]
        | Observed.Value _ | Observed.Loading _ | Observed.Absent
        | Observed.Unreported | Observed.Failed _ ->
            [])
      @
      match rt.browser_screenshot with
      | Observed.Value { observed_at; data = tid, sh; _ } when tab_matches tid ->
          [ (observed_at, Printf.sprintf "shot:#%d (%dB)" tid sh.base64_bytes) ]
      | Observed.Value _ | Observed.Loading _ | Observed.Absent
      | Observed.Unreported | Observed.Failed _ ->
          []
    in
    let op_note =
      List.fold_left
        (fun acc (ts, txt) ->
          match acc with
          | None -> Some (ts, txt)
          | Some (best_ts, _) ->
              if Clock.Mono.compare ts best_ts > 0 then Some (ts, txt) else acc)
        None candidates
      |> Option.map snd
    in
    match op_note with
    | Some n -> Printf.sprintf "%s · %s" base n
    | None -> base
  in
  let right_inner =
    Card.draw ~cache grid ~rect:right_rect ~theme
      (H.card_spec ~focused:(Model.pane_focused model 1)
         ~subtitle:right_focus_tag
         ~badge:
           (H.make_badge ~glyph:Glyph.Live_idle ~tone:Theme.Status_historical
              (Say.resolve lang (Say.make ~ko:"스냅샷 · [r]" ~en:"SNAPSHOT · [r]")))
         ~hotkey:
           (Say.resolve lang
              (Say.make ~ko:"[→/Tab] 포커스 · [t] 탭 · [c] 조작 · [O] 씬 · [W] 캡처 · [o] 열기"
                 ~en:"[→/Tab] Focus · [t] Tabs · [c] Act · [O] Scene · [W] Shot · [o] Open"))
         (Say.resolve lang
            (Say.make ~ko:"브라우저 레인 클라이언트 · 탭"
               ~en:"Browser Clients & Open Tabs")))
  in
  if not (Rect.is_empty right_inner) then begin
    let issues_h =
      if browser_issues <> [] && right_inner.h >= 12 then
        Int.min 3 (List.length browser_issues)
      else 0
    in
    let main_h = Int.max 0 (right_inner.h - issues_h) in
    let clients_h =
      if main_h <= 0 then 0 else Int.min main_h (Int.max 4 ((main_h * 45) / 100))
    in
    let tabs_h = Int.max 0 (main_h - clients_h) in
    let clients_rect =
      Rect.make ~x:right_inner.x ~y:right_inner.y ~w:right_inner.w ~h:clients_h
    in
    let issues_rect =
      Rect.make ~x:right_inner.x ~y:(right_inner.y + clients_h) ~w:right_inner.w
        ~h:issues_h
    in
    let tabs_rect =
      Rect.make ~x:right_inner.x ~y:(right_inner.y + clients_h + issues_h)
        ~w:right_inner.w ~h:tabs_h
    in
    (* Top: Clients table *)
    (match rt.browser_lane with
     | Observed.Value _ when clients <> [] ->
         let columns : Table.column list =
           [
             {
               id = "client";
               header = Say.make ~ko:"스페이스/클라이언트" ~en:"Space/Client";
               priority = 0;
               min_width = 14;
               max_width = None;
               weight = 3;
               align = Table.Left;
             };
             {
               id = "browser";
               header = Say.make ~ko:"브라우저" ~en:"Browser/Ver";
               priority = 1;
               min_width = 10;
               max_width = Some 18;
               weight = 2;
               align = Table.Left;
             };
             {
               id = "presence";
               header = Say.make ~ko:"존재/소유" ~en:"Pres/Owner";
               priority = 1;
               min_width = 10;
               max_width = Some 16;
               weight = 1;
               align = Table.Left;
             };
             {
               id = "activity";
               header = Say.make ~ko:"활성 작업" ~en:"Active Actor·Action";
               priority = 2;
               min_width = 12;
               max_width = None;
               weight = 2;
               align = Table.Left;
             };
           ]
         in
         let rows =
           List.map
             (fun (cl : Wire_runtime.browser_client_row) ->
               let name_s =
                 match cl.space with
                 | Some sp ->
                     Printf.sprintf "%s (%s)" sp.space_name
                       (H.short_hash ~len:8 cl.client_id)
                 | None -> H.short_hash ~len:14 cl.client_id
               in
               let ver_s =
                 if String.equal cl.version "" then cl.browser
                 else Printf.sprintf "%s %s" cl.browser cl.version
               in
               let pres_txt, pres_tone =
                 match cl.presence_state, cl.ownership with
                 | Some "present", Some own ->
                     (Printf.sprintf "present/%s" own, Theme.Status_ok)
                 | Some "present", None -> ("present", Theme.Status_ok)
                 | Some "missing", _ -> ("missing", Theme.Status_critical)
                 | Some st, Some own ->
                     (Printf.sprintf "%s/%s" st own, Theme.Status_attention)
                 | Some st, None -> (st, Theme.Status_attention)
                 | None, Some own -> (own, Theme.Status_active)
                 | None, None -> ("live", Theme.Status_active)
               in
               let act_s =
                 match cl.interactions with
                 | act :: _ ->
                     let who = Option.value ~default:"agent" act.actor in
                     Printf.sprintf "%s·%s (%s)" who act.action act.phase
                 | [] -> (
                     match cl.last_activities with
                     | last :: _ ->
                         let who = Option.value ~default:"agent" last.work.actor in
                         Printf.sprintf "%s·%s [%s]" who last.work.action
                           last.outcome
                     | [] -> "idle")
               in
               {
                 Table.id = cl.client_id;
                 cells =
                   [
                     ("client", Table.text_cell name_s);
                     ( "browser"
                     , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                         ver_s );
                     ( "presence"
                     , Table.Badge
                         { glyph = None; text = pres_txt; tone = pres_tone } );
                     ("activity", Table.text_cell act_s);
                   ];
               })
             clients
         in
         let sel =
           H.clamp_index (List.length clients) rt.browser_client_selected_index
         in
         let clients_focused =
           Model.pane_focused model 1
           && match rt.browser_right_focus with `Clients -> true | `Tabs -> false
         in
         ignore
           (Table.draw grid ~rect:clients_rect ~theme ~caps:H.default_caps ~lang
              ~col_gap:(Layout.table_col_gap bp)
              ~scroll:rt.browser_client_scroll_offset ~selected:sel
              ~focused:clients_focused ~columns rows)
     | Observed.Value _ ->
         H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp clients_rect) ~theme
           (Say.resolve lang
              (Say.make ~ko:"연결된 브라우저 클라이언트 없음"
                 ~en:"No connected browser clients"))
     | ( Observed.Loading _
       | Observed.Absent
       | Observed.Unreported
       | Observed.Failed _ ) as obs ->
         H.draw_observed_placeholder ~grid
           ~rect:(H.pad_content ~bp clients_rect) ~theme ~lang obs);
    (* Optional inventoryIssues warning rails *)
    if issues_h > 0 then begin
      let pad_r = H.pad_content ~bp issues_rect in
      let iy = ref pad_r.y and ibot = Rect.bottom pad_r in
      List.iter
        (fun (iss : Wire_runtime.browser_inventory_issue) ->
          if !iy < ibot then begin
            Card.draw_left_rail ~tone:Theme.Status_attention grid ~x:pad_r.x
              ~y:!iy ~h:1 ~theme;
            ignore
              (H.put_clipped ~grid ~clip:pad_r ~x:(pad_r.x + 2) ~y:!iy
                 ~max_w:(Int.max 0 (pad_r.w - 2))
                 ~style:(H.status_style ~theme Theme.Status_attention)
                 (Printf.sprintf "%s [%s] %s"
                    (Glyph.to_utf8 Glyph.Warning_triangle)
                    iss.kind iss.message));
            incr iy
          end)
        (H.safe_take issues_h browser_issues)
    end;
    (* Bottom: Per-Tab Listing for selected client *)
    if tabs_h >= 2 then begin
      let pad_x = Layout.card_pad_x bp in
      let sel_cl_label =
        match Runtime_store.selected_browser_client rt with
        | Some cl ->
            Printf.sprintf "%s (%d) · %s"
              (Say.resolve lang (Say.make ~ko:"열린 탭" ~en:"Open Tabs"))
              (List.length tabs)
              (H.short_hash ~len:10 cl.client_id)
        | None -> Say.resolve lang (Say.make ~ko:"열린 탭" ~en:"Open Tabs")
      in
      H.draw_divider ~grid ~rect:tabs_rect ~y:tabs_rect.y ~theme ~pad_x
        ~label:sel_cl_label ();
      let tabs_body =
        Rect.make ~x:tabs_rect.x ~y:(tabs_rect.y + 1) ~w:tabs_rect.w
          ~h:(Int.max 0 (tabs_rect.h - 1))
      in
      match Runtime_store.selected_browser_client rt with
      | None ->
          H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp tabs_body) ~theme
            (Say.resolve lang
               (Say.make ~ko:"브라우저 클라이언트를 선택하면 탭이 표시됩니다"
                  ~en:"Select a browser client to inspect open tabs"))
      | Some cl -> (
          match Runtime_store.browser_tabs_for ~client_id:cl.client_id rt with
          | Observed.Value { data = resp; _ } -> (
              match resp.error with
              | Some err ->
                  H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp tabs_body)
                    ~theme
                    (Printf.sprintf "%s %s"
                       (Glyph.to_utf8 Glyph.Warning_triangle) err)
              | None when tabs = [] ->
                  H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp tabs_body)
                    ~theme
                    (Say.resolve lang
                       (Say.make ~ko:"열린 탭 없음 · [t] 새로고침"
                          ~en:"No open tabs · [t] refresh"))
              | None ->
                  let columns : Table.column list =
                    [
                      {
                        id = "id";
                        header = Say.literal "#ID";
                        priority = 1;
                        min_width = 4;
                        max_width = Some 6;
                        weight = 1;
                        align = Table.Right;
                      };
                      {
                        id = "act";
                        header = Say.literal "●";
                        priority = 1;
                        min_width = 2;
                        max_width = Some 3;
                        weight = 1;
                        align = Table.Center;
                      };
                      {
                        id = "origin";
                        header = Say.make ~ko:"출처" ~en:"Origin";
                        priority = 2;
                        min_width = 5;
                        max_width = Some 8;
                        weight = 1;
                        align = Table.Left;
                      };
                      {
                        id = "title";
                        header = Say.make ~ko:"제목" ~en:"Title";
                        priority = 0;
                        min_width = 14;
                        max_width = None;
                        weight = 3;
                        align = Table.Left;
                      };
                      {
                        id = "url";
                        header = Say.literal "URL";
                        priority = 0;
                        min_width = 14;
                        max_width = None;
                        weight = 2;
                        align = Table.Left;
                      };
                    ]
                  in
                  let rows =
                    List.map
                      (fun (tb : Wire_runtime.browser_tab_row) ->
                        let act_cell =
                          if tb.active then
                            Table.text_cell ~fg:(Color.of_rgb theme.status_ok)
                              ~attrs:Attr.bold
                              (Glyph.to_utf8 Glyph.Live_healthy)
                          else
                            Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                              (Glyph.to_utf8 Glyph.Live_idle)
                        in
                        let orig_lbl, orig_tone =
                          match tb.opened_by with
                          | Some Wire_runtime.Tab_origin_agent ->
                              ("agent", Theme.Status_ai)
                          | Some Wire_runtime.Tab_origin_unknown ->
                              ("user", Theme.Status_historical)
                          | None -> ("—", Theme.Status_historical)
                        in
                        let title_s =
                          let base =
                            if String.equal (String.trim tb.title) "" then
                              Option.value ~default:"(untitled)" tb.label
                            else tb.title
                          in
                          if tb.dialog_present then
                            let dk =
                              Option.value ~default:"dialog" tb.dialog_kind
                            in
                            Printf.sprintf "[%s] %s" dk base
                          else base
                        in
                        {
                          Table.id = string_of_int tb.id;
                          cells =
                            [
                              ("id", Table.text_cell (Printf.sprintf "#%d" tb.id));
                              ("act", act_cell);
                              ( "origin"
                              , Table.Badge
                                  {
                                    glyph = None;
                                    text = orig_lbl;
                                    tone = orig_tone;
                                  } );
                              ("title", Table.text_cell (H.sanitize_single_line title_s));
                              ( "url"
                              , Table.text_cell
                                  ~fg:(Color.of_rgb theme.accent)
                                  (H.sanitize_single_line tb.url) );
                            ];
                        })
                      tabs
                  in
                  let sel =
                    H.clamp_index (List.length tabs) rt.browser_tab_selected_index
                  in
                  let tabs_focused =
                    Model.pane_focused model 1
                    && match rt.browser_right_focus with
                       | `Tabs -> true
                       | `Clients -> false
                  in
                  ignore
                    (Table.draw grid ~rect:tabs_body ~theme ~caps:H.default_caps
                       ~lang ~col_gap:(Layout.table_col_gap bp)
                       ~scroll:rt.browser_tab_scroll_offset ~selected:sel
                       ~focused:tabs_focused ~columns rows))
          | Observed.Absent | Observed.Unreported ->
              H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp tabs_body)
                ~theme
                (Say.resolve lang
                   (Say.make ~ko:"[t] 키로 이 클라이언트의 열린 탭 조회"
                      ~en:"Press [t] to fetch open tabs for this client"))
          | (Observed.Loading _ | Observed.Failed _) as obs ->
              H.draw_observed_placeholder ~grid
                ~rect:(H.pad_content ~bp tabs_body) ~theme ~lang obs)
    end
  end
  end

(* --- 8. Top-Level Runtime Workspace Entry & Tool Detail Dive --- *)

let render ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Theme.of_preset model.theme_preset in
    let bp = H.layout_bp ~model ~rect in
    let body = H.body_rect ~bp rect in
    match model.runtime.active_tab with
    | Nav.Runtime_quotas_credits ->
        render_quotas_credits ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Runtime_efficiency_spend ->
        render_efficiency_spend ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Runtime_failover_lanes ->
        render_failover_lanes ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Runtime_fusion ->
        render_fusion ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Runtime_tools_usage ->
        render_tools_usage ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Runtime_connectors ->
        render_connectors ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Runtime_addons_browser ->
        render_addons_browser ~model ~cache ~rect:body ~theme ~bp grid

let render_inspector
    ~(target : [ `Tool of string | `Skill of string | `Exact_run of string ])
    ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Theme.of_preset model.theme_preset in
    let bp = H.layout_bp ~model ~rect in
    let body = H.body_rect ~bp rect in
    let lang = model.lang in
    let rt = model.runtime in
    match target with
    | `Tool tool_name ->
        let entry_opt =
          match Observed.to_option rt.tools_dashboard with
          | Some d ->
              List.find_opt
                (fun (e : Wire_runtime.tool_catalog_entry) ->
                  String.equal e.name tool_name)
                d.entries
          | None -> None
        in
        let top_h = if body.h >= 20 then 9 else 6 in
        let meta_rect, series_rect =
          match
            Layout.split_v_bp bp body [ Layout.Fixed top_h; Layout.Flex 1 ]
          with
          | [ a; b ] -> (a, b)
          | _ -> (body, Rect.empty)
        in
        let badge =
          match entry_opt with
          | Some e ->
              Some
                (H.make_badge ~tone:Theme.Status_active
                   (Printf.sprintf "%s / %s" e.domain e.family))
          | None -> None
        in
        let meta_inner =
          Card.draw ~cache grid ~rect:meta_rect ~theme
            (H.card_spec ?badge ~focused:(Model.pane_focused model 0)
               ~hotkey:
                 (Say.resolve lang
                    (Say.make ~ko:"[e] MCP 실행 · [Tab] 시계열 · [w] 기간(24h/7d/14d) · [Esc] 뒤로"
                       ~en:"[e] Execute MCP · [Tab] Series · [w] Window(24h/7d/14d) · [Esc] Back"))
               (Printf.sprintf "%s > %s"
                  (Say.resolve lang (Say.make ~ko:"도구 상세" ~en:"Tool Detail"))
                  tool_name))
        in
        let mc = H.pad_content ~bp meta_inner in
        if not (Rect.is_empty mc) then begin
          let y = ref mc.y and bot = Rect.bottom mc in
          let schema_opt =
            Runtime_store.mcp_tool_schema_for ~name:tool_name rt
          in
          (match entry_opt with
           | None ->
               H.put_kv ~grid ~clip:mc ~x:mc.x ~y:!y ~max_w:mc.w ~theme
                 ~key_w:10 ~key:"Tool" tool_name;
               incr y
           | Some e ->
               let direct_s =
                 match e.direct_call_allowed with
                 | Some true -> "yes"
                 | Some false -> "no"
                 | None -> "—"
               in
               let surf_s =
                 if e.surfaces = [] then "—" else String.concat ", " e.surfaces
               in
               let pub_s =
                 if e.public_names = [] then "—"
                 else String.concat ", " e.public_names
               in
               if !y < bot then begin
                 H.put_kv ~grid ~clip:mc ~x:mc.x ~y:!y ~max_w:mc.w ~theme
                   ~key_w:10 ~key:"Surface"
                   (Printf.sprintf "%s · Direct=%s · Public: %s" surf_s direct_s
                      pub_s);
                 incr y
               end;
               if e.doc_refs <> [] && !y < bot then begin
                 H.put_kv ~grid ~clip:mc ~x:mc.x ~y:!y ~max_w:mc.w ~theme
                   ~key_w:10 ~key:"Docs" (String.concat ", " e.doc_refs);
                 incr y
               end);
          (match schema_opt with
           | Some s when !y < bot ->
               let req_s =
                 if s.required_params = [] then "none"
                 else String.concat ", " s.required_params
               in
               let all_s =
                 if s.param_names = [] then "{}"
                 else String.concat ", " s.param_names
               in
               H.put_kv ~grid ~clip:mc ~x:mc.x ~y:!y ~max_w:mc.w ~theme
                 ~key_w:10 ~key:"Schema"
                 (Printf.sprintf "req=[%s] · params=[%s]" req_s all_s);
               incr y
           | Some _ | None -> ());
          (match rt.mcp_call_result with
           | Observed.Loading _ when !y < bot ->
               H.put_kv ~grid ~clip:mc ~x:mc.x ~y:!y ~max_w:mc.w ~theme
                 ~key_w:10 ~key:"MCP Run"
                 (Say.resolve lang
                    (Say.make ~ko:"실행 중…" ~en:"Executing…"));
               incr y
           | Observed.Failed { reason; _ } when !y < bot ->
               H.put_kv ~grid ~clip:mc ~x:mc.x ~y:!y ~max_w:mc.w ~theme
                 ~key_w:10 ~key:"MCP Err" (H.redact_secrets_in_text reason);
               incr y
           | Observed.Value { data = res; _ }
             when String.equal res.tool_name tool_name && !y < bot ->
               let out_body =
                 match (res.raw_error, res.content_texts, res.structured_json) with
                 | Some e, _, _ -> "ERR: " ^ H.redact_secrets_in_text e
                 | None, (_ :: _ as texts), _ ->
                     let prefix = if res.is_error then "ERR: " else "OK: " in
                     prefix
                     ^ H.redact_secrets_in_text (String.concat "\n" texts)
                 | None, [], Some j ->
                     let prefix = if res.is_error then "ERR: " else "OK: " in
                     prefix
                     ^ H.redact_secrets_in_text (Yojson.Safe.pretty_to_string j)
                 | None, [], None -> if res.is_error then "ERR" else "OK (empty)"
               in
               let out_lines = String.split_on_char '\n' out_body in
               (match out_lines with
               | first :: rest ->
                   H.put_kv ~grid ~clip:mc ~x:mc.x ~y:!y ~max_w:mc.w ~theme
                     ~key_w:10 ~key:"MCP Out" first;
                   incr y;
                   let bg = Color.of_rgb theme.surface_1 in
                   let st = Typography.primary ~bg theme in
                   let max_extra = Int.min 6 (List.length rest) in
                   List.iteri
                     (fun idx line ->
                       if idx < max_extra && !y < bot then begin
                         ignore
                           (Cell_grid.put_text ~clip:mc grid ~x:(mc.x + 2) ~y:!y
                              ~style:st
                              (Grapheme.truncate_to_width
                                 ~max_width:(Int.max 1 (mc.w - 2))
                                 line));
                         incr y
                       end)
                     rest
               | [] -> ())
           | Observed.Loading _ | Observed.Failed _ | Observed.Value _ | Observed.Absent | Observed.Unreported -> ());
          (let desc_opt =
             match entry_opt with
             | Some e when Option.is_some e.description -> e.description
             | Some _ | None ->
                 Option.bind schema_opt (fun s -> s.description)
           in
           match desc_opt with
           | Some desc when !y < bot ->
               let md_r =
                 Rect.make ~x:mc.x ~y:!y ~w:mc.w ~h:(Int.max 0 (bot - !y))
               in
               ignore
                 (Markdown.draw grid ~rect:md_r ~theme ~osc8:true
                    ~scroll:model.nav.inspector_scroll_offset desc)
           | Some _ | None -> ())
        end;
        if not (Rect.is_empty series_rect) then begin
          match Observed.to_option rt.tool_detail_series with
          | Some (tn, summary) when String.equal tn tool_name ->
              draw_tool_series_analytics ~table_focused:(Model.pane_focused model 1)
                ~grid ~cache ~rect:series_rect ~theme ~bp ~model
                ~series:summary.series ~summary:(Some summary)
                ~show_err_classes:true
          | _ ->
              let inner =
                Card.draw ~cache grid ~rect:series_rect ~theme
                  (H.card_spec ~focused:(Model.pane_focused model 1)
                     (Say.resolve lang
                        (Say.make ~ko:"도구별 시계열 추이"
                           ~en:"Per-Tool Time Series")))
              in
              H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp inner)
                ~theme ~lang rt.tool_detail_series
        end
    | `Skill ref_s ->
        let inner =
          Card.draw ~cache grid ~rect:body ~theme
            (H.card_spec ~focused:(Model.body_has_focus model) ~subtitle:ref_s
               ~hotkey:
                 (Say.resolve lang
                    (Say.make
                       ~ko:"[e] 편집 · [p] 미리보기 검증 · [x] 삭제 · [n] 생성 · [R] 갱신 · [Esc] 뒤로"
                       ~en:"[e] Edit · [p] Preview · [x] Delete · [n] New · [R] Refresh · [Esc] Back"))
               (Say.resolve lang
                  (Say.make ~ko:"런타임 > 스킬 인스펙터 & 편집기"
                     ~en:"Runtime > Skill Inspector & Editor")))
        in
        let content = H.pad_content ~bp inner in
        if not (Rect.is_empty content) then begin
          match rt.skill_editor_loaded with
          | Observed.Value { data = r, loaded; _ }
            when String.equal r ref_s || String.equal loaded.reference ref_s ->
              let sources_s =
                match Observed.to_option rt.skill_editor_sources with
                | Some (_ :: _ as xs) -> String.concat ", " xs
                | Some [] | None -> "—"
              in
              let tools_n =
                match Observed.to_option rt.skill_editor_tools with
                | Some xs -> List.length xs
                | None -> 0
              in
              let plain s = (Update_nav.Line_plain, s) in
              let sec s = (Update_nav.Line_section, s) in
              let warn s = (Update_nav.Line_warn, s) in
              let preview_lines =
                match Observed.to_option rt.skill_editor_preview with
                | None -> []
                | Some pv ->
                    let diag_part =
                      if pv.diagnostics = [] then
                        [ plain "  preview: valid (0 diagnostics)" ]
                      else
                        List.map
                          (fun d -> warn ("  [DIAG] " ^ H.redact_secrets_in_text d))
                          pv.diagnostics
                    in
                    sec "── Preview" :: diag_part
              in
              let all_lines =
                [
                  plain
                    (Printf.sprintf "Reference: %s · Access: %s · Rev: %s"
                       loaded.reference
                       (Wire_runtime.skill_access_to_string loaded.access)
                       loaded.snapshot_revision);
                  plain
                    (Printf.sprintf "Writable Sources: %s · Authoring Tools: %d"
                       sources_s tools_n);
                ]
                @ preview_lines
                @ (sec "── SKILL.md Source"
                  :: List.map plain
                       (String.split_on_char '\n'
                          (H.redact_secrets_in_text loaded.source_text)))
              in
              let skip =
                Int.max 0
                  (Int.min
                     (Int.max 0 (List.length all_lines - content.h))
                     model.nav.inspector_scroll_offset)
              in
              let y = ref content.y and bot = Rect.bottom content in
              let bg = Color.of_rgb theme.surface_1 in
              List.iter
                (fun (tone, ln) ->
                  if !y < bot then begin
                    (match tone with
                     | Update_nav.Line_section ->
                         let lbl =
                           Option.value (Card.legacy_rule_label ln)
                             ~default:(String.trim ln)
                         in
                         Card.draw_hairline ~pad_x:0 ~bg ~label:lbl grid
                           ~rect:content ~y:!y ~theme
                     | Update_nav.Line_accent ->
                         ignore
                           (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                              ~max_w:content.w
                              ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                              ln)
                     | Update_nav.Line_warn ->
                         ignore
                           (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                              ~max_w:content.w
                              ~style:(H.status_style ~theme Theme.Status_attention)
                              ln)
                     | Update_nav.Line_error ->
                         ignore
                           (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                              ~max_w:content.w
                              ~style:(H.status_style ~theme Theme.Status_critical)
                              ln)
                     | Update_nav.Line_ok ->
                         ignore
                           (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                              ~max_w:content.w
                              ~style:(H.status_style ~theme Theme.Status_ok)
                              ln)
                     | Update_nav.Line_selected | Update_nav.Line_plain ->
                         ignore
                           (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                              ~max_w:content.w ~style:(H.text_style ~theme ()) ln));
                    incr y
                  end)
                (Store_scroll.drop skip all_lines)
          | Observed.Loading _ ->
              H.draw_observed_placeholder ~grid ~rect:content ~theme ~lang
                rt.skill_editor_loaded
          | Observed.Failed _ as obs ->
              H.draw_observed_placeholder ~grid ~rect:content ~theme ~lang obs
          | Observed.Value _ | Observed.Absent | Observed.Unreported ->
              let sf_summary =
                match Runtime_store.find_skill_surface ~reference:ref_s rt with
                | Some sf ->
                    Printf.sprintf "Skill %s [%s] — loading SKILL.md…"
                      sf.reference sf.kind
                | None ->
                    Printf.sprintf "Skill %s — press [R] to refresh catalog"
                      ref_s
              in
              ignore
                (H.put_clipped ~grid ~clip:content ~x:content.x ~y:content.y
                   ~max_w:content.w ~style:(H.whisper_style ~theme ())
                   sf_summary)
        end
    | `Exact_run run_id ->
        let inner =
          Card.draw ~cache grid ~rect:body ~theme
            (H.card_spec ~focused:(Model.body_has_focus model) ~subtitle:run_id
               ~hotkey:
                 (Say.resolve lang
                    (Say.make ~ko:"[↑↓] 스크롤 · [y] ID 복사 · [r] 새로고침 · [Esc] 뒤로"
                       ~en:"[↑↓] Scroll · [y] Copy ID · [r] Refresh · [Esc] Back"))
               (Say.resolve lang
                  (Say.make ~ko:"런타임 > Exact 레인 실행 상세"
                     ~en:"Runtime > Exact Lane Run Detail")))
        in
        let content = H.pad_content ~bp inner in
        if not (Rect.is_empty content) then begin
          match rt.exact_run_detail with
          | Observed.Value { data = rid, detail; _ }
            when String.equal rid run_id ->
              let opt_s = function Some s -> s | None -> "—" in
              let elapsed_s =
                match detail.elapsed_s with
                | Some e -> Printf.sprintf "%.2fs" e
                | None -> "—"
              in
              let plain s = (Update_nav.Line_plain, s) in
              let sec s = (Update_nav.Line_section, s) in
              let json_lines heading j_opt =
                match j_opt with
                | None -> []
                | Some j ->
                    sec ("── " ^ heading)
                    :: List.map plain
                         (String.split_on_char '\n'
                            (H.redact_secrets_in_text
                               (Yojson.Safe.pretty_to_string j)))
              in
              let all_lines =
                [
                  plain
                    (Printf.sprintf "Run ID: %s · Kind: %s · Lane: %s"
                       detail.run_id detail.run_kind detail.lane);
                  plain
                    (Printf.sprintf "Status: %s · Elapsed: %s · Slot: %s"
                       detail.status elapsed_s (opt_s detail.selected_slot));
                  plain
                    (Printf.sprintf "Subject: %s · Actor: %s · Skill Evidence: %s"
                       (opt_s detail.subject_id) (opt_s detail.actor)
                       (opt_s detail.skill_evidence_state));
                ]
                @ json_lines "Input" detail.input_json
                @ json_lines "Output" detail.output_json
                @ json_lines "Raw Payload" (Some detail.raw_json)
              in
              let skip =
                Int.max 0
                  (Int.min
                     (Int.max 0 (List.length all_lines - content.h))
                     model.nav.inspector_scroll_offset)
              in
              let y = ref content.y and bot = Rect.bottom content in
              let bg = Color.of_rgb theme.surface_1 in
              List.iter
                (fun (tone, ln) ->
                  if !y < bot then begin
                    (match tone with
                     | Update_nav.Line_section ->
                         let lbl =
                           Option.value (Card.legacy_rule_label ln)
                             ~default:(String.trim ln)
                         in
                         Card.draw_hairline ~pad_x:0 ~bg ~label:lbl grid
                           ~rect:content ~y:!y ~theme
                     | Update_nav.Line_accent ->
                         ignore
                           (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                              ~max_w:content.w
                              ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                              ln)
                     | Update_nav.Line_plain
                     | Update_nav.Line_selected
                     | Update_nav.Line_ok
                     | Update_nav.Line_warn
                     | Update_nav.Line_error ->
                         ignore
                           (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                              ~max_w:content.w ~style:(H.text_style ~theme ()) ln));
                    incr y
                  end)
                (Store_scroll.drop skip all_lines)
          | Observed.Loading _ ->
              H.draw_observed_placeholder ~grid ~rect:content ~theme ~lang
                rt.exact_run_detail
          | Observed.Failed _ as obs ->
              H.draw_observed_placeholder ~grid ~rect:content ~theme ~lang obs
          | Observed.Value _ | Observed.Absent | Observed.Unreported ->
              ignore
                (H.put_clipped ~grid ~clip:content ~x:content.x ~y:content.y
                   ~max_w:content.w ~style:(H.whisper_style ~theme ())
                   (Printf.sprintf "Exact run %s — press [r] to refresh" run_id))
        end
