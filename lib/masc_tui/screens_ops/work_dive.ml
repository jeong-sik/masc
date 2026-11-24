open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let json_of_goal (g : Wire_work.goal) : Yojson.Safe.t =
  let opt_s = function Some s -> `String s | None -> `Null in
  let crit =
    match g.criterion_verdict with
    | Wire_work.Criterion_pending -> `String "pending"
    | Wire_work.Criterion_valid -> `String "valid"
    | Wire_work.Criterion_invalid r -> `Assoc [ ("invalid", `String r) ]
    | Wire_work.Criterion_unavailable r -> `Assoc [ ("unavailable", `String r) ]
  in
  `Assoc
    [
      ("id", `String g.id);
      ("title", `String g.title);
      ("phase", `String (Wire_work.goal_phase_to_string g.phase));
      ("priority", `Int g.priority);
      ("due_date", opt_s g.due_date);
      ("measure", `String g.measure);
      ("procedure", `String g.procedure);
      ("criterion_revision", opt_s g.criterion_revision);
      ("criterion_verdict", crit);
      ("last_review_note", opt_s g.last_review_note);
    ]

let json_of_task (tk : Wire_work.task) : Yojson.Safe.t =
  let opt_s = function Some s -> `String s | None -> `Null in
  let st_json =
    match tk.status with
    | Wire_work.Todo -> `Assoc [ ("state", `String "Todo") ]
    | Wire_work.Claimed { assignee; claimed_at } ->
        `Assoc
          [
            ("state", `String "Claimed");
            ("assignee", `String assignee);
            ("claimed_at", `String claimed_at);
          ]
    | Wire_work.InProgress { assignee; started_at } ->
        `Assoc
          [
            ("state", `String "InProgress");
            ("assignee", `String assignee);
            ("started_at", `String started_at);
          ]
    | Wire_work.AwaitingVerification
        { assignee; started_at; submitted_at; verification_id } ->
        `Assoc
          [
            ("state", `String "AwaitingVerification");
            ("assignee", `String assignee);
            ("started_at", `String started_at);
            ("submitted_at", `String submitted_at);
            ("verification_id", `String verification_id);
          ]
    | Wire_work.Done { assignee; completed_at; notes } ->
        `Assoc
          [
            ("state", `String "Done");
            ("assignee", `String assignee);
            ("completed_at", `String completed_at);
            ("notes", opt_s notes);
          ]
    | Wire_work.Cancelled { cancelled_by; cancelled_at; reason } ->
        `Assoc
          [
            ("state", `String "Cancelled");
            ("cancelled_by", `String cancelled_by);
            ("cancelled_at", `String cancelled_at);
            ("reason", opt_s reason);
          ]
  in
  let gl_json =
    match tk.goal_link with
    | Wire_work.Unlinked -> `Null
    | Wire_work.Linked gid -> `String gid
  in
  `Assoc
    [
      ("id", `String tk.id);
      ("title", `String tk.title);
      ("priority", `Int tk.priority);
      ("goal_id", gl_json);
      ("status", st_json);
      ("description", opt_s tk.description);
    ]

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

(* Peer sibling card split so [J] Json_tree NEVER nests a Card inside a Card. *)
let split_dive_with_json ~(model : Model.t) (rect : Rect.t) =
  let bp = Ops_common.layout_bp model in
  if model.infra.show_raw_json && rect.w >= 88 then
    match Layout.split_h_bp bp rect [ Layout.Ratio 0.58; Layout.Flex 1 ] with
    | [ l; r ] -> (l, r)
    | _ -> (rect, Rect.empty)
  else if model.infra.show_raw_json then (Rect.empty, rect)
  else (rect, Rect.empty)

let render_opt_in_json_tree grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~cache json =
  let spec : Card.spec =
    {
      (Card.default_spec
         ~title:
           (Ops_common.say model ~ko:"구조화 JSON 트리 [Space]"
              ~en:"Structured Json_tree [Space]"))
      with
      footer_hint =
        Some
          (if rect.w >= 44 then
             Ops_common.say model ~ko:"[↑↓] 스크롤 · [Tab] 본문 · [Space] 숨김"
               ~en:"[↑↓] Scroll · [Tab] Main · [Space] Hide"
           else "[↑↓] · [Tab] · [Space]");
      elevated = false;
      focused =
        (match Model.dive_work_json_pane_index model with
        | Some idx -> Model.pane_focused model idx
        | None -> false);
    }
  in
  let inner = Card.draw ~cache grid ~rect ~theme spec in
  if not (Rect.is_empty inner) then begin
    let pad_x = Ops_common.pad_x_for ~model inner in
    let content = Card.pad_inner ~pad_x inner in
    let scrubbed = Ops_common.scrub_json_secrets json in
    let lines = Json_tree.flatten ~max_depth:4 ~redact_secrets:true scrubbed in
    ignore
      (Json_tree.draw grid ~rect:content ~theme
         ~scroll:model.nav.json_scroll_offset lines)
  end

let draw_evidence_checklist ?(scroll = 0) grid ~(rect : Rect.t)
    ~(theme : Theme.t) ~(model : Model.t) (v : Wire_work.verification_request) =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let rows_acc = ref [] in
    List.iter
      (fun req ->
        let present =
          List.exists
            (fun ev -> Ops_common.contains_ci ~needle:req ev)
            v.submitted_evidence
        in
        rows_acc := `Req (req, present) :: !rows_acc)
      v.required_artifacts;
    List.iter (fun ev -> rows_acc := `Ev ev :: !rows_acc) v.submitted_evidence;
    (match v.evidence_projection_error with
    | Some err -> rows_acc := `Err err :: !rows_acc
    | None -> ());
    let rows = List.rev !rows_acc in
    let vis_h = Int.max 1 rect.h in
    let max_skip = Int.max 0 (List.length rows - vis_h) in
    let skip = Int.min max_skip (Int.max 0 scroll) in
    let y = ref rect.y in
    let bot = Rect.bottom rect in
    List.iter
      (function
        | `Req (req, present) ->
            if !y < bot then begin
              let g, tok =
                if present then (Glyph.Check_mark, Theme.Status_ok)
                else (Glyph.Live_failing, Theme.Status_critical)
              in
              let st_g = Typography.status ~bg ~bold:true theme tok in
              let st_txt =
                if present then Typography.primary ~bg theme
                else Typography.status ~bg theme Theme.Status_critical
              in
              let tag =
                Printf.sprintf "%s %s: " (Glyph.to_utf8 g)
                  (Ops_common.say model ~ko:"필수" ~en:"Required")
              in
              let adv =
                Ops_common.put_line ~clip:rect grid ~x:rect.x ~y:!y
                  ~max_w:rect.w ~style:st_g tag
              in
              ignore
                (Ops_common.put_line ~clip:rect grid ~x:(rect.x + adv) ~y:!y
                   ~max_w:(Int.max 0 (rect.w - adv))
                   ~style:st_txt req);
              incr y
            end
        | `Ev ev ->
            if !y < bot then begin
              let tag =
                Printf.sprintf "%s %s: "
                  (Glyph.to_utf8 Glyph.Check_mark)
                  (Ops_common.say model ~ko:"증거" ~en:"Evidence")
              in
              let adv =
                Ops_common.put_line ~clip:rect grid ~x:rect.x ~y:!y
                  ~max_w:rect.w
                  ~style:(Typography.status ~bg ~bold:true theme Theme.Status_ok)
                  tag
              in
              ignore
                (Ops_common.put_line ~clip:rect grid ~x:(rect.x + adv) ~y:!y
                   ~max_w:(Int.max 0 (rect.w - adv))
                   ~style:(Typography.primary ~bg theme)
                   ev);
              incr y
            end
        | `Err err ->
            if !y < bot then begin
              Card.draw_left_rail ~bg ~tone:Theme.Status_critical grid
                ~x:rect.x ~y:!y ~h:1 ~theme;
              let line =
                Printf.sprintf "%s %s: %s"
                  (Glyph.to_utf8 Glyph.Live_failing)
                  (Ops_common.say model ~ko:"증거 오류" ~en:"Evidence Error")
                  err
              in
              ignore
                (Ops_common.put_line ~clip:rect grid ~x:(rect.x + 2) ~y:!y
                   ~max_w:(Int.max 0 (rect.w - 2))
                   ~style:
                     (Typography.status ~bg ~bold:true theme
                        Theme.Status_critical)
                   line);
              incr y
            end)
      (Store_scroll.drop skip rows)

let render_goal_dive ~goal_id ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) grid =
  let g_opt =
    List.find_opt
      (fun (g : Wire_work.goal) -> String.equal g.id goal_id)
      (Work_store.goals model.work)
  in
  let main_card_rect, json_card_rect =
    match g_opt with
    | Some _ -> split_dive_with_json ~model rect
    | None -> (rect, Rect.empty)
  in
  if not (Rect.is_empty main_card_rect) then begin
    let title =
      Printf.sprintf "%s %s %s: %s"
        (Say.resolve model.lang (Nav.workspace_label Nav.Work))
        (Glyph.to_utf8 Glyph.Prompt_caret)
        (Ops_common.say model ~ko:"목표" ~en:"Goal")
        goal_id
    in
    let badge =
      match g_opt with
      | Some g ->
          let pg, ptok, plbl = Ops_common.goal_phase_badge g.phase in
          Some
            {
              Card.glyph = Some pg;
              text = Say.resolve model.lang plbl;
              tone = Some ptok;
            }
      | None -> None
    in
    let main_focused =
      Model.body_has_focus model
      &&
      match Model.dive_work_json_pane_index model with
      | Some idx -> not (Model.pane_focused model idx)
      | None -> true
    in
    let header_hotkey =
      match g_opt with
      | None ->
          Ops_common.say model ~ko:"[Space] JSON · [Esc] 뒤로"
            ~en:"[Space] JSON · [Esc] Back"
      | Some g -> (
          match g.phase with
          | Wire_work.Awaiting_confirmation ->
              Ops_common.say model
                ~ko:"[a] 완료 확정 · [x] 일시정지 · [Space] JSON · [Esc] 뒤로"
                ~en:"[a] Confirm · [x] Pause · [Space] JSON · [Esc] Back"
          | Wire_work.Paused _ ->
              Ops_common.say model
                ~ko:"[a] 재개 · [x] 중단 · [Space] JSON · [Esc] 뒤로"
                ~en:"[a] Resume · [x] Drop · [Space] JSON · [Esc] Back"
          | Wire_work.Blocked _ ->
              Ops_common.say model
                ~ko:"[a] 차단 해제 · [x] 일시정지 · [Space] JSON · [Esc] 뒤로"
                ~en:"[a] Unblock · [x] Pause · [Space] JSON · [Esc] Back"
          | Wire_work.Executing ->
              Ops_common.say model
                ~ko:"[a] 검증 요청 · [x] 일시정지 · [Space] JSON · [Esc] 뒤로"
                ~en:"[a] Verify · [x] Pause · [Space] JSON · [Esc] Back"
          | Wire_work.Verifying ->
              Ops_common.say model
                ~ko:"[x] 일시정지 · [Space] JSON · [Esc] 뒤로"
                ~en:"[x] Pause · [Space] JSON · [Esc] Back"
          | Wire_work.Completed | Wire_work.Dropped ->
              Ops_common.say model
                ~ko:"[a] 다시 열기 · [Space] JSON · [Esc] 뒤로"
                ~en:"[a] Reopen · [Space] JSON · [Esc] Back")
    in
    let spec : Card.spec =
      {
        (Card.default_spec ~title) with
        subtitle = (match g_opt with Some g -> Some g.title | None -> None);
        badge;
        hotkey = Some header_hotkey;
        focused = main_focused;
      }
    in
    let inner = Card.draw ~cache grid ~rect:main_card_rect ~theme spec in
    if not (Rect.is_empty inner) then
      match g_opt with
      | None ->
          Ops_common.draw_observed_empty grid ~rect:inner ~theme
            ~lang:model.lang model.work.planning
            ~empty_msg:
              (Say.make
                 ~ko:("목표를 찾을 수 없음: " ^ goal_id)
                 ~en:("Goal not found: " ^ goal_id))
      | Some g ->
          let bg = Color.of_rgb theme.surface_1 in
          let pad_x = Ops_common.pad_x_for ~model inner in
          let y = ref inner.y in
          let bot = Rect.bottom inner in
          (* 1. Elevated section band when height permits *)
          if inner.h >= 8 then begin
            let right_meta =
              match g.due_date, g.updated_at with
              | Some d, _ -> Printf.sprintf "due %s" d
              | None, Some u -> u
              | None, None -> g.id
            in
            let sub =
              match g.last_review_note with
              | Some n when not (String.equal (String.trim n) "") -> Some n
              | Some _ | None -> g.criterion_revision
            in
            let band_h = match sub with Some _ -> 2 | None -> 1 in
            Card.draw_section_band ~pad_x grid
              ~rect:(Rect.make ~x:inner.x ~y:!y ~w:inner.w ~h:band_h)
              ~theme
              ~left_title:(Printf.sprintf "P%d  %s" g.priority g.title)
              ~right_meta ?subtitle:sub ();
            y := !y + band_h + (if inner.h >= 14 then 1 else 0)
          end;
          let content = Card.pad_inner ~pad_x inner in
          let action_h = if bot - !y >= 6 then 1 else 0 in
          let body_bot = bot - action_h in
          (* 2. Pipeline stepper *)
          if !y < body_bot then begin
            let step_h =
              Work_views.draw_goal_pipeline_stepper grid
                ~rect:
                  (Rect.make ~x:content.x ~y:!y ~w:content.w
                     ~h:(Int.min 2 (body_bot - !y)))
                ~theme ~model g.phase
            in
            y := !y + step_h
          end;
          let linked =
            List.filter
              (fun (tk : Wire_work.task) ->
                match tk.goal_link with
                | Wire_work.Linked gid -> String.equal gid g.id
                | Wire_work.Unlinked -> false)
              (Work_store.tasks model.work)
          in
          let linked_ids = List.map (fun (tk : Wire_work.task) -> tk.id) linked in
          let verifs =
            List.filter
              (fun (v : Wire_work.verification_request) ->
                List.exists (String.equal v.task_id) linked_ids)
              (Work_store.verifications_list model.work)
          in
          let rem_h = Int.max 0 (body_bot - !y) in
          let md_h =
            if rem_h <= 0 then 0
            else
              Int.min 7
                (Int.min rem_h (if rem_h >= 2 then Int.max 2 (rem_h / 3) else rem_h))
          in
          if md_h > 0 then begin
            let md_rect = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:md_h in
            let md_src =
              Printf.sprintf "**%s:** %s\n\n**%s:** %s"
                (Ops_common.say model ~ko:"성공 조건" ~en:"Measure")
                (Ops_common.rewrite_masc_links_for_markdown g.measure)
                (Ops_common.say model ~ko:"측정 절차" ~en:"Procedure")
                (Ops_common.rewrite_masc_links_for_markdown g.procedure)
            in
            ignore
              (Markdown.draw grid ~rect:md_rect ~theme ~osc8:true
                 ~scroll:model.nav.dive_scroll_offset md_src);
            y := !y + md_h
          end;
          let rest_rect =
            Rect.make ~x:content.x ~y:!y ~w:content.w
              ~h:(Int.max 0 (body_bot - !y))
          in
          if not (Rect.is_empty rest_rect) then begin
            let tasks_focused = Model.pane_focused model 0 in
            let verifs_focused = Model.pane_focused model 1 in
            let focus_prefix f = if f then "▸ " else "" in
            let tasks_r, verif_r =
              match
                Layout.split_v ~gap:0 rest_rect [ Layout.Ratio 0.42; Layout.Flex 1 ]
              with
              | [ t; b ] -> (t, b)
              | _ -> (rest_rect, Rect.empty)
            in
            let t_body =
              Rect.make ~x:tasks_r.x ~y:(tasks_r.y + 1) ~w:tasks_r.w
                ~h:(Int.max 0 (tasks_r.h - 1))
            in
            let t_total = List.length linked in
            let t_sel =
              Store_scroll.clamp_index t_total model.work.goal_dive_task_index
            in
            let t_skip =
              if t_total <= 0 || t_body.h <= 0 then 0
              else
                let max_s = Int.max 0 (t_total - t_body.h) in
                let s0 = Int.min max_s (Int.max 0 model.work.goal_dive_task_scroll) in
                if t_sel < s0 then t_sel
                else if t_sel >= s0 + t_body.h then Int.min max_s (t_sel - t_body.h + 1)
                else s0
            in
            let t_pos_suffix =
              if t_total > t_body.h && t_body.h > 0 then
                Printf.sprintf " · %d/%d" (t_sel + 1) t_total
              else ""
            in
            Card.draw_hairline ~pad_x:0 ~bg
              ~label:
                (Printf.sprintf "%s%s (%d)%s · [Enter] %s"
                   (focus_prefix tasks_focused)
                   (Ops_common.say model ~ko:"연결 작업" ~en:"Linked Tasks")
                   t_total t_pos_suffix
                   (Ops_common.say model ~ko:"상세" ~en:"Dive"))
              grid ~rect:tasks_r ~y:tasks_r.y ~theme;
            if linked = [] && not (Rect.is_empty t_body) then begin
              Card.draw_left_rail ~bg ~tone:Theme.Status_attention grid
                ~x:t_body.x ~y:t_body.y ~h:1 ~theme;
              ignore
                (Ops_common.put_line ~clip:t_body grid ~x:(t_body.x + 2)
                   ~y:t_body.y ~max_w:(Int.max 0 (t_body.w - 2))
                   ~style:(Typography.whisper ~bg theme)
                   (Glyph.to_utf8 Glyph.Warning_triangle ^ " "
                    ^ Ops_common.say model ~ko:"연결된 작업 없음"
                        ~en:"No tasks linked to this goal"))
            end
            else
              List.iteri
                (fun idx (tk : Wire_work.task) ->
                  let py = t_body.y + idx in
                  if py < Rect.bottom t_body then begin
                    let abs_idx = t_skip + idx in
                    let is_sel = Int.equal abs_idx t_sel in
                    let rbg =
                      if is_sel && tasks_focused then Color.of_rgb theme.selection_bg
                      else if is_sel then Color.of_rgb theme.surface_2
                      else bg
                    in
                    let row_r =
                      Rect.make ~x:t_body.x ~y:py ~w:t_body.w ~h:1
                    in
                    if is_sel then begin
                      Cell_grid.fill_rect ~clip:t_body grid ~rect:row_r
                        ~style:(Typography.primary ~bg:rbg theme) ();
                      if tasks_focused then
                        Card.draw_left_rail ~bg:rbg ~tone:Theme.Status_active
                          grid ~x:t_body.x ~y:py ~h:1 ~theme
                      else
                        Card.draw_left_rail ~bg:rbg ~color:theme.border_inactive
                          grid ~x:t_body.x ~y:py ~h:1 ~theme
                    end;
                    let tg, ttok, tlbl = Ops_common.task_status_badge tk.status in
                    let who =
                      match Ops_common.task_assignee_opt tk.status with
                      | Some a -> " @" ^ a
                      | None -> ""
                    in
                    let badge_s =
                      Printf.sprintf "%s %s  " (Glyph.to_utf8 tg)
                        (Say.resolve model.lang tlbl)
                    in
                    let start_x = t_body.x + 2 in
                    let avail_w = Int.max 0 (t_body.w - 2) in
                    let adv =
                      Ops_common.put_line ~clip:row_r grid ~x:start_x ~y:py
                        ~max_w:avail_w
                        ~style:(Typography.status ~bg:rbg ~bold:true theme ttok)
                        badge_s
                    in
                    let line = Printf.sprintf "%s  %s" tk.id tk.title in
                    let who_w = Grapheme.display_width who in
                    let mid_w =
                      Int.max 0
                        (avail_w - adv - (if who_w > 0 then who_w + 1 else 0))
                    in
                    let title_st =
                      if is_sel && tasks_focused then Typography.anchor ~bg:rbg theme
                      else Typography.primary ~bg:rbg theme
                    in
                    ignore
                      (Ops_common.put_line ~clip:row_r grid ~x:(start_x + adv)
                         ~y:py ~max_w:mid_w ~style:title_st line);
                    if who_w > 0 && avail_w > adv + who_w + 4 then
                      ignore
                        (Ops_common.put_line ~clip:row_r grid
                           ~x:(Rect.right row_r - who_w)
                           ~y:py ~max_w:who_w
                           ~style:(Typography.whisper ~bg:rbg theme)
                           who)
                  end)
                (Store_scroll.drop t_skip linked |> List.take t_body.h);
            if not (Rect.is_empty verif_r) then begin
              let v_total = List.length verifs in
              let v_sel =
                Store_scroll.clamp_index v_total model.work.goal_dive_verif_index
              in
              let v_pos_suffix =
                if v_total > 1 then Printf.sprintf " · %d/%d" (v_sel + 1) v_total
                else ""
              in
              Card.draw_hairline ~pad_x:0 ~bg
                ~label:
                  (Printf.sprintf "%s%s (%d)%s · [Enter] %s"
                     (focus_prefix verifs_focused)
                     (Ops_common.say model ~ko:"검증 실행 · 증거"
                        ~en:"Verifier Runs & Evidence")
                     v_total v_pos_suffix
                     (Ops_common.say model ~ko:"상세" ~en:"Dive"))
                grid ~rect:verif_r ~y:verif_r.y ~theme;
              let v_body =
                Rect.make ~x:verif_r.x ~y:(verif_r.y + 1) ~w:verif_r.w
                  ~h:(Int.max 0 (verif_r.h - 1))
              in
              match verifs with
              | [] ->
                  if not (Rect.is_empty v_body) then
                    ignore
                      (Ops_common.put_line ~clip:v_body grid ~x:v_body.x
                         ~y:v_body.y ~max_w:v_body.w
                         ~style:(Typography.whisper ~bg theme)
                         (Ops_common.say model ~ko:"기록된 검증 실행이 없습니다"
                            ~en:"No verifier runs recorded yet"))
              | _ :: _ ->
                  let list_h =
                    if v_body.h <= 3 then v_body.h
                    else Int.min (Int.max 2 v_total) (Int.max 2 (v_body.h / 2))
                  in
                  let vlist_r =
                    Rect.make ~x:v_body.x ~y:v_body.y ~w:v_body.w ~h:list_h
                  in
                  let preview_r =
                    Rect.make ~x:v_body.x ~y:(v_body.y + list_h) ~w:v_body.w
                      ~h:(Int.max 0 (v_body.h - list_h))
                  in
                  let v_skip =
                    if v_total <= 0 || vlist_r.h <= 0 then 0
                    else
                      let max_s = Int.max 0 (v_total - vlist_r.h) in
                      let s0 =
                        Int.min max_s (Int.max 0 model.work.goal_dive_verif_scroll)
                      in
                      if v_sel < s0 then v_sel
                      else if v_sel >= s0 + vlist_r.h then
                        Int.min max_s (v_sel - vlist_r.h + 1)
                      else s0
                  in
                  List.iteri
                    (fun idx (vr : Wire_work.verification_request) ->
                      let py = vlist_r.y + idx in
                      if py < Rect.bottom vlist_r then begin
                        let abs_idx = v_skip + idx in
                        let is_sel = Int.equal abs_idx v_sel in
                        let rbg =
                          if is_sel && verifs_focused then
                            Color.of_rgb theme.selection_bg
                          else if is_sel then Color.of_rgb theme.surface_2
                          else bg
                        in
                        let row_r =
                          Rect.make ~x:vlist_r.x ~y:py ~w:vlist_r.w ~h:1
                        in
                        if is_sel then begin
                          Cell_grid.fill_rect ~clip:vlist_r grid ~rect:row_r
                            ~style:(Typography.primary ~bg:rbg theme) ();
                          if verifs_focused then
                            Card.draw_left_rail ~bg:rbg ~tone:Theme.Status_active
                              grid ~x:vlist_r.x ~y:py ~h:1 ~theme
                          else
                            Card.draw_left_rail ~bg:rbg
                              ~color:theme.border_inactive grid ~x:vlist_r.x
                              ~y:py ~h:1 ~theme
                        end;
                        let vg, vtok, vlbl =
                          match vr.review_observation with
                          | Some obs -> Ops_common.review_state_badge obs.state
                          | None ->
                              ( Glyph.Action_required
                              , Theme.Status_attention
                              , Say.make ~ko:"검증대기" ~en:"Pending" )
                        in
                        let start_x = vlist_r.x + 2 in
                        let avail_w = Int.max 0 (vlist_r.w - 2) in
                        let badge_s =
                          Printf.sprintf "%s %s  " (Glyph.to_utf8 vg)
                            (Say.resolve model.lang vlbl)
                        in
                        let adv =
                          Ops_common.put_line ~clip:row_r grid ~x:start_x ~y:py
                            ~max_w:avail_w
                            ~style:
                              (Typography.status ~bg:rbg ~bold:true theme vtok)
                            badge_s
                        in
                        let by_s = " @" ^ vr.submitted_by in
                        let by_w = Grapheme.display_width by_s in
                        let mid_w =
                          Int.max 0
                            (avail_w - adv - (if by_w > 0 then by_w + 1 else 0))
                        in
                        let line = Printf.sprintf "%s  %s" vr.request_id vr.task_title in
                        let title_st =
                          if is_sel && verifs_focused then
                            Typography.anchor ~bg:rbg theme
                          else Typography.primary ~bg:rbg theme
                        in
                        ignore
                          (Ops_common.put_line ~clip:row_r grid
                             ~x:(start_x + adv) ~y:py ~max_w:mid_w
                             ~style:title_st line);
                        if by_w > 0 && avail_w > adv + by_w + 4 then
                          ignore
                            (Ops_common.put_line ~clip:row_r grid
                               ~x:(Rect.right row_r - by_w)
                               ~y:py ~max_w:by_w
                               ~style:(Typography.whisper ~bg:rbg theme)
                               by_s)
                      end)
                    (Store_scroll.drop v_skip verifs |> List.take vlist_r.h);
                  (match List.nth_opt verifs v_sel with
                  | Some v when not (Rect.is_empty preview_r) ->
                      let check_r, diff_r =
                        match
                          Layout.split_v ~gap:0 preview_r
                            [ Layout.Ratio 0.50; Layout.Flex 1 ]
                        with
                        | [ a; b ] -> (a, b)
                        | _ -> (preview_r, Rect.empty)
                      in
                      draw_evidence_checklist ~scroll:0 grid ~rect:check_r ~theme
                        ~model v;
                      if not (Rect.is_empty diff_r) then
                        ignore
                          (Diff.draw grid ~rect:diff_r ~theme ~scroll:0
                             (Work_views.build_rejection_diff_rows ~model v))
                  | Some _ | None -> ())
            end
          end;
          if action_h = 1 then
            let phase_keys =
              match g.phase with
              | Wire_work.Awaiting_confirmation ->
                  [
                    ("a", Ops_common.say model ~ko:"완료 확정" ~en:"Confirm");
                    ("x", Ops_common.say model ~ko:"일시정지" ~en:"Pause");
                  ]
              | Wire_work.Paused _ ->
                  [
                    ("a", Ops_common.say model ~ko:"재개" ~en:"Resume");
                    ("x", Ops_common.say model ~ko:"중단" ~en:"Drop");
                  ]
              | Wire_work.Blocked _ ->
                  [
                    ("a", Ops_common.say model ~ko:"차단 해제" ~en:"Unblock");
                    ("x", Ops_common.say model ~ko:"일시정지" ~en:"Pause");
                  ]
              | Wire_work.Executing ->
                  [
                    ("a", Ops_common.say model ~ko:"검증 요청" ~en:"Verify");
                    ("x", Ops_common.say model ~ko:"일시정지" ~en:"Pause");
                  ]
              | Wire_work.Verifying ->
                  [ ("x", Ops_common.say model ~ko:"일시정지" ~en:"Pause") ]
              | Wire_work.Completed | Wire_work.Dropped ->
                  [ ("a", Ops_common.say model ~ko:"다시 열기" ~en:"Reopen") ]
            in
            let nav_keys =
              [
                ("←/→/Tab", Ops_common.say model ~ko:"섹션" ~en:"Section");
                ("↑↓", Ops_common.say model ~ko:"선택" ~en:"Select");
                ("Enter", Ops_common.say model ~ko:"상세 진입" ~en:"Dive");
              ]
              @ phase_keys
              @ [
                  ("Space", "JSON");
                  ("Esc", Ops_common.say model ~ko:"뒤로" ~en:"Back");
                ]
            in
            ignore
              (Ops_common.draw_keycap_bar grid
                 ~rect:(Rect.make ~x:content.x ~y:(bot - 1) ~w:content.w ~h:1)
                 ~theme ~bg nav_keys)
  end;
  match g_opt with
  | Some g when not (Rect.is_empty json_card_rect) ->
      render_opt_in_json_tree grid ~rect:json_card_rect ~theme ~model ~cache
        (json_of_goal g)
  | Some _ | None -> ()

let draw_task_stepper grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) (st : Wire_work.task_status) =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let cur =
      match st with
      | Wire_work.Todo -> 0
      | Wire_work.Claimed _ -> 1
      | Wire_work.InProgress _ -> 2
      | Wire_work.AwaitingVerification _ -> 3
      | Wire_work.Done _ -> 4
      | Wire_work.Cancelled _ -> -1
    in
    let steps =
      [
        (0, Ops_common.say model ~ko:"대기" ~en:"Todo");
        (1, Ops_common.say model ~ko:"배정" ~en:"Claimed");
        (2, Ops_common.say model ~ko:"진행" ~en:"InProgress");
        (3, Ops_common.say model ~ko:"검증대기" ~en:"AwaitingVerify");
        (4, Ops_common.say model ~ko:"완료" ~en:"Done");
      ]
    in
    let cx = ref rect.x in
    let re = Rect.right rect in
    List.iteri
      (fun pos (i, lbl) ->
        if !cx < re then begin
          if pos > 0 then begin
            let adv =
              Ops_common.put_line ~clip:rect grid ~x:!cx ~y:rect.y
                ~max_w:(re - !cx)
                ~style:(Style.make ~fg:(Color.of_rgb theme.border_subtle) ~bg ())
                " ─> "
            in
            cx := !cx + adv
          end;
          if i = cur then begin
            let pill_bg = Color.of_rgb theme.surface_2 in
            let tok =
              if i = 4 then Theme.Status_ok
              else if i = 3 then Theme.Status_attention
              else Theme.Status_active
            in
            let dot = " " ^ Glyph.to_utf8 Glyph.Live_healthy ^ " " in
            let adv1 =
              Ops_common.put_line ~clip:rect grid ~x:!cx ~y:rect.y
                ~max_w:(Int.max 0 (re - !cx))
                ~style:(Typography.status ~bg:pill_bg ~bold:true theme tok)
                dot
            in
            cx := !cx + adv1;
            let adv2 =
              Ops_common.put_line ~clip:rect grid ~x:!cx ~y:rect.y
                ~max_w:(Int.max 0 (re - !cx))
                ~style:(Typography.anchor ~bg:pill_bg theme)
                (lbl ^ " ")
            in
            cx := !cx + adv2
          end
          else begin
            let g, st_s =
              if cur < 0 then
                (Glyph.Live_failing, Typography.status ~bg theme Theme.Status_historical)
              else if i < cur then
                (Glyph.Check_mark, Typography.status ~bg theme Theme.Status_ok)
              else
                (Glyph.Live_idle, Typography.whisper ~bg ~italic:false theme)
            in
            let adv =
              Ops_common.put_line ~clip:rect grid ~x:!cx ~y:rect.y
                ~max_w:(Int.max 0 (re - !cx))
                ~style:st_s
                (Printf.sprintf "%s %s" (Glyph.to_utf8 g) lbl)
            in
            cx := !cx + adv
          end
        end)
      steps

let render_task_dive ~task_id ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) grid =
  let tk_opt =
    List.find_opt
      (fun (tk : Wire_work.task) -> String.equal tk.id task_id)
      (Work_store.tasks model.work)
  in
  let main_card_rect, json_card_rect =
    match tk_opt with
    | Some _ -> split_dive_with_json ~model rect
    | None -> (rect, Rect.empty)
  in
  if not (Rect.is_empty main_card_rect) then begin
    let title =
      Printf.sprintf "%s %s %s: %s"
        (Say.resolve model.lang (Nav.workspace_label Nav.Work))
        (Glyph.to_utf8 Glyph.Prompt_caret)
        (Ops_common.say model ~ko:"작업" ~en:"Task")
        task_id
    in
    let badge =
      match tk_opt with
      | Some tk ->
          let g, tok, lbl = Ops_common.task_status_badge tk.status in
          Some
            {
              Card.glyph = Some g;
              text = Say.resolve model.lang lbl;
              tone = Some tok;
            }
      | None -> None
    in
    let task_main_focused =
      Model.body_has_focus model
      &&
      match Model.dive_work_json_pane_index model with
      | Some idx -> not (Model.pane_focused model idx)
      | None -> true
    in
    let spec : Card.spec =
      {
        (Card.default_spec ~title) with
        subtitle = (match tk_opt with Some tk -> Some tk.title | None -> None);
        badge;
        hotkey =
          Some
            (Ops_common.say model ~ko:"[x] 취소 · [Space] JSON · [Esc] 뒤로"
               ~en:"[x] Cancel · [Space] JSON · [Esc] Back");
        focused = task_main_focused;
      }
    in
    let inner = Card.draw ~cache grid ~rect:main_card_rect ~theme spec in
    if not (Rect.is_empty inner) then
      match tk_opt with
      | None ->
          Ops_common.draw_observed_empty grid ~rect:inner ~theme
            ~lang:model.lang model.work.planning
            ~empty_msg:
              (Say.make
                 ~ko:("작업을 찾을 수 없음: " ^ task_id)
                 ~en:("Task not found: " ^ task_id))
      | Some tk ->
          let bg = Color.of_rgb theme.surface_1 in
          let pad_x = Ops_common.pad_x_for ~model inner in
          let content = Card.pad_inner ~pad_x inner in
          let y = ref inner.y in
          let bot = Rect.bottom inner in
          if inner.h >= 8 then begin
            let who_sub =
              match Ops_common.task_assignee_opt tk.status with
              | Some a -> Some ("@" ^ a)
              | None -> None
            in
            let right_meta =
              match tk.updated_at with
              | Some u -> Printf.sprintf "P%d · %s" tk.priority u
              | None -> Printf.sprintf "P%d" tk.priority
            in
            let band_h = match who_sub with Some _ -> 2 | None -> 1 in
            Card.draw_section_band ~pad_x grid
              ~rect:(Rect.make ~x:inner.x ~y:!y ~w:inner.w ~h:band_h)
              ~theme ~left_title:tk.title ~right_meta ?subtitle:who_sub ();
            y := !y + band_h + (if inner.h >= 14 then 1 else 0)
          end;
          let action_h = if bot - !y >= 6 then 1 else 0 in
          let body_bot = bot - action_h in
          if !y < body_bot then begin
            draw_task_stepper grid
              ~rect:(Rect.make ~x:content.x ~y:!y ~w:content.w ~h:1)
              ~theme ~model tk.status;
            incr y
          end;
          if !y < body_bot then begin
            Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"담당자" ~en:"Assignee")
              ~value:
                (match Ops_common.task_assignee_opt tk.status with
                | Some a -> "@" ^ a
                | None -> Glyph.to_utf8 Glyph.Missing_absent)
              ();
            incr y
          end;
          if !y < body_bot then begin
            Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg
              ~label_w:14 ~key:"started_at"
              ~value:
                (match Ops_common.task_started_at_opt tk.status with
                | Some s -> s
                | None -> Glyph.to_utf8 Glyph.Missing_absent)
              ~val_fg:theme.text_muted ~val_attrs:Attr.italic ();
            incr y
          end;
          if !y < body_bot then begin
            let gl_s, gl_fg =
              match tk.goal_link with
              | Wire_work.Linked gid ->
                  (Glyph.to_utf8 Glyph.Check_mark ^ " " ^ gid, theme.status_ok)
              | Wire_work.Unlinked ->
                  ( Glyph.to_utf8 Glyph.Warning_triangle ^ " "
                    ^ Ops_common.say model ~ko:"미연결" ~en:"Unlinked"
                  , theme.status_attention )
            in
            Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg
              ~label_w:14
              ~key:(Ops_common.say model ~ko:"목표 연결" ~en:"Goal Link")
              ~value:gl_s ~val_fg:gl_fg ();
            incr y
          end;
          let v_opt = Work_store.verification_for_task ~task_id:tk.id model.work in
          let has_two_panes =
            Option.is_some tk.description && Option.is_some v_opt
          in
          let desc_focused = has_two_panes && Model.pane_focused model 0 in
          let verif_focused =
            (has_two_panes && Model.pane_focused model 1)
            || ((not has_two_panes) && Option.is_some v_opt && Model.pane_focused model 0)
          in
          let rest_h = Int.max 0 (body_bot - !y) in
          let desc_h =
            if rest_h <= 0 then 0
            else
              match tk.description, v_opt with
              | Some _, Some _ -> Int.min rest_h (Int.max 1 (rest_h / 2))
              | Some _, None -> rest_h
              | None, _ -> 0
          in
          (match tk.description with
          | Some d when desc_h > 0 ->
              let md_src = Ops_common.rewrite_masc_links_for_markdown d in
              let total_lines =
                if content.w <= 0 then 0
                else List.length (Markdown.render_lines ~width:content.w ~theme md_src)
              in
              let hdr_rows = if desc_h >= 3 then 1 else 0 in
              let actual_h =
                Int.max 0 (Int.min (desc_h - hdr_rows) (body_bot - !y - hdr_rows))
              in
              let max_d_scroll = Int.max 0 (total_lines - Int.max 1 actual_h) in
              let d_scroll =
                Int.min max_d_scroll (Int.max 0 model.work.task_dive_desc_scroll)
              in
              if hdr_rows = 1 then begin
                let prefix = if desc_focused then "▸ " else "" in
                let base_lbl =
                  Ops_common.say model ~ko:"작업 설명" ~en:"Description"
                in
                let pos_lbl =
                  if total_lines > actual_h && actual_h > 0 then
                    let vis_start = d_scroll + 1 in
                    let vis_end = Int.min total_lines (d_scroll + actual_h) in
                    let rem = Int.max 0 (total_lines - vis_end) in
                    if rem > 0 then
                      Ops_common.say model
                        ~ko:(Printf.sprintf " · L%d-%d/%d · ↓ +%d줄" vis_start vis_end total_lines rem)
                        ~en:(Printf.sprintf " · L%d-%d/%d · ↓ +%dL" vis_start vis_end total_lines rem)
                    else
                      Printf.sprintf " · L%d-%d/%d" vis_start vis_end total_lines
                  else ""
                in
                Card.draw_hairline ~pad_x:0 ~bg
                  ~label:(prefix ^ base_lbl ^ pos_lbl)
                  grid ~rect:content ~y:!y ~theme;
                incr y
              end;
              let dr =
                Rect.make ~x:content.x ~y:!y ~w:content.w ~h:actual_h
              in
              ignore
                (Markdown.draw grid ~rect:dr ~theme ~osc8:true
                   ~scroll:d_scroll md_src);
              y := !y + actual_h
          | Some _ | None -> ());
          (match v_opt with
          | Some v when !y < body_bot ->
              let v_scroll = Int.max 0 model.work.task_dive_verif_scroll in
              let vr_h = Int.max 0 (body_bot - !y - 1) in
              let diff_rows = Work_views.build_rejection_diff_rows ~model v in
              let chk_r, diff_r =
                let vr = Rect.make ~x:content.x ~y:(!y + 1) ~w:content.w ~h:vr_h in
                match
                  Layout.split_v ~gap:0 vr [ Layout.Ratio 0.45; Layout.Flex 1 ]
                with
                | [ a; b ] -> (a, b)
                | _ -> (vr, Rect.empty)
              in
              let v_prefix = if verif_focused then "▸ " else "" in
              let v_overflow =
                let total_d = List.length diff_rows in
                if not (Rect.is_empty diff_r) && total_d > diff_r.h && diff_r.h > 0
                then
                  let cs = Int.min (Int.max 0 (total_d - diff_r.h)) v_scroll in
                  let vis_end = Int.min total_d (cs + diff_r.h) in
                  let rem = Int.max 0 (total_d - vis_end) in
                  if rem > 0 then
                    Printf.sprintf " · L%d-%d/%d · ↓ +%d" (cs + 1) vis_end total_d rem
                  else Printf.sprintf " · L%d-%d/%d" (cs + 1) vis_end total_d
                else ""
              in
              Card.draw_hairline ~pad_x:0 ~bg
                ~label:
                  (Printf.sprintf "%s%s%s · [Enter] %s" v_prefix
                     (Ops_common.say model ~ko:"검증 증거 · 반려 Diff"
                        ~en:"Verification Evidence & Rejection Diff")
                     v_overflow
                     (Ops_common.say model ~ko:"검증 상세" ~en:"Verif Dive"))
                grid ~rect:content ~y:!y ~theme;
              incr y;
              draw_evidence_checklist ~scroll:v_scroll grid ~rect:chk_r ~theme
                ~model v;
              if not (Rect.is_empty diff_r) then
                ignore
                  (Diff.draw grid ~rect:diff_r ~theme ~scroll:v_scroll diff_rows)
          | Some _ | None -> ());
          if action_h = 1 then
            let keys =
              (if has_two_panes then
                 [
                   ("←/→/Tab", Ops_common.say model ~ko:"섹션" ~en:"Section");
                   ("↑↓/PgDn", Ops_common.say model ~ko:"스크롤" ~en:"Scroll");
                   ("Enter", Ops_common.say model ~ko:"검증 상세" ~en:"Verif");
                 ]
               else if Option.is_some v_opt then
                 [
                   ("↑↓/PgDn", Ops_common.say model ~ko:"스크롤" ~en:"Scroll");
                   ("Enter", Ops_common.say model ~ko:"검증 상세" ~en:"Verif");
                 ]
               else
                 [ ("↑↓/PgDn", Ops_common.say model ~ko:"스크롤" ~en:"Scroll") ])
              @ [
                  ("x", Ops_common.say model ~ko:"작업 취소" ~en:"Cancel");
                  ("Space", "JSON");
                  ("Esc", Ops_common.say model ~ko:"뒤로" ~en:"Back");
                ]
            in
            ignore
              (Ops_common.draw_keycap_bar grid
                 ~rect:(Rect.make ~x:content.x ~y:(bot - 1) ~w:content.w ~h:1)
                 ~theme ~bg keys)
  end;
  match tk_opt with
  | Some tk when not (Rect.is_empty json_card_rect) ->
      render_opt_in_json_tree grid ~rect:json_card_rect ~theme ~model ~cache
        (json_of_task tk)
  | Some _ | None -> ()

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
    | Some _ -> split_dive_with_json ~model rect
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
                Int.min max_s (Int.max 0 model.nav.dive_scroll_offset)
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
                        (Int.max 0 model.nav.dive_scroll_offset)
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
                        (Int.max 0 model.nav.dive_scroll_offset)
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
                     ~scroll:model.nav.dive_scroll_offset diff_rows)
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
      render_opt_in_json_tree grid ~rect:json_card_rect ~theme ~model ~cache
        (json_of_verification v)
  | Some _ | None -> ()

let render ~target ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Ops_common.theme_of_model model in
    match target with
    | Nav.Goal_dive goal_id ->
        render_goal_dive ~goal_id ~model ~cache ~rect ~theme grid
    | Nav.Task_dive task_id ->
        render_task_dive ~task_id ~model ~cache ~rect ~theme grid
    | Nav.Verification_dive req_id ->
        render_verification_dive ~req_id ~model ~cache ~rect ~theme grid
