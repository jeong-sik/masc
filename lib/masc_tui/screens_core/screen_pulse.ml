open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let caps = Presenter.default_capabilities

(* ---------- Shared Pulse Selectors & Formatters ---------- *)

let attention_items_for_grouping (m : Model.t) =
  List.map
    (fun (e : Attention.entry) : Wire_fleet.attention_item ->
      let bucket =
        match e.kind with
        | Health.Pending_ask _ -> Wire_fleet.Bucket_asks
        | Health.Held_tool_approval _ -> Wire_fleet.Bucket_approvals
        | Health.Goal_confirmation _ -> Wire_fleet.Bucket_confirmations
      in
      {
        Wire_fleet.id = e.id;
        bucket;
        kind = e.kind;
        title = e.title;
        summary = e.summary;
        created_at_unix = e.created_at_unix;
        keeper = e.keeper;
      })
    m.attention.items

let company_groups_for_pulse (m : Model.t) =
  let attn_items = attention_items_for_grouping m in
  let keeper_costs_24h = Runtime_store.keeper_costs_24h_assoc m.runtime in
  Fleet_store.company_groups_with_costs ~attention:attn_items ~keeper_costs_24h
    m.fleet

let sparkline_samples_of_floats (xs : float list) =
  match xs with
  | [] -> [||]
  | _ ->
      let arr = Array.of_list xs in
      Array.map
        (fun v ->
          if not (Float.is_finite v) then Chart.Series.Unread
          else if v <= 0.0 then Chart.Series.Zero
          else Chart.Series.Value v)
        arr

let fleet_sparkline_samples (groups : Wire_fleet.company_group list) =
  let max_len =
    List.fold_left
      (fun acc (g : Wire_fleet.company_group) ->
        Int.max acc (List.length g.sparkline_24h))
      0 groups
  in
  if max_len = 0 then [||]
  else
    let sums = Array.make max_len 0.0 in
    let seen = Array.make max_len false in
    List.iter
      (fun (g : Wire_fleet.company_group) ->
        let arr = Array.of_list g.sparkline_24h in
        let n = Array.length arr in
        let offset = max_len - n in
        for i = 0 to n - 1 do
          let v = arr.(i) in
          if Float.is_finite v then begin
            sums.(offset + i) <- sums.(offset + i) +. Float.max 0.0 v;
            seen.(offset + i) <- true
          end
        done)
      groups;
    Array.init max_len (fun i ->
        if not seen.(i) then Chart.Series.Unread
        else if sums.(i) <= 0.0 then Chart.Series.Zero
        else Chart.Series.Value sums.(i))

let heap_summary (m : Model.t) =
  match m.server_identity.health with
  | Some { gc = Some { live_words = Some live; heap_words = Some heap; _ }; _ }
    when heap > 0 ->
      let live_b = float_of_int live *. 8.0 in
      let heap_b = float_of_int heap *. 8.0 in
      Some
        (Printf.sprintf "%s/%s"
           (Format_val.format_value Format_val.Bytes live_b)
           (Format_val.format_value Format_val.Bytes heap_b))
  | Some _ | None -> None

let latest_velocity_pair (m : Model.t) =
  match Observed.to_option m.runtime.efficiency with
  | None -> None
  | Some eff -> (
      match List.rev eff.velocity with
      | [] -> None
      | last :: _ -> (
          let up =
            match
              ( Observed.to_option last.input_tok_per_min,
                Observed.to_option last.cache_read_tok_per_min )
            with
            | Some a, Some b -> Some (Float.max a b)
            | Some a, None -> Some a
            | None, Some b -> Some b
            | None, None -> None
          in
          let dn = Observed.to_option last.output_tok_per_min in
          match (up, dn) with
          | Some u, Some d -> Some (u, d)
          | Some _, None | None, Some _ | None, None -> None))

let goal_linked_progress ~(model : Model.t) (g : Wire_work.goal) =
  let tasks = Work_store.tasks model.work in
  let linked, done_n =
    List.fold_left
      (fun (tot, dn) (t : Wire_work.task) ->
        match t.goal_link with
        | Wire_work.Linked gid when String.equal gid g.id ->
            let dn' =
              match t.status with
              | Wire_work.Done _ -> dn + 1
              | Wire_work.Todo
              | Wire_work.Claimed _
              | Wire_work.InProgress _
              | Wire_work.AwaitingVerification _
              | Wire_work.Cancelled _ ->
                  dn
            in
            (tot + 1, dn')
        | Wire_work.Linked _ | Wire_work.Unlinked -> (tot, dn))
      (0, 0) tasks
  in
  let declared =
    match Observed.to_option g.linked_task_count with
    | Some n when n > linked -> n
    | Some _ | None -> linked
  in
  let ratio =
    match g.phase with
    | Wire_work.Completed -> 1.0
    | Wire_work.Awaiting_confirmation -> 0.9
    | Wire_work.Verifying -> 0.75
    | Wire_work.Executing
    | Wire_work.Dropped
    | Wire_work.Paused _
    | Wire_work.Blocked _ ->
        if declared > 0 then
          Float.min 1.0 (float_of_int done_n /. float_of_int declared)
        else 0.0
  in
  (done_n, declared, ratio)

let top_contributors_summary (m : Model.t) =
  match Observed.to_option m.fleet.keepers with
  | None | Some [] -> ""
  | Some ks ->
      let score (k : Wire_fleet.keeper_summary) =
        match Observed.to_option k.total_turns with Some n -> n | None -> 0
      in
      let sorted =
        List.sort (fun a b -> Int.compare (score b) (score a)) ks
      in
      let rec take n acc = function
        | _ when n <= 0 -> List.rev acc
        | [] -> List.rev acc
        | (k : Wire_fleet.keeper_summary) :: rest ->
            let s = score k in
            let item =
              if s > 0 then Printf.sprintf "%s(%d)" k.name s else k.name
            in
            take (n - 1) (item :: acc) rest
      in
      String.concat ", " (take 3 [] sorted)

let format_observed_marker ~lang (obs : _ Observed.t) =
  match obs with
  | Observed.Loading _ -> Glyph.to_utf8 Glyph.Ellipsis
  | Observed.Absent -> Glyph.to_utf8 Glyph.Missing_absent
  | Observed.Unreported ->
      Say.resolve lang (Say.make ~ko:"? 미보고" ~en:"? Unreported")
  | Observed.Failed _ ->
      Say.resolve lang (Say.make ~ko:"✕ 오류" ~en:"✕ Error")
  | Observed.Value _ -> Glyph.to_utf8 Glyph.Missing_absent

let candle_hero_display ~lang ~(theme : Theme.t) ~bg ~(model : Model.t)
    ~(hero : Model.pulse_hero_metrics) =
  let spark = Glyph.to_utf8 Glyph.Ai_spark in
  match hero.candle_circulating_milli with
  | Some raw ->
      ( Printf.sprintf "%s %s" spark (Render_util.format_milli_candles raw),
        Typography.ai ~bg ~bold:true theme )
  | None -> (
      match model.work.candle_ledger with
      | Observed.Value { data; _ } ->
          ( Printf.sprintf "%s %s" spark
              (Render_util.format_milli_candles data.issued_milli),
            Typography.ai ~bg ~bold:true theme )
      | ( Observed.Loading _ | Observed.Absent | Observed.Unreported
        | Observed.Failed _ ) as obs ->
          let st =
            match obs with
            | Observed.Failed _ ->
                Typography.status ~bg ~bold:true theme Theme.Status_critical
            | Observed.Loading _ | Observed.Absent | Observed.Unreported
            | Observed.Value _ ->
                Typography.whisper ~bg theme
          in
          ( Printf.sprintf "%s %s" spark (format_observed_marker ~lang obs),
            st ))

let candle_unattributed_count (m : Model.t) =
  match Observed.to_option m.work.candle_ledger with
  | Some l -> l.diagnostics.unattributed_count
  | None -> 0

let put_left_right grid ~(clip : Rect.t) ~y ~left_text ~left_style ~right_text
    ~right_style =
  if clip.w <= 0 then ()
  else
    let nat_r =
      if String.equal right_text "" then 0
      else Grapheme.display_width right_text
    in
    let rw =
      if nat_r = 0 then 0
      else Int.min (Int.max (clip.w / 2) (clip.w * 3 / 5)) nat_r
    in
    let left_max =
      if rw > 0 then Int.max 0 (clip.w - rw - 1) else clip.w
    in
    let adv =
      if left_max > 0 then
        Cell_grid.put_text ~clip grid ~x:clip.x ~y ~style:left_style
          (Grapheme.truncate_to_width ~max_width:left_max left_text)
      else 0
    in
    if rw > 0 then begin
      let fit_r = Grapheme.truncate_to_width ~max_width:rw right_text in
      let fw = Grapheme.display_width fit_r in
      let rx = Rect.right clip - fw in
      if rx >= clip.x + adv + 1 then
        ignore (Cell_grid.put_text ~clip grid ~x:rx ~y ~style:right_style fit_r)
    end

(* ---------- Top 4-KPI Hero Band (h=4, surface_1 + v-hairlines, ZERO nested boxes) ---------- *)

let render_kpi_hero_band grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~(groups : Wire_fleet.company_group list) ~bp =
  if Rect.is_empty rect then ()
  else
    let lang = model.lang in
    let bg = Color.of_rgb theme.surface_1 in
    let hero = Model.pulse_hero_metrics model in
    let sc = Model.effective_scorecard model in
    let task_counts = Work_store.effective_task_counts model.work in
    let v_pass_w, v_rej_w, v_await_w =
      Work_store.verification_pass_summary model.work
    in
    let v_pass =
      match Observed.to_option sc.verifications_passed_24h with
      | Some n when n > v_pass_w -> n
      | Some _ | None -> v_pass_w
    in
    let v_rej =
      match Observed.to_option sc.verifications_rejected_24h with
      | Some n when n > v_rej_w -> n
      | Some _ | None -> v_rej_w
    in
    let anchor_st = Typography.anchor ~bg theme in
    let pri_st = Typography.primary ~bg theme in
    let struct_st = Typography.structure ~bg theme in
    let whisper_st = Typography.whisper ~bg theme in
    let ok_st = Typography.status ~bg ~bold:true theme Theme.Status_ok in
    let act_st = Typography.status ~bg ~bold:true theme Theme.Status_active in
    let attn_st =
      Typography.status ~bg ~bold:true theme Theme.Status_attention
    in
    Cell_grid.fill_rect ~clip:rect grid ~rect ~style:pri_st ();
    let pad_x = if Layout.equal_breakpoint bp Layout.Wide then 2 else 1 in
    let compact =
      Layout.equal_breakpoint bp Layout.Compact
      || Layout.equal_breakpoint bp Layout.Micro
    in
    (* Precompute truthful metric values across live 8935 & isolated 18935 *)
    let fleet_vm, fleet_ssh, fleet_dk =
      if hero.microvm_count + hero.ssh_count + hero.docker_count > 0 then
        (hero.microvm_count, hero.ssh_count, hero.docker_count)
      else Fleet_store.fleet_infra_counts model.fleet
    in
    let infra_mix =
      if fleet_vm + fleet_ssh + fleet_dk > 0 then
        let base = Printf.sprintf "%dvm · %dssh" fleet_vm fleet_ssh in
        if fleet_dk > 0 then Printf.sprintf "%s · %ddk" base fleet_dk else base
      else
        match heap_summary model with
        | Some h ->
            Say.resolve lang (Say.make ~ko:("힙 " ^ h) ~en:("Heap " ^ h))
        | None ->
            Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%d 조직" (Int.max hero.company_count (List.length groups)))
                 ~en:(Printf.sprintf "%d cos" (Int.max hero.company_count (List.length groups))))
    in
    let roster_ks =
      match Observed.to_option model.fleet.keepers with
      | Some ks -> ks
      | None -> []
    in
    let fleet_hc = Fleet_store.fleet_health_counts roster_ks in
    let hero_active_k, hero_total_k, failing_total =
      if fleet_hc.total > 0 then
        (fleet_hc.active, fleet_hc.total, fleet_hc.failing)
      else
        let ft =
          List.fold_left
            (fun acc (g : Wire_fleet.company_group) -> acc + g.failing_count)
            0 groups
        in
        (hero.running_keepers, hero.total_keepers, ft)
    in
    let turns_str =
      match Observed.to_option hero.turns_24h with
      | Some n ->
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "%s 턴"
                      (Format_val.format_value Format_val.Count (float_of_int n)))
               ~en:(Printf.sprintf "%s turns"
                      (Format_val.format_value Format_val.Count (float_of_int n))))
      | None -> (
          match Fleet_store.total_turns_24h model.fleet with
          | Some n ->
              Say.resolve lang
                (Say.make
                   ~ko:(Printf.sprintf "%s 턴"
                          (Format_val.format_value Format_val.Count (float_of_int n)))
                   ~en:(Printf.sprintf "%s turns"
                          (Format_val.format_value Format_val.Count (float_of_int n))))
          | None ->
              let slot_n =
                match Observed.to_option model.runtime.runtime_resolved with
                | Some rr -> List.length rr.runtimes
                | None -> (
                    match Observed.to_option model.fleet.shell with
                    | Some sh -> sh.counts.total_runtimes
                    | None -> 0)
              in
              Say.resolve lang
                (Say.make
                   ~ko:(Printf.sprintf "슬롯 %d" slot_n)
                   ~en:(Printf.sprintf "%d slots" slot_n)))
    in
    let crit_st = Typography.status ~bg ~bold:true theme Theme.Status_critical in
    let cache_pct_opt = Observed.to_option hero.cache_hit_pct in
    let cache_str =
      Format_val.format_observed Format_val.Percent hero.cache_hit_pct ~lang
    in
    let cache_st =
      match hero.cache_hit_pct with
      | Observed.Value { data; _ } ->
          if data >= 80.0 then ok_st else anchor_st
      | Observed.Failed _ -> crit_st
      | Observed.Loading _ | Observed.Absent | Observed.Unreported ->
          whisper_st
    in
    let spend_bd = Runtime_store.spend_24h_breakdown model.runtime in
    let spend_obs =
      match spend_bd.total_usd with
      | Observed.Value _ as v -> v
      | Observed.Loading _ | Observed.Absent | Observed.Unreported
      | Observed.Failed _ -> (
          match sc.cost_24h_usd with
          | Observed.Value _ as v -> v
          | Observed.Loading _ | Observed.Absent | Observed.Unreported
          | Observed.Failed _ ->
              hero.spend_24h_usd)
    in
    let spend_str = Format_val.format_observed Format_val.Usd spend_obs ~lang in
    let spend_st =
      match spend_obs with
      | Observed.Value _ -> act_st
      | Observed.Failed _ -> crit_st
      | Observed.Loading _ | Observed.Absent | Observed.Unreported ->
          whisper_st
    in
    let spend_kpi_label =
      match spend_bd.source with
      | Runtime_store.Spend_provider_24h ->
          Say.resolve lang
            (Say.make ~ko:"24h 캐시 · 프로바이더" ~en:"24h Cache · Prov")
      | Runtime_store.Spend_keeper_turns_24h ->
          Say.resolve lang
            (Say.make ~ko:"24h 캐시 · 키퍼 귀속" ~en:"24h Cache · Keeper")
      | Runtime_store.Spend_unreported ->
          Say.resolve lang (Say.make ~ko:"24h 캐시 · 비용" ~en:"24h Cache & Cost")
    in
    let calls_p95_str, calls_p95_st =
      match
        ( Observed.to_option hero.tool_calls_24h,
          Observed.to_option hero.p95_latency_ms )
      with
      | Some c, Some ms ->
          ( Printf.sprintf "%s · p95 %s"
              (Format_val.format_value Format_val.Count (float_of_int c))
              (Format_val.format_value Format_val.Milliseconds ms),
            struct_st )
      | Some c, None ->
          ( Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%s 호출"
                        (Format_val.format_value Format_val.Count (float_of_int c)))
                 ~en:(Printf.sprintf "%s calls"
                        (Format_val.format_value Format_val.Count (float_of_int c)))),
            struct_st )
      | None, Some ms ->
          ( Printf.sprintf "p95 %s"
              (Format_val.format_value Format_val.Milliseconds ms),
            struct_st )
      | None, None -> (
          match Observed.to_option model.runtime.runtime_probe with
          | Some pr ->
              ( Say.resolve lang
                  (Say.make
                     ~ko:(Printf.sprintf "%d/%d 슬롯" pr.reachable_count
                            pr.runtimes_count)
                     ~en:(Printf.sprintf "%d/%d slots" pr.reachable_count
                            pr.runtimes_count)),
                struct_st )
          | None ->
              ( Format_val.format_observed Format_val.Count
                  (Observed.map float_of_int hero.tool_calls_24h)
                  ~lang,
                whisper_st ))
    in
    let done_lbl, done_st, done_compact_lbl =
      match Observed.to_option hero.tasks_done_24h with
      | Some n ->
          ( Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%d 완료" n)
                 ~en:(Printf.sprintf "%d done" n)),
            anchor_st,
            Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%d완료" n)
                 ~en:(Printf.sprintf "%d done" n)) )
      | None -> (
          let total_opt =
            match Observed.to_option hero.tasks_done_total with
            | Some _ as v -> v
            | None -> (
                match task_counts with Some c -> Some c.done_total | None -> None)
          in
          match total_opt with
          | Some n ->
              ( Say.resolve lang
                  (Say.make
                     ~ko:(Printf.sprintf "누적 %d" n)
                     ~en:(Printf.sprintf "Total %d" n)),
                anchor_st,
                Say.resolve lang
                  (Say.make
                     ~ko:(Printf.sprintf "누적 %d" n)
                     ~en:(Printf.sprintf "Tot %d" n)) )
          | None ->
              let m =
                Format_val.format_observed Format_val.Count
                  (Observed.map float_of_int hero.tasks_done_24h)
                  ~lang
              in
              (m, whisper_st, m))
    in
    let in_prog_opt =
      match Observed.to_option hero.tasks_in_progress with
      | Some _ as v -> v
      | None -> (
          match task_counts with Some c -> Some c.in_progress | None -> None)
    in
    let ver_total = v_pass + v_rej in
    let ver_ratio_opt =
      if ver_total > 0 then Some (float_of_int v_pass /. float_of_int ver_total)
      else None
    in
    let ver_observed =
      Observed.is_value model.work.verifications
      || Observed.is_value sc.verifications_passed_24h
      || Observed.is_value sc.verifications_rejected_24h
    in
    let ver_badge_str, ver_badge_st =
      match ver_ratio_opt with
      | Some r ->
          let pct = r *. 100.0 in
          ( Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%.0f%% 통과" pct)
                 ~en:(Printf.sprintf "%.0f%% pass" pct)),
            if pct >= 80.0 then ok_st else attn_st )
      | None ->
          if v_await_w > 0 then
            ( Say.resolve lang
                (Say.make
                   ~ko:(Printf.sprintf "%d 대기" v_await_w)
                   ~en:(Printf.sprintf "%d wait" v_await_w)),
              act_st )
          else if ver_observed then
            ( Say.resolve lang (Say.make ~ko:"검증 0건" ~en:"0 checks"),
              whisper_st )
          else
            ( format_observed_marker ~lang model.work.verifications,
              whisper_st )
    in
    let candle_str, candle_st =
      candle_hero_display ~lang ~theme ~bg ~model ~hero
    in
    let unattrib_n = candle_unattributed_count model in
    let wm_hero_str, wm_hero_st, wm_conf_str, wm_conf_st =
      match model.knowledge.world_memory with
      | Observed.Value { data = wm; _ } ->
          let main =
            Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%d 주장 · %d 사실" wm.claims_count wm.facts_count)
                 ~en:(Printf.sprintf "%d claims · %d facts" wm.claims_count wm.facts_count))
          in
          let conf_s, conf_st =
            if wm.conflicts_count > 0 then
              ( Say.resolve lang
                  (Say.make
                     ~ko:(Printf.sprintf "%s %d 충돌"
                            (Glyph.to_utf8 Glyph.Action_required)
                            wm.conflicts_count)
                     ~en:(Printf.sprintf "%s %d conflicts"
                            (Glyph.to_utf8 Glyph.Action_required)
                            wm.conflicts_count)),
                attn_st )
            else
              ( Say.resolve lang
                  (Say.make
                     ~ko:(Printf.sprintf "%s 0 충돌" (Glyph.to_utf8 Glyph.Live_healthy))
                     ~en:(Printf.sprintf "%s 0 conflicts" (Glyph.to_utf8 Glyph.Live_healthy))),
                ok_st )
          in
          (main, anchor_st, conf_s, conf_st)
      | Observed.Failed { reason; _ } ->
          ( Printf.sprintf "%s %s" (Glyph.to_utf8 Glyph.Live_failing)
              (Say.resolve lang (Say.make ~ko:"기억 조회 실패" ~en:"Memory failed")),
            crit_st,
            reason,
            crit_st )
      | Observed.Loading _ ->
          let wiki_s =
            match Observed.to_option model.knowledge.wiki_index with
            | Some wi -> Printf.sprintf "Wiki %dp" wi.pages_total
            | None ->
                Printf.sprintf "%s %s"
                  (Glyph.to_utf8 Glyph.Transport_reconnecting)
                  (Say.resolve lang (Say.make ~ko:"기억 동기화" ~en:"Memory sync"))
          in
          (wiki_s, anchor_st, "", whisper_st)
      | Observed.Unreported | Observed.Absent ->
          let wiki_s =
            match Observed.to_option model.knowledge.wiki_index with
            | Some wi -> Printf.sprintf "Wiki %dp" wi.pages_total
            | None ->
                Say.resolve lang
                  (Say.make ~ko:"기억 미보고" ~en:"Memory unreported")
          in
          (wiki_s, whisper_st, "", whisper_st)
    in
    if compact || rect.h <= 3 then begin
      (* Compact 2x2 KPI Strip (h=3: 2 KPI rows + 1 bottom border_subtle hairline) *)
      let content_h = Int.min 2 rect.h in
      let cols_r =
        Layout.split_h ~gap:1
          (Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:content_h)
          [ Layout.Flex 1; Layout.Flex 1 ]
      in
      (match cols_r with
       | [ left_k; right_k ] ->
           if Rect.right left_k >= rect.x && Rect.right left_k < Rect.right rect
           then
             Card.draw_v_hairline ~bg grid ~x:(Rect.right left_k) ~y:rect.y
               ~h:content_h ~theme;
           let lc = Rect.inset ~left:1 ~right:1 left_k in
           let rc = Rect.inset ~left:1 ~right:1 right_k in
           if content_h >= 1 then begin
             put_left_right grid ~clip:(Rect.make ~x:lc.x ~y:lc.y ~w:lc.w ~h:1)
               ~y:lc.y
               ~left_text:
                 (Printf.sprintf "%s %d/%d · %s"
                    (Say.resolve lang (Say.make ~ko:"플릿" ~en:"Fleet"))
                    hero_active_k hero_total_k infra_mix)
               ~left_style:anchor_st ~right_text:turns_str ~right_style:struct_st;
             put_left_right grid ~clip:(Rect.make ~x:rc.x ~y:rc.y ~w:rc.w ~h:1)
               ~y:rc.y
               ~left_text:
                 (Printf.sprintf "%s %s · %s"
                    (Say.resolve lang (Say.make ~ko:"캐시" ~en:"Cache"))
                    cache_str spend_str)
               ~left_style:cache_st ~right_text:calls_p95_str
               ~right_style:whisper_st
           end;
           if content_h >= 2 then begin
             let y2 = rect.y + 1 in
             let wip_compact =
               match in_prog_opt with
               | Some n ->
                   Say.resolve lang
                     (Say.make
                        ~ko:(Printf.sprintf " · %d진행" n)
                        ~en:(Printf.sprintf " · %d wip" n))
               | None -> ""
             in
             put_left_right grid ~clip:(Rect.make ~x:lc.x ~y:y2 ~w:lc.w ~h:1)
               ~y:y2
               ~left_text:
                 (Say.resolve lang
                    (Say.make
                       ~ko:(Printf.sprintf "작업 %s%s · %d목표"
                              done_compact_lbl wip_compact
                              hero.active_goals_count)
                       ~en:(Printf.sprintf "Tasks %s%s · %dg"
                              done_compact_lbl wip_compact
                              hero.active_goals_count)))
               ~left_style:pri_st ~right_text:ver_badge_str
               ~right_style:ver_badge_st;
             put_left_right grid ~clip:(Rect.make ~x:rc.x ~y:y2 ~w:rc.w ~h:1)
               ~y:y2 ~left_text:wm_hero_str ~left_style:wm_hero_st
               ~right_text:candle_str ~right_style:candle_st
           end
       | _ -> ());
      if rect.h >= 3 then
        Card.draw_hairline ~bg grid ~rect ~y:(Rect.bottom rect - 1) ~theme
    end
    else begin
      (* Wide / Standard 4-Column Hero Band (h=4: 3 content rows + bottom hairline) *)
      let body_h = Int.max 1 (rect.h - 1) in
      let band_r = Rect.make ~x:rect.x ~y:rect.y ~w:rect.w ~h:body_h in
      let cells =
        Layout.split_h ~gap:1 band_r
          [ Layout.Flex 1; Layout.Flex 1; Layout.Flex 1; Layout.Flex 1 ]
      in
      let fleet_samples = fleet_sparkline_samples groups in
      let draw_kpi_cell idx (cell : Rect.t) =
        if idx > 0 && cell.x - 1 >= rect.x && cell.x - 1 < Rect.right rect then
          Card.draw_v_hairline ~bg grid ~x:(cell.x - 1) ~y:cell.y ~h:cell.h
            ~theme;
        let inner =
          let px = Int.min pad_x ((cell.w - 1) / 4) in
          Rect.inset ~left:px ~right:px cell
        in
        if not (Rect.is_empty inner) then begin
          let r0 = Rect.make ~x:inner.x ~y:inner.y ~w:inner.w ~h:1 in
          let r1 = Rect.make ~x:inner.x ~y:(inner.y + 1) ~w:inner.w ~h:1 in
          let r2 = Rect.make ~x:inner.x ~y:(inner.y + 2) ~w:inner.w ~h:1 in
          match idx with
          | 0 ->
              (* KPI 1: Fleet & Infra *)
              let status_badge, status_st =
                if failing_total > 0 then
                  ( Printf.sprintf "%s %d" (Glyph.to_utf8 Glyph.Live_failing)
                      failing_total,
                    Typography.status ~bg ~bold:true theme Theme.Status_critical )
                else
                  ( Say.resolve lang
                      (Say.make
                         ~ko:(Printf.sprintf "%s %d조직"
                                (Glyph.to_utf8 Glyph.Live_healthy)
                                (Int.max hero.company_count (List.length groups)))
                         ~en:(Printf.sprintf "%s %d cos"
                                (Glyph.to_utf8 Glyph.Live_healthy)
                                (Int.max hero.company_count (List.length groups)))),
                    ok_st )
              in
              put_left_right grid ~clip:r0 ~y:r0.y
                ~left_text:
                  (Say.resolve lang (Say.make ~ko:"플릿 · 인프라" ~en:"Fleet & Infra"))
                ~left_style:struct_st ~right_text:status_badge
                ~right_style:status_st;
              if body_h >= 2 then
                put_left_right grid ~clip:r1 ~y:r1.y
                  ~left_text:
                    (Printf.sprintf "%d/%d" hero_active_k hero_total_k)
                  ~left_style:anchor_st ~right_text:infra_mix
                  ~right_style:act_st;
              if body_h >= 3 then begin
                let adv =
                  Cell_grid.put_text ~clip:r2 grid ~x:r2.x ~y:r2.y
                    ~style:whisper_st
                    (Grapheme.truncate_to_width ~max_width:(r2.w / 2) turns_str)
                in
                let sx = r2.x + adv + 2 in
                let sw = Int.min 12 (Rect.right r2 - sx) in
                if sw >= 4 && Array.length fleet_samples > 0 then
                  ignore
                    (Chart.draw_sparkline_run ~clip:r2 grid
                       ~x:(Rect.right r2 - sw) ~y:r2.y ~width:sw ~theme ~bg
                       ~unicode:caps.unicode_blocks
                       ~gradient:Chart.Gradient.Cool_flow fleet_samples)
                else
                  match heap_summary model with
                  | Some h when Rect.right r2 - sx >= 6 ->
                      let hw = Grapheme.display_width h in
                      ignore
                        (Cell_grid.put_text ~clip:r2 grid
                           ~x:(Rect.right r2 - hw) ~y:r2.y ~style:whisper_st h)
                  | Some _ | None -> ()
              end
          | 1 ->
              (* KPI 2: 24h Cache & Spend with explicit provenance *)
              put_left_right grid ~clip:r0 ~y:r0.y
                ~left_text:spend_kpi_label
                ~left_style:struct_st ~right_text:spend_str ~right_style:spend_st;
              if body_h >= 2 then
                put_left_right grid ~clip:r1 ~y:r1.y ~left_text:cache_str
                  ~left_style:cache_st
                  ~right_text:calls_p95_str ~right_style:calls_p95_st;
              if body_h >= 3 then begin
                let right_meta =
                  let fallback_meta () =
                    match latest_velocity_pair model with
                    | Some (u, d) ->
                        Printf.sprintf "%s%s %s%s"
                          (Glyph.to_utf8 Glyph.Delta_up)
                          (Format_val.format_value Format_val.Count u)
                          (Glyph.to_utf8 Glyph.Delta_down)
                          (Format_val.format_value Format_val.Count d)
                    | None -> (
                        match Observed.to_option hero.tool_error_rate_pct with
                        | Some e -> Printf.sprintf "%.1f%% err" e
                        | None -> "24h")
                  in
                  match spend_bd.source with
                  | Runtime_store.Spend_provider_24h -> (
                      match
                        ( Observed.to_option spend_bd.keeper_attributed_usd
                        , spend_bd.system_unattributed_usd )
                      with
                      | Some kp_usd, Some _ ->
                          Printf.sprintf "%s %s"
                            (Say.resolve lang (Say.make ~ko:"키퍼" ~en:"Kp"))
                            (Format_val.format_value Format_val.Usd kp_usd)
                      | Some _, None | None, (Some _ | None) ->
                          fallback_meta ())
                  | Runtime_store.Spend_keeper_turns_24h
                  | Runtime_store.Spend_unreported ->
                      fallback_meta ()
                in
                let rm_w =
                  Int.min (r2.w / 2) (Grapheme.display_width right_meta)
                in
                let bar_w = Int.max 0 (Int.min 12 (r2.w - rm_w - 2)) in
                (match cache_pct_opt with
                 | Some p when bar_w >= 4 ->
                     let ratio = Float.max 0.0 (Float.min 1.0 (p /. 100.0)) in
                     ignore
                       (Chart.draw_ratio_bar_run ~clip:r2 grid ~x:r2.x ~y:r2.y
                          ~width:bar_w ~theme ~bg ~unicode:caps.unicode_blocks
                          ~gradient:Chart.Gradient.Efficiency ~ratio)
                 | Some _ | None -> ());
                if rm_w > 0 then begin
                  let fit =
                    Grapheme.truncate_to_width ~max_width:rm_w right_meta
                  in
                  let fw = Grapheme.display_width fit in
                  ignore
                    (Cell_grid.put_text ~clip:r2 grid ~x:(Rect.right r2 - fw)
                       ~y:r2.y ~style:whisper_st fit)
                end
              end
          | 2 ->
              (* KPI 3: Tasks & Verification *)
              let goal_chip =
                Say.resolve lang
                  (Say.make
                     ~ko:(Printf.sprintf "%d 목표" hero.active_goals_count)
                     ~en:(Printf.sprintf "%d goals" hero.active_goals_count))
              in
              put_left_right grid ~clip:r0 ~y:r0.y
                ~left_text:
                  (Say.resolve lang (Say.make ~ko:"작업 · 검증" ~en:"Tasks & Verify"))
                ~left_style:struct_st ~right_text:goal_chip ~right_style:act_st;
              if body_h >= 2 then
                put_left_right grid ~clip:r1 ~y:r1.y ~left_text:done_lbl
                  ~left_style:done_st ~right_text:ver_badge_str
                  ~right_style:ver_badge_st;
              if body_h >= 3 then begin
                let wip_txt =
                  let wip_part =
                    match in_prog_opt with
                    | Some n ->
                        Some
                          (Say.resolve lang
                             (Say.make
                                ~ko:(Printf.sprintf "%d 진행" n)
                                ~en:(Printf.sprintf "%d wip" n)))
                    | None -> None
                  in
                  let chk_part =
                    if ver_total > 0 || ver_observed then
                      Some
                        (Say.resolve lang
                           (Say.make
                              ~ko:(Printf.sprintf "%d 검증" ver_total)
                              ~en:(Printf.sprintf "%d chk" ver_total)))
                    else None
                  in
                  String.concat Typography.sep_dot
                    (List.filter_map Fun.id [ wip_part; chk_part ])
                in
                let w_w = Int.min (r2.w * 2 / 3) (Grapheme.display_width wip_txt) in
                let bar_w = Int.max 0 (Int.min 10 (r2.w - w_w - 2)) in
                (match ver_ratio_opt with
                 | Some r when bar_w >= 4 ->
                     ignore
                       (Chart.draw_ratio_bar_run ~clip:r2 grid ~x:r2.x ~y:r2.y
                          ~width:bar_w ~theme ~bg ~unicode:caps.unicode_blocks
                          ~gradient:Chart.Gradient.Efficiency ~ratio:r)
                 | Some _ | None -> ());
                if w_w > 0 then begin
                  let fit = Grapheme.truncate_to_width ~max_width:w_w wip_txt in
                  let fw = Grapheme.display_width fit in
                  ignore
                    (Cell_grid.put_text ~clip:r2 grid ~x:(Rect.right r2 - fw)
                       ~y:r2.y ~style:whisper_st fit)
                end
              end
          | _ ->
              (* KPI 4: World Memory & Candle (Violet Status_ai) *)
              put_left_right grid ~clip:r0 ~y:r0.y
                ~left_text:
                  (Say.resolve lang
                     (Say.make ~ko:"월드 기억 · 캔들" ~en:"Memory & Candle"))
                ~left_style:struct_st ~right_text:candle_str
                ~right_style:candle_st;
              if body_h >= 2 then
                put_left_right grid ~clip:r1 ~y:r1.y ~left_text:wm_hero_str
                  ~left_style:wm_hero_st ~right_text:"" ~right_style:struct_st;
              if body_h >= 3 then begin
                let right_note, right_st =
                  if unattrib_n > 0 then
                    ( Say.resolve lang
                        (Say.make
                           ~ko:(Printf.sprintf "%s%d 미귀속"
                                  (Glyph.to_utf8 Glyph.Warning_triangle)
                                  unattrib_n)
                           ~en:(Printf.sprintf "%s%d unattributed"
                                  (Glyph.to_utf8 Glyph.Warning_triangle)
                                  unattrib_n)),
                      attn_st )
                  else
                    match Observed.to_option model.knowledge.wiki_index with
                    | Some wi -> (Printf.sprintf "Wiki %dp" wi.pages_total, whisper_st)
                    | None -> ("", whisper_st)
                in
                put_left_right grid ~clip:r2 ~y:r2.y ~left_text:wm_conf_str
                  ~left_style:wm_conf_st ~right_text:right_note
                  ~right_style:right_st
              end
        end
      in
      List.iteri draw_kpi_cell cells;
      Card.draw_hairline ~bg grid ~rect ~y:(Rect.bottom rect - 1) ~theme
    end

(* ---------- Panel A: Collapsible Human Attention Queue (1-line green strip when 0) ---------- *)

let attention_panel_height (m : Model.t) ~max_rows =
  let n = Attention.count m.attention in
  if n = 0 then 1 else Int.min max_rows (Int.max 4 (n + 2))

let render_attention_panel grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~bp =
  if Rect.is_empty rect then ()
  else
    let lang = model.lang in
    let n = Attention.count model.attention in
    if n = 0 then begin
      (* Sleek 1-line green strip with Left_rail — NEVER steals an empty 8-row box *)
      let bg = Color.of_rgb theme.surface_1 in
      let ok_st = Typography.status ~bg ~bold:true theme Theme.Status_ok in
      let whisper_st = Typography.whisper ~bg theme in
      Cell_grid.fill_rect ~clip:rect grid ~rect ~style:ok_st ();
      Card.draw_left_rail ~bg ~tone:Theme.Status_ok grid ~x:rect.x ~y:rect.y
        ~h:1 ~theme;
      let pill_txt =
        Say.resolve lang
          (Say.make
             ~ko:(Printf.sprintf "%s 확인 대기 없음 %s 0건"
                    (Glyph.to_utf8 Glyph.Live_healthy)
                    (Glyph.to_utf8 Glyph.Separator_dot))
             ~en:(Printf.sprintf "%s All clear %s 0 pending"
                    (Glyph.to_utf8 Glyph.Live_healthy)
                    (Glyph.to_utf8 Glyph.Separator_dot)))
      in
      let hint =
        Say.resolve lang (Say.make ~ko:"[2] 작업 수신함" ~en:"[2] Work Inbox")
      in
      let content = Rect.inset ~left:2 ~right:1 rect in
      put_left_right grid ~clip:content ~y:rect.y ~left_text:pill_txt
        ~left_style:ok_st ~right_text:hint ~right_style:whisper_st
    end
    else begin
      let title =
        Say.resolve lang
          (Say.make ~ko:"운영자 확인 필요" ~en:"Human Attention")
      in
      let badge : Card.badge =
        {
          glyph = Some Glyph.Action_required;
          text =
            Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%d건" n)
                 ~en:(Printf.sprintf "%d live" n));
          tone = Some Theme.Status_attention;
        }
      in
      let hotkey =
        Say.resolve lang
          (Say.make ~ko:"[J] 이동 · [Enter] 상세" ~en:"[J] Jump · [Enter] Dive")
      in
      let inner =
        Card.draw ~cache grid ~rect ~theme
          {
            (Card.default_spec ~title) with
            badge = Some badge;
            hotkey = Some hotkey;
            focused =
              Model.equal_pulse_pane (Model.active_pulse_pane model)
                Model.Pulse_attention;
            elevated = true;
          }
      in
      if not (Rect.is_empty inner) then begin
        let pad_x = Layout.card_pad_x bp in
        let items = Array.of_list model.attention.items in
        let count = Array.length items in
        let sel =
          if count <= 0 then 0
          else Int.max 0 (Int.min (count - 1) model.attention.triage_index)
        in
        let start, _ =
          Table.compute_viewport ~total_rows:count ~viewport_rows:inner.h
            ~scroll:0 ~selected:(Some sel)
        in
        let max_show = Int.min inner.h (Int.max 0 (count - start)) in
        for i = 0 to max_show - 1 do
          let idx = start + i in
          let e = items.(idx) in
          let py = inner.y + i in
          let row_r = Rect.make ~x:inner.x ~y:py ~w:inner.w ~h:1 in
          let is_sel = Int.equal idx sel in
          let rbg =
            Color.of_rgb (if is_sel then theme.selection_bg else theme.surface_2)
          in
          Cell_grid.fill_rect ~clip:inner grid ~rect:row_r
            ~style:(Typography.primary ~bg:rbg theme) ();
          if is_sel then
            Cell_grid.put_glyph ~clip:row_r grid ~x:inner.x ~y:py
              ~style:(Typography.accent ~bg:rbg ~bold:true theme)
              Glyph.Left_rail;
          let attn_st =
            Typography.status ~bg:rbg ~bold:true theme Theme.Status_attention
          in
          let keeper_st =
            if is_sel then Typography.anchor ~bg:rbg theme
            else Typography.primary ~bg:rbg theme
          in
          let sum_st = Typography.structure ~bg:rbg theme in
          let hint_st = Typography.whisper ~bg:rbg theme in
          let tag = Say.resolve lang (Render_util.attention_kind_tag e.kind) in
          let keeper =
            match e.keeper with
            | Some k -> k
            | None -> (
                match Render_util.attention_kind_keeper e.kind with
                | Some k -> k
                | None -> e.title)
          in
          let action_hint =
            match e.kind with
            | Health.Held_tool_approval _ | Health.Pending_ask _ -> "[Y/N]"
            | Health.Goal_confirmation _ ->
                Say.resolve lang (Say.make ~ko:"[Enter] 확인" ~en:"[Enter]")
          in
          let ah_w = Grapheme.display_width action_hint in
          let right_edge = Rect.right inner - pad_x in
          let x = ref (inner.x + Int.max 2 pad_x) in
          let a0 =
            Cell_grid.put_text ~clip:row_r grid ~x:!x ~y:py ~style:attn_st
              (Printf.sprintf "%s %s" (Glyph.to_utf8 Glyph.Action_required) tag)
          in
          x := !x + a0 + 2;
          let k_clipped = Grapheme.truncate_to_width ~max_width:18 keeper in
          let a1 =
            Cell_grid.put_text ~clip:row_r grid ~x:!x ~y:py ~style:keeper_st
              k_clipped
          in
          x := !x + a1 + 2;
          let right_x = right_edge - ah_w in
          let sum_w = Int.max 0 (right_x - !x - 2) in
          if sum_w > 3 then begin
            let sum_txt =
              if String.equal (String.trim e.summary) "" then e.title
              else e.summary
            in
            ignore
              (Cell_grid.put_text ~clip:row_r grid ~x:!x ~y:py ~style:sum_st
                 (Grapheme.truncate_to_width ~max_width:sum_w sum_txt))
          end;
          if right_x > !x then
            ignore
              (Cell_grid.put_text ~clip:row_r grid ~x:right_x ~y:py
                 ~style:hint_st action_hint)
        done
      end
    end

(* ---------- Panel B: Autonomous Companies (0 ungrouped, sparklines, infra & spend) ---------- *)

let company_infra_tag ~(model : Model.t) (g : Wire_fleet.company_group) =
  let vm_n, ssh_n, dk_n = (g.microvm_count, g.ssh_count, g.docker_count) in
  if vm_n + ssh_n + dk_n > 0 then
    if vm_n > 0 && ssh_n > 0 then Printf.sprintf "%dvm·%dssh" vm_n ssh_n
    else if vm_n > 0 then Printf.sprintf "%dvm" vm_n
    else if ssh_n > 0 then Printf.sprintf "%dssh" ssh_n
    else Printf.sprintf "%ddk" dk_n
  else
    match Observed.to_option model.infra.sandboxes with
    | None -> ""
    | Some sb ->
        let vm_set =
          List.map (fun (x : Wire_infra.microvm_guest) -> x.keeper)
            sb.microvm_guests
        in
        let ssh_set =
          List.concat_map
            (fun (p : Wire_infra.ssh_pool) ->
              List.map (fun (s : Wire_infra.ssh_keeper_session) -> s.keeper)
                p.keeper_sessions)
            sb.ssh_pools
          @ List.map (fun (u : Wire_infra.ssh_unbound_keeper) -> u.keeper)
              sb.ssh_unbound_keepers
        in
        let v, s =
          List.fold_left
            (fun (v, s) (k : Wire_fleet.keeper_summary) ->
              let v' =
                if List.exists (String.equal k.name) vm_set then v + 1 else v
              in
              let s' =
                if List.exists (String.equal k.name) ssh_set then s + 1 else s
              in
              (v', s'))
            (0, 0) g.keepers
        in
        if v > 0 && s > 0 then Printf.sprintf "%dvm·%dssh" v s
        else if v > 0 then Printf.sprintf "%dvm" v
        else if s > 0 then Printf.sprintf "%dssh" s
        else ""

let company_spend_or_turns ~(model : Model.t) (g : Wire_fleet.company_group) =
  if g.cost_24h_usd > 0.005 then
    Format_val.format_value Format_val.Usd g.cost_24h_usd
  else if g.turns_24h > 0 then
    Printf.sprintf "%st"
      (Format_val.format_value Format_val.Count (float_of_int g.turns_24h))
  else
    let names = List.map (fun (k : Wire_fleet.keeper_summary) -> k.name) g.keepers in
    let has_keeper name = List.exists (String.equal name) names in
    let done_tasks =
      List.fold_left
        (fun acc (t : Wire_work.task) ->
          match t.status with
          | Wire_work.Done { assignee; _ } when has_keeper assignee -> acc + 1
          | Wire_work.Todo
          | Wire_work.Claimed _
          | Wire_work.InProgress _
          | Wire_work.AwaitingVerification _
          | Wire_work.Done _
          | Wire_work.Cancelled _ ->
              acc)
        0 (Work_store.tasks model.work)
    in
    if done_tasks > 0 then Printf.sprintf "+%dt" done_tasks
    else
      let total_t =
        List.fold_left
          (fun acc (k : Wire_fleet.keeper_summary) ->
            match Observed.to_option k.total_turns with
            | Some n -> acc + n
            | None -> acc)
          0 g.keepers
      in
      if total_t > 0 then
        Printf.sprintf "%st"
          (Format_val.format_value Format_val.Count (float_of_int total_t))
      else Glyph.to_utf8 Glyph.Missing_absent

let live_failing_keepers_of_groups (groups : Wire_fleet.company_group list) =
  List.concat_map
    (fun (g : Wire_fleet.company_group) ->
      List.filter
        (fun (k : Wire_fleet.keeper_summary) ->
          match k.health with
          | Wire_fleet.Keeper_failing -> true
          | Wire_fleet.Keeper_healthy
          | Wire_fleet.Keeper_working
          | Wire_fleet.Keeper_idle
          | Wire_fleet.Keeper_degraded
          | Wire_fleet.Keeper_recovering
          | Wire_fleet.Keeper_paused
          | Wire_fleet.Keeper_offline
          | Wire_fleet.Keeper_booting ->
              false)
        g.keepers)
    groups

let companies_panel_height (groups : Wire_fleet.company_group list) ~bp =
  let n = Int.max 1 (List.length groups) in
  let has_fail_banner = live_failing_keepers_of_groups groups <> [] in
  let fail_rows = if has_fail_banner then 1 else 0 in
  match bp with
  | Layout.Compact | Layout.Micro ->
      (* 2 card borders + 1 table header + optional 1-row live fault banner *)
      Layout.adaptive_list_height ~items:n ~overhead:(3 + fail_rows) ~min_h:6
        ~max_h:(9 + fail_rows) ()
  | Layout.Wide | Layout.Standard ->
      (* 2 card borders + 1 table header + 1 hairline sep + optional 1-row live fault banner *)
      Layout.adaptive_list_height ~items:n ~overhead:(4 + fail_rows) ~min_h:8
        ~max_h:(12 + fail_rows) ()

let render_companies_panel grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~(groups : Wire_fleet.company_group list) ~bp =
  if Rect.is_empty rect then ()
  else
    let lang = model.lang in
    let total_keepers =
      List.fold_left
        (fun acc (g : Wire_fleet.company_group) -> acc + List.length g.keepers)
        0 groups
    in
    let title =
      Say.resolve lang
        (Say.make
           ~ko:(Printf.sprintf "%d개 자율 조직" (List.length groups))
           ~en:(Printf.sprintf "%d Autonomous Companies" (List.length groups)))
    in
    let spend_bd = Runtime_store.spend_24h_breakdown model.runtime in
    let subtitle =
      match spend_bd.system_unattributed_usd with
      | Some sys_usd ->
          Say.resolve lang
            (Say.make
               ~ko:
                 (Printf.sprintf "%d 키퍼 · 시스템 %s" total_keepers
                    (Format_val.format_value Format_val.Usd sys_usd))
               ~en:
                 (Printf.sprintf "%d Keepers · Sys %s" total_keepers
                    (Format_val.format_value Format_val.Usd sys_usd)))
      | None ->
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "%d 키퍼" total_keepers)
               ~en:(Printf.sprintf "%d Keepers" total_keepers))
    in
    let hotkey =
      Say.resolve lang
        (Say.make ~ko:"[4] 키퍼 · [Enter] 상세" ~en:"[4] Keepers · [Enter]")
    in
    let inner =
      Card.draw ~cache grid ~rect ~theme
        {
          (Card.default_spec ~title) with
          subtitle = Some subtitle;
          hotkey = Some hotkey;
          focused =
            Model.equal_pulse_pane (Model.active_pulse_pane model)
              Model.Pulse_companies;
        }
    in
    if not (Rect.is_empty inner) then begin
      let bg = Color.of_rgb theme.surface_1 in
      let hdr_bg = Color.of_rgb theme.surface_2 in
      let pad_x = Layout.card_pad_x bp in
      let whisper_st = Typography.whisper ~bg theme in
      let hdr_st = Typography.structure ~bg:hdr_bg ~bold:true theme in
      let crit_st = Typography.status ~bg ~bold:true theme Theme.Status_critical in
      match model.fleet.keepers with
      | Observed.Loading _ ->
          let msg =
            Say.resolve lang
              (Say.make
                 ~ko:(Glyph.to_utf8 Glyph.Transport_reconnecting ^ " 키퍼 조직 불러오는 중...")
                 ~en:(Glyph.to_utf8 Glyph.Transport_reconnecting ^ " Loading companies & fleet..."))
          in
          ignore
            (Cell_grid.put_text ~clip:inner grid ~x:(inner.x + pad_x) ~y:inner.y
               ~style:whisper_st msg)
      | Observed.Failed { reason; _ } ->
          let msg =
            Printf.sprintf "%s %s" (Glyph.to_utf8 Glyph.Live_failing) reason
          in
          ignore
            (Cell_grid.put_text ~clip:inner grid ~x:(inner.x + pad_x) ~y:inner.y
               ~style:crit_st
               (Grapheme.truncate_to_width
                  ~max_width:(Int.max 0 (inner.w - (2 * pad_x)))
                  msg))
      | Observed.Absent | Observed.Unreported ->
          let msg =
            Say.resolve lang
              (Say.make
                 ~ko:(Glyph.to_utf8 Glyph.Live_idle ^ " 조직 데이터 대기 중")
                 ~en:(Glyph.to_utf8 Glyph.Live_idle ^ " Awaiting fleet snapshot"))
          in
          ignore
            (Cell_grid.put_text ~clip:inner grid ~x:(inner.x + pad_x) ~y:inner.y
               ~style:whisper_st msg)
      | Observed.Value _ -> (
          if groups = [] then
            let msg =
              Say.resolve lang
                (Say.make
                   ~ko:(Glyph.to_utf8 Glyph.Live_idle ^ " 등록된 키퍼 없음")
                   ~en:(Glyph.to_utf8 Glyph.Live_idle ^ " No keepers registered"))
            in
            ignore
              (Cell_grid.put_text ~clip:inner grid ~x:(inner.x + pad_x)
                 ~y:inner.y ~style:whisper_st msg)
          else
            let live_failing_keepers = live_failing_keepers_of_groups groups in
            let show_fail_footer =
              live_failing_keepers <> [] && inner.h >= 4
            in
            let table_h =
              Int.max 1 (inner.h - (if show_fail_footer then 1 else 0))
            in
            let compact =
              Layout.equal_breakpoint bp Layout.Compact
              || Layout.equal_breakpoint bp Layout.Micro
            in
            let show_hdr = table_h >= 2 in
            let show_hdr_sep = (not compact) && show_hdr && table_h >= 4 in
            let hdr_rows =
              (if show_hdr then 1 else 0) + (if show_hdr_sep then 1 else 0)
            in
            let start_y = inner.y + hdr_rows in
            let show_infra = inner.w >= 66 in
            let show_spark = inner.w >= 44 in
            let spark_w =
              if compact || inner.w < 58 then 8 else Int.min 12 (inner.w / 6)
            in
            let out_w = 7 in
            let infra_w = if show_infra then 9 else 0 in
            let act_w = 5 in
            let buckets_w = if inner.w >= 54 then 12 else 0 in
            let right_pad = 1 in
            let left_gutter = 2 in
            let fixed_w =
              left_gutter + right_pad + act_w + 1
              + (if buckets_w > 0 then buckets_w + 2 else 0)
              + (if show_spark then spark_w + 2 else 0)
              + out_w + 1
              + (if show_infra then infra_w + 1 else 0)
            in
            let name_w = Int.max 12 (inner.w - fixed_w) in
            if show_hdr then begin
              let hdr_r = Rect.make ~x:inner.x ~y:inner.y ~w:inner.w ~h:1 in
              Cell_grid.fill_rect ~clip:inner grid ~rect:hdr_r ~style:hdr_st ();
              let hx = ref (inner.x + left_gutter) in
              ignore
                (Cell_grid.put_text ~clip:hdr_r grid ~x:!hx ~y:inner.y
                   ~style:hdr_st
                   (Grapheme.truncate_to_width ~max_width:name_w
                      (Say.resolve lang (Say.make ~ko:"조직" ~en:"Company"))));
              hx := !hx + name_w + 1;
              ignore
                (Cell_grid.put_text ~clip:hdr_r grid ~x:!hx ~y:inner.y
                   ~style:hdr_st
                   (Grapheme.truncate_to_width ~max_width:act_w
                      (Say.resolve lang (Say.make ~ko:"활성" ~en:"Act"))));
              hx := !hx + act_w + 1;
              if buckets_w > 0 then begin
                ignore
                  (Cell_grid.put_text ~clip:hdr_r grid ~x:!hx ~y:inner.y
                     ~style:hdr_st
                     (Printf.sprintf "%s  %s  %s  %s"
                        (Glyph.to_utf8 Glyph.Action_required)
                        (Glyph.to_utf8 Glyph.Live_working)
                        (Glyph.to_utf8 Glyph.Live_healthy)
                        (Glyph.to_utf8 Glyph.Live_failing)));
                hx := !hx + buckets_w + 2
              end;
              if show_spark then begin
                ignore
                  (Cell_grid.put_text ~clip:hdr_r grid ~x:!hx ~y:inner.y
                     ~style:hdr_st
                     (Grapheme.truncate_to_width ~max_width:spark_w "24h"));
                hx := !hx + spark_w + 2
              end;
              if show_infra then begin
                ignore
                  (Cell_grid.put_text ~clip:hdr_r grid ~x:!hx ~y:inner.y
                     ~style:hdr_st
                     (Grapheme.truncate_to_width ~max_width:infra_w
                        (Say.resolve lang (Say.make ~ko:"인프라" ~en:"Infra"))));
                hx := !hx + infra_w + 1
              end;
              let out_hdr =
                Say.resolve lang (Say.make ~ko:"성과" ~en:"Output")
              in
              let oh_w = Grapheme.display_width out_hdr in
              ignore
                (Cell_grid.put_text ~clip:hdr_r grid
                   ~x:(Rect.right inner - right_pad - oh_w)
                   ~y:inner.y ~style:hdr_st out_hdr)
            end;
            if show_hdr_sep then
              Card.draw_hairline ~bg grid ~rect:inner ~y:(inner.y + 1) ~theme;
            let groups_arr = Array.of_list groups in
            let total_groups = Array.length groups_arr in
            let sel_group_idx =
              let by_selected_keeper =
                match Fleet_store.selected_company_keeper model.fleet with
                | None -> None
                | Some k ->
                    let rec find i =
                      if i >= total_groups then None
                      else if
                        List.exists
                          (fun (m : Wire_fleet.keeper_summary) ->
                            String.equal m.name k.name)
                          groups_arr.(i).keepers
                      then Some i
                      else find (i + 1)
                    in
                    find 0
              in
              match by_selected_keeper with
              | Some idx -> idx
              | None ->
                  if total_groups <= 0 then 0
                  else
                    Int.max 0
                      (Int.min (total_groups - 1) model.fleet.selected_index)
            in
            let viewport_rows = Int.max 0 (table_h - hdr_rows) in
            let start_group, _ =
              Table.compute_viewport ~total_rows:total_groups ~viewport_rows
                ~scroll:model.fleet.pulse_scroll_offset
                ~selected:(Some sel_group_idx)
            in
            let max_rows =
              Int.min viewport_rows (Int.max 0 (total_groups - start_group))
            in
            let attn_fg =
              Color.of_rgb (Theme.status_color theme Theme.Status_attention)
            in
            let work_fg =
              Color.of_rgb (Theme.status_color theme Theme.Status_active)
            in
            let ok_fg = Color.of_rgb (Theme.status_color theme Theme.Status_ok) in
            let crit_fg =
              Color.of_rgb (Theme.status_color theme Theme.Status_critical)
            in
            let mut_fg = Color.of_rgb theme.text_muted in
            for i = 0 to max_rows - 1 do
              let idx = start_group + i in
              let g = groups_arr.(idx) in
              let py = start_y + i in
              let row_r = Rect.make ~x:inner.x ~y:py ~w:inner.w ~h:1 in
              let is_sel = Int.equal idx sel_group_idx in
              let rbg =
                Color.of_rgb
                  (if is_sel then theme.selection_bg else theme.surface_1)
              in
              Cell_grid.fill_rect ~clip:inner grid ~rect:row_r
                ~style:(Typography.primary ~bg:rbg theme) ();
              if is_sel then
                Cell_grid.put_glyph ~clip:row_r grid ~x:inner.x ~y:py
                  ~style:(Typography.accent ~bg:rbg ~bold:true theme)
                  Glyph.Left_rail;
              let x = ref (inner.x + left_gutter) in
              let name_st =
                if is_sel then Typography.anchor ~bg:rbg theme
                else Typography.primary ~bg:rbg theme
              in
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:!x ~y:py ~style:name_st
                   (Grapheme.truncate_to_width ~max_width:name_w g.company));
              x := !x + name_w + 1;
              let hc = Fleet_store.fleet_health_counts g.keepers in
              let act_s = Printf.sprintf "%d/%d" hc.active hc.total in
              let act_st =
                if hc.failing > 0 then
                  Typography.status ~bg:rbg ~bold:true theme
                    Theme.Status_attention
                else if hc.active > 0 then
                  Typography.status ~bg:rbg theme Theme.Status_ok
                else Typography.whisper ~bg:rbg ~italic:false theme
              in
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:!x ~y:py ~style:act_st
                   (Grapheme.truncate_to_width ~max_width:act_w act_s));
              x := !x + act_w + 1;
              if buckets_w > 0 then begin
                let put_count n fg =
                  let s =
                    if n > 0 then Printf.sprintf "%-2d" n
                    else Glyph.to_utf8 Glyph.Separator_dot ^ " "
                  in
                  let st =
                    Style.make ~fg:(if n > 0 then fg else mut_fg) ~bg:rbg
                      ~attrs:(if n > 0 then Attr.bold else Attr.none)
                      ()
                  in
                  ignore
                    (Cell_grid.put_text ~clip:row_r grid ~x:!x ~y:py ~style:st s);
                  x := !x + 3
                in
                put_count g.attention_count attn_fg;
                put_count (hc.working + hc.degraded) work_fg;
                put_count hc.healthy ok_fg;
                put_count hc.failing crit_fg;
                x := !x + 2
              end;
              if show_spark then begin
                let samples = sparkline_samples_of_floats g.sparkline_24h in
                if Array.length samples > 0 then
                  ignore
                    (Chart.draw_sparkline_run ~clip:row_r grid ~x:!x ~y:py
                       ~width:spark_w ~theme ~bg:rbg
                       ~unicode:caps.unicode_blocks
                       ~gradient:Chart.Gradient.Cool_flow samples)
                else
                  ignore
                    (Cell_grid.put_text ~clip:row_r grid ~x:!x ~y:py
                       ~style:(Typography.whisper ~bg:rbg theme)
                       (Glyph.to_utf8 Glyph.Missing_absent));
                x := !x + spark_w + 2
              end;
              if show_infra then begin
                let tag = company_infra_tag ~model g in
                ignore
                  (Cell_grid.put_text ~clip:row_r grid ~x:!x ~y:py
                     ~style:(Typography.structure ~bg:rbg theme)
                     (Grapheme.truncate_to_width ~max_width:infra_w tag));
                x := !x + infra_w + 1
              end;
              let out_txt = company_spend_or_turns ~model g in
              let fit_out =
                Grapheme.truncate_to_width ~max_width:out_w out_txt
              in
              let ow = Grapheme.display_width fit_out in
              let ox = Int.max !x (Rect.right inner - right_pad - ow) in
              ignore
                (Cell_grid.put_text ~clip:row_r grid ~x:ox ~y:py
                   ~style:
                     (if g.cost_24h_usd > 0.005 then
                        Typography.primary ~bg:rbg theme
                      else Typography.structure ~bg:rbg theme)
                   fit_out)
            done;
            if show_fail_footer then begin
              let fy = Rect.bottom inner - 1 in
              let fail_r = Rect.make ~x:inner.x ~y:fy ~w:inner.w ~h:1 in
              Card.draw_left_rail ~bg ~tone:Theme.Status_critical grid
                ~x:inner.x ~y:fy ~h:1 ~theme;
              let names =
                live_failing_keepers
                |> List.map (fun (k : Wire_fleet.keeper_summary) -> k.name)
                |> String.concat ", "
              in
              let line =
                Say.resolve lang
                  (Say.make
                     ~ko:(Printf.sprintf "%s 실시간 오류: %s"
                            (Glyph.to_utf8 Glyph.Live_failing)
                            names)
                     ~en:(Printf.sprintf "%s Live fault: %s"
                            (Glyph.to_utf8 Glyph.Live_failing)
                            names))
              in
              ignore
                (Cell_grid.put_text ~clip:fail_r grid ~x:(inner.x + 2) ~y:fy
                   ~style:crit_st
                   (Grapheme.truncate_to_width
                      ~max_width:(Int.max 0 (inner.w - 3))
                      line))
            end)
    end

(* ---------- Panel C: Active Goals & 24h Daily Scorecard (Kills Left Void!) ---------- *)

let render_goals_and_scorecard_panel grid ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~(model : Model.t) ~bp =
  if Rect.is_empty rect then ()
  else
    let lang = model.lang in
    let goals = Work_store.pulse_active_goals model.work in
    let pane_focused =
      Model.equal_pulse_pane (Model.active_pulse_pane model) Model.Pulse_goals
    in
    let title =
      Say.resolve lang
        (Say.make ~ko:"진행 중인 목표 · 일일 성과" ~en:"Active Goals · 24h Output")
    in
    let badge =
      if goals <> [] then
        Some
          {
            Card.glyph = None;
            text =
              Say.resolve lang
                (Say.make
                   ~ko:(Printf.sprintf "%d 진행" (List.length goals))
                   ~en:(Printf.sprintf "%d active" (List.length goals)));
            tone = Some Theme.Status_active;
          }
      else None
    in
    let inner =
      Card.draw ~cache grid ~rect ~theme
        {
          (Card.default_spec ~title) with
          badge;
          hotkey =
            Some
              (Say.resolve lang
                 (Say.make ~ko:"[2] 파이프라인" ~en:"[2] Pipeline"));
          focused = pane_focused;
        }
    in
    let pad_x = Layout.card_pad_x bp in
    let content = Card.pad_inner ~pad_x inner in
    if not (Rect.is_empty content) then begin
      let bg = Color.of_rgb theme.surface_1 in
      let pri_st = Typography.primary ~bg theme in
      let struct_st = Typography.structure ~bg theme in
      let whisper_st = Typography.whisper ~bg theme in
      let attn_st =
        Typography.status ~bg ~bold:true theme Theme.Status_attention
      in
      let unlinked = Work_store.unlinked_task_count model.work in
      let unattrib = candle_unattributed_count model in
      (* Reserve bottom 3..4 rows for 24h Scorecard hairline + summary *)
      let score_rows =
        if content.h >= 7 then
          3 + (if unlinked > 0 || unattrib > 0 then 1 else 0)
        else if content.h >= 4 then 2
        else 1
      in
      let goals_budget = Int.max 0 (content.h - score_rows) in
      let y = ref content.y in
      let goals_bottom = content.y + goals_budget in
      if goals_budget > 0 then begin
        if goals = [] then begin
          ignore
            (Cell_grid.put_text ~clip:content grid ~x:content.x ~y:!y
               ~style:whisper_st
               (Grapheme.truncate_to_width ~max_width:content.w
                  (Say.resolve lang
                     (Say.make
                        ~ko:"진행 중인 목표 없음 · [2] 파이프라인에서 생성"
                        ~en:"No active goals · create in [2] Pipeline"))));
          incr y
        end
        else
          let arr = Array.of_list goals in
          let n_goals = Array.length arr in
          let sel_goal_idx =
            if n_goals <= 0 then 0
            else Int.max 0 (Int.min (n_goals - 1) model.work.pulse_goal_index)
          in
          let show_measure = goals_budget >= (n_goals * 2) in
          let rows_per_goal = if show_measure then 2 else 1 in
          let vis_goals = Int.max 1 (goals_budget / rows_per_goal) in
          let start_goal_idx =
            if n_goals <= vis_goals then 0
            else
              Int.max 0
                (Int.min (n_goals - vis_goals) (sel_goal_idx - vis_goals + 1))
          in
          for i = start_goal_idx to n_goals - 1 do
            if !y < goals_bottom then begin
              let g = arr.(i) in
              let py = !y in
              let is_sel = pane_focused && Int.equal i sel_goal_idx in
              let rbg =
                Color.of_rgb
                  (if is_sel then theme.selection_bg else theme.surface_1)
              in
              let row_full = Rect.make ~x:inner.x ~y:py ~w:inner.w ~h:1 in
              if is_sel then begin
                Cell_grid.fill_rect ~clip:inner grid ~rect:row_full
                  ~style:(Typography.primary ~bg:rbg theme) ();
                Cell_grid.put_glyph ~clip:row_full grid ~x:inner.x ~y:py
                  ~style:(Typography.accent ~bg:rbg ~bold:true theme)
                  Glyph.Left_rail
              end;
              let row_r = Rect.make ~x:content.x ~y:py ~w:content.w ~h:1 in
              let phase_g, phase_st =
                match g.phase with
                | Wire_work.Awaiting_confirmation ->
                    ( Glyph.Action_required,
                      Typography.status ~bg:rbg ~bold:true theme
                        Theme.Status_attention )
                | Wire_work.Verifying ->
                    ( Glyph.Live_working,
                      Typography.status ~bg:rbg ~bold:true theme
                        Theme.Status_active )
                | Wire_work.Executing
                | Wire_work.Completed
                | Wire_work.Dropped
                | Wire_work.Paused _
                | Wire_work.Blocked _ ->
                    ( Glyph.Live_healthy,
                      Typography.status ~bg:rbg ~bold:true theme Theme.Status_ok )
              in
              let done_n, decl_n, ratio = goal_linked_progress ~model g in
              let cnt_txt =
                if decl_n > 0 then Printf.sprintf "%d/%d" done_n decl_n
                else
                  match g.phase with
                  | Wire_work.Awaiting_confirmation ->
                      Say.resolve lang (Say.make ~ko:"확정 대기" ~en:"confirm")
                  | Wire_work.Verifying ->
                      Say.resolve lang (Say.make ~ko:"검증 중" ~en:"verify")
                  | Wire_work.Executing
                  | Wire_work.Completed
                  | Wire_work.Dropped
                  | Wire_work.Paused _
                  | Wire_work.Blocked _ ->
                      "0/0"
              in
              let cnt_w = Grapheme.display_width cnt_txt in
              let bar_w = if content.w >= 42 then 8 else 0 in
              let right_total_w =
                cnt_w + (if bar_w > 0 then bar_w + 1 else 0)
              in
              let p_adv =
                Cell_grid.put_text ~clip:row_r grid ~x:content.x ~y:py
                  ~style:phase_st
                  (Printf.sprintf "%s P%d " (Glyph.to_utf8 phase_g) g.priority)
              in
              let tx = content.x + p_adv in
              let right_x = Rect.right content - right_total_w in
              let title_w = Int.max 0 (right_x - tx - 2) in
              if title_w > 3 then
                ignore
                  (Cell_grid.put_text ~clip:row_r grid ~x:tx ~y:py
                     ~style:
                       (if is_sel then Typography.anchor ~bg:rbg theme
                        else
                          match g.phase with
                          | Wire_work.Awaiting_confirmation ->
                              Typography.anchor ~bg:rbg theme
                          | Wire_work.Executing
                          | Wire_work.Verifying
                          | Wire_work.Completed
                          | Wire_work.Dropped
                          | Wire_work.Paused _
                          | Wire_work.Blocked _ ->
                              Typography.primary ~bg:rbg theme)
                     (Grapheme.truncate_to_width ~max_width:title_w g.title));
              if bar_w > 0 && right_x > tx then
                ignore
                  (Chart.draw_ratio_bar_run ~clip:row_r grid ~x:right_x ~y:py
                     ~width:bar_w ~theme ~bg:rbg ~unicode:caps.unicode_blocks
                     ~gradient:Chart.Gradient.Efficiency ~ratio);
              let cx = Rect.right content - cnt_w in
              if cx > tx then
                ignore
                  (Cell_grid.put_text ~clip:row_r grid ~x:cx ~y:py
                     ~style:(Typography.structure ~bg:rbg theme) cnt_txt);
              incr y;
              if show_measure && !y < goals_bottom && not (String.equal (String.trim g.measure) "") then begin
                let mr = Rect.make ~x:(content.x + 2) ~y:!y ~w:(Int.max 0 (content.w - 2)) ~h:1 in
                ignore
                  (Cell_grid.put_text ~clip:mr grid ~x:mr.x ~y:!y ~style:whisper_st
                     (Grapheme.truncate_to_width ~max_width:mr.w g.measure));
                incr y
              end
            end
          done
      end;
      (* Padded Hairline Divider + 24h Daily Scorecard Summary *)
      let score_y = Rect.bottom content - score_rows in
      let sc = Model.effective_scorecard model in
      let hero = Model.pulse_hero_metrics model in
      let cy = ref score_y in
      if score_rows >= 3 && !cy >= content.y then begin
        Card.draw_hairline ~pad_x ~bg
          ~label:(Say.resolve lang (Say.make ~ko:"일일 성과 (24h)" ~en:"Daily Output (24h)"))
          grid ~rect:inner ~y:!cy ~theme;
        incr cy
      end;
      if !cy < Rect.bottom content then begin
        let r1 = Rect.make ~x:content.x ~y:!cy ~w:content.w ~h:1 in
        let done_part =
          match Observed.to_option sc.tasks_done_24h with
          | Some n ->
              Say.resolve lang
                (Say.make
                   ~ko:(Printf.sprintf "완료 %d" n)
                   ~en:(Printf.sprintf "Done %d" n))
          | None -> (
              match Observed.to_option sc.tasks_done_total with
              | Some n ->
                  Say.resolve lang
                    (Say.make
                       ~ko:(Printf.sprintf "누적 %d" n)
                       ~en:(Printf.sprintf "Total %d" n))
              | None ->
                  let m =
                    Format_val.format_observed Format_val.Count
                      (Observed.map float_of_int sc.tasks_done_24h)
                      ~lang
                  in
                  Say.resolve lang
                    (Say.make
                       ~ko:(Printf.sprintf "완료 %s" m)
                       ~en:(Printf.sprintf "Done %s" m)))
        in
        let v_pass, v_rej, _ = Work_store.verification_pass_summary model.work in
        let vp =
          match Observed.to_option sc.verifications_passed_24h with
          | Some n when n > v_pass -> n
          | Some _ | None -> v_pass
        in
        let vr =
          match Observed.to_option sc.verifications_rejected_24h with
          | Some n when n > v_rej -> n
          | Some _ | None -> v_rej
        in
        let ver_observed =
          Observed.is_value model.work.verifications
          || Observed.is_value sc.verifications_passed_24h
          || Observed.is_value sc.verifications_rejected_24h
        in
        let ver_part =
          if vp + vr > 0 then
            let pct_s =
              Printf.sprintf "%.0f%%(%d/%d)"
                (100.0 *. float_of_int vp /. float_of_int (vp + vr))
                vp (vp + vr)
            in
            Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "검증 %s" pct_s)
                 ~en:(Printf.sprintf "Ver %s" pct_s))
          else if ver_observed then
            Say.resolve lang (Say.make ~ko:"검증 0" ~en:"Ver 0")
          else
            let m = format_observed_marker ~lang model.work.verifications in
            Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "검증 %s" m)
                 ~en:(Printf.sprintf "Ver %s" m))
        in
        let third_part =
          match Observed.to_option sc.turns_24h with
          | Some n ->
              Some
                (Say.resolve lang
                   (Say.make
                      ~ko:(Printf.sprintf "턴 %s"
                             (Format_val.format_value Format_val.Count
                                (float_of_int n)))
                      ~en:(Printf.sprintf "Turns %s"
                             (Format_val.format_value Format_val.Count
                                (float_of_int n)))))
          | None -> (
              match Observed.to_option sc.board_posts_24h with
              | Some n ->
                  Some
                    (Say.resolve lang
                       (Say.make
                          ~ko:(Printf.sprintf "토론 %d" n)
                          ~en:(Printf.sprintf "Posts %d" n)))
              | None -> None)
        in
        let left_s =
          [ Some done_part; Some ver_part; third_part ]
          |> List.filter_map Fun.id
          |> String.concat Typography.sep_dot
        in
        let candle_s, candle_st =
          if unattrib > 0 && score_rows <= 2 then
            ( Printf.sprintf "%s%d %s"
                (Glyph.to_utf8 Glyph.Warning_triangle)
                unattrib
                (Say.resolve lang (Say.make ~ko:"미귀속" ~en:"unattributed")),
              attn_st )
          else candle_hero_display ~lang ~theme ~bg ~model ~hero
        in
        put_left_right grid ~clip:r1 ~y:!cy ~left_text:left_s ~left_style:pri_st
          ~right_text:candle_s ~right_style:candle_st;
        incr cy
      end;
      if !cy < Rect.bottom content then begin
        let r2 = Rect.make ~x:content.x ~y:!cy ~w:content.w ~h:1 in
        let top_c = top_contributors_summary model in
        let top_line =
          if String.equal top_c "" then ""
          else
            Say.resolve lang
              (Say.make ~ko:("상위: " ^ top_c) ~en:("Top: " ^ top_c))
        in
        let vel_line =
          match latest_velocity_pair model with
          | Some (u, d) ->
              Printf.sprintf "%s %s %s %s"
                (Glyph.to_utf8 Glyph.Delta_up)
                (Format_val.format_value Format_val.Count u)
                (Glyph.to_utf8 Glyph.Delta_down)
                (Format_val.format_value Format_val.Count d)
          | None -> ""
        in
        put_left_right grid ~clip:r2 ~y:!cy ~left_text:top_line
          ~left_style:struct_st ~right_text:vel_line ~right_style:whisper_st;
        incr cy
      end;
      if !cy < Rect.bottom content && (unlinked > 0 || unattrib > 0) then begin
        let r3 = Rect.make ~x:content.x ~y:!cy ~w:content.w ~h:1 in
        Card.draw_left_rail ~bg ~tone:Theme.Status_attention grid ~x:content.x
          ~y:!cy ~h:1 ~theme;
        let parts =
          (if unlinked > 0 then
             [
               Say.resolve lang
                 (Say.make
                    ~ko:(Printf.sprintf "미연결 작업 %d건" unlinked)
                    ~en:(Printf.sprintf "%d unlinked tasks" unlinked));
             ]
           else [])
          @
          if unattrib > 0 then
            [
              Say.resolve lang
                (Say.make
                   ~ko:(Printf.sprintf "%d 미귀속 캔들" unattrib)
                   ~en:(Printf.sprintf "%d unattributed candle" unattrib));
            ]
          else []
        in
        let warn =
          Glyph.to_utf8 Glyph.Warning_triangle
          ^ " "
          ^ String.concat Typography.sep_dot parts
        in
        ignore
          (Cell_grid.put_text ~clip:r3 grid ~x:(content.x + 2) ~y:!cy
             ~style:attn_st
             (Grapheme.truncate_to_width
                ~max_width:(Int.max 0 (content.w - 2))
                warn))
      end
    end

(* ---------- Panel D: World Pulse (Signal-First Board + World Memory & Candle Footer) ---------- *)

let one_line_excerpt s =
  s
  |> String.trim
  |> String.map (function '\n' | '\r' | '\t' -> ' ' | c -> c)

let render_world_pulse_panel grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~bp =
  if Rect.is_empty rect then ()
  else
    let lang = model.lang in
    let threads = Knowledge_store.hottest_signal_threads model.knowledge in
    let pane_focused =
      Model.equal_pulse_pane (Model.active_pulse_pane model) Model.Pulse_world
    in
    let title =
      Say.resolve lang
        (Say.make ~ko:"월드 펄스 · 핵심 토론" ~en:"World Pulse · Signal Threads")
    in
    let badge : Card.badge =
      {
        glyph = Some Glyph.Live_healthy;
        text =
          Say.resolve lang
            (Say.make
               ~ko:(Printf.sprintf "신호만 · %d" (List.length threads))
               ~en:(Printf.sprintf "Signal · %d" (List.length threads)));
        tone = Some Theme.Status_active;
      }
    in
    let hotkey = Say.resolve lang (Say.make ~ko:"[3] 지식" ~en:"[3] Knowledge") in
    let inner =
      Card.draw ~cache grid ~rect ~theme
        {
          (Card.default_spec ~title) with
          badge = Some badge;
          hotkey = Some hotkey;
          focused = pane_focused;
        }
    in
    let pad_x = Layout.card_pad_x bp in
    let content = Card.pad_inner ~pad_x inner in
    if not (Rect.is_empty content) then begin
      let bg = Color.of_rgb theme.surface_1 in
      let pill_bg = Color.of_rgb theme.surface_2 in
      let pri_st = Typography.primary ~bg theme in
      let struct_st = Typography.structure ~bg theme in
      let whisper_st = Typography.whisper ~bg theme in
      let ok_st = Typography.status ~bg ~bold:true theme Theme.Status_ok in
      let attn_st =
        Typography.status ~bg ~bold:true theme Theme.Status_attention
      in
      let mem_rows = if content.h >= 6 then 2 else 1 in
      let div_rows = if content.h >= 5 then 1 else 0 in
      let thread_rows = Int.max 0 (content.h - mem_rows - div_rows) in
      let y = ref content.y in
      let thread_bottom = content.y + thread_rows in
      if thread_rows > 0 then begin
        match model.knowledge.board with
        | Observed.Loading _ ->
            ignore
              (Cell_grid.put_text ~clip:content grid ~x:content.x ~y:!y
                 ~style:whisper_st
                 (Say.resolve lang
                    (Say.make
                       ~ko:(Glyph.to_utf8 Glyph.Transport_reconnecting ^ " 신호 스레드 불러오는 중...")
                       ~en:(Glyph.to_utf8 Glyph.Transport_reconnecting ^ " Loading signal threads..."))));
            incr y
        | Observed.Absent | Observed.Unreported | Observed.Failed _ | Observed.Value _ ->
            if threads = [] then begin
              ignore
                (Cell_grid.put_text ~clip:content grid ~x:content.x ~y:!y
                   ~style:whisper_st
                   (Grapheme.truncate_to_width ~max_width:content.w
                      (Say.resolve lang
                         (Say.make
                            ~ko:(Glyph.to_utf8 Glyph.Live_idle ^ " 활성 신호 스레드 없음 (Verify 노이즈 제외)")
                            ~en:(Glyph.to_utf8 Glyph.Live_idle ^ " No active signal threads (Verify noise hidden)")))));
              incr y
            end
            else
              let arr = Array.of_list threads in
              let total = Array.length arr in
              let sel_thread_idx =
                if total <= 0 then 0
                else
                  Int.max 0
                    (Int.min (total - 1) model.knowledge.pulse_thread_index)
              in
              let rich_mode = thread_rows >= 8 && content.w >= 48 in
              let rows_per_thread = if rich_mode then 3 else 1 in
              let vis_threads = Int.max 1 (thread_rows / rows_per_thread) in
              let start_thread_idx =
                if total <= vis_threads then 0
                else
                  Int.max 0
                    (Int.min (total - vis_threads)
                       (sel_thread_idx - vis_threads + 1))
              in
              let rec draw_thread i =
                if i >= total || !y >= thread_bottom then ()
                else begin
                  let p = arr.(i) in
                  let py = !y in
                  let is_sel = pane_focused && Int.equal i sel_thread_idx in
                  let rbg =
                    Color.of_rgb
                      (if is_sel then theme.selection_bg else theme.surface_1)
                  in
                  let row_full = Rect.make ~x:inner.x ~y:py ~w:inner.w ~h:1 in
                  if is_sel then begin
                    Cell_grid.fill_rect ~clip:inner grid ~rect:row_full
                      ~style:(Typography.primary ~bg:rbg theme) ();
                    Cell_grid.put_glyph ~clip:row_full grid ~x:inner.x ~y:py
                      ~style:(Typography.accent ~bg:rbg ~bold:true theme)
                      Glyph.Left_rail
                  end;
                  let row_r = Rect.make ~x:content.x ~y:py ~w:content.w ~h:1 in
                  let x = ref content.x in
                  (* Subtle hearth pill *)
                  (match p.hearth with
                   | Some h when not (String.equal (String.trim h) "") ->
                       let ht =
                         " #" ^ Grapheme.truncate_to_width ~max_width:10 h ^ " "
                       in
                       let h_adv =
                         Cell_grid.put_text ~clip:row_r grid ~x:!x ~y:py
                           ~style:(Typography.structure ~bg:pill_bg ~bold:true theme)
                           ht
                       in
                       x := !x + h_adv + 1
                   | Some _ | None -> ());
                  (* Succession chain depth badge *)
                  (match p.chain_depth with
                   | Some d when d > 1 ->
                       let c_adv =
                         Cell_grid.put_text ~clip:row_r grid ~x:!x ~y:py
                           ~style:(Typography.accent ~bg:rbg ~bold:true theme)
                           (Printf.sprintf "[x%d] " d)
                       in
                       x := !x + c_adv
                   | Some _ | None -> ());
                  let age_txt =
                    match
                      Render_util.format_relative_age
                        ~now_unix:model.freshness.last_wall_unix
                        ~at_unix:p.created_at_unix
                    with
                    | Some a -> a
                    | None -> ""
                  in
                  let reply_txt =
                    if p.comment_count > 0 then Printf.sprintf "%dc" p.comment_count
                    else ""
                  in
                  if rich_mode && py + 1 < thread_bottom then begin
                    (* Line 1: Hearth + [xN] + Bold text_bright Title *)
                    let title_w = Int.max 0 (Rect.right content - !x) in
                    if title_w > 3 then
                      ignore
                        (Cell_grid.put_text ~clip:row_r grid ~x:!x ~y:py
                           ~style:(Typography.anchor ~bg:rbg theme)
                           (Grapheme.truncate_to_width ~max_width:title_w p.title));
                    incr y;
                    (* Line 2: @author · excerpt ... reply_cnt · italic age *)
                    let py2 = !y in
                    let row2 = Rect.make ~x:content.x ~y:py2 ~w:content.w ~h:1 in
                    let rx = ref (Rect.right content) in
                    if not (String.equal age_txt "") then begin
                      let aw = Grapheme.display_width age_txt in
                      rx := !rx - aw;
                      if !rx > content.x + 8 then
                        ignore
                          (Cell_grid.put_text ~clip:row2 grid ~x:!rx ~y:py2
                             ~style:whisper_st age_txt)
                    end;
                    if not (String.equal reply_txt "") then begin
                      let sep_s =
                        if not (String.equal age_txt "") then Typography.sep_dot
                        else ""
                      in
                      let rw = Grapheme.display_width reply_txt in
                      let sw = Grapheme.display_width sep_s in
                      rx := !rx - sw - rw;
                      if !rx > content.x + 8 then begin
                        let a =
                          Cell_grid.put_text ~clip:row2 grid ~x:!rx ~y:py2
                            ~style:struct_st reply_txt
                        in
                        if sw > 0 then
                          ignore
                            (Cell_grid.put_text ~clip:row2 grid ~x:(!rx + a)
                               ~y:py2
                               ~style:(Typography.whisper ~bg ~italic:false theme)
                               sep_s)
                      end
                    end;
                    let left_limit = Int.max content.x (!rx - 2) in
                    let ax = ref (content.x + 1) in
                    let author_s = "@" ^ p.author in
                    let a_adv =
                      Cell_grid.put_text ~clip:row2 grid ~x:!ax ~y:py2
                        ~style:struct_st
                        (Grapheme.truncate_to_width
                           ~max_width:(Int.min 20 (Int.max 0 (left_limit - !ax)))
                           author_s)
                    in
                    ax := !ax + a_adv;
                    let excerpt = one_line_excerpt p.body in
                    let rem_w = left_limit - !ax - 3 in
                    if rem_w > 6 && not (String.equal excerpt "") then begin
                      let s_adv =
                        Cell_grid.put_text ~clip:row2 grid ~x:!ax ~y:py2
                          ~style:(Typography.whisper ~bg ~italic:false theme)
                          Typography.sep_dot
                      in
                      ax := !ax + s_adv;
                      ignore
                        (Cell_grid.put_text ~clip:row2 grid ~x:!ax ~y:py2
                           ~style:whisper_st
                           (Grapheme.truncate_to_width ~max_width:rem_w excerpt))
                    end;
                    incr y;
                    (* Subtle hairline divider between rich items when room allows *)
                    if i + 1 < total && !y + 2 <= thread_bottom then begin
                      Card.draw_hairline ~pad_x ~bg grid ~rect:inner ~y:!y ~theme;
                      incr y
                    end;
                    draw_thread (i + 1)
                  end
                  else begin
                    (* Compact single-line thread row *)
                    let meta_w =
                      let rw = Grapheme.display_width reply_txt in
                      let aw = Grapheme.display_width age_txt in
                      if rw > 0 && aw > 0 then rw + 3 + aw else rw + aw
                    in
                    let right_x = Rect.right content - meta_w in
                    let title_w = Int.max 0 (right_x - !x - 1) in
                    if title_w > 3 then
                      ignore
                        (Cell_grid.put_text ~clip:row_r grid ~x:!x ~y:py
                           ~style:
                             (if is_sel || i = 0 then
                                Typography.anchor ~bg:rbg theme
                              else Typography.primary ~bg:rbg theme)
                           (Grapheme.truncate_to_width ~max_width:title_w p.title));
                    if meta_w > 0 && right_x > !x then begin
                      let mx = ref right_x in
                      if not (String.equal reply_txt "") then begin
                        let a =
                          Cell_grid.put_text ~clip:row_r grid ~x:!mx ~y:py
                            ~style:(Typography.structure ~bg:rbg theme) reply_txt
                        in
                        mx := !mx + a;
                        if not (String.equal age_txt "") then
                          let s =
                            Cell_grid.put_text ~clip:row_r grid ~x:!mx ~y:py
                              ~style:(Typography.whisper ~bg:rbg ~italic:false theme)
                              Typography.sep_dot
                          in
                          mx := !mx + s
                      end;
                      if not (String.equal age_txt "") then
                        ignore
                          (Cell_grid.put_text ~clip:row_r grid ~x:!mx ~y:py
                             ~style:(Typography.whisper ~bg:rbg theme) age_txt)
                    end;
                    incr y;
                    draw_thread (i + 1)
                  end
                end
              in
              draw_thread start_thread_idx
      end;
      (* Footer Hairline Band: Live World Memory + Candle Highlight *)
      let mem_y = Rect.bottom content - mem_rows in
      if div_rows = 1 && mem_y - 1 >= content.y then
        Card.draw_hairline ~pad_x ~bg
          ~label:(Say.resolve lang (Say.make ~ko:"월드 기억 · 캔들" ~en:"World Memory & Candle"))
          grid ~rect:inner ~y:(mem_y - 1) ~theme;
      if mem_y >= content.y && mem_y < Rect.bottom content then begin
        let row1 = Rect.make ~x:content.x ~y:mem_y ~w:content.w ~h:1 in
        let hero = Model.pulse_hero_metrics model in
        let unattrib = candle_unattributed_count model in
        match model.knowledge.world_memory with
        | Observed.Failed { reason; _ } ->
            let err_st =
              Typography.status ~bg ~bold:true theme Theme.Status_critical
            in
            let err_msg =
              Printf.sprintf "%s %s: %s"
                (Glyph.to_utf8 Glyph.Live_failing)
                (Say.resolve lang
                   (Say.make ~ko:"월드 기억 조회 실패" ~en:"World Memory failed"))
                reason
            in
            let candle_s, candle_st =
              candle_hero_display ~lang ~theme ~bg ~model ~hero
            in
            put_left_right grid ~clip:row1 ~y:mem_y ~left_text:err_msg
              ~left_style:err_st ~right_text:candle_s ~right_style:candle_st
        | Observed.Loading _ ->
            let loading_msg =
              Printf.sprintf "%s %s"
                (Glyph.to_utf8 Glyph.Transport_reconnecting)
                (Say.resolve lang
                   (Say.make ~ko:"월드 기억 스냅샷 불러오는 중…"
                      ~en:"Loading World Memory snapshot…"))
            in
            let candle_s, candle_st =
              candle_hero_display ~lang ~theme ~bg ~model ~hero
            in
            put_left_right grid ~clip:row1 ~y:mem_y ~left_text:loading_msg
              ~left_style:whisper_st ~right_text:candle_s ~right_style:candle_st
        | Observed.Unreported | Observed.Absent ->
            let unrep_msg =
              match model.knowledge.world_memory with
              | Observed.Unreported ->
                  Printf.sprintf "%s %s"
                    (Glyph.to_utf8 Glyph.Missing_unreported)
                    (Say.resolve lang
                       (Say.make ~ko:"월드 기억 미보고 (Legacy API)"
                          ~en:"World Memory unreported (Legacy API)"))
              | Observed.Absent | Observed.Loading _ | Observed.Failed _
              | Observed.Value _ ->
                  Printf.sprintf "%s %s"
                    (Glyph.to_utf8 Glyph.Missing_absent)
                    (Say.resolve lang
                       (Say.make ~ko:"월드 기억 비어 있음"
                          ~en:"World Memory empty"))
            in
            let candle_s, candle_st =
              candle_hero_display ~lang ~theme ~bg ~model ~hero
            in
            put_left_right grid ~clip:row1 ~y:mem_y ~left_text:unrep_msg
              ~left_style:whisper_st ~right_text:candle_s ~right_style:candle_st
        | Observed.Value { data = wm; _ } ->
            let headline =
              match wm.briefing.text with
              | Some txt when not (String.equal (String.trim txt) "") -> (
                  match String.split_on_char '\n' (String.trim txt) with
                  | h :: _ -> String.trim h
                  | [] -> "")
              | Some _ | None ->
                  Say.resolve lang
                    (match wm.briefing.status with
                     | Wire_knowledge.Briefing_current ->
                         Say.make ~ko:"브리핑 최신" ~en:"Briefing current"
                     | Wire_knowledge.Briefing_stale ->
                         Say.make ~ko:"브리핑 갱신 필요" ~en:"Briefing stale"
                     | Wire_knowledge.Briefing_missing ->
                         Say.make ~ko:"인벤토리 동기화" ~en:"Inventory synced"
                     | Wire_knowledge.Briefing_unavailable ->
                         Say.make ~ko:"브리핑 미가용" ~en:"Briefing unavailable")
            in
            let conflicts_str, conf_st =
              if wm.conflicts_count > 0 then
                ( Printf.sprintf "%s %d %s"
                    (Glyph.to_utf8 Glyph.Action_required)
                    wm.conflicts_count
                    (Say.resolve lang (Say.make ~ko:"충돌" ~en:"conflicts")),
                  attn_st )
              else
                ( Printf.sprintf "%s 0 %s"
                    (Glyph.to_utf8 Glyph.Live_healthy)
                    (Say.resolve lang (Say.make ~ko:"충돌" ~en:"conflicts")),
                  ok_st )
            in
            let counts_str =
              Printf.sprintf "%d %s %s %d %s %s " wm.claims_count
                (Say.resolve lang (Say.make ~ko:"주장" ~en:"claims"))
                (Glyph.to_utf8 Glyph.Separator_dot)
                wm.facts_count
                (Say.resolve lang (Say.make ~ko:"사실" ~en:"facts"))
                (Glyph.to_utf8 Glyph.Separator_dot)
            in
            let stats_w =
              Grapheme.display_width counts_str
              + Grapheme.display_width conflicts_str
            in
            let stats_x = Rect.right content - stats_w in
            let hl_w = Int.max 0 (stats_x - content.x - 2) in
            if hl_w > 6 then
              ignore
                (Cell_grid.put_text ~clip:row1 grid ~x:content.x ~y:mem_y
                   ~style:pri_st
                   (Grapheme.truncate_to_width ~max_width:hl_w headline));
            if stats_x >= content.x then begin
              let a1 =
                Cell_grid.put_text ~clip:row1 grid ~x:stats_x ~y:mem_y
                  ~style:struct_st counts_str
              in
              ignore
                (Cell_grid.put_text ~clip:row1 grid ~x:(stats_x + a1) ~y:mem_y
                   ~style:conf_st conflicts_str)
            end;
            if mem_rows >= 2 && mem_y + 1 < Rect.bottom content then begin
              let row2 =
                Rect.make ~x:content.x ~y:(mem_y + 1) ~w:content.w ~h:1
              in
              let wiki_part =
                match Observed.to_option model.knowledge.wiki_index with
                | Some wi ->
                    if wi.lint.total_findings > 0 then
                      Printf.sprintf "Wiki %dp (%s%d)" wi.pages_total
                        (Glyph.to_utf8 Glyph.Warning_triangle)
                        wi.lint.total_findings
                    else Printf.sprintf "Wiki %dp" wi.pages_total
                | None -> ""
              in
              let left_line = wiki_part in
              let right_candle, right_st =
                if unattrib > 0 then
                  ( Printf.sprintf "%s%d %s"
                      (Glyph.to_utf8 Glyph.Warning_triangle)
                      unattrib
                      (Say.resolve lang
                         (Say.make ~ko:"미귀속" ~en:"unattributed")),
                    attn_st )
                else candle_hero_display ~lang ~theme ~bg ~model ~hero
              in
              put_left_right grid ~clip:row2 ~y:(mem_y + 1)
                ~left_text:left_line
                ~left_style:whisper_st
                ~right_text:right_candle ~right_style:right_st
            end
      end
    end

(* ---------- Adaptive Layout Orchestration (Wide / Standard / Compact) ---------- *)

let render ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Theme.of_preset model.theme_preset in
    let bp =
      Layout.classify_viewport ~cols:(Cell_grid.cols grid)
        ~rows:(Cell_grid.rows grid)
    in
    let groups = company_groups_for_pulse model in
    let gap_x = Layout.card_gap_x bp in
    let gap_y = Layout.card_gap_y bp in
    (* Pulse has no sub-tab bar: add a subtle 1-row top breathing cushion on
       Wide/Standard when height permits so the Hero Band never hugs row 0. *)
    let work_r =
      match bp with
      | Layout.Wide | Layout.Standard when rect.h >= 24 ->
          Rect.make ~x:rect.x ~y:(rect.y + 1) ~w:rect.w ~h:(rect.h - 1)
      | Layout.Wide | Layout.Standard | Layout.Compact | Layout.Micro -> rect
    in
    let hero_h =
      match bp with
      | Layout.Wide | Layout.Standard -> Int.min 4 work_r.h
      | Layout.Compact | Layout.Micro -> Int.min 3 work_r.h
    in
    let hero_r, below_hero = Rect.split_v work_r ~top_h:hero_h in
    render_kpi_hero_band grid ~rect:hero_r ~theme ~model ~groups ~bp;
    let main_r =
      if gap_y > 0 && below_hero.h > gap_y + 4 then
        Rect.make ~x:below_hero.x ~y:(below_hero.y + gap_y) ~w:below_hero.w
          ~h:(below_hero.h - gap_y)
      else below_hero
    in
    if not (Rect.is_empty main_r) then
      match bp with
      | Layout.Wide | Layout.Standard -> (
          let cols_r =
            Layout.split_h ~gap:gap_x main_r [ Layout.Ratio 0.46; Layout.Flex 1 ]
          in
          match cols_r with
          | [ left_col; right_col ] ->
              let attn_h =
                attention_panel_height model
                  ~max_rows:(if Layout.equal_breakpoint bp Layout.Wide then 7 else 5)
              in
              let comp_h = companies_panel_height groups ~bp in
              let left_rows =
                Layout.split_v ~gap:gap_y left_col
                  [
                    Layout.Fixed attn_h;
                    Layout.Min_max
                      {
                        min = Int.min comp_h 7;
                        max = comp_h;
                        weight = 2;
                      };
                    Layout.Flex 1;
                  ]
              in
              (match left_rows with
               | [ attn_r; comp_r; goals_r ] ->
                   render_attention_panel grid ~cache ~rect:attn_r ~theme ~model
                     ~bp;
                   render_companies_panel grid ~cache ~rect:comp_r ~theme ~model
                     ~groups ~bp;
                   render_goals_and_scorecard_panel grid ~cache ~rect:goals_r
                     ~theme ~model ~bp
               | _ -> ());
              render_world_pulse_panel grid ~cache ~rect:right_col ~theme ~model
                ~bp
          | _ -> ())
      | Layout.Compact | Layout.Micro -> (
          let attn_h = attention_panel_height model ~max_rows:4 in
          let comp_h = companies_panel_height groups ~bp in
          let rows_r =
            Layout.split_v ~gap:0 main_r
              [
                Layout.Fixed attn_h;
                Layout.Min_max { min = 6; max = comp_h; weight = 2 };
                Layout.Min_max { min = 4; max = 5; weight = 1 };
                Layout.Flex 2;
              ]
          in
          match rows_r with
          | [ a_r; c_r; g_r; w_r ] ->
              render_attention_panel grid ~cache ~rect:a_r ~theme ~model ~bp;
              render_companies_panel grid ~cache ~rect:c_r ~theme ~model ~groups
                ~bp;
              render_goals_and_scorecard_panel grid ~cache ~rect:g_r ~theme
                ~model ~bp;
              render_world_pulse_panel grid ~cache ~rect:w_r ~theme ~model ~bp
          | _ -> ())
