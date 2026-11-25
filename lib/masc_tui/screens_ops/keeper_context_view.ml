open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let short_sha s =
  let len = String.length s in
  if len <= 10 then s else String.sub s 0 10

let format_bytes n =
  Format_val.format_value Format_val.Bytes (float_of_int (Int.max 0 n))

let format_tokens_opt ~lang = function
  | Some n -> Format_val.format_value Format_val.Tokens (float_of_int n)
  | None ->
      ignore lang;
      Glyph.to_utf8 Glyph.Missing_absent

let format_ms_opt = function
  | Some ms -> Format_val.format_value Format_val.Milliseconds (float_of_int ms)
  | None -> Glyph.to_utf8 Glyph.Missing_absent

let format_ms_float_opt = function
  | Some ms -> Format_val.format_value Format_val.Milliseconds ms
  | None -> Glyph.to_utf8 Glyph.Missing_absent

let draw_auth_denied_notice grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~endpoint =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = Ops_common.pad_x_for ~model rect in
    let c = Card.pad_inner ~pad_x rect in
    if not (Rect.is_empty c) then begin
      Card.draw_left_rail ~bg ~tone:Theme.Status_attention grid ~x:c.x ~y:c.y
        ~h:(Int.min 2 c.h) ~theme;
      ignore
        (Ops_common.put_line ~clip:c grid ~x:(c.x + 2) ~y:c.y
           ~max_w:(Int.max 0 (c.w - 2))
           ~style:(Typography.status ~bg ~bold:true theme Theme.Status_attention)
           (Printf.sprintf "%s %s (%s)"
              (Glyph.to_utf8 Glyph.Action_required)
              (Ops_common.say model ~ko:"관리자 권한(CanAdmin) 필요"
                 ~en:"Admin permission (CanAdmin) required")
              endpoint));
      if c.h >= 2 then
        ignore
          (Ops_common.put_line ~clip:c grid ~x:(c.x + 2) ~y:(c.y + 1)
             ~max_w:(Int.max 0 (c.w - 2))
             ~style:(Typography.whisper ~bg theme)
             (Ops_common.say model
                ~ko:"서버가 401/403을 반환했습니다 — 다른 컨텍스트 탭은 정상 동작합니다."
                ~en:"Server returned 401/403 — other inspector tabs remain live."))
    end

let component_buckets (r : Turn_record.t) =
  match r.input_components with
  | Some comps ->
      List.fold_left
        (fun (prompt_b, tools_b, msgs_b) (c : Turn_record.input_component) ->
          match c.component with
          | Turn_record.Prompt_block _ -> (prompt_b + c.bytes, tools_b, msgs_b)
          | Turn_record.Tool_schemas -> (prompt_b, tools_b + c.bytes, msgs_b)
          | Turn_record.Message_user
          | Turn_record.Message_system
          | Turn_record.Message_assistant_text
          | Turn_record.Message_thinking
          | Turn_record.Message_redacted_thinking
          | Turn_record.Message_tool_use
          | Turn_record.Message_tool_result
          | Turn_record.Message_image
          | Turn_record.Message_document
          | Turn_record.Message_audio ->
              (prompt_b, tools_b, msgs_b + c.bytes))
        (0, 0, 0) comps
  | None ->
      let pb =
        List.fold_left
          (fun acc (b : Turn_record.prompt_block) -> acc + b.bytes)
          0 r.blocks
      in
      (pb, 0, 0)

let format_message_list_change (ch : Message_list_change.t) =
  match ch with
  | Message_list_change.Appended { kept; added } ->
      ( Printf.sprintf "Appended (kept %d, +%d)" kept added
      , Theme.Status_ok )
  | Message_list_change.Tail_removed { kept; removed } ->
      ( Printf.sprintf "Tail_removed (kept %d, -%d)" kept removed
      , Theme.Status_attention )
  | Message_list_change.Block_dropped { at; dropped; kept_after; added } ->
      ( Printf.sprintf "Block_dropped @%d (-%d, kept_after %d, +%d)" at dropped
          kept_after added
      , Theme.Status_critical )
  | Message_list_change.Rewritten_in_place
      {
        first_index;
        last_index;
        rewritten;
        previous_bytes;
        current_bytes;
        first_previous_role;
        first_current_role;
        added;
      } ->
      ( Printf.sprintf "Rewritten [%d..%d] (%d, %s->%s, %dB->%dB, +%d)"
          first_index last_index rewritten
          (Llm_provider.Types.role_to_string first_previous_role)
          (Llm_provider.Types.role_to_string first_current_role)
          previous_bytes current_bytes added
      , Theme.Status_critical )
  | Message_list_change.Diverged_at
      {
        index;
        previous_role;
        previous_bytes;
        current_role;
        current_bytes;
        previous_count;
        current_count;
      } ->
      ( Printf.sprintf "Diverged @%d (%s %dB vs %s %dB; %d->%d msgs)" index
          (Llm_provider.Types.role_to_string previous_role)
          previous_bytes
          (Llm_provider.Types.role_to_string current_role)
          current_bytes previous_count current_count
      , Theme.Status_critical )

let cache_outcome_lines ~(model : Model.t)
    (reading : Keeper_cache_outcome_reading.reading) :
    (Theme.status_token * string) list =
  match reading.outcome with
  | Keeper_cache_outcome_reading.Turn_not_in_ledger ->
      [
        ( Theme.Status_historical
        , Ops_common.say model ~ko:"비용 원장에 이 턴 기록 없음"
            ~en:"Turn not recorded in cost ledger" );
      ]
  | Keeper_cache_outcome_reading.Ledger_row_unreadable reason ->
      [ (Theme.Status_critical, "Ledger unreadable: " ^ reason) ]
  | Keeper_cache_outcome_reading.Not_per_request req ->
      [
        ( Theme.Status_active
        , Printf.sprintf "Session/turn-scoped (%s) · cache read=%s write=%s"
            req.runtime_id
            (format_tokens_opt ~lang:model.lang req.cache_read_tokens)
            (format_tokens_opt ~lang:model.lang req.cache_creation_tokens) );
      ]
  | Keeper_cache_outcome_reading.First_request
      { request; other_runtime_since; earlier } ->
      let head =
        let other_s =
          match other_runtime_since with
          | Some r -> Printf.sprintf " · switched via %s" r
          | None -> ""
        in
        ( Theme.Status_active
        , Printf.sprintf "%s · read %s · write %s%s" request.runtime_id
            (format_tokens_opt ~lang:model.lang request.cache_read_tokens)
            (format_tokens_opt ~lang:model.lang request.cache_creation_tokens)
            other_s )
      in
      let detail =
        match earlier with
        | Keeper_cache_outcome_reading.No_earlier_request { horizon_s } ->
            [
              ( Theme.Status_historical
              , Printf.sprintf "No earlier request within %.0fs horizon"
                  horizon_s );
            ]
        | Keeper_cache_outcome_reading.Earlier { request = prev; idle; prefix }
          ->
            let ttl_line =
              match idle with
              | Keeper_cache_outcome_reading.Start_unrecorded ->
                  ( Theme.Status_historical
                  , Printf.sprintf "Prev %s · TTL idle unknown (no latency)"
                      (Ids.Turn_ref.to_string prev.turn_ref) )
              | Keeper_cache_outcome_reading.Idle { idle_s; lifetime } -> (
                  match lifetime with
                  | Keeper_cache_outcome_reading.Lifetime_unrecorded ->
                      ( Theme.Status_historical
                      , Printf.sprintf "Idle %.1fs · TTL unrecorded" idle_s )
                  | Keeper_cache_outcome_reading.Provider_default_unknown
                      Keeper_cache_outcome_reading.Default_undeclared ->
                      ( Theme.Status_historical
                      , Printf.sprintf "Idle %.1fs · provider default TTL undeclared"
                          idle_s )
                  | Keeper_cache_outcome_reading.Provider_default_unknown
                      Keeper_cache_outcome_reading.Runtime_inactive ->
                      ( Theme.Status_attention
                      , Printf.sprintf "Idle %.1fs · runtime inactive" idle_s )
                  | Keeper_cache_outcome_reading.Lifetime_declared
                      { lifetime_s; check } ->
                      let tok, tag =
                        match check with
                        | Keeper_cache_outcome_reading.Within ->
                            (Theme.Status_ok, "TTL Within")
                        | Keeper_cache_outcome_reading.Outlived ->
                            (Theme.Status_critical, "TTL Outlived")
                        | Keeper_cache_outcome_reading.Undecided ->
                            (Theme.Status_attention, "TTL Undecided")
                      in
                      ( tok
                      , Printf.sprintf "%s (idle %.1fs / ttl %.0fs)" tag idle_s
                          lifetime_s ))
            in
            let prefix_line =
              match prefix with
              | Keeper_cache_outcome_reading.Not_compared
                  Keeper_cache_outcome_reading.Earlier_turn_not_settled ->
                  ( Theme.Status_historical
                  , "Prefix: not compared (earlier turn not settled)" )
              | Keeper_cache_outcome_reading.Not_compared
                  (Keeper_cache_outcome_reading.Snapshot_unread { detail; _ }) ->
                  (Theme.Status_attention, "Prefix: snapshot unread · " ^ detail)
              | Keeper_cache_outcome_reading.Not_compared
                  (Keeper_cache_outcome_reading.Snapshot_of_other_runtime
                     { runtime_profile; _ }) ->
                  ( Theme.Status_attention
                  , "Prefix: snapshot from other runtime " ^ runtime_profile )
              | Keeper_cache_outcome_reading.Compared
                  { system_changed; tools_changed; messages } ->
                  let msg_txt, msg_tok = format_message_list_change messages in
                  let flags =
                    Printf.sprintf "sys=%s tools=%s"
                      (if system_changed then "CHANGED" else "same")
                      (if tools_changed then "CHANGED" else "same")
                  in
                  let tok =
                    if system_changed || tools_changed then Theme.Status_critical
                    else msg_tok
                  in
                  (tok, Printf.sprintf "Prefix: %s · %s" flags msg_txt)
            in
            [ ttl_line; prefix_line ]
      in
      head :: detail

let draw_composition_subtab grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~(st : Keeper_context_store.keeper_state) =
  let bg = Color.of_rgb theme.surface_1 in
  let pad_x = Ops_common.pad_x_for ~model rect in
  let content = Card.pad_inner ~pad_x rect in
  if Rect.is_empty content then ()
  else
    match Keeper_context_store.selected_turn_entry st with
    | None ->
        Ops_common.draw_observed_empty grid ~rect:content ~theme
          ~lang:model.lang st.turn_records
          ~empty_msg:
            (Say.make ~ko:"기록된 턴 레코드가 없습니다"
               ~en:"No turn records observed yet")
    | Some entry ->
        let r = entry.record in
        let y = ref content.y in
        let bot = Rect.bottom content in
        (* 1. Context Window Occupancy Ratio Gauge *)
        let denom_opt =
          match r.provider_context_window with
          | Some w when w > 0 -> Some w
          | Some _ | None -> r.context_window
        in
        let used_obs =
          match r.usage.input_tokens with
          | Some n -> Observed.value ~observed_at:Clock.Mono.zero (float_of_int n)
          | None -> Observed.unreported
        in
        let lim_obs =
          match denom_opt with
          | Some n -> Observed.value ~observed_at:Clock.Mono.zero (float_of_int n)
          | None -> Observed.unreported
        in
        if !y + 1 < bot then begin
          let gauge_h = if bot - !y >= 14 then 2 else 1 in
          let g_rect = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:gauge_h in
          let prov_hint =
            match r.usage.input_provenance with
            | Some Turn_input_provenance.Context_estimate ->
                Some (Say.make ~ko:"추정치" ~en:"estimate")
            | Some Turn_input_provenance.Measured_request ->
                Some (Say.make ~ko:"실측 요청" ~en:"dispatched")
            | None -> None
          in
          let spec : Chart.Spec.t =
            {
              title = Say.make ~ko:"컨텍스트 점유" ~en:"Context Window";
              hotkey_hint = None;
              kind =
                Chart.Spec.Ratio_gauge
                  {
                    used = used_obs;
                    limit = lim_obs;
                    unit = Format_val.Tokens;
                    gradient = Chart.Gradient.Thermal;
                    reset_hint = prov_hint;
                  };
            }
          in
          ignore
            (Chart.draw grid ~rect:g_rect ~theme ~caps:Ops_common.default_caps
               ~lang:model.lang ~show_title:false spec);
          y := !y + gauge_h
        end;
        (* 2. Provider Usage Strip & Latency *)
        if !y < bot then begin
          let cache_pct_s =
            match (r.usage.input_tokens, r.usage.cache_read_input_tokens) with
            | Some inp, Some cr when inp > 0 ->
                Printf.sprintf " (%.0f%%)"
                  (float_of_int cr /. float_of_int inp *. 100.0)
            | _ -> ""
          in
          let usage_line =
            Printf.sprintf
              "In %s · CacheR %s%s · CacheW %s · Out %s · Lat %s · TTFRC %s"
              (format_tokens_opt ~lang:model.lang r.usage.input_tokens)
              (format_tokens_opt ~lang:model.lang
                 r.usage.cache_read_input_tokens)
              cache_pct_s
              (format_tokens_opt ~lang:model.lang
                 r.usage.cache_creation_input_tokens)
              (format_tokens_opt ~lang:model.lang r.usage.output_tokens)
              (format_ms_opt r.request_latency_ms)
              (format_ms_float_opt r.ttfrc_ms)
          in
          ignore
            (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
               ~max_w:content.w ~style:(Typography.structure ~bg theme)
               usage_line);
          incr y
        end;
        (* 3. Recent-Turns Input Sparkline *)
        (match Observed.to_option st.turn_records with
        | Some page when List.length page.entries >= 2 && !y < bot ->
            let samples =
              List.rev page.entries
              |> List.map (fun (e : Wire_keeper_context.turn_record_entry) ->
                     match e.record.usage.input_tokens with
                     | Some n when n > 0 -> Chart.Series.Value (float_of_int n)
                     | Some _ -> Chart.Series.Zero
                     | None -> Chart.Series.Absent)
              |> Array.of_list
            in
            let lbl =
              Ops_common.say model ~ko:"최근 턴 입력 추이: " ~en:"Recent Input: "
            in
            let adv =
              Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                ~max_w:content.w ~style:(Typography.whisper ~bg theme) lbl
            in
            let spark_w = Int.min 28 (Int.max 0 (content.w - adv - 18)) in
            if spark_w >= 4 then begin
              let s_adv =
                Chart.draw_sparkline_run ~clip:content grid
                  ~x:(content.x + adv) ~y:!y ~width:spark_w ~theme ~bg
                  ~unicode:true ~gradient:Chart.Gradient.Cool_flow samples
              in
              let n_turns = List.length page.entries in
              ignore
                (Ops_common.put_line ~clip:content grid
                   ~x:(content.x + adv + s_adv + 1)
                   ~y:!y
                   ~max_w:(Int.max 0 (content.w - adv - s_adv - 1))
                   ~style:(Typography.whisper ~bg theme)
                   (Printf.sprintf "(%d turns)" n_turns))
            end;
            incr y
        | Some _ | None -> ());
        (* 4. Carried History Reach Bar *)
        (match r.model_input_window with
        | Some win when !y < bot ->
            let ratio =
              if win.total_atoms > 0 then
                Float.max 0.0
                  (Float.min 1.0
                     (float_of_int win.transmitted_atoms
                     /. float_of_int win.total_atoms))
              else 0.0
            in
            let lbl =
              Ops_common.say model ~ko:"이력 도달: " ~en:"History Reach: "
            in
            let adv =
              Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                ~max_w:content.w ~style:(Typography.structure ~bg theme) lbl
            in
            let bar_w = Int.min 16 (Int.max 0 (content.w - adv - 26)) in
            let after_bar =
              if bar_w >= 4 then
                adv
                + Chart.draw_ratio_bar_run ~clip:content grid
                    ~x:(content.x + adv) ~y:!y ~width:bar_w ~theme ~bg
                    ~unicode:true ~gradient:Chart.Gradient.Cool_flow ~ratio
                + 1
              else adv
            in
            let shape_s =
              match win.measurement with
              | Turn_record.Wire_shape -> "wire"
              | Turn_record.Durable_shape -> "durable"
            in
            let ref_s =
              match r.refused_model_input with
              | Some _ -> " · REFUSED"
              | None -> ""
            in
            ignore
              (Ops_common.put_line ~clip:content grid
                 ~x:(content.x + after_bar) ~y:!y
                 ~max_w:(Int.max 0 (content.w - after_bar))
                 ~style:(Typography.primary ~bg theme)
                 (Printf.sprintf "%d/%d atoms (%s)%s" win.transmitted_atoms
                    win.total_atoms shape_s ref_s));
            incr y
        | Some _ | None -> ());
        (* 5. Stacked Composition Bar (Prompt Assembly / Tool Surface / Provider Messages) *)
        let prompt_b, tools_b, msgs_b = component_buckets r in
        if prompt_b + tools_b + msgs_b > 0 && !y + 1 < bot then begin
          let bar_r = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:2 in
          let wire_lbl =
            match r.request_wire_observation with
            | Some wo ->
                Printf.sprintf "wire %s" (format_bytes wo.body_bytes)
            | None ->
                format_bytes (prompt_b + tools_b + msgs_b)
          in
          let spec : Chart.Spec.t =
            {
              title = Say.make ~ko:"입력 구성" ~en:"Input Composition";
              hotkey_hint = None;
              kind =
                Chart.Spec.Stacked_bar
                  {
                    segments =
                      [
                        ( Say.make ~ko:"프롬프트" ~en:"Prompt"
                        , float_of_int prompt_b
                        , Theme.Status_active );
                        ( Say.make ~ko:"도구 스키마" ~en:"Tools"
                        , float_of_int tools_b
                        , Theme.Status_ai );
                        ( Say.make ~ko:"메시지" ~en:"Messages"
                        , float_of_int msgs_b
                        , Theme.Status_ok );
                      ];
                    total_label = Say.literal wire_lbl;
                    unit = Format_val.Bytes;
                  };
            }
          in
          ignore
            (Chart.draw grid ~rect:bar_r ~theme ~caps:Ops_common.default_caps
               ~lang:model.lang ~show_title:false spec);
          y := !y + 2
        end;
        (* 6. Block Diff vs Previous Turn *)
        (match entry.diff_vs_prev with
        | Some d when !y < bot ->
            let add_n = List.length d.added in
            let rem_n = List.length d.removed in
            let chg_n = List.length d.changed in
            if add_n + rem_n + chg_n > 0 then begin
              let chg_names =
                List.map
                  (fun ((_, b) : Turn_record.prompt_block * Turn_record.prompt_block) ->
                    Prompt_block_id.to_string b.block)
                  d.changed
                @ List.map
                    (fun (b : Turn_record.prompt_block) ->
                      "+" ^ Prompt_block_id.to_string b.block)
                    d.added
                @ List.map
                    (fun (b : Turn_record.prompt_block) ->
                      "-" ^ Prompt_block_id.to_string b.block)
                    d.removed
              in
              let diff_s =
                Printf.sprintf "Δ blocks: +%d -%d ~%d (%s)" add_n rem_n chg_n
                  (String.concat ", " (List.take 4 chg_names))
              in
              ignore
                (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                   ~max_w:content.w
                   ~style:(Typography.status ~bg theme Theme.Status_attention)
                   diff_s);
              incr y
            end
        | Some _ | None -> ());
        (* 7. Next-Request Forecast Band *)
        if !y + 1 < bot then begin
          Card.draw_hairline ~pad_x:0 ~bg
            ~label:
              (Ops_common.say model ~ko:"다음 요청 예측 (Next-Request Forecast)"
                 ~en:"Next-Request Forecast Band")
            grid ~rect:content ~y:!y ~theme;
          incr y;
          let forecast_rows =
            match st.next_request with
            | Observed.Value { data = fc; _ } ->
                let acc = ref [] in
                let push st_t txt = acc := (st_t, txt) :: !acc in
                let walk_s =
                  match fc.walk with
                  | Wire_keeper_context.Walk_order { lane_id; declared } ->
                      Printf.sprintf "Lane %s [%s] · ckpt %d msgs · wake %s"
                        lane_id (String.concat " → " declared)
                        fc.checkpoint_messages (format_bytes fc.wake_line_bytes)
                  | Wire_keeper_context.Walk_refused reason ->
                      Printf.sprintf "Walk refused: %s · ckpt %d msgs" reason
                        fc.checkpoint_messages
                in
                push (Typography.structure ~bg ~bold:true theme) walk_s;
                List.iter
                  (fun (cand : Wire_keeper_context.forecast_candidate) ->
                    let rest_s, rest_tok =
                      match cand.place.rest with
                      | Wire_keeper_context.Forecast_serving ->
                          ("serving", Theme.Status_ok)
                      | Wire_keeper_context.Forecast_resting
                          { release_basis; _ } ->
                          ("resting:" ^ release_basis, Theme.Status_attention)
                    in
                    let lane_s =
                      match cand.lane with
                      | Wire_keeper_context.Forecast_agent_core -> "agent_core"
                      | Wire_keeper_context.Forecast_not_applicable r ->
                          "n/a:" ^ r
                    in
                    let parts_s =
                      match cand.parts with
                      | Wire_keeper_context.Forecast_parts_ok p ->
                          Printf.sprintf "instr %s · schemas %s · pinned %s"
                            (format_bytes p.instructions_bytes)
                            (format_bytes p.schemas_bytes)
                            (format_bytes p.pinned_bytes)
                      | Wire_keeper_context.Forecast_parts_error e ->
                          "parts err: " ^ e
                    in
                    let carried_s =
                      match cand.carried with
                      | Some c ->
                          let tok_s =
                            match c.counted_tokens with
                            | Some t -> Printf.sprintf " (%d tok)" t
                            | None -> ""
                          in
                          Printf.sprintf "carry %d/%d atoms (%s%s)"
                            c.kept_atoms cand.history_atoms
                            (format_bytes c.transmitted_bytes)
                            tok_s
                      | None ->
                          Printf.sprintf "history %d atoms" cand.history_atoms
                    in
                    push
                      (Typography.status ~bg ~bold:true theme rest_tok)
                      (Printf.sprintf "#%d %s [%s · %s] · %s · %s"
                         cand.place.walks_at cand.runtime_id rest_s lane_s
                         parts_s carried_s);
                    match cand.assembly with
                    | Some slots when slots <> [] ->
                        let slot_strs =
                          List.map
                            (function
                              | Wire_keeper_context.Slot_system_prompt { bytes } ->
                                  "sys:" ^ format_bytes bytes
                              | Wire_keeper_context.Slot_tools { bytes } ->
                                  "tools:" ^ format_bytes bytes
                              | Wire_keeper_context.Slot_preamble { bytes } ->
                                  "pre:" ^ format_bytes bytes
                              | Wire_keeper_context.Slot_history
                                  { atoms; of_atoms; bytes } ->
                                  Printf.sprintf "hist:%d/%d(%s)" atoms of_atoms
                                    (format_bytes bytes)
                              | Wire_keeper_context.Slot_wake_line { bytes } ->
                                  "wake:" ^ format_bytes bytes
                              | Wire_keeper_context.Slot_system_context
                                  { bytes; _ } ->
                                  "ctx:" ^ format_bytes bytes)
                            slots
                        in
                        push (Typography.whisper ~bg theme)
                          ("  " ^ String.concat " → " slot_strs)
                    | Some _ | None -> ())
                  fc.candidates;
                List.rev !acc
            | Observed.Loading _ ->
                [
                  ( Typography.whisper ~bg theme
                  , Glyph.to_utf8 Glyph.Transport_reconnecting ^ " "
                    ^ Ops_common.say model ~ko:"다음 요청 예측 불러오는 중..."
                        ~en:"Loading next-request forecast..." );
                ]
            | Observed.Absent | Observed.Unreported ->
                [
                  ( Typography.whisper ~bg theme
                  , Ops_common.say model ~ko:"다음 요청 예측 미보고"
                      ~en:"Next-request forecast unreported" );
                ]
            | Observed.Failed { reason; _ } ->
                [
                  ( Typography.status ~bg theme Theme.Status_critical
                  , Glyph.to_utf8 Glyph.Live_failing ^ " " ^ reason );
                ]
          in
          let avail = Int.max 1 (bot - !y) in
          let max_skip = Int.max 0 (List.length forecast_rows - avail) in
          let skip = Int.min max_skip (Int.max 0 st.scroll_offset) in
          List.iter
            (fun (style, txt) ->
              if !y < bot then begin
                ignore
                  (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                     ~max_w:content.w ~style txt);
                incr y
              end)
            (Store_scroll.drop skip forecast_rows)
        end

let draw_flow_subtab grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~(st : Keeper_context_store.keeper_state) =
  let bg = Color.of_rgb theme.surface_1 in
  let pad_x = Ops_common.pad_x_for ~model rect in
  let content = Card.pad_inner ~pad_x rect in
  if Rect.is_empty content then ()
  else
    let rows_acc = ref [] in
    let push style txt = rows_acc := (style, txt) :: !rows_acc in
    let sec_hdr ~ko ~en =
      push (Typography.accent ~bg ~bold:true theme)
        ("── " ^ Ops_common.say model ~ko ~en ^ " ──")
    in
    (* 1. Selected Turn Intake, Source Outcomes & Runtime Attempts *)
    (match Keeper_context_store.selected_turn_entry st with
    | None ->
        push (Typography.whisper ~bg theme)
          (Ops_common.say model ~ko:"선택된 턴이 없습니다" ~en:"No turn selected")
    | Some entry ->
        let r = entry.record in
        (* 1a. Turn Latency Waterfall + Sampling & Cost *)
        sec_hdr ~ko:"턴 지연 워터폴 · 샘플링 · 비용"
          ~en:"Turn Latency Waterfall · Sampling · Cost";
        let lat_s =
          Printf.sprintf "Total %s · TTFRC %s · Profile %s · Model %s · Kind %s"
            (format_ms_opt r.request_latency_ms)
            (format_ms_float_opt r.ttfrc_ms)
            r.runtime_profile
            (Option.value ~default:"—" r.selected_model)
            (Turn_record.turn_kind_to_string r.turn_kind)
        in
        push (Typography.structure ~bg theme) ("  " ^ lat_s);
        let samp = r.sampling in
        let fmt_f opt =
          match opt with Some f -> Printf.sprintf "%.2f" f | None -> "—"
        in
        let fmt_i opt =
          match opt with Some n -> Int.to_string n | None -> "—"
        in
        let fmt_b opt =
          match opt with Some true -> "on" | Some false -> "off" | None -> "—"
        in
        let cost_s =
          let has_cache_tokens =
            match
              ( r.usage.cache_read_input_tokens,
                r.usage.cache_creation_input_tokens )
            with
            | Some cr, _ when cr > 0 -> true
            | _, Some cc when cc > 0 -> true
            | (Some _ | None), (Some _ | None) -> false
          in
          let measured_input =
            match r.usage.input_provenance with
            | Some Turn_input_provenance.Measured_request -> true
            | Some Turn_input_provenance.Context_estimate | None -> false
          in
          match (r.price_input_per_million, r.price_output_per_million) with
          | Some pin, Some pout -> (
              match (r.usage.input_tokens, r.usage.output_tokens) with
              | Some tin, Some tout when measured_input && not has_cache_tokens ->
                  let usd =
                    (float_of_int tin *. pin +. float_of_int tout *. pout)
                    /. 1_000_000.0
                  in
                  Printf.sprintf "$%.5f (in $%.2f/M · out $%.2f/M)" usd pin pout
              | (Some _ | None), (Some _ | None) ->
                  Printf.sprintf "in $%.2f/M · out $%.2f/M" pin pout)
          | Some pin, None -> Printf.sprintf "in $%.2f/M" pin
          | None, Some pout -> Printf.sprintf "out $%.2f/M" pout
          | None, None -> "—"
        in
        push (Typography.whisper ~bg theme)
          (Printf.sprintf
             "  temp=%s · top_p=%s · max_tok=%s · thinking=%s · rates=%s"
             (fmt_f samp.temperature) (fmt_f samp.top_p) (fmt_i samp.max_tokens)
             (fmt_b samp.enable_thinking) cost_s);
        (* 1b. Intake & Runtime Flow Events (/runtime-trace) *)
        sec_hdr ~ko:"인테이크 · 페일오버 흐름 (runtime-trace)"
          ~en:"Intake · Failover Flow (runtime-trace)";
        (match Keeper_context_store.turn_flow_for_selected_turn st with
        | Some flow ->
            (match flow.intake with
            | Wire_keeper_context.Intake_observed { channel; sources } ->
                let ch_s = Option.value ~default:"—" channel in
                push (Typography.status ~bg ~bold:true theme Theme.Status_ok)
                  (Printf.sprintf "  Intake observed · channel=%s · %d stimuli"
                     ch_s (List.length sources));
                List.iter
                  (fun (src : Wire_keeper_context.turn_intake_source) ->
                    let kind_s = Option.value ~default:"stimulus" src.source_kind in
                    push (Typography.structure ~bg theme)
                      (Printf.sprintf "    • [%s] %s · snap=%s · rev=%s" kind_s
                         (short_sha src.stimulus_id) (short_sha src.snapshot_ref)
                         (short_sha src.admitted_revision)))
                  (List.take 8 sources);
                if List.length sources > 8 then
                  push (Typography.whisper ~bg theme)
                    (Printf.sprintf "    (+%d more stimuli)"
                       (List.length sources - 8))
            | Wire_keeper_context.Intake_not_recorded reason ->
                push (Typography.whisper ~bg theme)
                  ("  Intake not recorded: " ^ reason)
            | Wire_keeper_context.Intake_unavailable reason ->
                push (Typography.status ~bg theme Theme.Status_attention)
                  ("  Intake unavailable: " ^ reason)
            | Wire_keeper_context.Intake_ambiguous n ->
                push (Typography.status ~bg theme Theme.Status_critical)
                  (Printf.sprintf "  Intake ambiguous: %d turn_started rows" n));
            (match flow.outcomes with
            | Wire_keeper_context.Outcomes_observed
                { coverage_state; rows_inspected; sources; _ } ->
                push (Typography.whisper ~bg theme)
                  (Printf.sprintf "  Outcomes (%s · %d rows · %d sources)"
                     coverage_state rows_inspected (List.length sources));
                List.iter
                  (fun (so : Wire_keeper_context.turn_source_outcome) ->
                    let rkinds =
                      List.map
                        (fun (rc : Wire_keeper_context.turn_source_receipt) ->
                          rc.kind)
                        so.receipts
                    in
                    let r_s =
                      if rkinds = [] then "no receipts"
                      else String.concat ", " rkinds
                    in
                    push (Typography.structure ~bg theme)
                      (Printf.sprintf "    ↳ %s → %s" (short_sha so.stimulus_id) r_s))
                  (List.take 6 sources);
                if List.length sources > 6 then
                  push (Typography.whisper ~bg theme)
                    (Printf.sprintf "    (+%d more outcome sources)"
                       (List.length sources - 6))
            | Wire_keeper_context.Outcomes_unavailable reason ->
                push (Typography.whisper ~bg theme)
                  ("  Outcomes unavailable: " ^ reason));
            if flow.events <> [] then begin
              push (Typography.whisper ~bg theme)
                (Printf.sprintf "  Runtime trace events (%d/%d):"
                   (List.length flow.events) flow.manifest_total_rows);
              List.iter
                (fun (ev : Wire_keeper_context.turn_flow_event) ->
                  let rt = Option.value ~default:"—" ev.runtime_id in
                  let act =
                    match (ev.routing_action, ev.routing_reason) with
                    | Some a, Some rsn -> Printf.sprintf " · %s (%s)" a rsn
                    | Some a, None -> " · " ^ a
                    | None, Some rsn -> " · " ^ rsn
                    | None, None -> ""
                  in
                  let tok =
                    match String.lowercase_ascii ev.status with
                    | "ok" | "completed" | "succeeded" -> Theme.Status_ok
                    | "error" | "failed" -> Theme.Status_critical
                    | _ -> Theme.Status_active
                  in
                  push (Typography.status ~bg theme tok)
                    (Printf.sprintf "    %s [%s] rt=%s%s" ev.event ev.status rt
                       act))
                (List.take 16 flow.events);
              if List.length flow.events > 16 then
                push (Typography.whisper ~bg theme)
                  (Printf.sprintf "    (+%d more events)"
                     (List.length flow.events - 16))
            end
        | None -> (
            match st.turn_flow with
            | Observed.Absent ->
                push (Typography.whisper ~bg theme)
                  ("  "
                   ^ Ops_common.say model ~ko:"턴 흐름 트레이스 없음"
                       ~en:"No turn flow trace recorded")
            | Observed.Failed { reason; _ } ->
                push (Typography.status ~bg theme Theme.Status_critical)
                  ("  " ^ Glyph.to_utf8 Glyph.Live_failing ^ " " ^ reason)
            | Observed.Loading _ | Observed.Value _ | Observed.Unreported ->
                push (Typography.whisper ~bg theme)
                  ("  " ^ Glyph.to_utf8 Glyph.Transport_reconnecting ^ " "
                   ^ Ops_common.say model ~ko:"턴 흐름 트레이스 대기/로딩 중..."
                       ~en:"Awaiting turn flow trace...")));
        (* 1c. Request Observations (Per-Runtime-Attempt Journal) *)
        if r.request_observations <> [] then begin
          sec_hdr ~ko:"런타임 시도별 요청 관측" ~en:"Runtime Attempt Observations";
          List.iter
            (fun (obs : Request_observation.t) ->
              let detail, tok =
                match obs.evidence with
                | Request_observation.Not_dispatched ->
                    ("not_dispatched", Theme.Status_historical)
                | Request_observation.No_durable_scope ->
                    ("no_durable_scope", Theme.Status_historical)
                | Request_observation.No_matching_call ->
                    ("no_matching_call", Theme.Status_attention)
                | Request_observation.Read_failed msg ->
                    ("read_failed: " ^ msg, Theme.Status_critical)
                | Request_observation.Recorded { call_id; requests } ->
                    ( Printf.sprintf "call=%s · %d req(s)" (short_sha call_id)
                        (List.length requests),
                      Theme.Status_ok )
              in
              push (Typography.status ~bg theme tok)
                (Printf.sprintf "  #%d %s · %s" obs.attempt obs.runtime_profile
                   detail))
            r.request_observations
        end;
        (* 1d. Parallel Tool Batches & Per-Call Latency Waterfall *)
        (match Keeper_context_store.call_evidence_for_selected_turn st with
        | Some calls when calls <> [] ->
            sec_hdr ~ko:"병렬 도구 배치 · 호출 지연"
              ~en:"Parallel Tool Batches · Call Latency";
            let max_dur =
              List.fold_left
                (fun acc (c : Wire_keeper_context.tool_call_entry) ->
                  match c.duration_ms with
                  | Some ms -> Float.max acc ms
                  | None -> acc)
                1.0 calls
            in
            List.iter
              (fun (c : Wire_keeper_context.tool_call_entry) ->
                let batch_s =
                  match (c.batch_index, c.batch_size) with
                  | Some bi, Some bs when bs > 1 ->
                      Printf.sprintf "[B%d/%d] " bi bs
                  | Some bi, Some bs -> Printf.sprintf "[%d/%d] " bi bs
                  | _ -> ""
                in
                let mode_s =
                  match c.execution_mode with
                  | Some m -> " (" ^ m ^ ")"
                  | None -> ""
                in
                let bar_w =
                  match c.duration_ms with
                  | Some ms ->
                      Int.max 1
                        (Int.min 12
                           (int_of_float (Float.round (ms /. max_dur *. 12.0))))
                  | None -> 0
                in
                let bar =
                  if bar_w > 0 then String.make bar_w '#' else "-"
                in
                let tok =
                  match c.ok with
                  | Some true -> Theme.Status_ok
                  | Some false -> Theme.Status_critical
                  | None -> Theme.Status_attention
                in
                push (Typography.status ~bg theme tok)
                  (Printf.sprintf "  %s%s%s  %-12s %s" batch_s c.tool mode_s bar
                     (format_ms_float_opt c.duration_ms)))
              (List.take 16 calls);
            if List.length calls > 16 then
              push (Typography.whisper ~bg theme)
                (Printf.sprintf "  (+%d more calls)" (List.length calls - 16))
        | Some _ | None -> ());
        (* 1e. Full Block Diff Details (prev -> next bytes & digest) *)
        (match entry.diff_vs_prev with
        | Some d
          when d.added <> [] || d.removed <> [] || d.changed <> [] ->
            sec_hdr ~ko:"프롬프트 블록 Diff 상세" ~en:"Prompt Block Diff Detail";
            List.iter
              (fun (b : Turn_record.prompt_block) ->
                push (Typography.status ~bg theme Theme.Status_ok)
                  (Printf.sprintf "  + %s  +%s  sha=%s"
                     (Prompt_block_id.to_string b.block)
                     (format_bytes b.bytes) (short_sha b.digest)))
              d.added;
            List.iter
              (fun (b : Turn_record.prompt_block) ->
                push (Typography.status ~bg theme Theme.Status_critical)
                  (Printf.sprintf "  - %s  -%s  sha=%s"
                     (Prompt_block_id.to_string b.block)
                     (format_bytes b.bytes) (short_sha b.digest)))
              d.removed;
            List.iter
              (fun ((prev_b, next_b) :
                     Turn_record.prompt_block * Turn_record.prompt_block) ->
                let delta = next_b.bytes - prev_b.bytes in
                let sign = if delta >= 0 then "+" else "" in
                push (Typography.status ~bg theme Theme.Status_attention)
                  (Printf.sprintf "  ~ %s  %s → %s (%s%dB)  %s→%s"
                     (Prompt_block_id.to_string next_b.block)
                     (format_bytes prev_b.bytes)
                     (format_bytes next_b.bytes) sign delta
                     (short_sha prev_b.digest) (short_sha next_b.digest)))
              d.changed
        | Some _ | None -> ()));
    (* 2. Memory OS Recall Snapshot from Turn Records *)
    (match Observed.to_option st.turn_records with
    | Some { memory_os = Some mo; _ } ->
        sec_hdr ~ko:"Memory OS 리콜 스냅샷" ~en:"Memory OS Recall Snapshot";
        let src_s =
          match mo.update_source_kind with Some k -> k | None -> "—"
        in
        push (Typography.structure ~bg theme)
          (Printf.sprintf
             "  recall=%s · rev=%d · source=%s · facts=%d/%d · Δ +%d -%d ret=%d inv=%d"
             (if mo.recall_enabled then "on" else "off")
             mo.revision src_s mo.facts_shown mo.facts_current
             (List.length mo.change.added) (List.length mo.change.removed)
             mo.change.retained mo.change.invalidated_count);
        List.iter
          (fun err ->
            push (Typography.status ~bg theme Theme.Status_critical)
              ("  err: " ^ err))
          mo.read_errors;
        List.iter
          (fun (f : Wire_keeper_context.memory_os_fact_item) ->
            let claim_clean =
              Ops_common.scrub_secrets_in_text f.claim
              |> String.map (function '\n' | '\r' -> ' ' | c -> c)
            in
            push (Typography.whisper ~bg theme)
              (Printf.sprintf "    [%s] %s" f.category
                 (Grapheme.truncate_to_width
                    ~max_width:(Int.max 16 (content.w - 14))
                    claim_clean)))
          (List.take 5 mo.facts);
        if List.length mo.facts > 5 then
          push (Typography.whisper ~bg theme)
            (Printf.sprintf "    (+%d more facts)" (List.length mo.facts - 5))
    | Some { memory_os = None; _ } | None -> ());
    (* 3. Checkpoints & Operator Note & Control Quick Strip *)
    sec_hdr ~ko:"체크포인트 · 운영자 노트 · 제어 (/ctl)"
      ~en:"Checkpoints · Operator Note · Control (/ctl)";
    (if st.checkpoints_auth_denied then
       push (Typography.status ~bg theme Theme.Status_attention)
         (Ops_common.say model
            ~ko:"  체크포인트: CanAdmin 인증 필요"
            ~en:"  Checkpoints: requires CanAdmin auth")
     else
       match st.checkpoints with
       | Observed.Value { data = inv; _ } ->
           let cur_s =
             match inv.current with
             | Some c ->
                 Printf.sprintf "%s · %d msgs · %s" c.snapshot_id
                   (Option.value ~default:0 c.message_count)
                   (match c.size_bytes with
                   | Some b -> format_bytes b
                   | None -> "—")
             | None ->
                 Printf.sprintf "%s%s" inv.current_status
                   (match inv.current_error_kind with
                   | Some k -> " (" ^ k ^ ")"
                   | None -> "")
           in
           push (Typography.structure ~bg theme)
             (Printf.sprintf "  Checkpoint: %s · history=%d · errors=%d" cur_s
                (List.length inv.history) (List.length inv.history_errors));
           List.iter
             (fun (h : Wire_keeper_context.checkpoint_summary) ->
               push (Typography.whisper ~bg theme)
                 (Printf.sprintf "    hist: %s (%d msgs, %s)" h.snapshot_id
                    (Option.value ~default:0 h.message_count)
                    (match h.size_bytes with
                    | Some b -> format_bytes b
                    | None -> "—")))
             (List.take 4 inv.history);
           if List.length inv.history > 4 then
             push (Typography.whisper ~bg theme)
               (Printf.sprintf "    (+%d more history snapshots)"
                  (List.length inv.history - 4));
           List.iter
             (fun (e : Wire_keeper_context.checkpoint_summary) ->
               push (Typography.status ~bg theme Theme.Status_critical)
                 (Printf.sprintf "    err [%s]: %s (%s)" e.snapshot_id
                    (Option.value ~default:"error" e.error_kind)
                    (Option.value ~default:"" e.error_detail)))
             (List.take 3 inv.history_errors);
           if List.length inv.history_errors > 3 then
             push (Typography.whisper ~bg theme)
               (Printf.sprintf "    (+%d more history errors)"
                  (List.length inv.history_errors - 3))
       | Observed.Loading _ ->
           push (Typography.whisper ~bg theme) "  Checkpoints: loading..."
       | Observed.Failed { reason; _ } ->
           push (Typography.status ~bg theme Theme.Status_critical)
             ("  Checkpoints err: " ^ reason)
       | Observed.Absent ->
           push (Typography.whisper ~bg theme) "  Checkpoints: absent (404)"
       | Observed.Unreported ->
           push (Typography.whisper ~bg theme) "  Checkpoints: unreported");
    (match st.last_purge_preview with
    | Some p ->
        let rpt = p.report in
        push (Typography.status ~bg theme Theme.Status_attention)
          (Printf.sprintf
             "  Purge (%s): %d→%d msgs · -%s · reason_stripped=%d · tools_cleared=%d · apply_ok=%b"
             p.action rpt.messages_before rpt.messages_after
             (format_bytes rpt.bytes_removed)
             rpt.reasoning_blocks_stripped rpt.tool_results_cleared
             p.apply_allowed)
    | None -> ());
    (match st.operator_note with
    | Observed.Value { data = n; _ } ->
        let st_s =
          if n.pending then "PENDING"
          else
            match n.consumed_turn with
            | Some t -> Printf.sprintf "consumed @turn #%d" t
            | None -> "consumed"
        in
        let txt_one =
          Ops_common.scrub_secrets_in_text n.text
          |> String.map (function '\n' | '\r' -> ' ' | c -> c)
        in
        push (Typography.status ~bg theme
                (if n.pending then Theme.Status_attention else Theme.Status_ok))
          (Printf.sprintf "  Note [%s · %s]: %s" st_s n.created_by
             (Grapheme.truncate_to_width
                ~max_width:(Int.max 16 (content.w - 26))
                txt_one))
    | Observed.Absent ->
        push (Typography.whisper ~bg theme)
          (Ops_common.say model ~ko:"  운영자 노트: 없음 (/ctl note 로 작성)"
             ~en:"  Operator note: none (use /ctl note to set)")
    | Observed.Loading _ ->
        push (Typography.whisper ~bg theme) "  Operator note: loading..."
    | Observed.Failed { reason; _ } ->
        push (Typography.status ~bg theme Theme.Status_critical)
          ("  Operator note err: " ^ reason)
    | Observed.Unreported -> ());
    push (Typography.whisper ~bg theme)
      "  /ctl boot|up|pause|resume|wakeup|shutdown|reset|clear|purge-preview|purge-apply|delete-history|note|run-next";
    let rows = List.rev !rows_acc in
    let vis_h = Int.max 1 content.h in
    let max_skip = Int.max 0 (List.length rows - vis_h) in
    let skip = Int.min max_skip (Int.max 0 st.scroll_offset) in
    let y = ref content.y and bot = Rect.bottom content in
    List.iter
      (fun (style, txt) ->
        if !y < bot then begin
          ignore
            (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
               ~max_w:content.w ~style txt);
          incr y
        end)
      (Store_scroll.drop skip rows)

let draw_exact_input_subtab grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~(st : Keeper_context_store.keeper_state) =
  let bg = Color.of_rgb theme.surface_1 in
  let pad_x = Ops_common.pad_x_for ~model rect in
  let content = Card.pad_inner ~pad_x rect in
  if Rect.is_empty content then ()
  else
    let y = ref content.y in
    let bot = Rect.bottom content in
    (* 1. Cache Outcome Diagnosis Strip (top 3-4 rows) *)
    (match Keeper_context_store.cache_outcome_for_selected_turn st with
    | Some reading when !y + 2 < bot ->
        let lines = cache_outcome_lines ~model reading in
        List.iter
          (fun (tok, txt) ->
            if !y < bot then begin
              Card.draw_left_rail ~bg ~tone:tok grid ~x:content.x ~y:!y ~h:1
                ~theme;
              ignore
                (Ops_common.put_line ~clip:content grid ~x:(content.x + 2) ~y:!y
                   ~max_w:(Int.max 0 (content.w - 2))
                   ~style:(Typography.status ~bg theme tok)
                   txt);
              incr y
            end)
          (List.take 3 lines);
        if !y < bot then begin
          Card.draw_hairline ~pad_x:0 ~bg
            ~label:
              (Ops_common.say model
                 ~ko:"와이어 캡처 입력 파트 ([↑↓] 선택 · [Enter] 본문)"
                 ~en:"Wire-Captured Input Parts ([↑↓] Select · [Enter] Read)")
            grid ~rect:content ~y:!y ~theme;
          incr y
        end
    | Some _ | None -> ());
    let parts_area =
      Rect.make ~x:content.x ~y:!y ~w:content.w ~h:(Int.max 0 (bot - !y))
    in
    if Rect.is_empty parts_area then ()
    else if st.provider_input_auth_denied then
      draw_auth_denied_notice grid ~rect:parts_area ~theme ~model
        ~endpoint:"/provider-input"
    else
      match Keeper_context_store.provider_input_for_selected_turn st with
      | None ->
          Ops_common.draw_observed_empty grid ~rect:parts_area ~theme
            ~lang:model.lang st.provider_input
            ~empty_msg:
              (Say.make ~ko:"이 턴의 provider-input 스냅샷이 없습니다"
                 ~en:"No provider-input wire snapshot for this turn")
      | Some manifest ->
          let left_r, right_r =
            if parts_area.w >= 72 then
              match
                Layout.split_h ~gap:2 parts_area
                  [ Layout.Ratio 0.44; Layout.Flex 1 ]
              with
              | [ l; r ] -> (l, r)
              | _ -> (parts_area, Rect.empty)
            else
              match
                Layout.split_v ~gap:1 parts_area
                  [ Layout.Ratio 0.48; Layout.Flex 1 ]
              with
              | [ t; b ] -> (t, b)
              | _ -> (parts_area, Rect.empty)
          in
          let cols : Table.column list =
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
                id = "kind";
                header = Say.make ~ko:"파트" ~en:"Part";
                priority = 0;
                min_width = 14;
                max_width = None;
                weight = 4;
                align = Table.Left;
              };
              {
                id = "bytes";
                header = Say.make ~ko:"크기" ~en:"Bytes";
                priority = 1;
                min_width = 7;
                max_width = Some 10;
                weight = 1;
                align = Table.Right;
              };
              {
                id = "sha";
                header = Say.literal "SHA";
                priority = 2;
                min_width = 8;
                max_width = Some 10;
                weight = 1;
                align = Table.Left;
              };
            ]
          in
          let rows =
            List.map
              (fun (p : Wire_keeper_context.provider_input_part) ->
                let kind_s, tok =
                  match p.part_kind with
                  | Wire_keeper_context.Part_system_prompt ->
                      ("System_prompt", Theme.Status_active)
                  | Wire_keeper_context.Part_message { role } ->
                      (Printf.sprintf "Message(%s)" role, Theme.Status_ok)
                  | Wire_keeper_context.Part_tool_schema { name } ->
                      (Printf.sprintf "Tool(%s)" name, Theme.Status_ai)
                in
                {
                  Table.id = Int.to_string p.part_index;
                  cells =
                    [
                      ("idx", Table.text_cell (Int.to_string p.part_index));
                      ( "kind"
                      , Table.text_cell
                          ~fg:(Color.of_rgb (Theme.status_color theme tok))
                          kind_s );
                      ("bytes", Table.text_cell (format_bytes p.part_bytes));
                      ( "sha"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                          (short_sha p.part_sha256) );
                    ];
                })
              manifest.parts
          in
          let sel =
            if manifest.parts = [] then None
            else
              Some
                (Int.max 0
                   (Int.min (List.length manifest.parts - 1)
                      st.selected_part_idx))
          in
          let is_dive = Option.is_some (Model.active_dive model) in
          let is_zoomed =
            (not is_dive) && model.nav.zoomed
            && Model.can_zoom_current_view model
          in
          let left_focused =
            if is_dive || is_zoomed then Model.pane_focused model 0
            else Model.pane_focused model 1
          in
          let right_focused =
            if is_dive || is_zoomed then Model.pane_focused model 1
            else Model.pane_focused model 2
          in
          ignore
            (Table.draw grid ~rect:left_r ~theme ~caps:Ops_common.default_caps
               ~lang:model.lang ?selected:sel ~focused:left_focused
               ~columns:cols rows);
          if not (Rect.is_empty right_r) then begin
            let right_hdr_style =
              if right_focused then
                Typography.anchor ~bg:(Color.of_rgb theme.selection_bg) theme
              else Typography.anchor ~bg theme
            in
            let right_prefix =
              if right_focused then Glyph.to_utf8 Glyph.Focus_caret ^ " " else ""
            in
            match Keeper_context_store.part_content_for_selected st with
            | Some pc ->
                let scrubbed = Ops_common.scrub_secrets_in_text pc.text in
                let hdr =
                  Printf.sprintf "%sPart #%d · %s · %s" right_prefix
                    pc.part.part_index
                    (format_bytes pc.part.part_bytes)
                    (short_sha pc.part.part_sha256)
                in
                ignore
                  (Ops_common.put_line ~clip:right_r grid ~x:right_r.x
                     ~y:right_r.y ~max_w:right_r.w ~style:right_hdr_style hdr);
                let body_r =
                  Rect.make ~x:right_r.x ~y:(right_r.y + 1) ~w:right_r.w
                    ~h:(Int.max 0 (right_r.h - 1))
                in
                if not (Rect.is_empty body_r) then
                  ignore
                    (Markdown.draw grid ~rect:body_r ~theme ~osc8:false
                       ~scroll:st.scroll_offset scrubbed)
            | None ->
                if right_focused && right_r.h >= 2 then begin
                  let hdr =
                    right_prefix
                    ^ Ops_common.say model ~ko:"파트 원문" ~en:"Part Text"
                  in
                  ignore
                    (Ops_common.put_line ~clip:right_r grid ~x:right_r.x
                       ~y:right_r.y ~max_w:right_r.w ~style:right_hdr_style hdr);
                  let body_r =
                    Rect.make ~x:right_r.x ~y:(right_r.y + 1) ~w:right_r.w
                      ~h:(Int.max 0 (right_r.h - 1))
                  in
                  Ops_common.draw_observed_empty grid ~rect:body_r ~theme
                    ~lang:model.lang st.part_content
                    ~empty_msg:
                      (Say.make ~ko:"[Enter]를 눌러 선택 파트의 원문을 불러오세요"
                         ~en:"Press [Enter] to load selected part text")
                end
                else
                  Ops_common.draw_observed_empty grid ~rect:right_r ~theme
                    ~lang:model.lang st.part_content
                    ~empty_msg:
                      (Say.make ~ko:"[Enter]를 눌러 선택 파트의 원문을 불러오세요"
                         ~en:"Press [Enter] to load selected part text")
          end

let draw_input_map_subtab grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~(st : Keeper_context_store.keeper_state) =
  let pad_x = Ops_common.pad_x_for ~model rect in
  let content = Card.pad_inner ~pad_x rect in
  if Rect.is_empty content then ()
  else
    match Keeper_context_store.selected_turn_entry st with
    | None ->
        Ops_common.draw_observed_empty grid ~rect:content ~theme
          ~lang:model.lang st.turn_records
          ~empty_msg:
            (Say.make ~ko:"표시할 입력 맵이 없습니다" ~en:"No input map data")
    | Some entry ->
        let r = entry.record in
        let manifest_opt =
          Keeper_context_store.provider_input_for_selected_turn st
        in
        let block_tbl : (string, Turn_record.prompt_block) Hashtbl.t =
          Hashtbl.create 16
        in
        List.iter
          (fun (b : Turn_record.prompt_block) ->
            Hashtbl.replace block_tbl (Prompt_block_id.to_string b.block) b)
          r.blocks;
        let has_wire_manifest = Option.is_some manifest_opt in
        let has_wire_obs = Option.is_some r.request_wire_observation in
        let cols : Table.column list =
          [
            {
              id = "comp";
              header = Say.make ~ko:"컴포넌트" ~en:"Component";
              priority = 0;
              min_width = 16;
              max_width = None;
              weight = 3;
              align = Table.Left;
            };
            {
              id = "prod";
              header = Say.make ~ko:"생산자" ~en:"Producer";
              priority = 2;
              min_width = 12;
              max_width = Some 20;
              weight = 2;
              align = Table.Left;
            };
            {
              id = "bytes";
              header = Say.make ~ko:"바이트" ~en:"Bytes";
              priority = 0;
              min_width = 7;
              max_width = Some 10;
              weight = 1;
              align = Table.Right;
            };
            {
              id = "sha";
              header = Say.literal "SHA-256";
              priority = 1;
              min_width = 10;
              max_width = Some 12;
              weight = 1;
              align = Table.Left;
            };
            {
              id = "proof";
              header = Say.make ~ko:"증명" ~en:"Proof";
              priority = 0;
              min_width = 11;
              max_width = Some 13;
              weight = 2;
              align = Table.Left;
            };
          ]
        in
        let make_row ~id ~comp ~prod ~bytes ~sha ~proof_lbl ~proof_tone :
            Table.row =
          {
            Table.id;
            cells =
              [
                ("comp", Table.text_cell comp);
                ( "prod"
                , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary) prod );
                ("bytes", Table.text_cell (format_bytes bytes));
                ( "sha"
                , Table.text_cell ~fg:(Color.of_rgb theme.text_muted) sha );
                ( "proof"
                , Table.Badge
                    { glyph = None; text = proof_lbl; tone = proof_tone } );
              ];
          }
        in
        let rows =
          match r.input_components with
          | Some comps when comps <> [] ->
              List.mapi
                (fun idx (c : Turn_record.input_component) ->
                  let name = Turn_record.input_component_id_to_string c.component in
                  let prod, sha_opt =
                    match c.component with
                    | Turn_record.Prompt_block pb ->
                        let key = Prompt_block_id.to_string pb in
                        let sha =
                          match Hashtbl.find_opt block_tbl key with
                          | Some b -> Some b.digest
                          | None -> None
                        in
                        ("prompt_assembly", sha)
                    | Turn_record.Tool_schemas -> ("tool_surface", None)
                    | Turn_record.Message_user
                    | Turn_record.Message_system
                    | Turn_record.Message_assistant_text
                    | Turn_record.Message_thinking
                    | Turn_record.Message_redacted_thinking
                    | Turn_record.Message_tool_use
                    | Turn_record.Message_tool_result
                    | Turn_record.Message_image
                    | Turn_record.Message_document
                    | Turn_record.Message_audio ->
                        ("message_list", None)
                  in
                  let proof_lbl, proof_tone =
                    if has_wire_manifest then ("VERIFIED", Theme.Status_ok)
                    else if has_wire_obs then ("SERIALIZED", Theme.Status_active)
                    else if Option.is_some sha_opt then
                      ("DIGEST ONLY", Theme.Status_attention)
                    else ("BYTES ONLY", Theme.Status_historical)
                  in
                  let sha_s =
                    match sha_opt with
                    | Some s -> short_sha s
                    | None -> Glyph.to_utf8 Glyph.Missing_absent
                  in
                  make_row ~id:(Printf.sprintf "c%d" idx) ~comp:name ~prod
                    ~bytes:c.bytes ~sha:sha_s ~proof_lbl ~proof_tone)
                comps
          | Some _ | None ->
              List.mapi
                (fun idx (b : Turn_record.prompt_block) ->
                  let name = Prompt_block_id.to_string b.block in
                  let proof_lbl, proof_tone =
                    if has_wire_manifest then ("VERIFIED", Theme.Status_ok)
                    else if has_wire_obs then ("SERIALIZED", Theme.Status_active)
                    else ("DIGEST ONLY", Theme.Status_attention)
                  in
                  make_row ~id:(Printf.sprintf "b%d" idx) ~comp:name
                    ~prod:"prompt_assembly" ~bytes:b.bytes
                    ~sha:(short_sha b.digest) ~proof_lbl ~proof_tone)
                r.blocks
        in
        if rows = [] then
          Ops_common.draw_observed_empty grid ~rect:content ~theme
            ~lang:model.lang st.turn_records
            ~empty_msg:
              (Say.make ~ko:"이 턴에 기록된 입력 블록이 없습니다"
                 ~en:"No input blocks recorded on this turn")
        else
          ignore
            (Table.draw grid ~rect:content ~theme ~caps:Ops_common.default_caps
               ~lang:model.lang ~scroll:st.scroll_offset ~columns:cols rows)

let draw_response_subtab grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~(st : Keeper_context_store.keeper_state) =
  let bg = Color.of_rgb theme.surface_1 in
  let pad_x = Ops_common.pad_x_for ~model rect in
  let content = Card.pad_inner ~pad_x rect in
  if Rect.is_empty content then ()
  else
    match Keeper_context_store.selected_turn_entry st with
    | None ->
        Ops_common.draw_observed_empty grid ~rect:content ~theme
          ~lang:model.lang st.turn_records
          ~empty_msg:
            (Say.make ~ko:"선택된 턴이 없습니다" ~en:"No turn selected")
    | Some entry ->
        let r = entry.record in
        let rows_acc = ref [] in
        let push style txt = rows_acc := (style, txt) :: !rows_acc in
        let finish_s = Option.value ~default:"—" r.finish_reason in
        push
          (Typography.anchor ~bg theme)
          (Printf.sprintf "Finish: %s · Out: %s · TurnOut: %s · ExecIDs: %d"
             finish_s
             (format_tokens_opt ~lang:model.lang r.usage.output_tokens)
             (format_tokens_opt ~lang:model.lang r.turn_output_tokens)
             (List.length r.execution_ids));
        (match Keeper_context_store.transcript_for_selected_turn st with
        | Some tr when tr.found ->
            if tr.user <> [] then begin
              push (Typography.accent ~bg ~bold:true theme)
                (Ops_common.say model ~ko:"── 사용자 입력 (User) ──"
                   ~en:"── User Input ──");
              List.iter
                (fun (l : Wire_keeper_context.transcript_line) ->
                  let safe = Ops_common.scrub_secrets_in_text l.content in
                  List.iter
                    (fun ln -> push (Typography.structure ~bg theme) ("  " ^ ln))
                    (Chat_transcript.wrap_plain_lines
                       ~width:(Int.max 12 (content.w - 4))
                       safe))
                tr.user
            end;
            if tr.assistant <> [] then begin
              push (Typography.status ~bg ~bold:true theme Theme.Status_ok)
                (Ops_common.say model ~ko:"── 키퍼 응답 (Assistant) ──"
                   ~en:"── Assistant Reply ──");
              List.iter
                (fun (l : Wire_keeper_context.transcript_line) ->
                  let safe = Ops_common.scrub_secrets_in_text l.content in
                  List.iter
                    (fun ln -> push (Typography.primary ~bg theme) ("  " ^ ln))
                    (Chat_transcript.wrap_plain_lines
                       ~width:(Int.max 12 (content.w - 4))
                       safe))
                tr.assistant
            end
        | Some _ ->
            push (Typography.whisper ~bg theme)
              (Ops_common.say model ~ko:"이 턴의 트랜스크립트 본문 없음"
                 ~en:"No transcript text stored for this turn")
        | None -> (
            match st.turn_transcript with
            | Observed.Loading _ ->
                push (Typography.whisper ~bg theme)
                  (Glyph.to_utf8 Glyph.Transport_reconnecting ^ " "
                   ^ Ops_common.say model ~ko:"트랜스크립트 불러오는 중..."
                       ~en:"Loading turn transcript...")
            | Observed.Failed { reason; _ } ->
                push (Typography.status ~bg theme Theme.Status_critical)
                  (Glyph.to_utf8 Glyph.Live_failing ^ " " ^ reason)
            | Observed.Value _ | Observed.Absent | Observed.Unreported -> ()));
        (* Joined Tool Call Evidence by execution_ids *)
        if r.execution_ids <> [] then begin
          push (Typography.accent ~bg ~bold:true theme)
            (Printf.sprintf "── %s (%d) ──"
               (Ops_common.say model ~ko:"도구 호출 증거 (Execution IDs)"
                  ~en:"Tool Execution Evidence")
               (List.length r.execution_ids));
          if st.call_evidence_auth_denied then
            push
              (Typography.status ~bg theme Theme.Status_attention)
              (Ops_common.say model
                 ~ko:"  CanAdmin 권한 필요 (/tool-calls)"
                 ~en:"  CanAdmin permission required for /tool-calls")
          else
            let ev_tbl : (string, Wire_keeper_context.tool_call_entry) Hashtbl.t
                =
              Hashtbl.create 16
            in
            (match Keeper_context_store.call_evidence_for_selected_turn st with
            | Some calls ->
                List.iter
                  (fun (c : Wire_keeper_context.tool_call_entry) ->
                    match c.execution_id with
                    | Some eid -> Hashtbl.replace ev_tbl eid c
                    | None -> ())
                  calls
            | None -> ());
            List.iter
              (fun eid_val ->
                let eid = Ids.Execution_id.to_string eid_val in
                match Hashtbl.find_opt ev_tbl eid with
                | Some c ->
                    let tok, st_lbl =
                      match
                        ( Option.map String.lowercase_ascii c.disposition
                        , c.ok )
                      with
                      | Some "deferred", _ -> (Theme.Status_attention, "◐")
                      | _, Some true -> (Theme.Status_ok, "✓")
                      | _, Some false -> (Theme.Status_critical, "✕")
                      | _, None -> (Theme.Status_historical, "?")
                    in
                    let disp =
                      match c.disposition with
                      | Some d -> " · " ^ d
                      | None -> ""
                    in
                    let dur =
                      match c.duration_ms with
                      | Some ms ->
                          " · "
                          ^ Format_val.format_value Format_val.Milliseconds ms
                      | None -> ""
                    in
                    push
                      (Typography.status ~bg theme tok)
                      (Printf.sprintf "  [%s] %s (%s%s%s)" st_lbl c.tool
                         (short_sha eid) disp dur);
                    let out_one =
                      Ops_common.scrub_secrets_in_text c.output
                      |> String.map (function '\n' | '\r' -> ' ' | ch -> ch)
                      |> String.trim
                    in
                    if not (String.equal out_one "") then
                      push (Typography.whisper ~bg theme)
                        ("      "
                         ^ Grapheme.truncate_to_width
                             ~max_width:(Int.max 12 (content.w - 8))
                             out_one)
                | None ->
                    push (Typography.whisper ~bg theme)
                      (Printf.sprintf "  • %s (awaiting evidence)"
                         (short_sha eid)))
              r.execution_ids
        end;
        let rows = List.rev !rows_acc in
        let vis_h = Int.max 1 content.h in
        let max_skip = Int.max 0 (List.length rows - vis_h) in
        let skip = Int.min max_skip (Int.max 0 st.scroll_offset) in
        let y = ref content.y and bot = Rect.bottom content in
        List.iter
          (fun (style, txt) ->
            if !y < bot then begin
              ignore
                (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                   ~max_w:content.w ~style txt);
              incr y
            end)
          (Store_scroll.drop skip rows)

let draw_context_tab grid ~(rect : Rect.t) ~(theme : Theme.t) ~(model : Model.t)
    ~name =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = Ops_common.pad_x_for ~model rect in
    let st = Keeper_context_store.get_keeper ~keeper:name model.keeper_context in
    let y = ref rect.y in
    let bot = Rect.bottom rect in
    (* Row 0: Turn Stepper Header *)
    if !y < bot then begin
      let hdr_r = Rect.make ~x:(rect.x + pad_x) ~y:!y ~w:(Int.max 0 (rect.w - (2 * pad_x))) ~h:1 in
      let left_s =
        match (st.turn_records, Keeper_context_store.selected_turn_entry st) with
        | Observed.Value { data = page; _ }, Some e ->
            let r = e.record in
            let total = Int.max 1 (List.length page.entries) in
            let pos = Int.max 1 (Int.min total (st.selected_turn_idx + 1)) in
            let model_s =
              match r.selected_model with Some m -> " · " ^ m | None -> ""
            in
            let live_s = if page.live_turn_in_progress then " · LIVE" else "" in
            Printf.sprintf "Turn #%d (%d/%d) · %s · %s%s%s" r.absolute_turn pos
              total (Ids.Turn_ref.to_string r.turn_ref) r.runtime_profile model_s
              live_s
        | Observed.Value { data = page; _ }, None ->
            Printf.sprintf "%s (%d)"
              (Ops_common.say model ~ko:"턴 레코드 없음" ~en:"No turn records")
              page.count
        | Observed.Failed { reason; _ }, _ ->
            Printf.sprintf "%s: %s"
              (Ops_common.say model ~ko:"턴 레코드 오류"
                 ~en:"Turn records error")
              reason
        | Observed.Absent, _ ->
            Ops_common.say model ~ko:"턴 레코드 없음" ~en:"No turn records"
        | (Observed.Loading _ | Observed.Unreported), _ ->
            Ops_common.say model ~ko:"턴 레코드 불러오는 중..."
              ~en:"Loading turn records..."
      in
      let right_s =
        Ops_common.say model ~ko:"< / > 턴 · [v] 하위탭" ~en:"< / > Turn · [v] View"
      in
      let rw = Grapheme.display_width right_s in
      let lw = Int.max 8 (hdr_r.w - rw - 2) in
      ignore
        (Ops_common.put_line ~clip:hdr_r grid ~x:hdr_r.x ~y:!y ~max_w:lw
           ~style:(Typography.anchor ~bg theme) left_s);
      if hdr_r.w > rw + 10 then
        ignore
          (Ops_common.put_line ~clip:hdr_r grid ~x:(Rect.right hdr_r - rw) ~y:!y
             ~max_w:rw ~style:(Typography.whisper ~bg theme) right_s);
      incr y
    end;
    (* Row 1: Sub-tab Pills *)
    if !y < bot then begin
      let pill_r = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:1 in
      let pills =
        List.map
          (fun sub ->
            ( Say.resolve model.lang (Keeper_context_store.context_subtab_label sub)
            , Keeper_context_store.equal_context_subtab sub st.subtab
            , None ))
          Keeper_context_store.all_context_subtabs
      in
      ignore (Ops_common.draw_pills grid ~rect:pill_r ~theme ~bg pills);
      incr y
    end;
    if !y < bot && rect.h >= 6 then begin
      Card.draw_hairline ~pad_x ~bg grid ~rect ~y:!y ~theme;
      incr y
    end;
    let body_r =
      Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:(Int.max 0 (bot - !y))
    in
    if not (Rect.is_empty body_r) then
      match st.subtab with
      | Keeper_context_store.Ctx_composition ->
          draw_composition_subtab grid ~rect:body_r ~theme ~model ~st
      | Keeper_context_store.Ctx_flow ->
          draw_flow_subtab grid ~rect:body_r ~theme ~model ~st
      | Keeper_context_store.Ctx_exact_input ->
          draw_exact_input_subtab grid ~rect:body_r ~theme ~model ~st
      | Keeper_context_store.Ctx_input_map ->
          draw_input_map_subtab grid ~rect:body_r ~theme ~model ~st
      | Keeper_context_store.Ctx_response ->
          draw_response_subtab grid ~rect:body_r ~theme ~model ~st

(* ---------- Per-Keeper Tool Calls Tab ---------- *)

let draw_tool_calls_tab grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~name =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = Ops_common.pad_x_for ~model rect in
    let st = Keeper_context_store.get_keeper ~keeper:name model.keeper_context in
    let y = ref rect.y in
    let bot = Rect.bottom rect in
    (* Row 0: Hourly Tool Stats Summary + Sparkline *)
    if !y < bot then begin
      let hdr_r =
        Rect.make ~x:(rect.x + pad_x) ~y:!y
          ~w:(Int.max 0 (rect.w - (2 * pad_x)))
          ~h:1
      in
      (match Observed.to_option st.tool_stats with
      | Some stats ->
          let tot_fail =
            List.fold_left
              (fun acc (t : Wire_keeper_context.keeper_tool_stat_row) ->
                acc + t.failure_count)
              0 stats.tools
          in
          let fail_pct =
            if stats.total_entries > 0 then
              float_of_int tot_fail /. float_of_int stats.total_entries *. 100.0
            else 0.0
          in
          let top_str =
            stats.tools |> List.take 3
            |> List.map (fun (t : Wire_keeper_context.keeper_tool_stat_row) ->
                   Printf.sprintf "%s(%d)" t.name t.call_count)
            |> String.concat " "
          in
          let left_s =
            Printf.sprintf "%dh: %d calls · %.1f%% fail%s" stats.window_hours
              stats.total_entries fail_pct
              (if String.equal top_str "" then "" else " · " ^ top_str)
          in
          let spark_w =
            if stats.timeline <> [] && hdr_r.w >= 48 then 16 else 0
          in
          let lw = Int.max 8 (hdr_r.w - spark_w - 2) in
          ignore
            (Ops_common.put_line ~clip:hdr_r grid ~x:hdr_r.x ~y:!y ~max_w:lw
               ~style:(Typography.structure ~bg theme) left_s);
          if spark_w > 0 then begin
            let samples =
              Array.of_list
                (List.map
                   (fun (b : Wire_keeper_context.keeper_tool_hourly_bucket) ->
                     if b.call_count <= 0 then Chart.Series.Zero
                     else Chart.Series.Value (float_of_int b.call_count))
                   stats.timeline)
            in
            ignore
              (Chart.draw_sparkline_run ~clip:hdr_r grid
                 ~x:(Rect.right hdr_r - spark_w)
                 ~y:!y ~width:spark_w ~theme ~bg ~unicode:true
                 ~gradient:Chart.Gradient.Cool_flow samples)
          end
      | None ->
          ignore
            (Ops_common.put_line ~clip:hdr_r grid ~x:hdr_r.x ~y:!y
               ~max_w:hdr_r.w ~style:(Typography.whisper ~bg theme)
               (Ops_common.say model
                  ~ko:"도구 호출 통계 · [Enter] 전체 결과 조회"
                  ~en:"Tool Calls · [Enter] Fetch Full Result")));
      incr y
    end;
    if !y < bot && rect.h >= 6 then begin
      Card.draw_hairline ~pad_x ~bg grid ~rect ~y:!y ~theme;
      incr y
    end;
    let body_r =
      Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:(Int.max 0 (bot - !y))
    in
    if Rect.is_empty body_r then ()
    else if st.tool_calls_auth_denied then
      draw_auth_denied_notice grid ~rect:body_r ~theme ~model
        ~endpoint:"/tool-calls"
    else
      match Observed.to_option st.tool_calls with
      | None ->
          Ops_common.draw_observed_empty grid ~rect:body_r ~theme
            ~lang:model.lang st.tool_calls
            ~empty_msg:
              (Say.make ~ko:"도구 호출 내역이 없습니다" ~en:"No tool calls recorded")
      | Some page when page.entries = [] ->
          Ops_common.draw_observed_empty grid ~rect:body_r ~theme
            ~lang:model.lang st.tool_calls
            ~empty_msg:
              (Say.make ~ko:"최근 도구 호출 내역이 없습니다"
                 ~en:"No recent tool calls for this keeper")
      | Some page ->
          let left_r, right_r =
            if body_r.w >= 76 then
              match
                Layout.split_h ~gap:2 body_r [ Layout.Ratio 0.50; Layout.Flex 1 ]
              with
              | [ l; r ] -> (l, r)
              | _ -> (body_r, Rect.empty)
            else
              match
                Layout.split_v ~gap:1 body_r [ Layout.Ratio 0.46; Layout.Flex 1 ]
              with
              | [ t; b ] -> (t, b)
              | _ -> (body_r, Rect.empty)
          in
          let cols : Table.column list =
            [
              {
                id = "time";
                header = Say.make ~ko:"시각" ~en:"Time";
                priority = 1;
                min_width = 5;
                max_width = Some 6;
                weight = 1;
                align = Table.Left;
              };
              {
                id = "tool";
                header = Say.make ~ko:"도구" ~en:"Tool";
                priority = 0;
                min_width = 12;
                max_width = None;
                weight = 3;
                align = Table.Left;
              };
              {
                id = "st";
                header = Say.make ~ko:"상태" ~en:"St";
                priority = 0;
                min_width = 4;
                max_width = Some 5;
                weight = 1;
                align = Table.Center;
              };
              {
                id = "dur";
                header = Say.make ~ko:"지연" ~en:"Dur";
                priority = 1;
                min_width = 6;
                max_width = Some 8;
                weight = 1;
                align = Table.Right;
              };
              {
                id = "src";
                header = Say.make ~ko:"출처" ~en:"Src";
                priority = 2;
                min_width = 6;
                max_width = Some 10;
                weight = 1;
                align = Table.Left;
              };
            ]
          in
          let rows =
            List.mapi
              (fun idx (c : Wire_keeper_context.tool_call_entry) ->
                let hhmm =
                  Ops_common.format_hhmm ~tz_offset_sec:model.tz_offset_sec
                    c.ts_unix
                in
                let st_txt, st_tone =
                  match
                    ( Option.map String.lowercase_ascii c.disposition
                    , c.ok )
                  with
                  | Some "deferred", _ -> ("◐", Theme.Status_attention)
                  | _, Some true -> ("✓", Theme.Status_ok)
                  | _, Some false -> ("✕", Theme.Status_critical)
                  | _, None -> ("?", Theme.Status_historical)
                in
                let dur_s =
                  match c.duration_ms with
                  | Some ms -> Format_val.format_value Format_val.Milliseconds ms
                  | None -> Glyph.to_utf8 Glyph.Missing_absent
                in
                let src_s =
                  Option.value ~default:(Glyph.to_utf8 Glyph.Missing_absent)
                    c.definition_source
                in
                let tool_disp =
                  match (c.batch_index, c.batch_size) with
                  | Some bi, Some bs when bs > 1 ->
                      Printf.sprintf "%s [%d/%d]" c.tool bi bs
                  | _ -> c.tool
                in
                {
                  Table.id =
                    Option.value ~default:(Int.to_string idx) c.execution_id;
                  cells =
                    [
                      ( "time"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_muted) hhmm );
                      ("tool", Table.text_cell tool_disp);
                      ( "st"
                      , Table.Badge
                          { glyph = None; text = st_txt; tone = st_tone } );
                      ("dur", Table.text_cell dur_s);
                      ( "src"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                          src_s );
                    ];
                })
              page.entries
          in
          let sel =
            Int.max 0
              (Int.min (List.length page.entries - 1) st.selected_call_idx)
          in
          let is_dive = Option.is_some (Model.active_dive model) in
          let is_zoomed =
            (not is_dive) && model.nav.zoomed
            && Model.can_zoom_current_view model
          in
          let left_focused =
            if is_dive || is_zoomed then Model.pane_focused model 0
            else Model.pane_focused model 1
          in
          let right_focused =
            if is_dive || is_zoomed then Model.pane_focused model 1
            else Model.pane_focused model 2
          in
          ignore
            (Table.draw grid ~rect:left_r ~theme ~caps:Ops_common.default_caps
               ~lang:model.lang ~scroll:st.call_scroll_offset ~selected:sel
               ~focused:left_focused ~columns:cols rows);
          if not (Rect.is_empty right_r) then begin
            match Keeper_context_store.selected_tool_call st with
            | None -> ()
            | Some call ->
                let ry = ref right_r.y and rbot = Rect.bottom right_r in
                let disp_s =
                  match call.disposition, call.failure_class with
                  | Some d, Some fc -> Printf.sprintf "%s (%s)" d fc
                  | Some d, None -> d
                  | None, Some fc -> fc
                  | None, None ->
                      (match call.ok with
                      | Some true -> "ok"
                      | Some false -> "failed"
                      | None -> "unknown")
                in
                let right_hdr_style =
                  if right_focused then
                    Typography.anchor ~bg:(Color.of_rgb theme.selection_bg) theme
                  else Typography.anchor ~bg theme
                in
                let right_prefix =
                  if right_focused then Glyph.to_utf8 Glyph.Focus_caret ^ " "
                  else ""
                in
                ignore
                  (Ops_common.put_line ~clip:right_r grid ~x:right_r.x ~y:!ry
                     ~max_w:right_r.w ~style:right_hdr_style
                     (Printf.sprintf "%s%s · %s" right_prefix call.tool disp_s));
                incr ry;
                if !ry < rbot then begin
                  let eid_s =
                    Option.value ~default:"—" call.execution_id
                  in
                  let mode_s =
                    match (call.execution_mode, call.batch_index, call.batch_size) with
                    | Some m, Some bi, Some bs ->
                        Printf.sprintf " · %s [%d/%d]" m bi bs
                    | Some m, _, _ -> " · " ^ m
                    | None, Some bi, Some bs ->
                        Printf.sprintf " · batch [%d/%d]" bi bs
                    | None, _, _ -> ""
                  in
                  let trunc_s =
                    match (call.original_bytes, call.truncated_to) with
                    | Some orig, Some tr ->
                        Printf.sprintf " · %s (trunc %s, [Enter] full)"
                          (format_bytes orig) (format_bytes tr)
                    | Some orig, None -> " · " ^ format_bytes orig
                    | None, _ -> ""
                  in
                  ignore
                    (Ops_common.put_line ~clip:right_r grid ~x:right_r.x ~y:!ry
                       ~max_w:right_r.w ~style:(Typography.whisper ~bg theme)
                       (Printf.sprintf "id=%s%s%s" (short_sha eid_s) mode_s
                          trunc_s));
                  incr ry
                end;
                let tree_json =
                  let output_json =
                    match Keeper_context_store.tool_result_for_selected_call st with
                    | Some (Wire_keeper_context.Tool_result_page p) -> (
                        match Yojson.Safe.from_string p.content with
                        | j -> Wire_keeper_context.unfold_json_strings j
                        | exception Yojson.Json_error _ -> `String p.content)
                    | Some Wire_keeper_context.Tool_result_pending ->
                        `String "(tool result pending)"
                    | Some (Wire_keeper_context.Tool_result_unavailable r) ->
                        `String ("(unavailable: " ^ r ^ ")")
                    | None -> (
                        match Yojson.Safe.from_string call.output with
                        | j -> Wire_keeper_context.unfold_json_strings j
                        | exception Yojson.Json_error _ -> `String call.output)
                  in
                  let unfolded_in =
                    Wire_keeper_context.unfold_json_strings call.input
                  in
                  Ops_common.scrub_json_secrets
                    (`Assoc
                      [
                        ("input", unfolded_in);
                        ("output", output_json);
                      ])
                in
                let tree_r =
                  Rect.make ~x:right_r.x ~y:!ry ~w:right_r.w
                    ~h:(Int.max 0 (rbot - !ry))
                in
                if not (Rect.is_empty tree_r) then begin
                  if st.tool_result_auth_denied then
                    draw_auth_denied_notice grid ~rect:tree_r ~theme ~model
                      ~endpoint:"/tool-result"
                  else
                    let lines =
                      Json_tree.flatten ~max_depth:5 ~redact_secrets:true tree_json
                    in
                    ignore
                      (Json_tree.draw grid ~rect:tree_r ~theme
                         ~scroll:st.call_detail_scroll_offset lines)
                end
          end
