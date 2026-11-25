open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

module H = Domain_helpers

let cached_code_lexer_mu = Stdlib.Mutex.create ()
let cached_code_lexer_rows :
    (string * string * string * Code_lexer.segment list list) option ref =
  ref None

let cached_rows_of_source ~(path : string) ~(revision : string) ~(content : string) =
  match
    Stdlib.Mutex.protect cached_code_lexer_mu (fun () -> !cached_code_lexer_rows)
  with
  | Some (p, r, c, rows)
    when String.equal p path && String.equal r revision && c == content ->
      rows
  | Some _ | None ->
      let lang_opt = Code_lexer.language_of_path path in
      let rows = Code_lexer.rows_of_source ~language:lang_opt content in
      Stdlib.Mutex.protect cached_code_lexer_mu (fun () ->
          cached_code_lexer_rows := Some (path, revision, content, rows));
      rows

(* --- 1. Sandbox Helpers & Canonical 8-Column Mapping --- *)

let network_mode_label = function
  | Wire_infra.Net_inherit -> "inherit"
  | Wire_infra.Net_none -> "none"
  | Wire_infra.Net_policy -> "policy"

let socket_status_display = function
  | Wire_infra.Socket_present _ -> (Glyph.Live_healthy, Theme.Status_ok, "live")
  | Wire_infra.Socket_absent _ ->
      (Glyph.Live_idle, Theme.Status_historical, "stopped")
  | Wire_infra.Socket_non_socket _ ->
      (Glyph.Warning_triangle, Theme.Status_attention, "non-sock")
  | Wire_infra.Socket_unreadable _ ->
      (Glyph.Live_failing, Theme.Status_critical, "unread")

let shim_parity_display ?(lang = Say.Lang_en) ?(fallback_404 = false) = function
  | Wire_infra.Shim_matched id ->
      (Glyph.Check_mark, Theme.Status_ok, "match " ^ H.short_hash ~len:7 id)
  | Wire_infra.Shim_mismatch { shim_identity; _ } ->
      ( Glyph.Warning_triangle
      , Theme.Status_attention
      , "mismatch " ^ H.short_hash ~len:7 shim_identity )
  | Wire_infra.Shim_undeclared ->
      let lbl =
        if fallback_404 then
          Say.resolve lang
            (Say.make ~ko:"심 미보고 (Legacy API)" ~en:"Shim unreported (Legacy API)")
        else Say.resolve lang (Say.make ~ko:"심 미보고" ~en:"Shim unreported")
      in
      (Glyph.Missing_absent, Theme.Status_historical, lbl)
  | Wire_infra.Shim_unavailable reason ->
      (Glyph.Live_failing, Theme.Status_critical, reason)

let shim_compact_badge ~lang = function
  | Wire_infra.Shim_matched _ ->
      ( Glyph.Check_mark
      , Theme.Status_ok
      , Say.resolve lang (Say.make ~ko:"일치" ~en:"match") )
  | Wire_infra.Shim_mismatch _ ->
      ( Glyph.Warning_triangle
      , Theme.Status_attention
      , Say.resolve lang (Say.make ~ko:"불일치" ~en:"mismatch") )
  | Wire_infra.Shim_undeclared ->
      (Glyph.Missing_absent, Theme.Status_historical, "—")
  | Wire_infra.Shim_unavailable _ ->
      ( Glyph.Live_failing
      , Theme.Status_critical
      , Say.resolve lang (Say.make ~ko:"불가" ~en:"unavail") )

let volume_is_invalid = function
  | Wire_infra.Volume_invalid _ -> true
  | Wire_infra.Volume_declared _ -> false

let format_metrics_fail (m : Wire_infra.tool_metrics_24h) =
  Printf.sprintf "%d/%d" m.failures m.calls

let log_level_badge = function
  | Wire_infra.Log_error -> ("ERR", Theme.Status_critical)
  | Wire_infra.Log_warn -> ("WRN", Theme.Status_attention)
  | Wire_infra.Log_info -> ("INF", Theme.Status_ok)
  | Wire_infra.Log_debug -> ("DBG", Theme.Status_historical)

type fleet_sandbox_entry =
  | Entry_microvm of Wire_infra.microvm_guest
  | Entry_ssh_bound of Wire_infra.ssh_pool * Wire_infra.ssh_keeper_session
  | Entry_ssh_unbound of Wire_infra.ssh_unbound_keeper
  | Entry_docker of Wire_infra.docker_keeper

let fleet_entries_of_snapshot (s : Wire_infra.sandboxes_snapshot) :
    fleet_sandbox_entry list =
  let mvs = List.map (fun g -> Entry_microvm g) s.microvm_guests in
  let ssh_b =
    List.concat_map
      (fun (p : Wire_infra.ssh_pool) ->
        List.map (fun ks -> Entry_ssh_bound (p, ks)) p.keeper_sessions)
      s.ssh_pools
  in
  let ssh_u = List.map (fun u -> Entry_ssh_unbound u) s.ssh_unbound_keepers in
  let dock = List.map (fun d -> Entry_docker d) s.docker_keepers in
  mvs @ ssh_b @ ssh_u @ dock

let entry_keeper_name = function
  | Entry_microvm g -> g.keeper
  | Entry_ssh_bound (_, ks) -> ks.keeper
  | Entry_ssh_unbound u -> u.keeper
  | Entry_docker d -> d.keeper

let entry_search_haystack = function
  | Entry_microvm g -> g.keeper ^ " " ^ g.guest_name ^ " " ^ g.backend
  | Entry_ssh_bound (p, ks) -> ks.keeper ^ " " ^ p.pool_name ^ " " ^ p.host ^ " ssh"
  | Entry_ssh_unbound u -> u.keeper ^ " " ^ u.backend ^ " ssh"
  | Entry_docker d -> d.keeper ^ " " ^ d.backend ^ " docker"

let entry_metrics = function
  | Entry_microvm g -> g.metrics_24h
  | Entry_ssh_bound (_, ks) -> ks.metrics_24h
  | Entry_ssh_unbound u -> u.metrics_24h
  | Entry_docker d -> d.metrics_24h

let keeper_company_of ~(model : Model.t) keeper =
  match Fleet_store.find_keeper ~name:keeper model.fleet with
  | Some k when not (String.equal (String.trim k.company) "") -> k.company
  | Some _ | None ->
      Option.value ~default:"ungrouped"
        (Wire_fleet.classify_company_single ~group:None keeper)

(* Rich 4-Section Inspector Body — zero nested Card.draw (reused in Sandboxes tab & Sandbox Dive!) *)
let draw_sandbox_inspector_body ?(scroll = 0) ~grid ~(inner : Rect.t)
    ~(theme : Theme.t) ~bp ~lang ~(model : Model.t) (entry : fleet_sandbox_entry)
    =
  if Rect.is_empty inner then ()
  else
    let keeper = entry_keeper_name entry in
    let company = keeper_company_of ~model keeper in
    let pad_x = Layout.card_pad_x bp in
    let bg = Color.of_rgb theme.surface_1 in
    (* Section 1: Elevated Identity Header Band (surface_2, full-bleed on inner) *)
    let right_status, sub_line =
      match entry with
      | Entry_microvm g ->
          let sg, _, sl = socket_status_display g.agent_socket in
          let honest_presence =
            match g.agent_socket with
            | Wire_infra.Socket_absent _
              when model.infra.sandboxes_fallback_404
                   || String.equal g.presence "unobserved" ->
                Say.resolve lang
                  (Say.make ~ko:"미관측 (Legacy API)" ~en:"unobserved (Legacy API)")
            | Wire_infra.Socket_absent _ when String.equal g.presence "running" ->
                Say.resolve lang
                  (Say.make ~ko:"소켓 없음" ~en:"socket absent")
            | Wire_infra.Socket_present _
            | Wire_infra.Socket_absent _
            | Wire_infra.Socket_non_socket _
            | Wire_infra.Socket_unreadable _ ->
                g.presence
          in
          ( Printf.sprintf "%s %s · vm" (Glyph.to_utf8 sg) sl
          , Printf.sprintf "%s · %s · %s" company g.guest_name honest_presence )
      | Entry_ssh_bound (pool, _) ->
          let sg, sl, rtt_s =
            match pool.reachability with
            | Wire_infra.Ssh_reachable { rtt_ms; _ } ->
                ( Glyph.Live_healthy
                , "live"
                , " " ^ Format_val.format_value Format_val.Milliseconds rtt_ms )
            | Wire_infra.Ssh_unreachable _ -> (Glyph.Live_failing, "down", "")
            | Wire_infra.Ssh_probe_pending ->
                (Glyph.Transport_reconnecting, "probe", "")
          in
          ( Printf.sprintf "%s %s · ssh%s" (Glyph.to_utf8 sg) sl rtt_s
          , Printf.sprintf "%s · %s (%s)" company pool.pool_name pool.unix_user )
      | Entry_ssh_unbound u ->
          ( Printf.sprintf "%s %s · ssh"
              (Glyph.to_utf8 Glyph.Warning_triangle)
              u.binding_state
          , Printf.sprintf "%s · %s" company
              (Option.value ~default:"unbound" u.remote_endpoint) )
      | Entry_docker d ->
          ( Printf.sprintf "%s live · docker" (Glyph.to_utf8 Glyph.Live_healthy)
          , Printf.sprintf "%s · %s" company (network_mode_label d.network_mode)
          )
    in
    let band_h = if inner.h >= 8 then 2 else 1 in
    Card.draw_section_band ~pad_x grid
      ~rect:(Rect.make ~x:inner.x ~y:inner.y ~w:inner.w ~h:band_h)
      ~theme ~left_title:keeper ~right_meta:right_status
      ?subtitle:(if band_h >= 2 then Some sub_line else None)
      ();
    let content =
      Rect.make ~x:inner.x ~y:(inner.y + band_h) ~w:inner.w
        ~h:(Int.max 0 (inner.h - band_h))
      |> H.pad_content ~bp
    in
    if Rect.is_empty content then ()
    else
      let y = ref content.y in
      let bottom = Rect.bottom content in
      let key_w = if content.w >= 34 then 10 else 8 in
      let put_row ?value_style key value =
        if !y < bottom then begin
          H.put_kv ~grid ~clip:content ~x:content.x ~y:!y ~max_w:content.w
            ~theme ~key_w ~key ?value_style value;
          incr y
        end
      in
      (* Section 2: Resource & Connection Specs *)
      if !y < bottom then begin
        H.draw_divider ~grid ~rect:content ~y:!y ~theme
          ~label:
            (Say.resolve lang
               (Say.make ~ko:"리소스 · 연결 스펙" ~en:"Resource & Connection"))
          ();
        incr y
      end;
      (match entry with
       | Entry_microvm g ->
           put_row
             (Say.resolve lang (Say.make ~ko:"호스트/VM" ~en:"Host/VM"))
             (Printf.sprintf "%s (%s)" g.guest_name g.backend);
           let sg, st, sl = socket_status_display g.agent_socket in
           let sock_detail =
             match g.agent_socket with
             | Wire_infra.Socket_present { path_basename = Some b }
             | Wire_infra.Socket_absent { path_basename = Some b } ->
                 " · " ^ b
             | Wire_infra.Socket_present { path_basename = None }
             | Wire_infra.Socket_absent { path_basename = None } ->
                 ""
             | Wire_infra.Socket_non_socket { file_kind = Some fk } -> " · " ^ fk
             | Wire_infra.Socket_non_socket { file_kind = None } -> ""
             | Wire_infra.Socket_unreadable { detail = Some d } -> " · " ^ d
             | Wire_infra.Socket_unreadable { detail = None } -> ""
           in
           put_row
             ~value_style:(H.status_style ~theme st)
             (Say.resolve lang (Say.make ~ko:"소켓" ~en:"Socket"))
             (Printf.sprintf "%s %s%s" (Glyph.to_utf8 sg) sl sock_detail);
           let shg, sht, shl =
             shim_parity_display ~lang
               ~fallback_404:model.infra.sandboxes_fallback_404 g.shim_parity
           in
           put_row
             ~value_style:(H.status_style ~theme sht)
             (Say.resolve lang (Say.make ~ko:"심/패리티" ~en:"Shim"))
             (Printf.sprintf "%s %s" (Glyph.to_utf8 shg) shl);
           put_row
             (Say.resolve lang (Say.make ~ko:"네트워크" ~en:"Network"))
             (Printf.sprintf "%s · CPU %s · RAM %s MiB"
                (network_mode_label g.network_mode)
                (Format_val.format_observed Format_val.Count
                   (Observed.map float_of_int g.cpus)
                   ~lang)
                (Format_val.format_observed Format_val.Count
                   (Observed.map float_of_int g.memory_mib)
                   ~lang));
           let vol_style, vol_txt =
             match g.volume with
             | Wire_infra.Volume_declared name ->
                 ( H.status_style ~theme Theme.Status_ok
                 , Glyph.to_utf8 Glyph.Live_healthy ^ " " ^ name )
             | Wire_infra.Volume_invalid reason ->
                 ( H.status_style ~theme ~attrs:Attr.bold Theme.Status_attention
                 , Glyph.to_utf8 Glyph.Warning_triangle ^ " ext4: " ^ reason )
           in
           put_row ~value_style:vol_style
             (Say.resolve lang (Say.make ~ko:"볼륨" ~en:"Volume"))
             vol_txt
       | Entry_ssh_bound (pool, ks) ->
           put_row
             (Say.resolve lang (Say.make ~ko:"호스트/풀" ~en:"Host/Pool"))
             (Printf.sprintf "%s (%s:%d)" pool.pool_name pool.host pool.port);
           put_row
             (Say.resolve lang (Say.make ~ko:"네트워크" ~en:"Network"))
             "ssh";
           put_row
             (Say.resolve lang (Say.make ~ko:"계정" ~en:"Account"))
             (Printf.sprintf "%s · %s%s" pool.unix_user pool.remote_root
                (if pool.private_home then " (priv)" else ""));
           let r_style, r_txt =
             match pool.reachability with
             | Wire_infra.Ssh_reachable { rtt_ms; _ } ->
                 ( H.status_style ~theme Theme.Status_ok
                 , Printf.sprintf "%s reachable · %s"
                     (Glyph.to_utf8 Glyph.Live_healthy)
                     (Format_val.format_value Format_val.Milliseconds rtt_ms) )
             | Wire_infra.Ssh_unreachable { detail; _ } ->
                 ( H.status_style ~theme Theme.Status_critical
                 , Glyph.to_utf8 Glyph.Live_failing ^ " " ^ detail )
             | Wire_infra.Ssh_probe_pending ->
                 ( H.status_style ~theme Theme.Status_active
                 , Glyph.to_utf8 Glyph.Transport_reconnecting ^ " probing" )
           in
           put_row ~value_style:r_style "SSH" r_txt;
           if !y < bottom then begin
             let sess_lbl =
               Say.resolve lang (Say.make ~ko:"풀 세션" ~en:"Sessions")
             in
             let active_opt = Observed.to_option pool.active_sessions in
             let sess_txt =
               Printf.sprintf "%s/%d"
                 (Format_val.format_observed Format_val.Count
                    (Observed.map float_of_int pool.active_sessions)
                    ~lang)
                 pool.max_sessions
             in
             H.put_kv ~grid ~clip:content ~x:content.x ~y:!y ~max_w:content.w
               ~theme ~key_w ~key:sess_lbl sess_txt;
             (match active_opt with
              | Some a when pool.max_sessions > 0 && content.w >= 34 ->
                  let bw = 10 in
                  ignore
                    (Chart.draw_ratio_bar_run ~clip:content grid
                       ~x:(Rect.right content - bw) ~y:!y ~width:bw ~theme ~bg
                       ~unicode:true ~gradient:Chart.Gradient.Thermal
                       ~ratio:(float_of_int a /. float_of_int pool.max_sessions))
              | Some _ | None -> ());
             incr y
           end;
           let disp = H.json_kv_summary ks.last_dispatch in
           if disp <> [] then
             put_row
               (Say.resolve lang (Say.make ~ko:"최근 디스패치" ~en:"Dispatch"))
               (disp |> H.safe_take 3
               |> List.map (fun (k, v) -> k ^ "=" ^ v)
               |> String.concat " · ")
       | Entry_ssh_unbound u ->
           put_row
             (Say.resolve lang (Say.make ~ko:"백엔드" ~en:"Backend"))
             (u.backend ^ " (unbound)");
           put_row
             ~value_style:(H.status_style ~theme Theme.Status_attention)
             (Say.resolve lang (Say.make ~ko:"바인딩" ~en:"Binding"))
             u.binding_state;
           put_row
             (Say.resolve lang (Say.make ~ko:"네트워크" ~en:"Network"))
             "ssh";
           (match u.remote_endpoint with
            | Some ep ->
                put_row
                  (Say.resolve lang (Say.make ~ko:"엔드포인트" ~en:"Endpoint"))
                  ep
            | None -> ())
       | Entry_docker d ->
           put_row
             (Say.resolve lang (Say.make ~ko:"백엔드" ~en:"Backend"))
             d.backend;
           put_row
             (Say.resolve lang (Say.make ~ko:"네트워크" ~en:"Network"))
             (network_mode_label d.network_mode));
      (* Section 3: 24h Tool Execution Summary *)
      let m = entry_metrics entry in
      if !y < bottom then begin
        H.draw_divider ~grid ~rect:content ~y:!y ~theme
          ~label:
            (Say.resolve lang
               (Say.make ~ko:"24h 도구 실행 요약" ~en:"24h Tool Execution"))
          ();
        incr y
      end;
      if !y < bottom then begin
        let fail_rate =
          if m.calls > 0 then
            float_of_int m.failures /. float_of_int m.calls
          else 0.0
        in
        let fail_tone =
          if m.failures = 0 then Theme.Status_ok
          else if fail_rate >= 0.1 then Theme.Status_critical
          else Theme.Status_attention
        in
        let calls_s =
          Printf.sprintf "%d calls · %d fail (%.1f%%)" m.calls m.failures
            (fail_rate *. 100.0)
        in
        H.put_kv ~grid ~clip:content ~x:content.x ~y:!y ~max_w:content.w ~theme
          ~key_w
          ~key:(Say.resolve lang (Say.make ~ko:"호출/실패" ~en:"Calls/Fail"))
          ~value_style:(H.status_style ~theme fail_tone) calls_s;
        if m.calls > 0 && content.w >= 44 then begin
          let bw = 8 in
          ignore
            (Chart.draw_ratio_bar_run ~clip:content grid
               ~x:(Rect.right content - bw) ~y:!y ~width:bw ~theme ~bg
               ~unicode:true ~gradient:Chart.Gradient.Thermal ~ratio:fail_rate)
        end;
        incr y
      end;
      put_row
        (Say.resolve lang (Say.make ~ko:"지연시간" ~en:"Latency"))
        (Printf.sprintf "p50 %s · p95 %s · max %s"
           (Format_val.format_observed Format_val.Milliseconds m.p50_ms ~lang)
           (Format_val.format_observed Format_val.Milliseconds m.p95_ms ~lang)
           (Format_val.format_observed Format_val.Milliseconds m.max_ms ~lang));
      if !y < bottom then begin
        let fc = m.failure_classes in
        let buckets =
          [
            ("dep", fc.dependency_unavailable, Theme.Status_attention);
            ("rt", fc.runtime_failure, Theme.Status_critical);
            ("pol", fc.policy_rejection, Theme.Status_attention);
            ("wf", fc.workflow_rejection, Theme.Status_active);
            ("cancel", fc.operator_cancelled, Theme.Status_historical);
          ]
        in
        ignore
          (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y ~max_w:key_w
             ~style:(H.secondary_style ~theme ())
             (Say.resolve lang (Say.make ~ko:"오류 분류" ~en:"Failures")));
        let cx = ref (content.x + key_w + 1) in
        let right_e = Rect.right content in
        List.iteri
          (fun i (lbl, cnt, tone) ->
            if !cx < right_e then begin
              if i > 0 then begin
                let sep = " · " in
                let sw =
                  H.put_clipped ~grid ~clip:content ~x:!cx ~y:!y
                    ~max_w:(right_e - !cx)
                    ~style:(H.whisper_style ~theme ~italic:false ())
                    sep
                in
                cx := !cx + sw
              end;
              let st =
                if cnt > 0 then H.status_style ~theme ~attrs:Attr.bold tone
                else H.whisper_style ~theme ~italic:false ()
              in
              let adv =
                H.put_clipped ~grid ~clip:content ~x:!cx ~y:!y
                  ~max_w:(right_e - !cx) ~style:st
                  (Printf.sprintf "%s %d" lbl cnt)
              in
              cx := !cx + adv
            end)
          buckets;
        incr y
      end;
      (* Section 4: Recent Logs & Sandbox Events (fills remaining space — kills 70% void!) *)
      if !y < bottom then begin
        H.draw_divider ~grid ~rect:content ~y:!y ~theme
          ~label:
            (Say.resolve lang
               (Say.make ~ko:"최근 로그 · 이벤트" ~en:"Recent Logs & Events"))
          ();
        incr y
      end;
      let rem_rows = Int.max 0 (bottom - !y) in
      if rem_rows > 0 then begin
        let keeper_logs =
          List.filter
            (fun (e : Wire_infra.system_log_entry) ->
              match e.keeper with Some k -> String.equal k keeper | None -> false)
            model.infra.logs
        in
        let display_logs =
          if keeper_logs <> [] then keeper_logs
          else
            List.filter
              (fun (e : Wire_infra.system_log_entry) ->
                H.contains_ci ~needle:"sandbox" e.source
                || H.contains_ci ~needle:"vm" e.module_name
                || H.contains_ci ~needle:"ssh" e.module_name)
              model.infra.logs
        in
        let keeper_acts =
          List.filter
            (fun (ev : Infra_store.activity_row) ->
              match ev.keeper with Some k -> String.equal k keeper | None -> false)
            model.infra.activity_events
        in
        if display_logs = [] && keeper_acts = [] then begin
          let empty_box =
            Rect.make ~x:content.x ~y:!y ~w:content.w ~h:rem_rows
          in
          Card.draw_left_rail ~bg ~color:theme.border_inactive grid
            ~x:empty_box.x ~y:empty_box.y ~h:(Int.min 2 rem_rows) ~theme;
          ignore
            (H.put_clipped ~grid ~clip:empty_box ~x:(empty_box.x + 2)
               ~y:empty_box.y ~max_w:(Int.max 0 (empty_box.w - 2))
               ~style:(H.whisper_style ~theme ())
               (Say.resolve lang
                  (Say.make ~ko:"최근 24h 샌드박스 오류/이벤트 없음"
                     ~en:"No sandbox errors or events in last 24h")));
          if rem_rows >= 2 then
            ignore
              (H.put_clipped ~grid ~clip:empty_box ~x:(empty_box.x + 2)
                 ~y:(empty_box.y + 1) ~max_w:(Int.max 0 (empty_box.w - 2))
                 ~style:(H.whisper_style ~theme ())
                 (Say.resolve lang
                    (Say.make ~ko:"[Enter/z] 확대 보기" ~en:"[Enter/z] Zoom")))
        end
        else begin
          let log_bg_rgb = theme.surface_0 in
          let log_bg = Color.of_rgb log_bg_rgb in
          let box = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:rem_rows in
          Cell_grid.fill_rect ~clip:content grid ~rect:box
            ~style:(H.whisper_style ~theme ~bg:log_bg_rgb ()) ();
          let combined =
            List.map (fun e -> `Log e) display_logs
            @ List.map (fun ev -> `Act ev) keeper_acts
          in
          let skip =
            Int.min
              (Int.max 0 (List.length combined - rem_rows))
              (Int.max 0 scroll)
          in
          let ly = ref !y in
          List.iter
            (function
              | `Log (e : Wire_infra.system_log_entry) ->
                  if !ly < bottom then begin
                    let lvl_s, tone = log_level_badge e.level in
                    Card.draw_left_rail ~bg:log_bg ~tone grid ~x:box.x ~y:!ly
                      ~h:1 ~theme;
                    let ts =
                      H.format_local_hhmmss ~tz_offset_sec:model.tz_offset_sec
                        e.ts
                    in
                    let x_ts = box.x + 2 in
                    let tw =
                      H.put_clipped ~grid ~clip:box ~x:x_ts ~y:!ly ~max_w:8
                        ~style:(H.whisper_style ~theme ~bg:log_bg_rgb ())
                        ts
                    in
                    let x_lvl = x_ts + tw + 1 in
                    let lw =
                      H.put_clipped ~grid ~clip:box ~x:x_lvl ~y:!ly ~max_w:4
                        ~style:
                          (H.status_style ~theme ~bg:log_bg_rgb ~attrs:Attr.bold
                             tone)
                        lvl_s
                    in
                    let x_msg = x_lvl + lw + 1 in
                    let msg_w = Int.max 0 (Rect.right box - x_msg - 1) in
                    ignore
                      (H.put_clipped ~grid ~clip:box ~x:x_msg ~y:!ly ~max_w:msg_w
                         ~style:(H.text_style ~theme ~bg:log_bg_rgb ())
                         (H.sanitize_single_line e.message));
                    incr ly
                  end
              | `Act (ev : Infra_store.activity_row) ->
                  if !ly < bottom then begin
                    Card.draw_left_rail ~bg:log_bg ~tone:Theme.Status_active grid
                      ~x:box.x ~y:!ly ~h:1 ~theme;
                    let age =
                      H.format_age ~now_unix:model.freshness.last_wall_unix
                        ev.at_unix
                    in
                    let aw =
                      H.put_clipped ~grid ~clip:box ~x:(box.x + 2) ~y:!ly
                        ~max_w:7
                        ~style:(H.whisper_style ~theme ~bg:log_bg_rgb ())
                        age
                    in
                    ignore
                      (H.put_clipped ~grid ~clip:box ~x:(box.x + 3 + aw) ~y:!ly
                         ~max_w:(Int.max 0 (Rect.right box - (box.x + 4 + aw)))
                         ~style:(H.secondary_style ~theme ~bg:log_bg_rgb ())
                         ev.summary);
                    incr ly
                  end)
            (Store_scroll.drop skip combined |> H.safe_take rem_rows)
        end
      end

let json_of_metrics (m : Wire_infra.tool_metrics_24h) : Yojson.Safe.t =
  let opt_float obs =
    match Observed.to_option obs with Some f -> `Float f | None -> `Null
  in
  let fc = m.failure_classes in
  `Assoc
    [
      ("calls", `Int m.calls);
      ("failures", `Int m.failures);
      ("failure_unclassified", `Int m.failure_unclassified);
      ("p50_ms", opt_float m.p50_ms);
      ("p95_ms", opt_float m.p95_ms);
      ("max_ms", opt_float m.max_ms);
      ( "failure_classes"
      , `Assoc
          [
            ("dependency_unavailable", `Int fc.dependency_unavailable);
            ("runtime_failure", `Int fc.runtime_failure);
            ("policy_rejection", `Int fc.policy_rejection);
            ("workflow_rejection", `Int fc.workflow_rejection);
            ("operator_cancelled", `Int fc.operator_cancelled);
          ] );
    ]

let json_of_sandbox_entry = function
  | Entry_microvm g ->
      let _, _, sock_s = socket_status_display g.agent_socket in
      let _, _, shim_s = shim_parity_display g.shim_parity in
      let vol_s =
        match g.volume with
        | Wire_infra.Volume_declared v -> v
        | Wire_infra.Volume_invalid err -> "invalid: " ^ err
      in
      `Assoc
        [
          ("keeper", `String g.keeper);
          ("backend", `String g.backend);
          ("guest_name", `String g.guest_name);
          ("presence", `String g.presence);
          ("socket", `String sock_s);
          ("shim_parity", `String shim_s);
          ("network_mode", `String (network_mode_label g.network_mode));
          ("volume", `String vol_s);
          ("metrics_24h", json_of_metrics g.metrics_24h);
        ]
  | Entry_ssh_bound (p, ks) ->
      `Assoc
        [
          ("keeper", `String ks.keeper);
          ("pool", `String p.pool_name);
          ("host", `String p.host);
          ("port", `Int p.port);
          ("unix_user", `String p.unix_user);
          ("remote_root", `String p.remote_root);
          ("last_dispatch", ks.last_dispatch);
          ("metrics_24h", json_of_metrics ks.metrics_24h);
        ]
  | Entry_ssh_unbound u ->
      `Assoc
        [
          ("keeper", `String u.keeper);
          ("backend", `String u.backend);
          ("binding_state", `String u.binding_state);
          ( "remote_endpoint"
          , match u.remote_endpoint with Some ep -> `String ep | None -> `Null );
          ("metrics_24h", json_of_metrics u.metrics_24h);
        ]
  | Entry_docker d ->
      `Assoc
        [
          ("keeper", `String d.keeper);
          ("backend", `String d.backend);
          ("network_mode", `String (network_mode_label d.network_mode));
          ("metrics_24h", json_of_metrics d.metrics_24h);
        ]

let entry_of_keeper_detail ~(sandboxes : Wire_infra.sandboxes_snapshot option)
    (detail : Wire_infra.keeper_sandbox_detail) : fleet_sandbox_entry =
  match detail with
  | Wire_infra.Sandbox_microvm g -> Entry_microvm g
  | Wire_infra.Sandbox_ssh_unbound u -> Entry_ssh_unbound u
  | Wire_infra.Sandbox_docker d -> Entry_docker d
  | Wire_infra.Sandbox_ssh_keeper { session = ks; pool = embedded_pool } -> (
      let pool_opt =
        match embedded_pool with
        | Some _ as p -> p
        | None -> (
            match sandboxes with
            | Some s ->
                List.find_opt
                  (fun (p : Wire_infra.ssh_pool) ->
                    List.exists
                      (fun (s_ks : Wire_infra.ssh_keeper_session) ->
                        String.equal s_ks.keeper ks.keeper)
                      p.keeper_sessions)
                  s.ssh_pools
            | None -> None)
      in
      match pool_opt with
      | Some p -> Entry_ssh_bound (p, ks)
      | None ->
          let fallback_pool : Wire_infra.ssh_pool =
            {
              pool_name = "remote_ssh";
              host = "remote";
              port = 22;
              unix_user = ks.keeper;
              remote_root = "/";
              private_home = false;
              max_sessions = 1;
              active_sessions = Observed.unreported;
              reachability = Wire_infra.Ssh_probe_pending;
              accounts = [];
              keeper_sessions = [ ks ];
              metrics_24h = ks.metrics_24h;
            }
          in
          Entry_ssh_bound (fallback_pool, ks))

let draw_sandbox_inspector ?(scroll = 0) ~grid ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp ~lang ~(model : Model.t)
    (entry_opt : fleet_sandbox_entry option)
    (obs : Wire_infra.sandboxes_snapshot Observed.t) ~focused =
  let inf = model.infra in
  let resolved_entry_opt =
    match entry_opt with
    | None -> None
    | Some fallback -> (
        let keeper = entry_keeper_name fallback in
        match Observed.to_option (Infra_store.keeper_sandbox_for ~keeper inf) with
        | Some resp ->
            Some
              (entry_of_keeper_detail
                 ~sandboxes:(Observed.to_option inf.sandboxes)
                 resp.sandbox)
        | None -> Some fallback)
  in
  let subtitle = Option.map entry_keeper_name resolved_entry_opt in
  let badge =
    if focused || inf.show_raw_json then
      Some
        (H.make_badge
           ~tone:
             (if inf.show_raw_json then Theme.Status_active
              else Theme.Status_historical)
           (if inf.show_raw_json then "[Space] Json_tree ON"
            else "[Space] Json_tree"))
    else None
  in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ?subtitle ?badge ~focused
         ~hotkey:
           (Say.resolve lang
              (Say.make ~ko:"[Enter/z] 확대 · [p] 프로브"
                 ~en:"[Enter/z] Zoom · [p] Probe"))
         (Say.resolve lang (Say.make ~ko:"샌드박스 인스펙터" ~en:"Sandbox Inspector")))
  in
  if Rect.is_empty inner then ()
  else
    match resolved_entry_opt with
    | None ->
        H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp inner) ~theme
          ~lang obs
    | Some entry ->
        if inf.show_raw_json then
          let lines =
            Json_tree.flatten ~max_depth:5 ~redact_secrets:true
              (json_of_sandbox_entry entry)
          in
          ignore
            (Json_tree.draw grid ~rect:(H.pad_content ~bp inner) ~theme ~scroll
               lines)
        else if
          model.nav.zoomed && Model.can_zoom_current_view model && inner.h >= 10
        then begin
          let top_rect, body_rect =
            match Layout.split_v inner [ Layout.Fixed 3; Layout.Flex 1 ] with
            | [ a; b ] -> (a, b)
            | _ -> (inner, Rect.empty)
          in
          let metrics = entry_metrics entry in
          let fc = metrics.failure_classes in
          let err_spec : Chart.Spec.t =
            {
              title =
                Say.make ~ko:"24h 도구 오류 분류" ~en:"24h Tool Failure Classes";
              hotkey_hint = None;
              kind =
                Chart.Spec.Stacked_bar
                  {
                    segments =
                      [
                        ( Say.literal "dep"
                        , float_of_int fc.dependency_unavailable
                        , Theme.Status_historical );
                        ( Say.literal "runtime"
                        , float_of_int fc.runtime_failure
                        , Theme.Status_critical );
                        ( Say.literal "policy"
                        , float_of_int fc.policy_rejection
                        , Theme.Status_attention );
                        ( Say.literal "workflow"
                        , float_of_int fc.workflow_rejection
                        , Theme.Status_active );
                      ];
                    total_label = Say.make ~ko:"24h 실패" ~en:"24h Failures";
                    unit = Format_val.Count;
                  };
            }
          in
          ignore
            (Chart.draw grid ~rect:(H.pad_content ~bp top_rect) ~theme
               ~caps:H.default_caps ~lang ~show_title:false err_spec);
          draw_sandbox_inspector_body ~scroll ~grid ~inner:body_rect ~theme ~bp
            ~lang ~model entry
        end
        else
          draw_sandbox_inspector_body ~scroll ~grid ~inner ~theme ~bp ~lang ~model
            entry

let render_sandboxes ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let inf = model.infra in
  let zoomed = model.nav.zoomed && Model.can_zoom_current_view model in
  let top_h = if H.is_wide_split rect then 6 else 4 in
  let top_rect, body_rect =
    if zoomed then (Rect.empty, rect)
    else
      match Layout.split_v_bp bp rect [ Layout.Fixed top_h; Layout.Flex 1 ] with
      | [ a; b ] -> (a, b)
      | _ -> (Rect.empty, rect)
  in
  (* Top 3 Peer Summary Cards *)
  (match inf.sandboxes with
   | Observed.Value { data = snap; _ } ->
       let invalid_vols =
         List.filter
           (fun (g : Wire_infra.microvm_guest) -> volume_is_invalid g.volume)
           snap.microvm_guests
       in
       if H.is_wide_split top_rect then begin
         let c1, c2, c3 =
           match
             Layout.split_h_bp bp top_rect
               [ Layout.Flex 1; Layout.Flex 1; Layout.Flex 1 ]
           with
           | [ a; b; c ] -> (a, b, c)
           | _ -> (top_rect, Rect.empty, Rect.empty)
         in
         (* Card 1: apple_container microVM Fleet *)
         let has_shim_unavail =
           List.exists
             (fun (g : Wire_infra.microvm_guest) ->
               match g.shim_parity with
               | Wire_infra.Shim_unavailable _ -> true
               | Wire_infra.Shim_matched _
               | Wire_infra.Shim_mismatch _
               | Wire_infra.Shim_undeclared ->
                   false)
             snap.microvm_guests
         in
         let has_shim_matched =
           List.exists
             (fun (g : Wire_infra.microvm_guest) ->
               match g.shim_parity with
               | Wire_infra.Shim_matched _ -> true
               | Wire_infra.Shim_mismatch _
               | Wire_infra.Shim_undeclared
               | Wire_infra.Shim_unavailable _ ->
                   false)
             snap.microvm_guests
         in
         let all_shim_undeclared =
           snap.microvm_guests <> []
           && List.for_all
                (fun (g : Wire_infra.microvm_guest) ->
                  match g.shim_parity with
                  | Wire_infra.Shim_undeclared -> true
                  | Wire_infra.Shim_matched _
                  | Wire_infra.Shim_mismatch _
                  | Wire_infra.Shim_unavailable _ ->
                      false)
                snap.microvm_guests
         in
         let shim_badge =
           if snap.microvm_shim_mismatch > 0 then
             H.make_badge ~glyph:Glyph.Warning_triangle
               ~tone:Theme.Status_attention
               (Printf.sprintf "%d mismatch" snap.microvm_shim_mismatch)
           else if has_shim_unavail then
             H.make_badge ~glyph:Glyph.Live_failing ~tone:Theme.Status_critical
               (Say.resolve lang (Say.make ~ko:"심 불가" ~en:"shim unavail"))
           else if inf.sandboxes_fallback_404 || all_shim_undeclared then
             H.make_badge ~glyph:Glyph.Missing_absent
               ~tone:Theme.Status_historical
               (Say.resolve lang
                  (if inf.sandboxes_fallback_404 then
                     Say.make ~ko:"심 미보고 (Legacy API)"
                       ~en:"shim unreported (Legacy API)"
                   else Say.make ~ko:"심 미보고" ~en:"shim unreported"))
           else if has_shim_matched then
             H.make_badge ~glyph:Glyph.Check_mark ~tone:Theme.Status_ok
               (Say.resolve lang (Say.make ~ko:"심 일치" ~en:"shim match"))
           else
             H.make_badge ~glyph:Glyph.Missing_absent
               ~tone:Theme.Status_historical
               (Say.resolve lang (Say.make ~ko:"심 미보고" ~en:"shim unreported"))
         in
         let i1 =
           Card.draw ~cache grid ~rect:c1 ~theme
             (H.card_spec ~badge:shim_badge
                (Printf.sprintf "apple_container (%d)" snap.microvm_declared))
           |> H.pad_content ~bp
         in
         if not (Rect.is_empty i1) then begin
           let y = ref i1.y and bot = Rect.bottom i1 in
           let bg = Color.of_rgb theme.surface_1 in
           if !y < bot then begin
             let run_glyph =
               if snap.microvm_running > 0 then Glyph.Live_healthy
               else Glyph.Live_idle
             in
             let run_txt =
               Printf.sprintf "%s %d/%d running · %d .sock"
                 (Glyph.to_utf8 run_glyph) snap.microvm_running
                 snap.microvm_declared snap.microvm_sockets_present
             in
             let run_style =
               if snap.microvm_running > 0 then H.anchor_style ~theme ()
               else H.secondary_style ~theme ()
             in
             let bw = if i1.w >= 34 && snap.microvm_declared > 0 then 6 else 0 in
             ignore
               (H.put_clipped ~grid ~clip:i1 ~x:i1.x ~y:!y
                  ~max_w:(i1.w - if bw > 0 then bw + 1 else 0)
                  ~style:run_style run_txt);
             if bw > 0 then
               ignore
                 (Chart.draw_ratio_bar_run ~clip:i1 grid
                    ~x:(Rect.right i1 - bw) ~y:!y ~width:bw ~theme ~bg
                    ~unicode:true ~gradient:Chart.Gradient.Efficiency
                    ~ratio:
                      (float_of_int snap.microvm_running
                      /. float_of_int snap.microvm_declared));
             incr y
           end;
           if !y < bot then begin
             let vt, vg, vtxt =
               if inf.sandboxes_fallback_404 then
                 ( Theme.Status_historical
                 , Glyph.Missing_absent
                 , Say.resolve lang
                     (Say.make ~ko:"소켓·심 미관측 (Legacy API)"
                        ~en:"sockets/shim unobserved (Legacy API)") )
               else if invalid_vols = [] then
                 ( Theme.Status_ok
                 , Glyph.Live_healthy
                 , Say.resolve lang
                     (Say.make ~ko:"ext4 볼륨 정상" ~en:"ext4 volumes clean") )
               else
                 let names =
                   invalid_vols
                   |> List.map (fun (g : Wire_infra.microvm_guest) -> g.keeper)
                   |> H.safe_take 2 |> String.concat ", "
                 in
                 ( Theme.Status_attention
                 , Glyph.Warning_triangle
                 , Printf.sprintf "%d ext4: %s" (List.length invalid_vols) names )
             in
             ignore
               (H.put_clipped ~grid ~clip:i1 ~x:i1.x ~y:!y ~max_w:i1.w
                  ~style:(H.status_style ~theme vt)
                  (Glyph.to_utf8 vg ^ " " ^ vtxt));
             incr y
           end;
           if !y < bot then begin
             let net_inh =
               List.fold_left
                 (fun acc (g : Wire_infra.microvm_guest) ->
                   match g.network_mode with
                   | Wire_infra.Net_inherit -> acc + 1
                   | Wire_infra.Net_none | Wire_infra.Net_policy -> acc)
                 0 snap.microvm_guests
             in
             let net_none = Int.max 0 (snap.microvm_declared - net_inh) in
             ignore
               (H.put_clipped ~grid ~clip:i1 ~x:i1.x ~y:!y ~max_w:i1.w
                  ~style:(H.whisper_style ~theme ())
                  (Printf.sprintf "Net: %d inherit · %d isolated" net_inh
                     net_none))
           end
         end;
         (* Card 2: remote_ssh Shared Pools — real observed RTT, ZERO synthetic sparklines *)
         let ssh_badge =
           if snap.ssh_unbound_keepers_count > 0 then
             H.make_badge ~glyph:Glyph.Warning_triangle
               ~tone:Theme.Status_attention
               (Printf.sprintf "%d unbound" snap.ssh_unbound_keepers_count)
           else
             H.make_badge ~glyph:Glyph.Live_healthy ~tone:Theme.Status_ok
               (Printf.sprintf "%d pools" snap.ssh_pools_count)
         in
         let i2 =
           Card.draw ~cache grid ~rect:c2 ~theme
             (H.card_spec ~badge:ssh_badge
                (Printf.sprintf "remote_ssh Pools (%d)" snap.ssh_keepers_count))
           |> H.pad_content ~bp
         in
         if not (Rect.is_empty i2) then begin
           let y = ref i2.y and bot = Rect.bottom i2 in
           let bg = Color.of_rgb theme.surface_1 in
           List.iter
             (fun (p : Wire_infra.ssh_pool) ->
               if !y < bot then begin
                 let rg, rt_tok, rtt_s =
                   match p.reachability with
                   | Wire_infra.Ssh_reachable { rtt_ms; _ } ->
                       ( Glyph.Live_healthy
                       , Theme.Status_ok
                       , Format_val.format_value Format_val.Milliseconds rtt_ms )
                   | Wire_infra.Ssh_unreachable _ ->
                       (Glyph.Live_failing, Theme.Status_critical, "down")
                   | Wire_infra.Ssh_probe_pending ->
                       (Glyph.Transport_reconnecting, Theme.Status_active, "probe")
                 in
                 let sess_s =
                   Printf.sprintf "%s/%d"
                     (Format_val.format_observed Format_val.Count
                        (Observed.map float_of_int p.active_sessions)
                        ~lang)
                     p.max_sessions
                 in
                 let sess_ratio_opt =
                   match Observed.to_option p.active_sessions with
                   | Some active when p.max_sessions > 0 ->
                       Some (float_of_int active /. float_of_int p.max_sessions)
                   | Some _ | None -> None
                 in
                 let bar_w =
                   if i2.w >= 34 && Option.is_some sess_ratio_opt then 5 else 0
                 in
                 let stats_txt = Printf.sprintf "%s %s" rtt_s sess_s in
                 let stats_w = Grapheme.display_width stats_txt in
                 let right_block =
                   stats_w + if bar_w > 0 then bar_w + 1 else 0
                 in
                 let name_w = Int.max 6 (i2.w - right_block - 1) in
                 ignore
                   (H.put_clipped ~grid ~clip:i2 ~x:i2.x ~y:!y ~max_w:name_w
                      ~style:(H.status_style ~theme rt_tok)
                      (Printf.sprintf "%s %s" (Glyph.to_utf8 rg) p.pool_name));
                 let stats_x = Rect.right i2 - right_block in
                 ignore
                   (H.put_clipped ~grid ~clip:i2 ~x:stats_x ~y:!y ~max_w:stats_w
                      ~style:(H.anchor_style ~theme ()) stats_txt);
                 (match sess_ratio_opt with
                  | Some ratio when bar_w > 0 ->
                      ignore
                        (Chart.draw_ratio_bar_run ~clip:i2 grid
                           ~x:(Rect.right i2 - bar_w) ~y:!y ~width:bar_w ~theme
                           ~bg ~unicode:true ~gradient:Chart.Gradient.Thermal
                           ~ratio)
                  | Some _ | None -> ());
                 incr y;
                 if !y < bot then begin
                   ignore
                     (H.put_clipped ~grid ~clip:i2 ~x:i2.x ~y:!y ~max_w:i2.w
                        ~style:(H.whisper_style ~theme ())
                        (Printf.sprintf "  %s:%d · %s (%d accts)" p.host p.port
                           p.unix_user (List.length p.accounts)));
                   incr y
                 end
               end)
             (H.safe_take 2 snap.ssh_pools);
           if snap.ssh_unbound_keepers_count > 0 && !y < bot then
             ignore
               (H.put_clipped ~grid ~clip:i2 ~x:i2.x ~y:!y ~max_w:i2.w
                  ~style:(H.status_style ~theme Theme.Status_attention)
                  (Printf.sprintf "%s %d unbound keepers"
                     (Glyph.to_utf8 Glyph.Warning_triangle)
                     snap.ssh_unbound_keepers_count))
         end;
         (* Card 3: Host Storage & 24h Errors *)
         let i3 =
           Card.draw ~cache grid ~rect:c3 ~theme
             (H.card_spec
                (Say.resolve lang
                   (Say.make ~ko:"호스트 스토리지 · 24h 오류"
                      ~en:"Host Storage & 24h Errors")))
           |> H.pad_content ~bp
         in
         if not (Rect.is_empty i3) then begin
           let y = ref i3.y and bot = Rect.bottom i3 in
           if !y < bot then begin
             let storage_s =
               match snap.host_storage with
               | Some j ->
                   let kvs = H.json_kv_summary j in
                   if kvs = [] then Glyph.to_utf8 Glyph.Missing_absent
                   else
                     kvs |> H.safe_take 2
                     |> List.map (fun (k, v) -> k ^ ": " ^ v)
                     |> String.concat " · "
               | None ->
                   Say.resolve lang
                     (Say.make ~ko:"스토리지: 미보고" ~en:"Storage: Unreported")
             in
             ignore
               (H.put_clipped ~grid ~clip:i3 ~x:i3.x ~y:!y ~max_w:i3.w
                  ~style:(H.text_style ~theme ()) storage_s);
             incr y
           end;
           if !y < bot then begin
             let gc_s =
               match snap.volume_gc_report with
               | Some j ->
                   let kvs = H.json_kv_summary j in
                   if kvs = [] then "GC: ok"
                   else
                     "GC "
                     ^ (kvs |> H.safe_take 2
                       |> List.map (fun (k, v) -> k ^ "=" ^ v)
                       |> String.concat " ")
               | None ->
                   Printf.sprintf "Docker: %d keepers" snap.docker_keepers_count
             in
             ignore
               (H.put_clipped ~grid ~clip:i3 ~x:i3.x ~y:!y ~max_w:i3.w
                  ~style:(H.secondary_style ~theme ()) gc_s);
             incr y
           end;
           if !y < bot then begin
             let fc = snap.fleet_metrics_24h.failure_classes in
             let has_err =
               fc.dependency_unavailable > 0
               || fc.runtime_failure > 0
               || fc.policy_rejection > 0
             in
             let style =
               if has_err then H.status_style ~theme Theme.Status_attention
               else H.whisper_style ~theme ()
             in
             ignore
               (H.put_clipped ~grid ~clip:i3 ~x:i3.x ~y:!y ~max_w:i3.w ~style
                  (Printf.sprintf "24h Fail: dep %d · rt %d · pol %d"
                     fc.dependency_unavailable fc.runtime_failure
                     fc.policy_rejection));
             incr y
           end;
           if snap.unobserved_reasons <> [] && !y < bot then
             ignore
               (H.put_clipped ~grid ~clip:i3 ~x:i3.x ~y:!y ~max_w:i3.w
                  ~style:(H.whisper_style ~theme ())
                  (Printf.sprintf "Unobserved: %d scopes"
                     (List.length snap.unobserved_reasons)))
         end
       end
       else begin
         (* Compact Pools summary card *)
         let ci =
           Card.draw ~cache grid ~rect:top_rect ~theme
             (H.card_spec
                (Say.resolve lang
                   (Say.make ~ko:"샌드박스 풀 요약" ~en:"Sandbox Pools")))
           |> H.pad_content ~bp
         in
         if not (Rect.is_empty ci) then begin
           let y = ref ci.y and bot = Rect.bottom ci in
           if !y < bot then begin
             let ext4_s =
               let n = List.length invalid_vols in
               if n = 0 then
                 Say.resolve lang (Say.make ~ko:"ext4 정상" ~en:"ext4 ok")
               else
                 Say.resolve lang
                   (Say.make
                      ~ko:(Printf.sprintf "ext4 오류 %d" n)
                      ~en:(Printf.sprintf "ext4 err %d" n))
             in
             ignore
               (H.put_clipped ~grid ~clip:ci ~x:ci.x ~y:!y ~max_w:ci.w
                  ~style:(H.text_style ~theme ())
                  (Printf.sprintf "microVM: %d/%d live · .sock %d · shim mis %d · %s"
                     snap.microvm_running snap.microvm_declared
                     snap.microvm_sockets_present snap.microvm_shim_mismatch
                     ext4_s));
             incr y
           end;
           if !y < bot then begin
             let pool_tokens =
               List.map
                 (fun (p : Wire_infra.ssh_pool) ->
                   let rtt =
                     match p.reachability with
                     | Wire_infra.Ssh_reachable { rtt_ms; _ } ->
                         Format_val.format_value Format_val.Milliseconds rtt_ms
                     | Wire_infra.Ssh_unreachable _ -> "down"
                     | Wire_infra.Ssh_probe_pending -> "probe"
                   in
                   Printf.sprintf "%s(%s)" p.pool_name rtt)
                 snap.ssh_pools
             in
             let prefix =
               Printf.sprintf "SSH(%d/%d): " snap.ssh_keepers_count
                 snap.ssh_unbound_keepers_count
             in
             let suffix = Printf.sprintf " · Docker %d" snap.docker_keepers_count in
             let pools_s =
               if pool_tokens = [] then Glyph.to_utf8 Glyph.Missing_absent
               else String.concat " · " pool_tokens
             in
             ignore
               (H.put_clipped ~grid ~clip:ci ~x:ci.x ~y:!y ~max_w:ci.w
                  ~style:(H.secondary_style ~theme ())
                  (prefix ^ pools_s ^ suffix))
           end
         end
       end
   | ( Observed.Loading _
     | Observed.Absent
     | Observed.Unreported
     | Observed.Failed _ ) as obs ->
       let ci =
         Card.draw ~cache grid ~rect:top_rect ~theme
           (H.card_spec
              (Say.resolve lang (Say.make ~ko:"샌드박스 풀" ~en:"Sandbox Pools")))
         |> H.pad_content ~bp
       in
       H.draw_observed_placeholder ~grid ~rect:ci ~theme ~lang obs);
  (* Bottom Main Split: 58% Left 8-Column Fleet Table / 42% Right 4-Section Inspector *)
  let all_entries =
    match Observed.to_option inf.sandboxes with
    | Some s -> fleet_entries_of_snapshot s
    | None -> []
  in
  let filter_q = String.trim inf.filter_query in
  let entries =
    if String.equal filter_q "" then all_entries
    else
      List.filter
        (fun e -> H.contains_ci ~needle:filter_q (entry_search_haystack e))
        all_entries
  in
  let sel_entry =
    List.nth_opt entries (H.clamp_index (List.length entries) inf.selected_index)
  in
  let tbl_rect, insp_rect =
    if zoomed then (Rect.empty, body_rect)
    else if H.is_wide_split body_rect then
      match
        Layout.split_h_bp bp body_rect [ Layout.Ratio 0.60; Layout.Flex 1 ]
      with
      | [ l; r ] -> (l, r)
      | _ -> (body_rect, Rect.empty)
    else (body_rect, Rect.empty)
  in
  let tbl_inner =
    Card.draw ~cache grid ~rect:tbl_rect ~theme
      (H.card_spec ~focused:(Model.pane_focused model 0)
         ~hotkey:(Say.resolve lang (Say.make ~ko:"[Enter/z] 확대" ~en:"[Enter/z] Zoom"))
         (Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "키퍼 샌드박스 플릿 (%d)" (List.length entries))
               ~en:(Printf.sprintf "Keeper Sandbox Fleet (%d)" (List.length entries)))))
  in
  if not (Rect.is_empty tbl_inner) then begin
    if entries = [] && not (String.equal filter_q "") && all_entries <> [] then
      H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp tbl_inner) ~theme
        (Say.resolve lang
           (Say.make ~ko:"필터에 일치하는 샌드박스 없음"
              ~en:"No sandboxes match filter"))
    else if entries = [] then
      H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp tbl_inner)
        ~theme ~lang inf.sandboxes
    else
      (* FIXED CANONICAL 8-COLUMN SCHEMA: ZERO pool-in-network or user-in-shim corruption! *)
      let columns : Table.column list =
        [
          {
            id = "keeper";
            header = Say.make ~ko:"키퍼" ~en:"Keeper";
            priority = 0;
            min_width = 12;
            max_width = None;
            weight = 3;
            align = Table.Left;
          };
          {
            id = "backend";
            header = Say.make ~ko:"백엔드" ~en:"Backend";
            priority = 1;
            min_width = 6;
            max_width = Some 7;
            weight = 1;
            align = Table.Left;
          };
          {
            id = "status";
            header = Say.make ~ko:"상태" ~en:"State";
            priority = 0;
            min_width = 7;
            max_width = Some 10;
            weight = 1;
            align = Table.Left;
          };
          {
            id = "rtt";
            header = Say.make ~ko:"RTT" ~en:"RTT";
            priority = 2;
            min_width = 6;
            max_width = Some 7;
            weight = 1;
            align = Table.Right;
          };
          {
            id = "host_pool";
            header = Say.make ~ko:"호스트/풀" ~en:"Host/Pool";
            priority = 1;
            min_width = 10;
            max_width = Some 20;
            weight = 2;
            align = Table.Left;
          };
          {
            id = "network";
            header = Say.make ~ko:"네트워크" ~en:"Net";
            priority = 3;
            min_width = 8;
            max_width = Some 9;
            weight = 1;
            align = Table.Left;
          };
          {
            id = "shim_acct";
            header = Say.make ~ko:"심/계정" ~en:"Shim/Acct";
            priority = 2;
            min_width = 9;
            max_width = Some 13;
            weight = 2;
            align = Table.Left;
          };
          {
            id = "fail24";
            header = Say.make ~ko:"24h 실패" ~en:"24h Fail";
            priority = 1;
            min_width = 8;
            max_width = Some 9;
            weight = 1;
            align = Table.Right;
          };
        ]
      in
      let fail_cell (m : Wire_infra.tool_metrics_24h) =
        let txt = format_metrics_fail m in
        if m.failures <= 0 then
          Table.text_cell ~fg:(Color.of_rgb theme.text_muted) txt
        else
          let rate =
            if m.calls > 0 then float_of_int m.failures /. float_of_int m.calls
            else 1.0
          in
          let fg =
            if rate >= 0.1 then Color.of_rgb theme.status_critical
            else Color.of_rgb theme.status_attention
          in
          Table.text_cell ~fg ~attrs:Attr.bold txt
      in
      let rows =
        List.map
          (fun entry ->
            match entry with
            | Entry_microvm g ->
                let sg, st, sl = socket_status_display g.agent_socket in
                let host_pool =
                  if String.equal (String.trim g.guest_name) "" then "local-vm"
                  else g.guest_name
                in
                let shim_cell =
                  if volume_is_invalid g.volume then
                    Table.Badge
                      {
                        glyph = Some Glyph.Warning_triangle;
                        text = "ext4";
                        tone = Theme.Status_attention;
                      }
                  else
                    let shg, sht, shl = shim_compact_badge ~lang g.shim_parity in
                    Table.Badge { glyph = Some shg; text = shl; tone = sht }
                in
                {
                  Table.id = g.keeper;
                  cells =
                    [
                      ("keeper", Table.text_cell g.keeper);
                      ( "backend"
                      , Table.Badge
                          { glyph = None; text = "vm"; tone = Theme.Status_active }
                      );
                      ( "status"
                      , Table.Badge { glyph = Some sg; text = sl; tone = st } );
                      ( "rtt"
                      , Table.text_cell
                          ~fg:
                            (Color.of_rgb
                               (if Observed.is_value g.metrics_24h.p50_ms then
                                  theme.text_primary
                                else theme.text_muted))
                          (Format_val.format_observed Format_val.Milliseconds
                             g.metrics_24h.p50_ms ~lang) );
                      ("host_pool", Table.text_cell host_pool);
                      ( "network"
                      , Table.text_cell (network_mode_label g.network_mode) );
                      ("shim_acct", shim_cell);
                      ("fail24", fail_cell g.metrics_24h);
                    ];
                }
            | Entry_ssh_bound (pool, ks) ->
                let rg, rt_tok, st_lbl, rtt_s =
                  match pool.reachability with
                  | Wire_infra.Ssh_reachable { rtt_ms; _ } ->
                      ( Glyph.Live_healthy
                      , Theme.Status_ok
                      , "live"
                      , Format_val.format_value Format_val.Milliseconds rtt_ms )
                  | Wire_infra.Ssh_unreachable _ ->
                      (Glyph.Live_failing, Theme.Status_critical, "down", "down")
                  | Wire_infra.Ssh_probe_pending ->
                      ( Glyph.Transport_reconnecting
                      , Theme.Status_active
                      , "probe"
                      , "…" )
                in
                {
                  Table.id = ks.keeper;
                  cells =
                    [
                      ("keeper", Table.text_cell ks.keeper);
                      ( "backend"
                      , Table.Badge
                          { glyph = None; text = "ssh"; tone = Theme.Status_ok }
                      );
                      ( "status"
                      , Table.Badge
                          { glyph = Some rg; text = st_lbl; tone = rt_tok } );
                      ("rtt", Table.text_cell rtt_s);
                      (* STRICT FIX: pool_name -> host_pool, "ssh" -> network, unix_user -> shim_acct *)
                      ("host_pool", Table.text_cell pool.pool_name);
                      ("network", Table.text_cell "ssh");
                      ("shim_acct", Table.text_cell pool.unix_user);
                      ("fail24", fail_cell ks.metrics_24h);
                    ];
                }
            | Entry_ssh_unbound u ->
                {
                  Table.id = u.keeper;
                  cells =
                    [
                      ("keeper", Table.text_cell u.keeper);
                      ( "backend"
                      , Table.Badge
                          {
                            glyph = None;
                            text = "ssh";
                            tone = Theme.Status_attention;
                          } );
                      ( "status"
                      , Table.Badge
                          {
                            glyph = Some Glyph.Warning_triangle;
                            text = u.binding_state;
                            tone = Theme.Status_attention;
                          } );
                      ( "rtt"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                          (Glyph.to_utf8 Glyph.Missing_absent) );
                      ( "host_pool"
                      , Table.text_cell
                          (Option.value
                             ~default:(Glyph.to_utf8 Glyph.Missing_absent)
                             u.remote_endpoint) );
                      ("network", Table.text_cell "ssh");
                      ( "shim_acct"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                          ~attrs:Attr.italic "unbound" );
                      ("fail24", fail_cell u.metrics_24h);
                    ];
                }
            | Entry_docker d ->
                {
                  Table.id = d.keeper;
                  cells =
                    [
                      ("keeper", Table.text_cell d.keeper);
                      ( "backend"
                      , Table.Badge
                          {
                            glyph = None;
                            text = "docker";
                            tone = Theme.Status_historical;
                          } );
                      ( "status"
                      , Table.Badge
                          {
                            glyph = Some Glyph.Live_healthy;
                            text = "live";
                            tone = Theme.Status_ok;
                          } );
                      ( "rtt"
                      , Table.text_cell
                          (Format_val.format_observed Format_val.Milliseconds
                             d.metrics_24h.p50_ms ~lang) );
                      ("host_pool", Table.text_cell "local-docker");
                      ( "network"
                      , Table.text_cell (network_mode_label d.network_mode) );
                      ("shim_acct", Table.text_cell "docker");
                      ("fail24", fail_cell d.metrics_24h);
                    ];
                })
          entries
      in
      let col_gap = if tbl_inner.w >= 90 then 2 else 1 in
      ignore
        (Table.draw grid ~rect:tbl_inner ~theme ~caps:H.default_caps ~lang
           ~col_gap ~scroll:inf.scroll_offset ~selected:inf.selected_index
           ~focused:(Model.pane_focused model 0) ~columns rows)
  end;
  if not (Rect.is_empty insp_rect) then
    draw_sandbox_inspector ~scroll:inf.detail_scroll_offset ~grid ~cache
      ~rect:insp_rect ~theme ~bp ~lang ~model sel_entry inf.sandboxes
      ~focused:(Model.detail_pane_focused ~detail_index:1 model)

(* --- 2. Sub-Tab 2: Repos & Read-Only Syntax-Highlighted Diffs --- *)

let repo_status_display ~lang = function
  | Wire_infra.Repo_active ->
      ( Glyph.Live_healthy
      , Theme.Status_ok
      , Say.resolve lang (Say.make ~ko:"활성" ~en:"active") )
  | Wire_infra.Repo_paused ->
      ( Glyph.Live_paused
      , Theme.Status_historical
      , Say.resolve lang (Say.make ~ko:"일시 정지" ~en:"paused") )
  | Wire_infra.Repo_cloning ->
      ( Glyph.Live_working
      , Theme.Status_active
      , Say.resolve lang (Say.make ~ko:"복제 중" ~en:"cloning") )
  | Wire_infra.Repo_error e -> (Glyph.Live_failing, Theme.Status_critical, e)

let file_change_badge (fc : Wire_infra.file_change) =
  if not fc.succeeded then ("!", Theme.Status_critical)
  else
    match fc.change with
    | Wire_infra.Change_edit _ -> ("~", Theme.Status_active)
    | Wire_infra.Change_write _ -> ("=", Theme.Status_attention)
    | Wire_infra.Change_insert _ -> ("+", Theme.Status_ok)
    | Wire_infra.Change_materialize _ -> ("*", Theme.Status_historical)

let change_kind_label = function
  | Wire_infra.Change_edit { replace_all = true; _ } -> "edit replace_all"
  | Wire_infra.Change_edit { replace_all = false; _ } -> "edit"
  | Wire_infra.Change_write _ -> "write"
  | Wire_infra.Change_insert _ -> "insert"
  | Wire_infra.Change_materialize _ -> "materialize"

let line_counts_text (counts : Wire_infra.line_counts) =
  let side sign = function
    | Some n -> Printf.sprintf "%s%d" sign n
    | None -> ""
  in
  String.trim
    (Printf.sprintf "%s %s" (side "+" counts.added) (side "-" counts.removed))

(* Calls the server could not read or place. [incomplete] belongs to this
   repository; [unattributed] is fleet-wide because its target is unknown. *)
let activity_gap_note ~lang (activity : Wire_infra.repository_activity) =
  let incomplete =
    if activity.incomplete > 0 then
      [
        Say.resolve lang
          (Say.make
             ~ko:(Printf.sprintf "+%d건 표시 못 함" activity.incomplete)
             ~en:(Printf.sprintf "+%d not shown" activity.incomplete));
      ]
    else []
  in
  let unattributed =
    if activity.unattributed > 0 then
      [
        Say.resolve lang
          (Say.make
             ~ko:(Printf.sprintf "대상 모르는 호출 %d건" activity.unattributed)
             ~en:
               (Printf.sprintf "%d calls with unknown target"
                  activity.unattributed));
      ]
    else []
  in
  match incomplete @ unattributed with
  | [] -> None
  | parts -> Some (String.concat " · " parts)

let draw_changes_empty_state ~grid ~rect ~theme ~lang (inf : Infra_store.t) =
  match Infra_store.selected_repo_activity inf with
  | None ->
      H.draw_empty_notice ~grid ~rect ~theme
        (Say.resolve lang
           (Say.make ~ko:"선택한 저장소 없음" ~en:"No repository selected"))
  | Some (_, Observed.Value { data = activity; _ }) ->
      H.draw_empty_notice ~grid ~rect ~theme
        (Say.resolve lang
           (if activity.changes = [] then
              Say.make
                ~ko:
                  (Printf.sprintf "%g시간 동안 이 저장소 파일을 바꾼 도구 호출 없음"
                     activity.window_hours)
                ~en:
                  (Printf.sprintf
                     "No file-writing tool calls in this repo in the last %gh"
                     activity.window_hours)
            else
              Say.make ~ko:"필터에 일치하는 파일 변경 없음"
                ~en:"No file changes match filter"))
  | Some
      ( _,
        (( Observed.Loading _
         | Observed.Absent
         | Observed.Unreported
         | Observed.Failed _ ) as activity) ) ->
      H.draw_observed_placeholder ~grid ~rect ~theme ~lang activity

let empty_preview_text ~lang (fc : Wire_infra.file_change) =
  match fc.change with
  | Wire_infra.Change_materialize { sha256 } ->
      Say.resolve lang
        (Say.make
           ~ko:("blob 내용은 기록에 없음 · sha256:" ^ sha256)
           ~en:("Blob content is not in the log · sha256:" ^ sha256))
  | Wire_infra.Change_edit _ | Wire_infra.Change_write _
  | Wire_infra.Change_insert _ ->
      Say.resolve lang
        (Say.make ~ko:"기록된 내용이 비어 있음" ~en:"The recorded text is empty")

let render_repos_changes ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let inf = model.infra in
  let zoomed = model.nav.zoomed && Model.can_zoom_current_view model in
  let left_rect, right_rect =
    if zoomed then (Rect.empty, rect)
    else
      Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.42
        ~top_ratio:0.46 bp rect
  in
  let repos_rect, changes_rect =
    match
      Layout.split_v_bp bp left_rect [ Layout.Ratio 0.50; Layout.Flex 1 ]
    with
    | [ a; b ] -> (a, b)
    | _ -> (left_rect, Rect.empty)
  in
  let repos_inner =
    Card.draw ~cache grid ~rect:repos_rect ~theme
      (H.card_spec ~focused:(Model.pane_focused model 0)
         ~hotkey:(Say.resolve lang (Say.make ~ko:"[n] 추가" ~en:"[n] Add"))
         (Say.resolve lang (Say.make ~ko:"등록된 Git 저장소" ~en:"Registered Repos")))
  in
  if not (Rect.is_empty repos_inner) then begin
    let repos = Infra_store.filtered_repositories inf in
    match inf.repositories with
    | Observed.Value _ when repos <> [] ->
        let columns : Table.column list =
          [
            {
              id = "name";
              header = Say.make ~ko:"저장소" ~en:"Repository";
              priority = 0;
              min_width = 14;
              max_width = None;
              weight = 3;
              align = Table.Left;
            };
            {
              id = "branch";
              header = Say.make ~ko:"브랜치" ~en:"Branch";
              priority = 2;
              min_width = 10;
              max_width = Some 20;
              weight = 1;
              align = Table.Left;
            };
            {
              id = "status";
              header = Say.make ~ko:"상태" ~en:"Status";
              priority = 1;
              min_width = 8;
              max_width = Some 12;
              weight = 1;
              align = Table.Left;
            };
          ]
        in
        let rows =
          List.map
            (fun (r : Wire_infra.repository) ->
              let g, tone, st = repo_status_display ~lang r.status in
              let pr_suffix =
                match Infra_store.pulls_entry_for ~repo_id:r.id inf with
                | Some e when String.equal e.state "read" && e.pulls <> [] ->
                    Printf.sprintf " · %dPR" (List.length e.pulls)
                | Some e when String.equal e.state "failed" -> " · PR!"
                | Some _ | None -> ""
              in
              let dirty_suffix =
                match
                  Observed.to_option
                    (Infra_store.repository_detail_for ~repo_id:r.id inf)
                with
                | Some obs -> (
                    match obs.git_status with
                    | Some gs when gs.available && gs.conflicted_files > 0 ->
                        " !"
                    | Some gs when gs.available && gs.dirty -> " *"
                    | Some _ | None -> "")
                | None -> ""
              in
              {
                Table.id = r.id;
                cells =
                  [
                    ("name", Table.text_cell (r.name ^ dirty_suffix));
                    ( "branch"
                    , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                        (r.default_branch ^ pr_suffix) );
                    ("status", Table.Badge { glyph = Some g; text = st; tone });
                  ];
              })
            repos
        in
        ignore
          (Table.draw grid ~rect:repos_inner ~theme ~caps:H.default_caps ~lang
             ~col_gap:(Layout.table_col_gap bp) ~scroll:inf.scroll_offset
             ~selected:inf.selected_index ~focused:(Model.pane_focused model 0)
             ~columns rows)
    | Observed.Value _ ->
        H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp repos_inner) ~theme
          (Say.resolve lang
             (if String.equal (String.trim inf.filter_query) "" then
                Say.make ~ko:"등록된 저장소가 없습니다 · [n] 추가"
                  ~en:"No registered repos · [n] Add"
              else
                Say.make ~ko:"필터에 일치하는 저장소 없음"
                  ~en:"No repositories match filter"))
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp repos_inner)
          ~theme ~lang obs
  end;
  let sel_repo = Infra_store.selected_repository inf in
  let changes = Infra_store.repo_changes inf in
  let active_change = Infra_store.selected_change inf in
  let gap_note =
    match Infra_store.selected_repo_activity inf with
    | Some (_, activity) ->
        Option.bind (Observed.to_option activity) (activity_gap_note ~lang)
    | None -> None
  in
  let ch_focused = changes <> [] && Model.pane_focused model 1 in
  let ch_inner =
    Card.draw ~cache grid ~rect:changes_rect ~theme
      (H.card_spec ?subtitle:gap_note ~focused:ch_focused
         (Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "키퍼 파일 변경 (%d)" (List.length changes))
               ~en:(Printf.sprintf "Keeper File Changes (%d)" (List.length changes)))))
  in
  if not (Rect.is_empty ch_inner) then begin
    if changes = [] then
      draw_changes_empty_state ~grid ~rect:(H.pad_content ~bp ch_inner) ~theme
        ~lang inf
    else
      let total_ch = List.length changes in
      let sel_ch_idx = H.clamp_index total_ch inf.change_selected_index in
      let start_ch, _ =
        Table.compute_viewport ~total_rows:total_ch ~viewport_rows:ch_inner.h
          ~scroll:inf.change_scroll_offset ~selected:(Some sel_ch_idx)
      in
      let y = ref ch_inner.y and bot = Rect.bottom ch_inner in
      let pad_r = if ch_inner.w >= 24 then 2 else 1 in
      List.iteri
        (fun local_i (fc : Wire_infra.file_change) ->
          let idx = start_ch + local_i in
          if !y < bot then begin
            (* Rows repeat per call, so one path can sit on several rows;
               the cursor is the row index. *)
            let is_active = Int.equal idx sel_ch_idx in
            let row_rect = Rect.make ~x:ch_inner.x ~y:!y ~w:ch_inner.w ~h:1 in
            let row_bg =
              if is_active then H.selected_row_bg ~theme ~focused:ch_focused
              else theme.surface_1
            in
            if is_active then
              H.paint_selected_row_bg ~grid ~clip:ch_inner ~row_rect ~theme
                ~focused:ch_focused ();
            let sign, tone = file_change_badge fc in
            let stats_s =
              line_counts_text (Wire_infra.file_change_line_counts fc)
            in
            let kp_s = "@" ^ fc.keeper in
            let right_edge = Rect.right ch_inner - pad_r in
            let tx = ch_inner.x + 2 in
            let r_meta =
              String.trim (Printf.sprintf "%s %s" stats_s kp_s)
            in
            let rw = Grapheme.display_width r_meta in
            ignore
              (H.put_clipped ~grid ~clip:row_rect ~x:tx ~y:!y ~max_w:2
                 ~style:(H.status_style ~theme ~bg:row_bg ~attrs:Attr.bold tone)
                 sign);
            let path_style =
              if is_active then H.anchor_style ~theme ~bg:row_bg ()
              else H.text_style ~theme ~bg:row_bg ()
            in
            ignore
              (H.put_clipped ~grid ~clip:row_rect ~x:(tx + 2) ~y:!y
                 ~max_w:(Int.max 6 (right_edge - (tx + 2) - rw - 2))
                 ~style:path_style fc.path);
            if rw > 0 then
              ignore
                (H.put_right ~grid ~clip:row_rect ~right_x:right_edge ~y:!y
                   ~max_w:rw ~style:(H.whisper_style ~theme ~bg:row_bg ())
                   r_meta);
            incr y
          end)
        (Store_scroll.drop start_ch changes)
  end;
  (* Right Card: the selected call's recorded text, syntax-highlighted *)
  let diff_subtitle =
    match active_change, sel_repo with
    | Some fc, _ ->
        let outcome =
          if fc.succeeded then []
          else [ Say.resolve lang (Say.make ~ko:"실패한 호출" ~en:"failed call") ]
        in
        Some
          (String.concat " · "
             ([ fc.path; change_kind_label fc.change; "@" ^ fc.keeper ] @ outcome))
    | None, Some r -> Some r.default_branch
    | None, None -> None
  in
  let diff_pane_idx = if changes <> [] then 2 else 1 in
  let diff_inner =
    Card.draw ~cache grid ~rect:right_rect ~theme
      (H.card_spec ?subtitle:diff_subtitle
         ~focused:(Model.detail_pane_focused ~detail_index:diff_pane_idx model)
         ~hotkey:(Say.resolve lang (Say.make ~ko:"[o] URL 열기" ~en:"[o] Open URL"))
         (Say.resolve lang (Say.make ~ko:"변경 미리보기" ~en:"Change Preview")))
  in
  if not (Rect.is_empty diff_inner) then begin
    let y = ref diff_inner.y and bot = Rect.bottom diff_inner in
    let pad_x = Layout.card_pad_x bp in
    (match sel_repo with
     | Some r when !y < bot ->
         let g, _tone, st = repo_status_display ~lang r.status in
         let band_h = if bot - !y >= 5 then 2 else 1 in
         Card.draw_section_band ~pad_x grid
           ~rect:(Rect.make ~x:diff_inner.x ~y:!y ~w:diff_inner.w ~h:band_h)
           ~theme
           ~left_title:(Printf.sprintf "%s %s" (Glyph.to_utf8 g) r.name)
           ~right_meta:(Printf.sprintf "%s · %s" r.default_branch st)
           ?subtitle:
             (if band_h >= 2 then
                Some
                  (Printf.sprintf "auto_sync=%b · %s" r.auto_sync
                     (if r.keepers = [] then Glyph.to_utf8 Glyph.Missing_absent
                      else String.concat ", " r.keepers))
              else None)
           ();
         y := !y + band_h;
         if !y < bot then begin
           let link_rect =
             Rect.make ~x:(diff_inner.x + pad_x) ~y:!y
               ~w:(Int.max 0 (diff_inner.w - (2 * pad_x)))
               ~h:1
           in
           let file_uri = "file://" ^ r.resolved_local_path in
           let adv =
             H.put_link ~grid ~clip:link_rect ~x:link_rect.x ~y:!y
               ~max_w:link_rect.w ~style:(H.accent_style ~theme ())
               ~uri:file_uri file_uri
           in
           let rem = link_rect.w - adv - 3 in
           if rem > 6 && not (String.equal r.url "") then
             ignore
               (H.put_link ~grid ~clip:link_rect ~x:(link_rect.x + adv + 2)
                  ~y:!y ~max_w:rem ~style:(H.secondary_style ~theme ())
                  ~uri:r.url r.url);
           incr y
         end;
         (* Per-repo git status & sync currency (from GET /api/v1/repositories/:id) *)
         let obs_rect =
           Rect.make ~x:(diff_inner.x + pad_x) ~y:!y
             ~w:(Int.max 0 (diff_inner.w - (2 * pad_x)))
             ~h:1
         in
         (match Infra_store.repository_detail_for ~repo_id:r.id inf with
          | Observed.Value { data = obs; _ } when !y < bot ->
              let git_part, git_tone =
                match obs.git_status with
                | Some gs when gs.available ->
                    if gs.conflicted_files > 0 then
                      ( Say.resolve lang
                          (Say.make
                             ~ko:(Printf.sprintf "충돌 %d · 변경 %d" gs.conflicted_files gs.changed_files)
                             ~en:(Printf.sprintf "%d conflicts · %d changed" gs.conflicted_files gs.changed_files))
                      , Theme.Status_critical )
                    else if gs.dirty then
                      ( Say.resolve lang
                          (Say.make
                             ~ko:(Printf.sprintf "작업트리 변경 %d파일" gs.changed_files)
                             ~en:(Printf.sprintf "dirty (%d files)" gs.changed_files))
                      , Theme.Status_attention )
                    else
                      ( Say.resolve lang (Say.make ~ko:"작업트리 깨끗함" ~en:"clean")
                      , Theme.Status_ok )
                | Some gs ->
                    ( Printf.sprintf "git %s"
                        (Option.value gs.error ~default:"unavailable")
                    , Theme.Status_attention )
                | None -> ("", Theme.Status_historical)
              in
              let sync_part, sync_tone =
                match obs.sync_currency with
                | Some sc when sc.available ->
                    let ref_s = Option.value sc.target_ref ~default:r.default_branch in
                    if sc.behind > 0 || sc.ahead > 0 then
                      ( Printf.sprintf "%s ↓%d ↑%d" ref_s sc.behind sc.ahead
                      , if sc.behind > 0 then Theme.Status_attention
                        else Theme.Status_active )
                    else
                      ( Printf.sprintf "%s %s" ref_s
                          (Say.resolve lang (Say.make ~ko:"최신" ~en:"up to date"))
                      , Theme.Status_ok )
                | Some sc ->
                    ( Printf.sprintf "sync %s"
                        (Option.value sc.error ~default:"unavailable")
                    , Theme.Status_attention )
                | None -> ("", Theme.Status_historical)
              in
              let parts =
                List.filter (fun s -> not (String.equal s "")) [ git_part; sync_part ]
              in
              if parts <> [] then begin
                let tone_rank = function
                  | Theme.Status_critical -> 4
                  | Theme.Status_attention -> 3
                  | Theme.Status_active | Theme.Status_ai -> 2
                  | Theme.Status_ok -> 1
                  | Theme.Status_historical -> 0
                in
                let line_tone =
                  if tone_rank git_tone >= tone_rank sync_tone then git_tone
                  else sync_tone
                in
                ignore
                  (H.put_clipped ~grid ~clip:obs_rect ~x:obs_rect.x ~y:!y
                     ~max_w:obs_rect.w ~style:(H.status_style ~theme line_tone)
                     ("Git: " ^ String.concat " · " parts));
                incr y
              end
          | Observed.Failed { reason; _ } when !y < bot ->
              ignore
                (H.put_clipped ~grid ~clip:obs_rect ~x:obs_rect.x ~y:!y
                   ~max_w:obs_rect.w
                   ~style:(H.status_style ~theme Theme.Status_critical)
                   (Printf.sprintf "%s Git: %s"
                      (Glyph.to_utf8 Glyph.Live_failing) reason));
              incr y
          | Observed.Value _ | Observed.Loading _ | Observed.Absent
          | Observed.Unreported | Observed.Failed _ ->
              ());
         (* Open GitHub Pull Requests (from GET /api/v1/repositories/pulls) *)
         (match inf.repository_pulls with
          | Observed.Value { data = snap; _ } when !y < bot ->
              let pr_clip =
                Rect.make ~x:(diff_inner.x + pad_x) ~y:!y
                  ~w:(Int.max 0 (diff_inner.w - (2 * pad_x)))
                  ~h:(Int.max 0 (bot - !y))
              in
              (match snap.repositories_error with
               | Some err ->
                   ignore
                     (H.put_clipped ~grid ~clip:pr_clip ~x:pr_clip.x ~y:!y
                        ~max_w:pr_clip.w
                        ~style:(H.status_style ~theme Theme.Status_critical)
                        (Printf.sprintf "%s PRs: %s"
                           (Glyph.to_utf8 Glyph.Live_failing) err));
                   incr y
               | None -> (
                   match Infra_store.pulls_entry_for ~repo_id:r.id inf with
                   | Some entry when String.equal entry.state "failed" ->
                       let detail =
                         Option.value entry.failure_summary ~default:"fetch failed"
                       in
                       ignore
                         (H.put_clipped ~grid ~clip:pr_clip ~x:pr_clip.x ~y:!y
                            ~max_w:pr_clip.w
                            ~style:(H.status_style ~theme Theme.Status_critical)
                            (Printf.sprintf "%s PRs: %s"
                               (Glyph.to_utf8 Glyph.Live_failing) detail));
                       incr y
                   | Some entry when String.equal entry.state "read" ->
                       let n_prs = List.length entry.pulls in
                       let undec_s =
                         if entry.undecodable > 0 then
                           Printf.sprintf " (+%d undecodable)" entry.undecodable
                         else ""
                       in
                       let hdr =
                         Say.resolve lang
                           (Say.make
                              ~ko:(Printf.sprintf "GitHub PR (%d건)%s" n_prs undec_s)
                              ~en:(Printf.sprintf "Open PRs (%d)%s" n_prs undec_s))
                       in
                       ignore
                         (H.put_clipped ~grid ~clip:pr_clip ~x:pr_clip.x ~y:!y
                            ~max_w:pr_clip.w
                            ~style:(H.secondary_style ~theme ()) hdr);
                       incr y;
                       let avail = Int.max 0 (bot - !y - 2) in
                       let max_pr_rows, show_more =
                         if avail <= 0 || n_prs = 0 then (0, false)
                         else if n_prs <= Int.min 3 avail then (n_prs, false)
                         else if avail = 1 then (1, false)
                         else (Int.min 3 (avail - 1), true)
                       in
                       List.iteri
                         (fun idx (pr : Wire_infra.repository_pull_row) ->
                           if idx < max_pr_rows && !y < bot then begin
                             let tone =
                               if
                                 String.equal pr.checks "failing"
                                 || String.equal pr.mergeable "conflicting"
                               then Theme.Status_critical
                               else if
                                 String.equal pr.review "changes_requested"
                                 || String.equal pr.checks "running"
                               then Theme.Status_attention
                               else if
                                 String.equal pr.checks "passing"
                                 && String.equal pr.review "approved"
                               then Theme.Status_ok
                               else Theme.Status_active
                             in
                             let draft_tag = if pr.draft then "[DRAFT] " else "" in
                             let author_s =
                               match pr.keeper, pr.author with
                               | Some k, _ -> "@" ^ k
                               | None, Some a -> "@" ^ a
                               | None, None -> ""
                             in
                             let title_s = Option.value pr.title ~default:"" in
                             let head_rev_s =
                               if String.equal pr.head_review "not_reviewed_on_head"
                               then " !head-rev"
                               else ""
                             in
                             let row_txt =
                               Printf.sprintf "  #%d %s[%s/%s/%s]%s %s %s"
                                 pr.number draft_tag pr.checks pr.review
                                 pr.mergeable head_rev_s author_s title_s
                             in
                             ignore
                               (H.put_clipped ~grid ~clip:pr_clip ~x:pr_clip.x
                                  ~y:!y ~max_w:pr_clip.w
                                  ~style:(H.status_style ~theme tone) row_txt);
                             incr y
                           end)
                         entry.pulls;
                       let hidden_prs = n_prs - max_pr_rows in
                       if show_more && hidden_prs > 0 && !y < bot then begin
                         ignore
                           (H.put_clipped ~grid ~clip:pr_clip ~x:pr_clip.x ~y:!y
                              ~max_w:pr_clip.w ~style:(H.whisper_style ~theme ())
                              (Say.resolve lang
                                 (Say.make
                                    ~ko:(Printf.sprintf "  … 외 PR %d건 더" hidden_prs)
                                    ~en:(Printf.sprintf "  … +%d more PRs" hidden_prs))));
                         incr y
                       end
                   | Some _ | None ->
                       if not (String.equal snap.reader_state "ready") then begin
                         let detail =
                           match snap.reader_detail with
                           | Some d -> " (" ^ d ^ ")"
                           | None -> ""
                         in
                         ignore
                           (H.put_clipped ~grid ~clip:pr_clip ~x:pr_clip.x ~y:!y
                              ~max_w:pr_clip.w
                              ~style:(H.whisper_style ~theme ())
                              (Printf.sprintf "PR reader: %s%s"
                                 snap.reader_state detail));
                         incr y
                       end))
          | Observed.Failed { reason; _ } when !y < bot ->
              let pr_clip =
                Rect.make ~x:(diff_inner.x + pad_x) ~y:!y
                  ~w:(Int.max 0 (diff_inner.w - (2 * pad_x)))
                  ~h:1
              in
              ignore
                (H.put_clipped ~grid ~clip:pr_clip ~x:pr_clip.x ~y:!y
                   ~max_w:pr_clip.w
                   ~style:(H.status_style ~theme Theme.Status_critical)
                   (Printf.sprintf "%s PRs: %s"
                      (Glyph.to_utf8 Glyph.Live_failing) reason));
              incr y
          | Observed.Value _ | Observed.Loading _ | Observed.Absent
          | Observed.Unreported | Observed.Failed _ ->
              ())
     | Some _ | None -> ());
    if !y < bot then begin
      H.draw_divider ~grid ~rect:diff_inner ~y:!y ~theme ~pad_x ();
      incr y
    end;
    let diff_content =
      Rect.make ~x:diff_inner.x ~y:!y ~w:diff_inner.w ~h:(Int.max 0 (bot - !y))
      |> H.pad_content ~bp
    in
    match active_change with
    | Some fc -> (
        match Infra_store.change_preview_rows fc with
        | [] ->
            H.draw_empty_notice ~grid ~rect:diff_content ~theme
              (empty_preview_text ~lang fc)
        | numbered ->
            let language = Code_lexer.language_of_path fc.path in
            if not (Rect.is_empty diff_content) then begin
              ignore
                (Diff.draw grid ~rect:diff_content ~theme ?language
                   ~scroll:inf.diff_scroll_offset numbered)
            end)
    | None -> (
        match sel_repo with
        | Some _ ->
            draw_changes_empty_state ~grid ~rect:diff_content ~theme ~lang inf
        | None ->
            H.draw_observed_placeholder ~grid ~rect:diff_content ~theme ~lang
              inf.repositories)
  end

(* --- 3. Sub-Tab 3: Activity & Logs (Calm Badges + Italic Timestamps + Json_tree) --- *)

let activity_kind_label = function
  | Infra_store.Activity_tool_call -> "TOOL"
  | Infra_store.Activity_turn_complete -> "TURN"
  | Infra_store.Activity_agent_core -> "CORE"
  | Infra_store.Activity_stream_gap -> "GAP"

let render_activity_logs ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let inf = model.infra in
  let vis_logs = Infra_store.visible_logs inf in
  let vis_events = Infra_store.visible_activity_events inf in
  let vis_timeline = Infra_store.visible_timeline inf in
  let events_n = List.length vis_events in
  let logs_n = List.length vis_logs in
  let bar_rect, body_rect =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ a; b ] -> (a, b)
    | _ -> (Rect.empty, rect)
  in
  let log_level_rank = function
    | Wire_infra.Log_debug -> 0
    | Wire_infra.Log_info -> 1
    | Wire_infra.Log_warn -> 2
    | Wire_infra.Log_error -> 3
  in
  let level_active lvl =
    Option.equal (fun a b -> Int.equal (log_level_rank a) (log_level_rank b))
      inf.log_level_filter lvl
  in
  let src_is_all =
    match inf.source_filter with
    | Infra_store.Source_all -> true
    | Infra_store.Source_logs | Infra_store.Source_events -> false
  in
  let src_is_logs =
    match inf.source_filter with
    | Infra_store.Source_logs -> true
    | Infra_store.Source_all | Infra_store.Source_events -> false
  in
  let src_is_events =
    match inf.source_filter with
    | Infra_store.Source_events -> true
    | Infra_store.Source_all | Infra_store.Source_logs -> false
  in
  let narrow_bar = bar_rect.w < 115 in
  let pills =
    [
      {
        H.label =
          Printf.sprintf "%s (%d)"
            (Say.resolve lang (Say.make ~ko:"전체" ~en:"All"))
            (events_n + logs_n);
        active = src_is_all;
        tone = Some Theme.Status_active;
        glyph = Some Glyph.Live_healthy;
      };
      {
        H.label =
          Printf.sprintf "%s (%d)"
            (Say.resolve lang
               (if narrow_bar then Say.make ~ko:"로그" ~en:"Logs"
                else Say.make ~ko:"서버 로그" ~en:"Server Logs"))
            logs_n;
        active = src_is_logs;
        tone = Some Theme.Status_ok;
        glyph = None;
      };
      {
        H.label =
          Printf.sprintf "%s (%d)"
            (Say.resolve lang
               (if narrow_bar then Say.make ~ko:"이벤트" ~en:"Events"
                else Say.make ~ko:"MASC 이벤트" ~en:"MASC Events"))
            events_n;
        active = src_is_events;
        tone = Some Theme.Status_ai;
        glyph = None;
      };
    ]
    @ (if inf.stream_gap_count > 0 then
         [
           {
             H.label =
               Printf.sprintf "Stream_gap: %d dropped" inf.stream_gap_count;
             active = true;
             tone = Some Theme.Status_attention;
             glyph = Some Glyph.Warning_triangle;
           };
         ]
       else [])
    @ (if src_is_events then []
       else
         [
           {
             H.label = "ERR";
             active = level_active (Some Wire_infra.Log_error);
             tone = Some Theme.Status_critical;
             glyph = None;
           };
           {
             H.label = "WRN";
             active = level_active (Some Wire_infra.Log_warn);
             tone = Some Theme.Status_attention;
             glyph = None;
           };
           {
             H.label = "INF";
             active = level_active (Some Wire_infra.Log_info);
             tone = Some Theme.Status_ok;
             glyph = None;
           };
           {
             H.label = "DBG";
             active = level_active (Some Wire_infra.Log_debug);
             tone = Some Theme.Status_historical;
             glyph = None;
           };
         ])
    @ (match inf.log_keeper_filter with
       | Some kp ->
           [
             {
               H.label = "@" ^ kp;
               active = true;
               tone = Some Theme.Status_active;
               glyph = None;
             };
           ]
       | None -> [])
    @
    if String.equal (String.trim inf.filter_query) "" then []
    else
      [
        {
          H.label = "/" ^ inf.filter_query;
          active = true;
          tone = Some Theme.Status_active;
          glyph = None;
        };
      ]
  in
  let acting_list = Update_nav.acting_keepers model in
  let pills =
    pills
    @ [
        {
          H.label =
            Printf.sprintf "[a] %s (%d)"
              (Say.resolve lang (Say.make ~ko:"활동" ~en:"Acting"))
              (List.length acting_list);
          active = inf.acting_rail_open;
          tone =
            Some
              (if acting_list <> [] then Theme.Status_ok
               else Theme.Status_historical);
          glyph = Some Glyph.Live_working;
        };
      ]
  in
  let bar_right_hint =
    if bar_rect.w >= 120 then Some "logs/stream + observer SSE · [s] · [a] Acting"
    else if bar_rect.w >= 96 && inf.stream_gap_count = 0 then Some "[s] src · [a] act"
    else None
  in
  ignore (H.draw_pills ~grid ~rect:bar_rect ~theme ?right_hint:bar_right_hint pills);
  let left_rect, right_rect, acting_rect_opt =
    if model.nav.zoomed && Model.can_zoom_current_view model then
      (Rect.empty, body_rect, None)
    else if inf.acting_rail_open && body_rect.w >= 104 then
      match
        Layout.split_h_bp bp body_rect
          [ Layout.Ratio 0.50; Layout.Ratio 0.32; Layout.Flex 1 ]
      with
      | [ a; b; c ] -> (a, b, Some c)
      | _ ->
          let l, r =
            Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.62
              ~top_ratio:0.56 bp body_rect
          in
          (l, r, None)
    else
      let l, r =
        Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.62
          ~top_ratio:0.56 bp body_rect
      in
      (l, r, None)
  in
  let stream_inner =
    Card.draw ~cache grid ~rect:left_rect ~theme
      (H.card_spec ~focused:(Model.pane_focused model 0)
         ~hotkey:
           (Say.resolve lang
              (Say.make ~ko:"[s] 소스 · [Space] 레벨 · [/] 필터"
                 ~en:"[s] Source · [Space] Level · [/] Filter"))
         (Say.resolve lang
            (Say.make ~ko:"실시간 활동 · 시스템 로그" ~en:"Activity & System Logs")))
  in
  if not (Rect.is_empty stream_inner) then begin
    if vis_timeline = [] then
      H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp stream_inner) ~theme
        (if inf.logs_loaded || inf.activity_events <> [] then
           Say.resolve lang
             (Say.make ~ko:"필터에 일치하는 항목이 없습니다"
                ~en:"No entries match active filters")
         else
           Say.resolve lang
             (Say.make ~ko:"로그·이벤트 스트림 연결 대기 중…"
                ~en:"Waiting for log & event streams…"))
    else begin
      let columns : Table.column list =
        [
          {
            id = "time";
            header = Say.make ~ko:"시각" ~en:"Time";
            priority = 2;
            min_width = 8;
            max_width = Some 8;
            weight = 1;
            align = Table.Left;
          };
          {
            id = "src";
            header = Say.make ~ko:"출처" ~en:"SRC";
            priority = 1;
            min_width = 4;
            max_width = Some 5;
            weight = 1;
            align = Table.Left;
          };
          {
            id = "lvl";
            header = Say.make ~ko:"종류" ~en:"Lvl";
            priority = 1;
            min_width = 4;
            max_width = Some 5;
            weight = 1;
            align = Table.Left;
          };
          {
            id = "comp";
            header = Say.make ~ko:"컴포넌트" ~en:"Comp";
            priority = 3;
            min_width = 8;
            max_width = Some 14;
            weight = 1;
            align = Table.Left;
          };
          {
            id = "keeper";
            header = Say.make ~ko:"키퍼" ~en:"Keeper";
            priority = 1;
            min_width = 14;
            max_width = Some 22;
            weight = 2;
            align = Table.Left;
          };
          {
            id = "summary";
            header = Say.make ~ko:"요약" ~en:"Summary";
            priority = 0;
            min_width = 16;
            max_width = None;
            weight = 4;
            align = Table.Left;
          };
        ]
      in
      let rows =
        List.mapi
          (fun idx entry ->
            match entry with
            | Infra_store.Entry_log e ->
                let lvl_txt, lvl_tone = log_level_badge e.level in
                let keeper_txt =
                  match e.keeper with
                  | Some k when not (String.equal (String.trim k) "") -> k
                  | Some _ | None -> Glyph.to_utf8 Glyph.Missing_absent
                in
                let comp_txt =
                  if not (String.equal (String.trim e.module_name) "") then
                    e.module_name
                  else e.source
                in
                {
                  Table.id = Printf.sprintf "log:%d" e.seq;
                  cells =
                    [
                      ( "time"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                          ~attrs:Attr.italic
                          (H.format_local_hhmmss
                             ~tz_offset_sec:model.tz_offset_sec e.ts) );
                      ( "src"
                      , Table.Badge
                          {
                            glyph = None;
                            text = "LOG";
                            tone = Theme.Status_historical;
                          } );
                      ( "lvl"
                      , Table.Badge
                          { glyph = None; text = lvl_txt; tone = lvl_tone } );
                      ( "comp"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                          comp_txt );
                      ( "keeper"
                      , Table.text_cell ~fg:(Color.of_rgb theme.accent)
                          keeper_txt );
                      ( "summary"
                      , Table.text_cell (H.sanitize_single_line e.message) );
                    ];
                }
            | Infra_store.Entry_event ev ->
                let kind_lbl = activity_kind_label ev.kind in
                let kind_tone =
                  match ev.kind with
                  | Infra_store.Activity_stream_gap -> Theme.Status_attention
                  | Infra_store.Activity_tool_call
                  | Infra_store.Activity_turn_complete
                  | Infra_store.Activity_agent_core ->
                      Theme.Status_active
                in
                let keeper_txt =
                  match ev.keeper with
                  | Some k when not (String.equal (String.trim k) "") -> k
                  | Some _ | None -> Glyph.to_utf8 Glyph.Missing_absent
                in
                let ts_str =
                  if Float.is_finite ev.at_unix && ev.at_unix > 0.0 then
                    H.format_local_hhmmss ~tz_offset_sec:model.tz_offset_sec
                      (Wire_common.format_unix_rfc3339 ev.at_unix)
                  else Glyph.to_utf8 Glyph.Missing_absent
                in
                {
                  Table.id = Printf.sprintf "evt:%d" idx;
                  cells =
                    [
                      ( "time"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                          ~attrs:Attr.italic ts_str );
                      ( "src"
                      , Table.Badge
                          { glyph = None; text = "EVT"; tone = Theme.Status_ai } );
                      ( "lvl"
                      , Table.Badge
                          { glyph = None; text = kind_lbl; tone = kind_tone } );
                      ( "comp"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                          "observer" );
                      ( "keeper"
                      , Table.text_cell ~fg:(Color.of_rgb theme.accent)
                          keeper_txt );
                      ( "summary"
                      , Table.text_cell (H.sanitize_single_line ev.summary) );
                    ];
                })
          vis_timeline
      in
      let sel = H.clamp_index (List.length vis_timeline) inf.selected_index in
      ignore
        (Table.draw grid ~rect:stream_inner ~theme ~caps:H.default_caps ~lang
           ~col_gap:(Layout.table_col_gap bp) ~scroll:inf.scroll_offset
           ~selected:sel ~focused:(Model.pane_focused model 0) ~columns rows)
    end
  end;
  (* Right: Structured K/V Detail Card for both Server Logs and MASC Events *)
  let sel_entry = Infra_store.selected_timeline_entry inf in
  let det_subtitle =
    match sel_entry with
    | Some (Infra_store.Entry_log e) -> Some ("LOG #" ^ string_of_int e.seq)
    | Some (Infra_store.Entry_event ev) ->
        Some ("EVT · " ^ activity_kind_label ev.kind)
    | None -> None
  in
  let det_inner =
    Card.draw ~cache grid ~rect:right_rect ~theme
      (H.card_spec ?subtitle:det_subtitle
         ~focused:(Model.detail_pane_focused ~detail_index:1 model)
         ~hotkey:(Say.resolve lang (Say.make ~ko:"[y] 복사" ~en:"[y] Copy"))
         (Say.resolve lang
            (Say.make ~ko:"구조화 K/V 상세" ~en:"Structured K/V Detail")))
  in
  if not (Rect.is_empty det_inner) then begin
    match sel_entry with
    | None ->
        H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp det_inner) ~theme
          (Say.resolve lang
             (Say.make ~ko:"로그·이벤트 항목을 선택하면 상세 속성이 표시됩니다"
                ~en:"Select a log or event entry to inspect structured fields"))
    | Some (Infra_store.Entry_log e) ->
        let pad_x = Layout.card_pad_x bp in
        let lvl_txt, lvl_tone = log_level_badge e.level in
        let local_ts =
          H.format_local_datetime ~tz_offset_sec:model.tz_offset_sec e.ts
        in
        let kp =
          match e.keeper with
          | Some k -> "@" ^ k
          | None -> Glyph.to_utf8 Glyph.Missing_absent
        in
        let turn =
          match e.turn_id with
          | Some t -> Printf.sprintf " · turn #%d" t
          | None -> ""
        in
        let cat = match e.category with Some c -> " · " ^ c | None -> "" in
        let band_h = if det_inner.h >= 6 then 2 else 1 in
        Card.draw_section_band ~pad_x grid
          ~rect:(Rect.make ~x:det_inner.x ~y:det_inner.y ~w:det_inner.w ~h:band_h)
          ~theme
          ~left_title:(Printf.sprintf "[LOG/%s] %s/%s" lvl_txt e.source e.module_name)
          ~right_meta:local_ts
          ?subtitle:(if band_h >= 2 then Some (kp ^ turn ^ cat) else None)
          ();
        let content =
          Rect.make ~x:det_inner.x ~y:(det_inner.y + band_h) ~w:det_inner.w
            ~h:(Int.max 0 (det_inner.h - band_h))
          |> H.pad_content ~bp
        in
        if not (Rect.is_empty content) then begin
          let y = ref content.y and bot = Rect.bottom content in
          let msg_lines =
            H.wrap_lines ~max_width:(Int.max 1 (content.w - 2)) e.message
          in
          let msg_n = List.length msg_lines in
          let eff_scroll = Int.max 0 inf.detail_scroll_offset in
          let msg_skip = Int.min msg_n eff_scroll in
          let vis_msg = Store_scroll.drop msg_skip msg_lines in
          let vis_msg_n = Int.min (List.length vis_msg) (Int.max 0 (bot - !y)) in
          if vis_msg_n > 0 then begin
            Card.draw_left_rail ~tone:lvl_tone grid ~x:content.x ~y:!y
              ~h:vis_msg_n ~theme;
            List.iter
              (fun line ->
                if !y < bot then begin
                  ignore
                    (H.put_clipped ~grid ~clip:content ~x:(content.x + 2) ~y:!y
                       ~max_w:(Int.max 0 (content.w - 2))
                       ~style:(H.text_style ~theme ()) line);
                  incr y
                end)
              vis_msg
          end;
          if eff_scroll <= msg_n && !y < bot then begin
            H.draw_divider ~grid ~rect:content ~y:!y ~theme
              ~label:(Say.resolve lang (Say.make ~ko:"속성 트리" ~en:"Attributes"))
              ();
            incr y
          end;
          let tree_h = Int.max 0 (bot - !y) in
          if tree_h > 0 then begin
            let tree_rect =
              Rect.make ~x:content.x ~y:!y ~w:content.w ~h:tree_h
            in
            let tree_scroll = Int.max 0 (eff_scroll - (msg_n + 1)) in
            let lines =
              Json_tree.flatten ~max_depth:5 ~redact_secrets:true e.details
            in
            ignore
              (Json_tree.draw grid ~rect:tree_rect ~theme
                 ~scroll:tree_scroll lines)
          end
        end
    | Some (Infra_store.Entry_event ev) ->
        let pad_x = Layout.card_pad_x bp in
        let kind_lbl = activity_kind_label ev.kind in
        let kind_tone =
          match ev.kind with
          | Infra_store.Activity_stream_gap -> Theme.Status_attention
          | Infra_store.Activity_tool_call
          | Infra_store.Activity_turn_complete
          | Infra_store.Activity_agent_core ->
              Theme.Status_ai
        in
        let local_ts =
          if Float.is_finite ev.at_unix && ev.at_unix > 0.0 then
            H.format_local_datetime ~tz_offset_sec:model.tz_offset_sec
              (Wire_common.format_unix_rfc3339 ev.at_unix)
          else Glyph.to_utf8 Glyph.Missing_absent
        in
        let kp =
          match ev.keeper with
          | Some k -> "@" ^ k
          | None -> Glyph.to_utf8 Glyph.Missing_absent
        in
        let band_h = if det_inner.h >= 6 then 2 else 1 in
        Card.draw_section_band ~pad_x grid
          ~rect:(Rect.make ~x:det_inner.x ~y:det_inner.y ~w:det_inner.w ~h:band_h)
          ~theme
          ~left_title:(Printf.sprintf "[EVT/%s] observer SSE" kind_lbl)
          ~right_meta:local_ts
          ?subtitle:(if band_h >= 2 then Some (kp ^ " · /mcp?sse_kind=observer") else None)
          ();
        let content =
          Rect.make ~x:det_inner.x ~y:(det_inner.y + band_h) ~w:det_inner.w
            ~h:(Int.max 0 (det_inner.h - band_h))
          |> H.pad_content ~bp
        in
        if not (Rect.is_empty content) then begin
          let sum_lines =
            Chat_transcript.wrap_plain_lines ~width:(Int.max 1 (content.w - 2))
              ev.summary
          in
          let detail_lines =
            match ev.detail with
            | Some d when not (String.equal (String.trim d) "") ->
                Chat_transcript.wrap_plain_lines
                  ~width:(Int.max 1 (content.w - 2))
                  d
            | Some _ | None -> []
          in
          let all_rows =
            List.map (fun l -> `Summary l) sum_lines
            @ [
                `Kv (Say.resolve lang (Say.make ~ko:"소스" ~en:"Origin"), "MASC Observer SSE");
                `Kv (Say.resolve lang (Say.make ~ko:"키퍼" ~en:"Keeper"), kp);
                `Divider (Say.resolve lang (Say.make ~ko:"이벤트 상세" ~en:"Event Detail"));
              ]
            @ List.map (fun l -> `Detail l) detail_lines
          in
          let vis_h = Int.max 1 content.h in
          let max_skip = Int.max 0 (List.length all_rows - vis_h) in
          let skip = Int.min max_skip (Int.max 0 inf.detail_scroll_offset) in
          let y = ref content.y and bot = Rect.bottom content in
          List.iter
            (function
              | `Summary line ->
                  if !y < bot then begin
                    Card.draw_left_rail ~tone:kind_tone grid ~x:content.x ~y:!y
                      ~h:1 ~theme;
                    ignore
                      (H.put_clipped ~grid ~clip:content ~x:(content.x + 2)
                         ~y:!y ~max_w:(Int.max 0 (content.w - 2))
                         ~style:(H.text_style ~theme ()) line);
                    incr y
                  end
              | `Kv (k, v) ->
                  if !y < bot then begin
                    H.put_kv ~grid ~clip:content ~x:content.x ~y:!y
                      ~max_w:content.w ~theme ~key_w:9 ~key:k v;
                    incr y
                  end
              | `Divider lbl ->
                  if !y < bot then begin
                    H.draw_divider ~grid ~rect:content ~y:!y ~theme ~label:lbl ();
                    incr y
                  end
              | `Detail line ->
                  if !y < bot then begin
                    ignore
                      (H.put_clipped ~grid ~clip:content ~x:(content.x + 2)
                         ~y:!y ~max_w:(Int.max 0 (content.w - 2))
                         ~style:(H.secondary_style ~theme ()) line);
                    incr y
                  end)
            (Store_scroll.drop skip all_rows)
        end
  end;
  match acting_rect_opt with
  | Some act_rect when not (Rect.is_empty act_rect) ->
      let act_inner =
        Card.draw ~cache grid ~rect:act_rect ~theme
          (H.card_spec ~focused:(Model.pane_focused model 2)
             ~hotkey:
               (Say.resolve lang
                  (Say.make ~ko:"[Enter] 트레이스 · [a] 닫기"
                     ~en:"[Enter] Trace · [a] Hide"))
             (Say.resolve lang
                (Say.make ~ko:"활동 중 키퍼" ~en:"Acting Keepers")))
      in
      if not (Rect.is_empty act_inner) then begin
        if acting_list = [] then
          H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp act_inner) ~theme
            (Say.resolve lang
               (Say.make ~ko:"현재 활동 중인 키퍼 없음"
                  ~en:"No actively acting keepers"))
        else
          let total = List.length acting_list in
          let sel = H.clamp_index total inf.acting_selected_index in
          let start_i, _ =
            Table.compute_viewport ~total_rows:total ~viewport_rows:act_inner.h
              ~scroll:0 ~selected:(Some sel)
          in
          let y = ref act_inner.y and bot = Rect.bottom act_inner in
          List.iteri
            (fun local_i kp ->
              let idx = start_i + local_i in
              if !y < bot then begin
                let is_sel = Int.equal idx sel in
                let act_focused = Model.pane_focused model 2 in
                let row_rect =
                  Rect.make ~x:act_inner.x ~y:!y ~w:act_inner.w ~h:1
                in
                let row_bg =
                  if is_sel then H.selected_row_bg ~theme ~focused:act_focused
                  else theme.surface_1
                in
                if is_sel then
                  H.paint_selected_row_bg ~grid ~clip:act_inner ~row_rect ~theme
                    ~focused:act_focused ();
                let st =
                  if is_sel && act_focused then
                    H.anchor_style ~theme ~bg:row_bg ()
                  else H.text_style ~theme ~bg:row_bg ()
                in
                ignore
                  (H.put_clipped ~grid ~clip:row_rect ~x:(act_inner.x + 1) ~y:!y
                     ~max_w:(Int.max 0 (act_inner.w - 2))
                     ~style:st
                     (Printf.sprintf "%s @%s"
                        (Glyph.to_utf8 Glyph.Live_working)
                        kp));
                incr y
              end)
            (Store_scroll.drop start_i acting_list)
      end
  | Some _ | None -> ()

(* --- 3b. Sub-Tab 3: Code Workspace File Browser + Syntax Viewer + Git --- *)

let workspace_scope_label = Wire_infra.workspace_scope_label

let render_code ~(model : Model.t) ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp grid =
  let lang = model.lang in
  let inf = model.infra in
  let code = inf.code in
  let bar_rect, body_rect =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ a; b ] -> (a, b)
    | _ -> (Rect.empty, rect)
  in
  let scope_lbl = "[s] " ^ workspace_scope_label code.scope in
  let mode_lbl =
    "[v] " ^ Say.resolve lang (Infra_store.code_right_mode_label code.right_mode)
  in
  let pills =
    [
      {
        H.label = scope_lbl;
        active = true;
        tone = Some Theme.Status_active;
        glyph = Some Glyph.Live_healthy;
      };
      {
        H.label = mode_lbl;
        active =
          not
            (Infra_store.equal_code_right_mode code.right_mode
               Infra_store.Code_file);
        tone = Some Theme.Status_ai;
        glyph = None;
      };
    ]
    @
    if String.equal (String.trim inf.filter_query) "" then []
    else
      [
        {
          H.label = "/" ^ inf.filter_query;
          active = true;
          tone = Some Theme.Status_active;
          glyph = None;
        };
      ]
  in
  ignore
    (H.draw_pills ~grid ~rect:bar_rect ~theme
       ~right_hint:
         (Say.resolve lang
            (Say.make ~ko:"[p] 파일 찾기 · [f] 코드 검색 · [v] Git · [y] 복사"
               ~en:"[p] Find · [f] Search · [v] Git · [y] Copy"))
       pills);
  let left_rect, right_rect =
    if model.nav.zoomed && Model.can_zoom_current_view model then
      (Rect.empty, body_rect)
    else
      Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.32
        ~top_ratio:0.42 bp body_rect
  in
  let left_inner =
    Card.draw ~cache grid ~rect:left_rect ~theme
      (H.card_spec ~focused:(Model.pane_focused model 0)
         ~subtitle:(workspace_scope_label code.scope)
         ~hotkey:
           (Say.resolve lang
              (Say.make ~ko:"[Enter] 열기 · [s] 범위" ~en:"[Enter] Open · [s] Scope"))
         (Say.resolve lang
            (Say.make ~ko:"워크스페이스 트리" ~en:"Workspace Tree")))
  in
  if not (Rect.is_empty left_inner) then begin
    let nodes = Infra_store.visible_code_tree_nodes inf in
    if nodes = [] then
      H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp left_inner) ~theme
        (if code.tree_loaded then
           Say.resolve lang
             (Say.make ~ko:"일치하는 파일/디렉터리 없음"
                ~en:"No matching files or directories")
         else
           Say.resolve lang
             (Say.make ~ko:"워크스페이스 트리 불러오는 중…"
                ~en:"Loading workspace tree…"))
    else
      let total = List.length nodes in
      let sel = H.clamp_index total code.tree_selected_index in
      let start_i, _ =
        Table.compute_viewport ~total_rows:total ~viewport_rows:left_inner.h
          ~scroll:code.tree_scroll_offset ~selected:(Some sel)
      in
      let y = ref left_inner.y and bot = Rect.bottom left_inner in
      List.iteri
        (fun local_i (nd : Wire_infra.workspace_tree_node) ->
          let idx = start_i + local_i in
          if !y < bot then begin
            let is_sel = Int.equal idx sel in
            let tree_focused = Model.pane_focused model 0 in
            let row_rect =
              Rect.make ~x:left_inner.x ~y:!y ~w:left_inner.w ~h:1
            in
            let row_bg =
              if is_sel then H.selected_row_bg ~theme ~focused:tree_focused
              else theme.surface_1
            in
            if is_sel then
              H.paint_selected_row_bg ~grid ~clip:left_inner ~row_rect ~theme
                ~focused:tree_focused ();
            let indent = String.make (Int.min 12 (nd.depth * 2)) ' ' in
            let caret =
              if nd.has_children then
                if Infra_store.String_set.mem nd.path code.expanded_dirs then
                  Glyph.to_utf8 Glyph.Expand_open ^ " "
                else Glyph.to_utf8 Glyph.Expand_closed ^ " "
              else "  "
            in
            let diff_s =
              match nd.diff with
              | Some d when not (String.equal (String.trim d) "") -> d
              | Some _ | None -> ""
            in
            let dw = Grapheme.display_width diff_s in
            let st =
              if is_sel then H.anchor_style ~theme ~bg:row_bg ()
              else if nd.has_children then
                H.accent_style ~theme ~bg:row_bg ()
              else H.text_style ~theme ~bg:row_bg ()
            in
            ignore
              (H.put_clipped ~grid ~clip:row_rect ~x:(left_inner.x + 1) ~y:!y
                 ~max_w:(Int.max 0 (left_inner.w - 2 - dw - 1))
                 ~style:st (indent ^ caret ^ nd.label));
            if dw > 0 then
              ignore
                (H.put_right ~grid ~clip:row_rect
                   ~right_x:(Rect.right row_rect - 1) ~y:!y ~max_w:dw
                   ~style:(H.status_style ~theme ~bg:row_bg Theme.Status_attention)
                   diff_s);
            incr y
          end)
        (Store_scroll.drop start_i nodes)
  end;
  let right_subtitle =
    match code.right_mode with
    | Infra_store.Code_file -> (
        match Infra_store.open_file_for_current inf with
        | Some f -> Some f.path
        | None -> None)
    | Infra_store.Code_search_results -> (
        match Observed.to_option code.search_result with
        | Some (sc, res) when Wire_infra.equal_workspace_scope sc code.scope ->
            Some (Printf.sprintf "/%s (%d)" res.query (List.length res.matches))
        | Some _ | None -> None)
    | Infra_store.Code_git_status
    | Infra_store.Code_git_branches
    | Infra_store.Code_git_worktrees
    | Infra_store.Code_git_blame
    | Infra_store.Code_git_log
    | Infra_store.Code_git_diff ->
        Some (workspace_scope_label code.scope)
  in
  let right_inner =
    Card.draw ~cache grid ~rect:right_rect ~theme
      (H.card_spec ?subtitle:right_subtitle
         ~focused:(Model.detail_pane_focused ~detail_index:1 model)
         ~hotkey:
           (Say.resolve lang
              (Say.make ~ko:"[→/Tab] 스크롤 · [v] Git · [p] 찾기 · [f] 검색 · [y] 복사"
                 ~en:"[→/Tab] Scroll · [v] Git · [p] Find · [f] Search · [y] Copy"))
         (Say.resolve lang (Infra_store.code_right_mode_label code.right_mode)))
  in
  let rc = H.pad_content ~bp right_inner in
  if not (Rect.is_empty rc) then begin
    let hdr_rect = Rect.make ~x:rc.x ~y:rc.y ~w:rc.w ~h:1 in
    let vis_rect =
      Rect.make ~x:rc.x ~y:(rc.y + 1) ~w:rc.w ~h:(Int.max 0 (rc.h - 1))
    in
    let draw_plain_scrolled ~scroll (lines : (Theme.status_token option * string) list) =
      let total = List.length lines in
      let vis_h = Int.max 1 vis_rect.h in
      let max_skip = Int.max 0 (total - vis_h) in
      let skip = Int.min max_skip (Int.max 0 scroll) in
      let y = ref vis_rect.y and bot = Rect.bottom vis_rect in
      List.iter
        (fun (tone_opt, txt) ->
          if !y < bot then begin
            let st =
              match tone_opt with
              | Some tone -> H.status_style ~theme tone
              | None -> H.text_style ~theme ()
            in
            ignore
              (H.put_clipped ~grid ~clip:vis_rect ~x:vis_rect.x ~y:!y
                 ~max_w:vis_rect.w ~style:st txt);
            incr y
          end)
        (Store_scroll.drop skip lines)
    in
    match code.right_mode with
    | Infra_store.Code_file -> (
        match Infra_store.open_file_for_current inf with
        | None ->
            ignore
              (H.put_clipped ~grid ~clip:hdr_rect ~x:hdr_rect.x ~y:hdr_rect.y
                 ~max_w:hdr_rect.w ~style:(H.whisper_style ~theme ())
                 (Say.resolve lang
                    (Say.make ~ko:"파일 미선택" ~en:"No file open")));
            (match code.open_file with
            | (Observed.Loading _ | Observed.Failed _) as obs ->
                H.draw_observed_placeholder ~grid ~rect:vis_rect ~theme ~lang obs
            | Observed.Value _ | Observed.Absent | Observed.Unreported ->
                H.draw_empty_notice ~grid ~rect:vis_rect ~theme
                  (Say.resolve lang
                     (Say.make
                        ~ko:"왼쪽 트리에서 파일을 선택하거나 [p]로 검색하세요"
                        ~en:"Select a file from the tree or press [p] to fuzzy-find")))
        | Some f ->
            let rows =
              cached_rows_of_source ~path:f.path ~revision:f.revision
                ~content:f.content
            in
            let total = List.length rows in
            let hdr_txt =
              Printf.sprintf "%s · %d lines · rev %s" f.path total
                (H.short_hash ~len:10 f.revision)
            in
            ignore
              (H.put_clipped ~grid ~clip:hdr_rect ~x:hdr_rect.x ~y:hdr_rect.y
                 ~max_w:hdr_rect.w ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                 hdr_txt);
            if not (Rect.is_empty vis_rect) then begin
              let gutter_w =
                Int.max 4 (String.length (Int.to_string (Int.max 1 total)) + 1)
              in
              let vis_h = Int.max 1 vis_rect.h in
              let max_skip = Int.max 0 (total - vis_h) in
              let skip = Int.min max_skip (Int.max 0 code.file_scroll_offset) in
              let bg = Color.of_rgb theme.surface_1 in
              let code_x = vis_rect.x + gutter_w + 1 in
              let code_w = Int.max 0 (vis_rect.w - gutter_w - 1) in
              List.iteri
                (fun local_i segs ->
                  let py = vis_rect.y + local_i in
                  if py < Rect.bottom vis_rect then begin
                    let lnum =
                      Printf.sprintf "%*d " (gutter_w - 1) (skip + local_i + 1)
                    in
                    ignore
                      (H.put_clipped ~grid ~clip:vis_rect ~x:vis_rect.x ~y:py
                         ~max_w:gutter_w ~style:(H.whisper_style ~theme ()) lnum);
                    if code_w > 0 then
                      ignore
                        (Code_lexer.draw_row ~clip:vis_rect grid ~x:code_x ~y:py
                           ~max_w:code_w ~theme ~bg segs)
                  end)
                (Store_scroll.drop skip rows |> H.safe_take vis_rect.h)
            end)
    | Infra_store.Code_search_results -> (
        match Observed.to_option code.search_result with
        | Some (sc, res) when Wire_infra.equal_workspace_scope sc code.scope ->
            let trunc = if res.truncated then " (truncated)" else "" in
            ignore
              (H.put_clipped ~grid ~clip:hdr_rect ~x:hdr_rect.x ~y:hdr_rect.y
                 ~max_w:hdr_rect.w ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                 (Printf.sprintf "Search \"%s\" · %d matches%s · [Enter] jump"
                    res.query (List.length res.matches) trunc));
            if res.matches = [] then
              H.draw_empty_notice ~grid ~rect:vis_rect ~theme
                (Say.resolve lang
                   (Say.make ~ko:"검색 결과 없음" ~en:"No search matches"))
            else
              let total = List.length res.matches in
              let sel = H.clamp_index total code.search_selected_index in
              let start_i, _ =
                Table.compute_viewport ~total_rows:total
                  ~viewport_rows:(Int.max 1 vis_rect.h)
                  ~scroll:code.git_scroll_offset ~selected:(Some sel)
              in
              let y = ref vis_rect.y and bot = Rect.bottom vis_rect in
              List.iteri
                (fun local_i (mt : Wire_infra.workspace_search_match) ->
                  let idx = start_i + local_i in
                  if !y < bot then begin
                    let is_sel = Int.equal idx sel in
                    let res_focused =
                      Model.detail_pane_focused ~detail_index:1 model
                    in
                    let row_rect =
                      Rect.make ~x:vis_rect.x ~y:!y ~w:vis_rect.w ~h:1
                    in
                    let row_bg =
                      if is_sel then H.selected_row_bg ~theme ~focused:res_focused
                      else theme.surface_1
                    in
                    if is_sel then
                      H.paint_selected_row_bg ~grid ~clip:vis_rect ~row_rect
                        ~theme ~focused:res_focused ();
                    let st =
                      if is_sel && res_focused then
                        H.anchor_style ~theme ~bg:row_bg ()
                      else H.text_style ~theme ~bg:row_bg ()
                    in
                    ignore
                      (H.put_clipped ~grid ~clip:row_rect ~x:vis_rect.x ~y:!y
                         ~max_w:vis_rect.w ~style:st
                         (Printf.sprintf "%s:%d  %s" mt.path mt.line
                            (H.sanitize_single_line mt.text)));
                    incr y
                  end)
                (Store_scroll.drop start_i res.matches)
        | Some _ | None ->
            ignore
              (H.put_clipped ~grid ~clip:hdr_rect ~x:hdr_rect.x ~y:hdr_rect.y
                 ~max_w:hdr_rect.w ~style:(H.whisper_style ~theme ())
                 "Press [f] to run ripgrep search");
            H.draw_observed_placeholder ~grid ~rect:vis_rect ~theme ~lang
              code.search_result)
    | Infra_store.Code_git_status -> (
        match Observed.to_option code.git_status with
        | Some (sc, st) when Wire_infra.equal_workspace_scope sc code.scope ->
            ignore
              (H.put_clipped ~grid ~clip:hdr_rect ~x:hdr_rect.x ~y:hdr_rect.y
                 ~max_w:hdr_rect.w ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                 (Printf.sprintf "Git Status · %d changes" st.total));
            let rows =
              [
                ( Some Theme.Status_active
                , Printf.sprintf "HEAD: %s · Upstream: %s"
                    (Option.value ~default:"-" st.head)
                    (Option.value ~default:"-" st.upstream) );
                ( None
                , Printf.sprintf "Total changed paths: %d" st.total );
              ]
              @ List.map
                  (fun (ch : Wire_infra.git_status_change) ->
                    let flags =
                      Printf.sprintf "%s%s%s%s"
                        (if ch.staged then "S" else ".")
                        (if ch.unstaged then "M" else ".")
                        (if ch.untracked then "?" else ".")
                        (if ch.conflicted then "!" else ".")
                    in
                    let tone =
                      if ch.conflicted then Some Theme.Status_critical
                      else if ch.staged then Some Theme.Status_ok
                      else Some Theme.Status_attention
                    in
                    (tone, Printf.sprintf "[%s] %s" flags ch.path))
                  st.changes
            in
            draw_plain_scrolled ~scroll:code.git_scroll_offset rows
        | Some _ | None ->
            H.draw_observed_placeholder ~grid ~rect:vis_rect ~theme ~lang
              code.git_status)
    | Infra_store.Code_git_branches -> (
        match Observed.to_option code.git_branches with
        | Some (sc, bs) when Wire_infra.equal_workspace_scope sc code.scope ->
            ignore
              (H.put_clipped ~grid ~clip:hdr_rect ~x:hdr_rect.x ~y:hdr_rect.y
                 ~max_w:hdr_rect.w ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                 (Printf.sprintf "Git Branches (%d)" (List.length bs)));
            let rows =
              List.map
                (fun (b : Wire_infra.git_branch_entry) ->
                  let ab =
                    match b.ahead, b.behind with
                    | Some a, Some bh -> Printf.sprintf "+%d/-%d" a bh
                    | Some a, None -> Printf.sprintf "+%d" a
                    | None, Some bh -> Printf.sprintf "-%d" bh
                    | None, None -> ""
                  in
                  let tone = if b.current then Some Theme.Status_ok else None in
                  ( tone
                  , Printf.sprintf "%s %-22s %-8s %s"
                      (if b.current then "*" else " ")
                      b.name ab
                      (H.sanitize_single_line b.subject) ))
                bs
            in
            draw_plain_scrolled ~scroll:code.git_scroll_offset rows
        | Some _ | None ->
            H.draw_observed_placeholder ~grid ~rect:vis_rect ~theme ~lang
              code.git_branches)
    | Infra_store.Code_git_worktrees -> (
        match Observed.to_option code.git_worktrees with
        | Some (sc, ws) when Wire_infra.equal_workspace_scope sc code.scope ->
            ignore
              (H.put_clipped ~grid ~clip:hdr_rect ~x:hdr_rect.x ~y:hdr_rect.y
                 ~max_w:hdr_rect.w ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                 (Printf.sprintf "Git Worktrees (%d)" (List.length ws)));
            let rows =
              List.map
                (fun (wt : Wire_infra.git_worktree_entry) ->
                  let flags =
                    String.trim
                      ((if wt.locked then "locked " else "")
                      ^ if wt.prunable then "prunable" else "")
                  in
                  let tone =
                    if wt.main then Some Theme.Status_ok
                    else if wt.prunable then Some Theme.Status_attention
                    else None
                  in
                  ( tone
                  , Printf.sprintf "%s %-18s [%s] %s %s"
                      (if wt.main then "*" else " ")
                      wt.name wt.state
                      (Option.value ~default:"-" wt.branch)
                      flags ))
                ws
            in
            draw_plain_scrolled ~scroll:code.git_scroll_offset rows
        | Some _ | None ->
            H.draw_observed_placeholder ~grid ~rect:vis_rect ~theme ~lang
              code.git_worktrees)
    | Infra_store.Code_git_blame -> (
        let expected_path = Infra_store.active_code_file_path inf in
        match Observed.to_option code.git_blame with
        | Some (sc, path, bs)
          when Wire_infra.equal_workspace_scope sc code.scope
               && (match expected_path with
                  | Some exp -> String.equal exp path
                  | None -> true) ->
            ignore
              (H.put_clipped ~grid ~clip:hdr_rect ~x:hdr_rect.x ~y:hdr_rect.y
                 ~max_w:hdr_rect.w ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                 (Printf.sprintf "Git Blame · %s (%d spans)" path (List.length bs)));
            let rows =
              List.map
                (fun (b : Wire_infra.git_blame_entry) ->
                  ( Some Theme.Status_active
                  , Printf.sprintf "L%d-%d  @%s  [%s]  %s" b.line_start
                      b.line_end b.keeper_id b.kind b.file_path ))
                bs
            in
            draw_plain_scrolled ~scroll:code.git_scroll_offset rows
        | Some _ | None ->
            H.draw_observed_placeholder ~grid ~rect:vis_rect ~theme ~lang
              code.git_blame)
    | Infra_store.Code_git_log -> (
        let expected_path = Infra_store.active_code_file_path inf in
        match Observed.to_option code.git_log with
        | Some (sc, path, cs)
          when Wire_infra.equal_workspace_scope sc code.scope
               && (match expected_path with
                  | Some exp -> String.equal exp path
                  | None -> true) ->
            let p_lbl = if String.equal path "" then "repo" else path in
            ignore
              (H.put_clipped ~grid ~clip:hdr_rect ~x:hdr_rect.x ~y:hdr_rect.y
                 ~max_w:hdr_rect.w ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                 (Printf.sprintf "Git Log · %s (%d commits)" p_lbl
                    (List.length cs)));
            let rows =
              List.map
                (fun (c : Wire_infra.git_log_commit) ->
                  ( None
                  , Printf.sprintf "%s  %-14s  %s"
                      (H.short_hash ~len:8 c.hash)
                      c.author
                      (H.sanitize_single_line c.subject) ))
                cs
            in
            draw_plain_scrolled ~scroll:code.git_scroll_offset rows
        | Some _ | None ->
            H.draw_observed_placeholder ~grid ~rect:vis_rect ~theme ~lang
              code.git_log)
    | Infra_store.Code_git_diff -> (
        let expected_path = Infra_store.active_code_file_path inf in
        match Observed.to_option code.git_diff with
        | Some (sc, path, df)
          when Wire_infra.equal_workspace_scope sc code.scope
               && (match expected_path with
                  | Some exp -> String.equal exp path
                  | None -> true) ->
            let p_lbl = if String.equal path "" then "working tree" else path in
            ignore
              (H.put_clipped ~grid ~clip:hdr_rect ~x:hdr_rect.x ~y:hdr_rect.y
                 ~max_w:hdr_rect.w ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                 (Printf.sprintf "Git Diff · %s (%d lines)" p_lbl
                    (List.length df.lines)));
            if not df.has_changes && df.lines = [] then
              H.draw_empty_notice ~grid ~rect:vis_rect ~theme
                (Say.resolve lang
                   (Say.make ~ko:"변경 사항 없음" ~en:"No working tree changes"))
            else
              let rows =
                List.map
                  (fun (ln : Wire_infra.git_diff_line) ->
                    let sign, tone =
                      match ln.kind with
                      | `Add -> ("+", Some Theme.Status_ok)
                      | `Delete -> ("-", Some Theme.Status_critical)
                      | `Context -> (" ", None)
                    in
                    let lno =
                      match ln.new_line, ln.old_line with
                      | Some n, _ -> Printf.sprintf "%4d " n
                      | None, Some o -> Printf.sprintf "%4d " o
                      | None, None -> "     "
                    in
                    (tone, Printf.sprintf "%s%s %s" lno sign ln.text))
                  df.lines
              in
              draw_plain_scrolled ~scroll:code.git_scroll_offset rows
        | Some _ | None ->
            H.draw_observed_placeholder ~grid ~rect:vis_rect ~theme ~lang
              code.git_diff)
  end

(* --- 4. Top-Level Infra Render & Dive Render (ZERO Nested Cards!) --- *)

let render ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Theme.of_preset model.theme_preset in
    let bp = H.layout_bp ~model ~rect in
    let body = H.body_rect ~bp rect in
    match model.infra.active_tab with
    | Nav.Infra_sandboxes -> render_sandboxes ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Infra_repos_changes ->
        render_repos_changes ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Infra_code ->
        render_code ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Infra_activity_logs ->
        render_activity_logs ~model ~cache ~rect:body ~theme ~bp grid

let draw_tail_logs ?(scroll = 0) ~grid ~(rect : Rect.t) ~(theme : Theme.t) ~lang
    ~tz_offset_sec ~filter_opt (logs : Wire_infra.system_log_entry list) =
  if Rect.is_empty rect then ()
  else
    let matching =
      match filter_opt with
      | None -> logs
      | Some needle ->
          List.filter
            (fun (e : Wire_infra.system_log_entry) ->
              let kp_match =
                match e.keeper with
                | Some k -> String.equal k needle
                | None -> false
              in
              kp_match || String.equal e.module_name needle)
            logs
    in
    if matching = [] then
      H.draw_empty_notice ~grid ~rect ~theme
        (Say.resolve lang
           (Say.make ~ko:"일치하는 최근 로그 없음" ~en:"No matching tail logs"))
    else
      let skip =
        Int.min
          (Int.max 0 (List.length matching - rect.h))
          (Int.max 0 scroll)
      in
      let y = ref rect.y and bot = Rect.bottom rect in
      List.iter
        (fun (e : Wire_infra.system_log_entry) ->
          if !y < bot then begin
            let lvl_s, tone = log_level_badge e.level in
            let ts = H.format_local_hhmmss ~tz_offset_sec e.ts in
            let tw =
              H.put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:8
                ~style:(H.whisper_style ~theme ()) ts
            in
            let lw =
              H.put_clipped ~grid ~clip:rect ~x:(rect.x + tw + 1) ~y:!y ~max_w:5
                ~style:(H.status_style ~theme ~attrs:Attr.bold tone)
                ("[" ^ lvl_s ^ "]")
            in
            ignore
              (H.put_clipped ~grid ~clip:rect ~x:(rect.x + tw + lw + 2) ~y:!y
                 ~max_w:(Int.max 0 (rect.w - tw - lw - 2))
                 ~style:(H.text_style ~theme ())
                 (Printf.sprintf "%s: %s" e.module_name
                    (H.sanitize_single_line e.message)));
            incr y
          end)
        (Store_scroll.drop skip matching |> H.safe_take rect.h)

let incident_source_display = function
  | Health.Source_keeper k -> ("keeper", Some k)
  | Health.Source_runtime r -> ("runtime:" ^ r, None)
  | Health.Source_sandbox s -> ("sandbox:" ^ s, Some s)
  | Health.Source_client_http -> ("client_http", None)
  | Health.Source_stream -> ("sse_stream", None)

let incident_status_label ~lang = function
  | Health.Resolved -> Say.resolve lang (Say.make ~ko:"해소됨" ~en:"Resolved")
  | Health.Retried -> Say.resolve lang (Say.make ~ko:"재시도됨" ~en:"Retried")
  | Health.Superseded ->
      Say.resolve lang (Say.make ~ko:"대체됨" ~en:"Superseded")
  | Health.Dismissed -> Say.resolve lang (Say.make ~ko:"숨김" ~en:"Dismissed")

let render_dive_incident ~incident_id ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let inf = model.infra in
  let inc_opt = Incidents.find_by_id incident_id model.incidents in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ~focused:(Model.body_has_focus model)
         ~subtitle:("#" ^ string_of_int incident_id)
         ~badge:
           (H.make_badge ~glyph:Glyph.Historical_incident
              ~tone:Theme.Status_historical
              (if inf.show_raw_json then "[Space] Json_tree ON"
               else
                 Say.resolve lang
                   (Say.make ~ko:"이력 원장 (Ch3)" ~en:"History Ledger (Ch3)")))
         ~hotkey:(Say.resolve lang (Say.make ~ko:"[Esc] 뒤로" ~en:"[Esc] Back"))
         (Printf.sprintf "%s > %s"
            (Say.resolve lang (Nav.workspace_label model.nav.workspace))
            (Say.resolve lang
               (Say.make ~ko:"과거 사건 상세" ~en:"Incident Dive"))))
  in
  if Rect.is_empty inner then ()
  else
    match inc_opt with
    | None ->
        H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp inner) ~theme
          (Say.resolve lang
             (Say.make ~ko:"해당 ID의 과거 사건을 찾을 수 없습니다"
                ~en:"Incident ID not found in historical ledger"))
    | Some inc ->
        let src_lbl, filter_opt = incident_source_display inc.source in
        let embedded_json = H.extract_embedded_json inc.detail in
        if inf.show_raw_json then
          let detail_fields =
            match embedded_json with
            | Some (prefix, parsed_json) ->
                let pref_field =
                  if String.equal prefix "" then []
                  else [ ("detail_prefix", `String (H.redact_secrets_in_text prefix)) ]
                in
                pref_field @ [ ("detail", parsed_json) ]
            | None -> [ ("detail", `String (H.redact_secrets_in_text inc.detail)) ]
          in
          let json =
            `Assoc
              ([
                 ("id", `Int inc.id);
                 ( "occurred_at"
                 , `String (Wire_common.format_unix_rfc3339 inc.occurred_at_unix)
                 );
                 ("source", `String src_lbl);
                 ("status", `String (incident_status_label ~lang inc.status));
                 ("summary", `String (Say.resolve lang inc.summary));
               ]
              @ detail_fields)
          in
          let lines = Json_tree.flatten ~max_depth:5 ~redact_secrets:true json in
          ignore
            (Json_tree.draw grid ~rect:(H.pad_content ~bp inner) ~theme
               ~scroll:model.nav.dive_scroll_offset lines)
        else
          let pad_x = Layout.card_pad_x bp in
          let band_h = if inner.h >= 6 then 2 else 1 in
          Card.draw_section_band ~pad_x grid
            ~rect:(Rect.make ~x:inner.x ~y:inner.y ~w:inner.w ~h:band_h)
            ~theme ~left_title:(Say.resolve lang inc.summary)
            ~right_meta:(Wire_common.format_unix_rfc3339 inc.occurred_at_unix)
            ?subtitle:
              (if band_h >= 2 then
                 Some
                   (Printf.sprintf "%s [%s] %s"
                      (Glyph.to_utf8 Glyph.Historical_incident)
                      (incident_status_label ~lang inc.status)
                      src_lbl)
               else None)
            ();
          let content =
            Rect.make ~x:inner.x ~y:(inner.y + band_h) ~w:inner.w
              ~h:(Int.max 0 (inner.h - band_h))
            |> H.pad_content ~bp
          in
          if not (Rect.is_empty content) then begin
            let y = ref content.y and bot = Rect.bottom content in
            let rem = Int.max 0 (bot - !y) in
            let detail_h = Int.max 0 (rem / 2) in
            let detail_max =
              if detail_h <= 0 then 0
              else
                match embedded_json with
                | Some (prefix, parsed_json) ->
                    let used = if String.equal prefix "" then 0 else 1 in
                    let tree_h = Int.max 1 (detail_h - used) in
                    let lines =
                      Json_tree.flatten ~max_depth:4 ~redact_secrets:true
                        parsed_json
                    in
                    Int.max 0 (List.length lines - tree_h)
                | None ->
                    let safe_detail = H.redact_secrets_in_text inc.detail in
                    let total_md =
                      List.length
                        (Markdown.render_lines ~theme ~width:content.w
                           ~osc8:true safe_detail)
                    in
                    Int.max 0 (total_md - detail_h)
            in
            let top_scroll = Int.min detail_max model.nav.dive_scroll_offset in
            let log_scroll = Int.max 0 (model.nav.dive_scroll_offset - detail_max) in
            if detail_h > 0 then begin
              (match embedded_json with
               | Some (prefix, parsed_json) ->
                   let used = ref 0 in
                   if (not (String.equal prefix "")) && !used < detail_h then begin
                     ignore
                       (H.put_clipped ~grid ~clip:content ~x:content.x
                          ~y:(!y + !used) ~max_w:content.w
                          ~style:(H.secondary_style ~theme ())
                          (H.redact_secrets_in_text prefix));
                     incr used
                   end;
                   let tree_h = Int.max 0 (detail_h - !used) in
                   if tree_h > 0 then begin
                     let tree_rect =
                       Rect.make ~x:content.x ~y:(!y + !used) ~w:content.w
                         ~h:tree_h
                     in
                     let lines =
                       Json_tree.flatten ~max_depth:4 ~redact_secrets:true
                         parsed_json
                     in
                     ignore
                       (Json_tree.draw grid ~rect:tree_rect ~theme
                          ~scroll:top_scroll lines)
                   end
               | None ->
                   let md_rect =
                     Rect.make ~x:content.x ~y:!y ~w:content.w ~h:detail_h
                   in
                   let safe_detail = H.redact_secrets_in_text inc.detail in
                   ignore
                     (Markdown.draw grid ~rect:md_rect ~theme ~osc8:true
                        ~scroll:top_scroll safe_detail));
              y := !y + detail_h
            end;
            if !y < bot then begin
              H.draw_divider ~grid ~rect:content ~y:!y ~theme
                ~label:
                  (Say.resolve lang (Say.make ~ko:"연관 로그" ~en:"Related Logs"))
                ();
              incr y;
              let log_area =
                Rect.make ~x:content.x ~y:!y ~w:content.w
                  ~h:(Int.max 0 (bot - !y))
              in
              draw_tail_logs ~scroll:log_scroll ~grid ~rect:log_area ~theme
                ~lang ~tz_offset_sec:model.tz_offset_sec ~filter_opt inf.logs
            end
          end

let render_dive_runtime_trace ~keeper ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let inf = model.infra in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ~focused:(Model.body_has_focus model) ~subtitle:("@" ^ keeper)
         ~hotkey:
           (Say.resolve lang
              (Say.make ~ko:"[↑↓] 스크롤 · [r] 새로고침 · [Esc] 뒤로"
                 ~en:"[↑↓] Scroll · [r] Reload · [Esc] Back"))
         (Say.resolve lang
            (Say.make ~ko:"인프라 > 키퍼 런타임 트레이스"
               ~en:"Infra > Keeper Runtime Trace")))
  in
  let content = H.pad_content ~bp inner in
  if Rect.is_empty content then ()
  else
    match Infra_store.runtime_trace_for ~keeper inf with
    | None ->
        H.draw_observed_placeholder ~grid ~rect:content ~theme ~lang
          inf.runtime_trace
    | Some tr ->
        let y = ref content.y and bot = Rect.bottom content in
        if !y < bot then begin
          ignore
            (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
               ~max_w:content.w
               ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
               (Printf.sprintf "Keeper: @%s · Trace: %s · Health: %s" tr.keeper
                  tr.trace_id tr.health));
          incr y
        end;
        if !y < bot then begin
          let turn_s =
            match tr.turn_id with
            | Some t -> Printf.sprintf "#%d" t
            | None -> "-"
          in
          let stale_s =
            match tr.stale_reason with
            | Some sr -> " · stale: " ^ sr
            | None -> ""
          in
          ignore
            (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
               ~max_w:content.w ~style:(H.secondary_style ~theme ())
               (Printf.sprintf "Turn: %s · Manifest: %d/%d · Receipts: %d%s"
                  turn_s tr.manifest_returned_rows tr.manifest_total_rows
                  tr.receipt_returned_rows stale_s));
          incr y
        end;
        if !y < bot then begin
          H.draw_divider ~grid ~rect:content ~y:!y ~theme
            ~label:
              (Say.resolve lang
                 (Say.make ~ko:"트레이스 원문 (Json_tree)"
                    ~en:"Runtime Trace Payload"))
            ();
          incr y
        end;
        let tree_h = Int.max 0 (bot - !y) in
        if tree_h > 0 then begin
          let tree_rect =
            Rect.make ~x:content.x ~y:!y ~w:content.w ~h:tree_h
          in
          let lines =
            Json_tree.flatten ~max_depth:4 ~redact_secrets:true tr.raw
          in
          ignore
            (Json_tree.draw grid ~rect:tree_rect ~theme
               ~scroll:model.nav.dive_scroll_offset lines)
        end

let render_dive ~(target : Nav.infra_dive_target) ~(model : Model.t) ~cache
    ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Theme.of_preset model.theme_preset in
    let bp = H.layout_bp ~model ~rect in
    let body = H.body_rect ~bp rect in
    match target with
    | Nav.Incident_dive incident_id ->
        render_dive_incident ~incident_id ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Runtime_trace_dive keeper ->
        render_dive_runtime_trace ~keeper ~model ~cache ~rect:body ~theme ~bp grid
