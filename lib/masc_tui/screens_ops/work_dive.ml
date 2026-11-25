open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let json_of_verification (v : Wire_work.verification_request) : Yojson.Safe.t =
  let opt_s = function Some s -> `String s | None -> `Null in
  let obs_json =
    match v.review_observation with
    | None -> `Null
    | Some obs ->
        let _, _, lbl = Ops_common.review_state_badge obs.state in
        `Assoc
          [
            ("state", `String (Say.resolve Say.Lang_en lbl));
            ("actor", `String obs.actor);
            ("detail", `String obs.detail);
          ]
  in
  `Assoc
    [
      ("request_id", `String v.request_id);
      ("task_id", `String v.task_id);
      ("task_title", `String v.task_title);
      ("submitted_by", `String v.submitted_by);
      ("completion_contract", `List (List.map (fun s -> `String s) v.completion_contract));
      ("required_artifacts", `List (List.map (fun s -> `String s) v.required_artifacts));
      ("submitted_evidence", `List (List.map (fun s -> `String s) v.submitted_evidence));
      ("evidence_projection_error", opt_s v.evidence_projection_error);
      ("review_observation", obs_json);
    ]

let render_verification_dive ~req_id ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) grid =
  let v_opt =
    List.find_opt
      (fun (v : Wire_work.verification_request) ->
        String.equal v.request_id req_id)
      (Work_store.verifications_list model.work)
  in
  let main_card_rect, json_card_rect =
    match v_opt with
    | Some _ -> Work_views.split_dive_with_json ~model rect
    | None -> (rect, Rect.empty)
  in
  if not (Rect.is_empty main_card_rect) then begin
    let title =
      Printf.sprintf "%s %s %s: %s"
        (Say.resolve model.lang (Nav.workspace_label Nav.Work))
        (Glyph.to_utf8 Glyph.Prompt_caret)
        (Ops_common.say model ~ko:"검증" ~en:"Verification")
        req_id
    in
    let badge =
      match v_opt with
      | Some { review_observation = Some obs; _ } ->
          let g, tok, lbl = Ops_common.review_state_badge obs.state in
          Some
            {
              Card.glyph = Some g;
              text = Say.resolve model.lang lbl;
              tone = Some tok;
            }
      | Some { review_observation = None; _ } | None -> None
    in
    let can_verdict_header =
      match v_opt with
      | Some v ->
          Result.is_ok (Update_nav.check_verification_verdict_precondition model v)
      | None -> false
    in
    let verif_main_focused =
      Model.body_has_focus model
      &&
      match Model.dive_work_json_pane_index model with
      | Some idx -> not (Model.pane_focused model idx)
      | None -> true
    in
    let spec : Card.spec =
      {
        (Card.default_spec ~title) with
        subtitle = (match v_opt with Some v -> Some v.task_title | None -> None);
        badge;
        hotkey =
          Some
            (if can_verdict_header then
               Ops_common.say model
                 ~ko:"[v] 탭 · [a] 승인 · [x] 반려 · [h] 재정의 · [Space] JSON · [Esc] 뒤로"
                 ~en:"[v] Tab · [a] Approve · [x] Reject · [h] Overrule · [Space] JSON · [Esc] Back"
             else
               Ops_common.say model
                 ~ko:"[v] 탭 · [h] 재정의 · [Space] JSON · [Esc] 뒤로"
                 ~en:"[v] Tab · [h] Overrule · [Space] JSON · [Esc] Back");
        focused = verif_main_focused;
      }
    in
    let inner = Card.draw ~cache grid ~rect:main_card_rect ~theme spec in
    if not (Rect.is_empty inner) then
      match v_opt with
      | None ->
          Ops_common.draw_observed_empty grid ~rect:inner ~theme
            ~lang:model.lang model.work.verifications
            ~empty_msg:
              (Say.make
                 ~ko:("검증 요청을 찾을 수 없음: " ^ req_id)
                 ~en:("Verification not found: " ^ req_id))
      | Some v ->
          let bg = Color.of_rgb theme.surface_1 in
          let pad_x = Ops_common.pad_x_for ~model inner in
          let content = Card.pad_inner ~pad_x inner in
          let y = ref inner.y in
          let bot = Rect.bottom inner in
          if inner.h >= 8 then begin
            let right_meta =
              match v.created_at_unix with
              | Some ts ->
                  Ops_common.format_age ~now_unix:model.freshness.last_wall_unix
                    ts ~lang:model.lang
              | None -> v.request_id
            in
            let sub =
              Printf.sprintf "%s · @%s" v.task_id v.submitted_by
            in
            Card.draw_section_band ~pad_x grid
              ~rect:(Rect.make ~x:inner.x ~y:!y ~w:inner.w ~h:2)
              ~theme ~left_title:v.task_title ~right_meta ~subtitle:sub ();
            y := !y + 2 + (if inner.h >= 14 then 1 else 0)
          end;
          let action_h = if bot - !y >= 6 then 1 else 0 in
          let body_bot = bot - action_h in
          if !y < body_bot then begin
            Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"대상 작업" ~en:"Task")
              ~value:(Printf.sprintf "%s · %s" v.task_id v.task_title)
              ~val_fg:theme.accent ();
            incr y
          end;
          if !y < body_bot then begin
            Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"제출자" ~en:"Submitted By")
              ~value:("@" ^ v.submitted_by) ();
            incr y
          end;
          (match v.review_observation with
          | Some obs when !y < body_bot ->
              let g, tok, lbl = Ops_common.review_state_badge obs.state in
              Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg
                ~label_w:14
                ~key:(Ops_common.say model ~ko:"검증자 판정" ~en:"Verifier")
                ~value:
                  (Printf.sprintf "%s %s (%s) · %s" (Glyph.to_utf8 g)
                     (Say.resolve model.lang lbl) obs.actor obs.detail)
                ~val_fg:(Theme.status_color theme tok)
                ~val_attrs:Attr.bold ();
              incr y
          | Some _ | None -> ());
          (* [v] Evidence Panel Tab Bar: Evidence | Summary | Specs | TLC *)
          if !y < body_bot then begin
            let tab_item t ko en =
              let active =
                Work_store.equal_verification_dive_tab
                  model.work.verification_dive_tab t
              in
              let lbl = Ops_common.say model ~ko ~en in
              if active then "[" ^ lbl ^ "]" else " " ^ lbl ^ " "
            in
            let bar =
              Printf.sprintf "[v] %s  %s  %s  %s"
                (tab_item Work_store.Verif_tab_evidence "증거" "Evidence")
                (tab_item Work_store.Verif_tab_summary "요약" "Summary")
                (tab_item Work_store.Verif_tab_specs "명세" "Specs")
                (tab_item Work_store.Verif_tab_tlc "TLC" "TLC")
            in
            ignore
              (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                 ~max_w:content.w
                 ~style:(Typography.accent ~bg ~bold:true theme)
                 bar);
            incr y
          end;
          let rest =
            Rect.make ~x:content.x ~y:!y ~w:content.w
              ~h:(Int.max 0 (body_bot - !y))
          in
          let draw_tab_lines ~(rect : Rect.t) lines =
            if not (Rect.is_empty rect) then
              let max_s = Int.max 0 (List.length lines - Int.max 1 rect.h) in
              let scroll =
                Int.min max_s (Int.max 0 model.nav.inspector_scroll_offset)
              in
              List.iteri
                (fun i ln ->
                  let py = rect.y + i in
                  if py < Rect.bottom rect then
                    let st =
                      if String.starts_with ~prefix:"[CanAdmin" ln then
                        Typography.status ~bg ~bold:true theme
                          Theme.Status_attention
                      else if String.starts_with ~prefix:"[unreadable" ln then
                        Typography.status ~bg theme Theme.Status_critical
                      else if String.starts_with ~prefix:"[" ln then
                        Typography.accent ~bg ~bold:true theme
                      else Typography.primary ~bg theme
                    in
                    ignore
                      (Ops_common.put_line ~clip:rect grid ~x:rect.x ~y:py
                         ~max_w:rect.w ~style:st ln))
                (Store_scroll.drop scroll lines |> List.take rect.h)
          in
          let tab_lines =
            Update_nav.verification_dive_tab_lines ~width:content.w model v
          in
          (match model.work.verification_dive_tab with
          | Work_store.Verif_tab_summary
          | Work_store.Verif_tab_specs
          | Work_store.Verif_tab_tlc ->
              draw_tab_lines ~rect:rest tab_lines
          | Work_store.Verif_tab_evidence ->
              let chk_r, diff_r =
                match
                  Layout.split_v ~gap:0 rest [ Layout.Ratio 0.56; Layout.Flex 1 ]
                with
                | [ a; b ] -> (a, b)
                | _ -> (rest, Rect.empty)
              in
              if not (Rect.is_empty chk_r) then begin
                let ev_r =
                  Rect.make ~x:chk_r.x ~y:(chk_r.y + 1) ~w:chk_r.w
                    ~h:(Int.max 0 (chk_r.h - 1))
                in
                let total_ev = List.length tab_lines in
                let ev_pos =
                  if total_ev > ev_r.h && ev_r.h > 0 then
                    let s =
                      Int.min (Int.max 0 (total_ev - ev_r.h))
                        (Int.max 0 model.nav.inspector_scroll_offset)
                    in
                    let ve = Int.min total_ev (s + ev_r.h) in
                    let rem = Int.max 0 (total_ev - ve) in
                    if rem > 0 then
                      Printf.sprintf " · L%d-%d/%d · ↓ +%d" (s + 1) ve total_ev rem
                    else Printf.sprintf " · L%d-%d/%d" (s + 1) ve total_ev
                  else ""
                in
                Card.draw_hairline ~pad_x:0 ~bg
                  ~label:
                    (Ops_common.say model ~ko:"검증 증거 번들 (/verification/evidence)"
                       ~en:"Verification Evidence Bundle"
                    ^ ev_pos)
                  grid ~rect:chk_r ~y:chk_r.y ~theme;
                draw_tab_lines ~rect:ev_r tab_lines
              end;
              if not (Rect.is_empty diff_r) then begin
                let dr =
                  Rect.make ~x:diff_r.x ~y:(diff_r.y + 1) ~w:diff_r.w
                    ~h:(Int.max 0 (diff_r.h - 1))
                in
                let diff_rows = Work_views.build_rejection_diff_rows ~model v in
                let total_d = List.length diff_rows in
                let d_pos =
                  if total_d > dr.h && dr.h > 0 then
                    let s =
                      Int.min (Int.max 0 (total_d - dr.h))
                        (Int.max 0 model.nav.inspector_scroll_offset)
                    in
                    let ve = Int.min total_d (s + dr.h) in
                    let rem = Int.max 0 (total_d - ve) in
                    if rem > 0 then
                      Printf.sprintf " · L%d-%d/%d · ↓ +%d" (s + 1) ve total_d rem
                    else Printf.sprintf " · L%d-%d/%d" (s + 1) ve total_d
                  else ""
                in
                Card.draw_hairline ~pad_x:0 ~bg
                  ~label:
                    (Ops_common.say model ~ko:"구조화 반려 Diff"
                       ~en:"Structured Rejection Diff"
                    ^ d_pos)
                  grid ~rect:diff_r ~y:diff_r.y ~theme;
                ignore
                  (Diff.draw grid ~rect:dr ~theme
                     ~scroll:model.nav.inspector_scroll_offset diff_rows)
              end);
          if action_h = 1 then
            let can_verdict =
              Result.is_ok (Update_nav.check_verification_verdict_precondition model v)
            in
            let verdict_keys =
              if can_verdict then
                [
                  ("a", Ops_common.say model ~ko:"승인" ~en:"Approve");
                  ("x", Ops_common.say model ~ko:"반려" ~en:"Reject");
                ]
              else []
            in
            ignore
              (Ops_common.draw_keycap_bar grid
                 ~rect:(Rect.make ~x:content.x ~y:(bot - 1) ~w:content.w ~h:1)
                 ~theme ~bg
                 ([ ("v", Ops_common.say model ~ko:"증거탭" ~en:"Tab") ]
                 @ verdict_keys
                 @ [
                     ("Space", "JSON");
                     ("Esc", Ops_common.say model ~ko:"돌아가기" ~en:"Back");
                   ]))
  end;
  match v_opt with
  | Some v when not (Rect.is_empty json_card_rect) ->
      Work_views.render_opt_in_json_tree grid ~rect:json_card_rect ~theme ~model
        ~cache (json_of_verification v)
  | Some _ | None -> ()

let render ~req_id ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Ops_common.theme_of_model model in
    render_verification_dive ~req_id ~model ~cache ~rect ~theme grid
