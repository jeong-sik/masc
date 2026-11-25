open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

(* --- Shared Stepper & Rejection Diff Helpers --- *)

let stage_index_of_goal_phase = function
  | Wire_work.Executing -> (0, None)
  | Wire_work.Verifying -> (1, None)
  | Wire_work.Awaiting_confirmation -> (2, None)
  | Wire_work.Completed -> (4, None)
  | Wire_work.Dropped ->
      ( 0
      , Some
          ( Glyph.Live_failing
          , Theme.Status_historical
          , Say.make ~ko:"중단됨" ~en:"Dropped" ) )
  | Wire_work.Paused r ->
      let idx =
        match r with
        | Wire_work.Resume_executing -> 0
        | Wire_work.Resume_verifying -> 1
        | Wire_work.Resume_awaiting_confirmation -> 2
      in
      ( idx
      , Some
          ( Glyph.Live_paused
          , Theme.Status_historical
          , Say.make ~ko:"보류됨" ~en:"Paused" ) )
  | Wire_work.Blocked r ->
      let idx =
        match r with
        | Wire_work.Resume_executing -> 0
        | Wire_work.Resume_verifying -> 1
        | Wire_work.Resume_awaiting_confirmation -> 2
      in
      ( idx
      , Some
          ( Glyph.Live_failing
          , Theme.Status_critical
          , Say.make ~ko:"차단됨" ~en:"Blocked" ) )

let draw_goal_pipeline_stepper grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) (phase : Wire_work.goal_phase) =
  if Rect.is_empty rect then 0
  else
    let bg = Color.of_rgb theme.surface_1 in
    let active_idx, hold_opt = stage_index_of_goal_phase phase in
    let stages =
      [
        (0, Ops_common.say model ~ko:"진행" ~en:"Executing");
        (1, Ops_common.say model ~ko:"검증" ~en:"Verifying");
        (2, Ops_common.say model ~ko:"확정" ~en:"Confirm");
        (3, Ops_common.say model ~ko:"완료" ~en:"Completed");
        (4, Ops_common.say model ~ko:"캔들" ~en:"Candle");
      ]
    in
    let cx = ref rect.x in
    let right_edge = Rect.right rect in
    List.iteri
      (fun pos (idx, label) ->
        if !cx < right_edge then begin
          if pos > 0 then begin
            let arrow = " " ^ Glyph.to_utf8 Glyph.Delta_flat ^ "> " in
            let ast = Style.make ~fg:(Color.of_rgb theme.border_subtle) ~bg () in
            let adv =
              Ops_common.put_line ~clip:rect grid ~x:!cx ~y:rect.y
                ~max_w:(right_edge - !cx) ~style:ast arrow
            in
            cx := !cx + adv
          end;
          if idx = active_idx then begin
            let pill_bg = Color.of_rgb theme.surface_2 in
            let g, tok =
              match hold_opt with
              | Some (hg, htok, _) -> (hg, htok)
              | None ->
                  let tok =
                    if idx = 2 then Theme.Status_attention
                    else if idx = 4 then Theme.Status_ai
                    else if idx = 3 then Theme.Status_ok
                    else Theme.Status_active
                  in
                  let g = if idx = 4 then Glyph.Ai_spark else Glyph.Live_healthy in
                  (g, tok)
            in
            let adv1 =
              Ops_common.put_line ~clip:rect grid ~x:!cx ~y:rect.y
                ~max_w:(Int.max 0 (right_edge - !cx))
                ~style:(Typography.status ~bg:pill_bg ~bold:true theme tok)
                (" " ^ Glyph.to_utf8 g ^ " ")
            in
            cx := !cx + adv1;
            let adv2 =
              Ops_common.put_line ~clip:rect grid ~x:!cx ~y:rect.y
                ~max_w:(Int.max 0 (right_edge - !cx))
                ~style:(Typography.anchor ~bg:pill_bg theme)
                (label ^ " ")
            in
            cx := !cx + adv2
          end
          else if idx < active_idx then begin
            let adv1 =
              Ops_common.put_line ~clip:rect grid ~x:!cx ~y:rect.y
                ~max_w:(Int.max 0 (right_edge - !cx))
                ~style:(Typography.status ~bg theme Theme.Status_ok)
                (Glyph.to_utf8 Glyph.Check_mark ^ " ")
            in
            cx := !cx + adv1;
            let adv2 =
              Ops_common.put_line ~clip:rect grid ~x:!cx ~y:rect.y
                ~max_w:(Int.max 0 (right_edge - !cx))
                ~style:(Typography.structure ~bg theme)
                label
            in
            cx := !cx + adv2
          end
          else begin
            let adv =
              Ops_common.put_line ~clip:rect grid ~x:!cx ~y:rect.y
                ~max_w:(Int.max 0 (right_edge - !cx))
                ~style:(Typography.whisper ~bg ~italic:false theme)
                (Printf.sprintf "%s %s" (Glyph.to_utf8 Glyph.Live_idle) label)
            in
            cx := !cx + adv
          end
        end)
      stages;
    match hold_opt with
    | Some (hg, htok, hsay) when rect.h >= 2 ->
        Card.draw_left_rail ~bg ~tone:htok grid ~x:rect.x ~y:(rect.y + 1) ~h:1
          ~theme;
        let note =
          Printf.sprintf "%s %s (%s)" (Glyph.to_utf8 hg)
            (Say.resolve model.lang hsay)
            (Ops_common.say model ~ko:"이전 진행 단계 보존됨"
               ~en:"prior progress preserved")
        in
        let st =
          match htok with
          | Theme.Status_critical ->
              Typography.status ~bg ~bold:true theme htok
          | Theme.Status_ok
          | Theme.Status_active
          | Theme.Status_attention
          | Theme.Status_ai
          | Theme.Status_historical ->
              Typography.status ~bg ~italic:true theme htok
        in
        ignore
          (Ops_common.put_line ~clip:rect grid ~x:(rect.x + 2) ~y:(rect.y + 1)
             ~max_w:(Int.max 0 (rect.w - 2))
             ~style:st note);
        2
    | Some _ | None -> 1

let build_rejection_diff_rows ~(model : Model.t)
    (v : Wire_work.verification_request) =
  let expected_lines =
    let c =
      List.map
        (fun s ->
          Ops_common.say model ~ko:("계약: " ^ s) ~en:("Contract: " ^ s))
        v.completion_contract
    in
    let a =
      List.map
        (fun s ->
          Ops_common.say model ~ko:("필수 산출물: " ^ s) ~en:("Required: " ^ s))
        v.required_artifacts
    in
    c @ a
  in
  let observed_lines =
    let ev =
      if v.submitted_evidence = [] then
        [ Ops_common.say model ~ko:"제출된 증거: 없음" ~en:"Submitted evidence: none" ]
      else
        List.map
          (fun s ->
            Ops_common.say model ~ko:("증거: " ^ s) ~en:("Evidence: " ^ s))
          v.submitted_evidence
    in
    let err =
      match v.evidence_projection_error with
      | Some e ->
          [
            Ops_common.say model ~ko:("증거 투영 오류: " ^ e)
              ~en:("Evidence gap: " ^ e);
          ]
      | None -> []
    in
    let critique =
      match v.review_observation with
      | Some obs when not (String.equal (String.trim obs.detail) "") ->
          [
            Printf.sprintf "%s (%s): %s"
              (Ops_common.say model ~ko:"검증자 판정" ~en:"Verifier")
              obs.actor obs.detail;
          ]
      | Some _ | None -> []
    in
    ev @ err @ critique
  in
  let before = String.concat "\n" expected_lines in
  let after = String.concat "\n" observed_lines in
  Diff.rows ~before ~after |> Diff.number ~old_start:1 ~new_start:(Some 1)

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

let work_read_notice (model : Model.t) ~label read =
  Ops_common.observed_read_notice ~lang:model.lang read
  |> Option.map (fun notice -> label ^ " " ^ notice)

let verification_notice (model : Model.t) =
  List.nth_opt (Work_store.verification_read_notices model.work) 0

let criterion_badge_text ~lang = function
  | Wire_work.Criterion_valid ->
      ( Glyph.to_utf8 Glyph.Check_mark ^ " "
        ^ Say.resolve lang
            (Say.make ~ko:"실재·도달 가능 검증됨"
               ~en:"Validated (real & reachable)")
      , Theme.Status_ok )
  | Wire_work.Criterion_pending ->
      ( Glyph.to_utf8 Glyph.Transport_reconnecting ^ " "
        ^ Say.resolve lang
            (Say.make ~ko:"기준 심사 대기" ~en:"Criterion review pending")
      , Theme.Status_active )
  | Wire_work.Criterion_invalid reason ->
      ( Glyph.to_utf8 Glyph.Live_failing ^ " "
        ^ Say.resolve lang
            (Say.make ~ko:("기준 부적합: " ^ reason) ~en:("Invalid: " ^ reason))
      , Theme.Status_critical )
  | Wire_work.Criterion_unavailable reason ->
      ( Glyph.to_utf8 Glyph.Missing_unreported ^ " "
        ^ Say.resolve lang
            (Say.make ~ko:("심사 불가: " ^ reason) ~en:("Unavailable: " ^ reason))
      , Theme.Status_attention )

let is_rejected_verification (v : Wire_work.verification_request) =
  Option.is_some v.evidence_projection_error
  ||
  match v.review_observation with
  | Some
      {
        state =
          ( Wire_work.Review_rejected
          | Wire_work.Review_failed
          | Wire_work.Review_commit_failed
          | Wire_work.Review_execution_repair_required );
        _;
      } ->
      true
  | Some
      {
        state =
          ( Wire_work.Review_unobserved
          | Wire_work.Review_running
          | Wire_work.Review_approved
          | Wire_work.Review_unavailable
          | Wire_work.Review_not_reviewed
          | Wire_work.Review_execution_pending
          | Wire_work.Review_cancelled
          | Wire_work.Review_superseded );
        _;
      }
  | None ->
      false

(* --- Sub-Tab 1: Pipeline (Adaptive Goals + Linked Tasks & Verifications + Rich Goal Inspector) --- *)

let render_linked_tasks_card grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~cache ~sel_goal ~unlinked_n ~total_tasks ~link_warnings =
  if Rect.is_empty rect then ()
  else
    let linked, related_verifs =
      match sel_goal with
      | Some (g : Wire_work.goal) ->
          ( Work_store.goal_linked_tasks ~goal_id:g.id model.work
          , Work_store.goal_linked_verifications ~goal_id:g.id model.work )
      | None -> ([], [])
    in
    let task_notice =
      work_read_notice model ~label:(Ops_common.say model ~ko:"작업" ~en:"Tasks")
        model.work.planning
    in
    let verification_notice = verification_notice model in
    let passed_v, failed_v =
      List.fold_left
        (fun (p, f) (v : Wire_work.verification_request) ->
          match v.review_observation with
          | Some { state = Wire_work.Review_approved; _ } -> (p + 1, f)
          | Some
              {
                state =
                  ( Wire_work.Review_rejected
                  | Wire_work.Review_failed
                  | Wire_work.Review_commit_failed
                  | Wire_work.Review_execution_repair_required );
                _;
              } ->
              (p, f + 1)
          | Some
              {
                state =
                  ( Wire_work.Review_unobserved
                  | Wire_work.Review_running
                  | Wire_work.Review_unavailable
                  | Wire_work.Review_not_reviewed
                  | Wire_work.Review_execution_pending
                  | Wire_work.Review_cancelled
                  | Wire_work.Review_superseded );
                _;
              }
          | None ->
              if Option.is_some v.evidence_projection_error then (p, f + 1)
              else (p, f))
        (0, 0) related_verifs
    in
    let badge =
      if Option.is_some task_notice then None
      else if failed_v > 0 && Option.is_none verification_notice then
        Some
          {
            Card.glyph = Some Glyph.Live_failing;
            text = Printf.sprintf "%d/%d" failed_v (List.length related_verifs);
            tone = Some Theme.Status_critical;
          }
      else if passed_v > 0 && Option.is_none verification_notice then
        Some
          {
            Card.glyph = Some Glyph.Check_mark;
            text = Printf.sprintf "%d %s" passed_v (Ops_common.say model ~ko:"통과" ~en:"pass");
            tone = Some Theme.Status_ok;
          }
      else if linked = [] && unlinked_n > 0 then
        Some
          {
            Card.glyph = Some Glyph.Warning_triangle;
            text = Printf.sprintf "%d/%d" unlinked_n total_tasks;
            tone = Some Theme.Status_attention;
          }
      else
        Some
          {
            Card.glyph = None;
            text = Int.to_string (List.length linked);
            tone = None;
          }
    in
    let all_filtered_verifs = Work_store.filtered_verifications model.work in
    let verif_focused = Model.pane_focused model 1 in
    let card_title =
      match verif_focused, model.work.verification_view with
      | true, `Pending -> Ops_common.say model ~ko:"검증 대기열" ~en:"Awaiting Verifications"
      | true, `All -> Ops_common.say model ~ko:"검증 이력" ~en:"Verification History"
      | false, _ -> Ops_common.say model ~ko:"연결 작업 · 검증" ~en:"Tasks & Verification"
    in
    let card_subtitle =
      let sources =
        if verif_focused then [] else [ task_notice ]
      in
      match List.filter_map Fun.id sources with
      | _ :: _ as notices -> Some (String.concat Typography.sep_dot notices)
      | [] when verif_focused -> None
      | [] -> Option.map (fun (g : Wire_work.goal) -> g.id) sel_goal
    in
    let card_badge =
      if not verif_focused then badge
      else if Option.is_some verification_notice then None
      else
        Some
          {
            Card.glyph = Some Glyph.Action_required;
            text = Int.to_string (List.length all_filtered_verifs);
            tone = Some Theme.Status_active;
          }
    in
    let spec : Card.spec =
      {
        (Card.default_spec ~title:card_title) with
        subtitle = card_subtitle;
        badge = card_badge;
        hotkey =
          Some
            (if verif_focused && Result.is_ok (Work_store.verification_read_allows_verdict model.work) then
               Ops_common.say model ~ko:"[a] 승인 · [x] 반려 · [v] 전체/대기 · [Enter] 상세"
                 ~en:"[a] Approve · [x] Reject · [v] All/Pending · [Enter] Dive"
             else if verif_focused then
               (match model.work.verification_view with
               | `All -> Ops_common.say model ~ko:"[v] 대기열 · [Enter] 상세"
                           ~en:"[v] Awaiting · [Enter] Dive"
               | `Pending -> Ops_common.say model ~ko:"[v] 이력 · [Enter] 상세"
                               ~en:"[v] History · [Enter] Dive")
             else
               Ops_common.say model ~ko:"[Tab] 검증 선택 · [v] 전체/대기"
                 ~en:"[Tab] Select · [v] All/Pending");
        focused = verif_focused;
      }
    in
    let inner = Card.draw ~cache grid ~rect ~theme spec in
    if Rect.is_empty inner then ()
    else
      let bg = Color.of_rgb theme.surface_1 in
      let pad_x = Ops_common.pad_x_for ~model inner in
      let content = Card.pad_inner ~pad_x inner in
      let show_unlinked_footer =
        link_warnings <> [] && content.h >= 5
      in
      let footer_h = if show_unlinked_footer then 3 else 0 in
      let body_h = Int.max 0 (content.h - footer_h) in
      let verifs_to_render =
        if verif_focused || Option.is_none sel_goal then all_filtered_verifs
        else related_verifs
      in
      let notice_height =
        if verifs_to_render = [] then body_h else Int.max 1 (body_h - 2)
      in
      let notices =
        Ops_common.draw_verification_read_notices grid
          ~rect:{ content with h = Int.min body_h notice_height }
          ~theme ~lang:model.lang model.work
      in
      let y = ref (content.y + notices) in
      let body_bot = content.y + body_h in
      let draw_verifs_section verifs =
        if verifs <> [] && !y + 1 < body_bot then begin
          Card.draw_hairline ~pad_x:0 ~bg
            ~label:
              (Printf.sprintf "%s (%d)"
                 (Ops_common.say model ~ko:"검증 결과" ~en:"Verifications")
                 (List.length verifs))
            grid ~rect:content ~y:!y ~theme;
          incr y;
          let avail = Int.max 0 (body_bot - !y) in
          let arr = Array.of_list verifs in
          let total = Array.length arr in
          let sel_v =
            if total <= 0 then 0
            else
              Int.max 0
                (Int.min (total - 1) model.work.verif_selected_index)
          in
          let start, _ =
            Table.compute_viewport ~total_rows:total ~viewport_rows:avail
              ~scroll:model.work.verif_scroll_offset ~selected:(Some sel_v)
          in
          let max_show = Int.min avail (Int.max 0 (total - start)) in
          for i = 0 to max_show - 1 do
            let idx = start + i in
            let v : Wire_work.verification_request = arr.(idx) in
            let py = !y in
            let is_sel = verif_focused && Int.equal idx sel_v in
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
            let vg, vtok, vlbl, detail =
              match v.review_observation with
              | Some obs ->
                  let g, t, l = Ops_common.review_state_badge obs.state in
                  (g, t, l, obs.detail)
              | None ->
                  ( Glyph.Action_required
                  , Theme.Status_attention
                  , Say.make ~ko:"대기" ~en:"Pending"
                  , match v.evidence_projection_error with
                    | Some e -> e
                    | None -> v.task_title )
            in
            let head =
              Printf.sprintf "%s %s  %s  " (Glyph.to_utf8 vg)
                (Say.resolve model.lang vlbl) v.task_id
            in
            let adv =
              Ops_common.put_line ~clip:content grid ~x:content.x ~y:py
                ~max_w:content.w
                ~style:(Typography.status ~bg:rbg ~bold:true theme vtok)
                head
            in
            let det_st =
              if is_sel then Typography.anchor ~bg:rbg theme
              else
                match vtok with
                | Theme.Status_critical ->
                    Typography.status ~bg:rbg theme Theme.Status_critical
                | Theme.Status_ok
                | Theme.Status_active
                | Theme.Status_attention
                | Theme.Status_ai
                | Theme.Status_historical ->
                    Typography.whisper ~bg:rbg theme
            in
            ignore
              (Ops_common.put_line ~clip:content grid
                 ~x:(content.x + adv) ~y:py
                 ~max_w:(Int.max 0 (content.w - adv))
                 ~style:det_st detail);
            incr y
          done
        end
      in
      let remaining = { content with y = !y; h = Int.max 0 (body_bot - !y) } in
      (* 1. Linked tasks rows *)
      (match sel_goal with
      | _ when verif_focused && verifs_to_render = [] ->
          Ops_common.draw_observed_empty grid ~rect:remaining ~theme
            ~lang:model.lang model.work.verifications
            ~empty_msg:
              (if Option.is_some verification_notice then
                 Say.make ~ko:"이 조회에서 표시할 수 있는 검증 항목이 없습니다"
                   ~en:"This read has no displayable verification rows"
               else Say.make ~ko:"표시할 검증 항목이 없습니다" ~en:"No verification rows")
      | None ->
          if verifs_to_render <> [] then draw_verifs_section verifs_to_render
          else
            Ops_common.draw_observed_empty grid ~rect:remaining ~theme
              ~lang:model.lang (Work_store.goals_read model.work)
              ~empty_msg:
                (Say.make ~ko:"목표를 선택하면 연결 작업이 표시됩니다"
                   ~en:"Select a goal to view linked tasks")
      | Some _ when linked = [] && Option.is_some task_notice ->
          draw_verifs_section verifs_to_render
      | Some _ ->
          if linked = [] then begin
            let verif_reserve =
              if verifs_to_render <> [] && body_bot - !y >= 4 then
                Int.min (List.length verifs_to_render + 1)
                  (Int.max 2 ((body_bot - !y) / 2))
              else 0
            in
            if !y < body_bot - verif_reserve then begin
              Ops_common.draw_observed_empty grid
                ~rect:(Rect.make ~x:content.x ~y:!y ~w:content.w ~h:1)
                ~theme ~lang:model.lang model.work.planning
                ~empty_msg:
                  (Say.make ~ko:"표시할 연결 작업이 없습니다"
                     ~en:"No linked tasks in this read");
              incr y
            end;
            let candidates =
              Work_store.tasks model.work
              |> List.filter (fun (tk : Wire_work.task) ->
                     match tk.goal_link with
                     | Wire_work.Unlinked -> Ops_common.task_is_active tk.status
                     | Wire_work.Linked _ -> false)
              |> List.take (Int.max 0 (body_bot - verif_reserve - !y - 1))
            in
            if candidates <> [] && !y < body_bot - verif_reserve then begin
              Card.draw_hairline ~pad_x:0 ~bg
                ~label:
                  (Ops_common.say model ~ko:"연결 가능 활성 작업"
                     ~en:"Active Unlinked Candidates")
                grid ~rect:content ~y:!y ~theme;
              incr y;
              List.iter
                (fun (tk : Wire_work.task) ->
                  if !y < body_bot - verif_reserve then begin
                    let tg, ttok, _ = Ops_common.task_status_badge tk.status in
                    let who =
                      match Ops_common.task_assignee_opt tk.status with
                      | Some a -> "@" ^ a
                      | None -> ""
                    in
                    let who_w = Grapheme.display_width who in
                    let adv1 =
                      Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                        ~max_w:content.w
                        ~style:(Typography.status ~bg theme ttok)
                        (Glyph.to_utf8 tg ^ " ")
                    in
                    let mid_w =
                      Int.max 0
                        (content.w - adv1 - (if who_w > 0 then who_w + 2 else 0))
                    in
                    ignore
                      (Ops_common.put_line ~clip:content grid
                         ~x:(content.x + adv1) ~y:!y ~max_w:mid_w
                         ~style:(Typography.primary ~bg theme)
                         (Printf.sprintf "%s  %s" tk.id tk.title));
                    if who_w > 0 && content.w > adv1 + who_w + 4 then
                      ignore
                        (Ops_common.put_line ~clip:content grid
                           ~x:(Rect.right content - who_w)
                           ~y:!y ~max_w:who_w
                           ~style:(Typography.whisper ~bg theme)
                           who);
                    incr y
                  end)
                candidates
            end;
            draw_verifs_section verifs_to_render
          end
          else begin
            let verif_reserve =
              if verifs_to_render <> [] && body_bot - !y >= 3 then
                Int.min (List.length verifs_to_render + 1)
                  (Int.max 3 ((body_bot - !y) / 2))
              else 0
            in
            let task_limit = Int.max 1 (body_bot - !y - verif_reserve) in
            List.iter
              (fun (tk : Wire_work.task) ->
                if !y < body_bot - verif_reserve then begin
                  let tg, ttok, tlbl = Ops_common.task_status_badge tk.status in
                  let v_opt =
                    List.find_opt
                      (fun (v : Wire_work.verification_request) ->
                        String.equal v.task_id tk.id)
                      related_verifs
                  in
                  let v_badge =
                    match v_opt with
                    | Some { review_observation = Some obs; _ } ->
                        let vg, vtok, vlbl = Ops_common.review_state_badge obs.state in
                        Some (Glyph.to_utf8 vg ^ " " ^ Say.resolve model.lang vlbl, vtok)
                    | Some _ ->
                        Some
                          ( Glyph.to_utf8 Glyph.Action_required ^ " "
                            ^ Ops_common.say model ~ko:"검증" ~en:"verify"
                          , Theme.Status_attention )
                    | None -> None
                  in
                  let who =
                    match Ops_common.task_assignee_opt tk.status with
                    | Some a -> "@" ^ a
                    | None -> ""
                  in
                  let right_w =
                    let vb_w =
                      match v_badge with
                      | Some (s, _) -> Grapheme.display_width s + 2
                      | None -> 0
                    in
                    let w_w =
                      if String.length who > 0 then Grapheme.display_width who + 2
                      else 0
                    in
                    vb_w + w_w
                  in
                  let adv_g =
                    Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                      ~max_w:content.w
                      ~style:(Typography.status ~bg ~bold:true theme ttok)
                      (Glyph.to_utf8 tg ^ " ")
                  in
                  let title_max = Int.max 8 (content.w - adv_g - right_w) in
                  let adv_id =
                    Ops_common.put_line ~clip:content grid ~x:(content.x + adv_g)
                      ~y:!y ~max_w:(Int.min 12 title_max)
                      ~style:(Typography.structure ~bg theme)
                      (tk.id ^ " ")
                  in
                  let rem_t = Int.max 0 (title_max - adv_id) in
                  ignore
                    (Ops_common.put_line ~clip:content grid
                       ~x:(content.x + adv_g + adv_id) ~y:!y ~max_w:rem_t
                       ~style:(Typography.primary ~bg theme)
                       (if rem_t >= 6 then tk.title
                        else Say.resolve model.lang tlbl));
                  let rx = ref (Rect.right content) in
                  (match v_badge with
                  | Some (bs, btok) ->
                      let bw = Grapheme.display_width bs in
                      if !rx - bw > content.x + adv_g + adv_id + 4 then begin
                        rx := !rx - bw;
                        ignore
                          (Ops_common.put_line ~clip:content grid ~x:!rx ~y:!y
                             ~max_w:bw
                             ~style:(Typography.status ~bg ~bold:true theme btok)
                             bs);
                        rx := !rx - 2
                      end
                  | None -> ());
                  if String.length who > 0 then begin
                    let ww = Grapheme.display_width who in
                    if !rx - ww > content.x + adv_g + adv_id + 6 then begin
                      rx := !rx - ww;
                      ignore
                        (Ops_common.put_line ~clip:content grid ~x:!rx ~y:!y
                           ~max_w:ww ~style:(Typography.whisper ~bg theme) who)
                    end
                  end;
                  incr y
                end)
              (List.take task_limit linked);
            (* 2. Verifications subsection *)
            draw_verifs_section verifs_to_render
          end);
      (* 3. Pinned bottom unlinked backlog bar (hairline + Amber left rail, ZERO nested box!) *)
      if show_unlinked_footer then begin
        let fy = Rect.bottom content - 3 in
        Card.draw_hairline ~pad_x:0 ~bg grid ~rect:content ~y:fy ~theme;
        Card.draw_left_rail ~bg ~tone:Theme.Status_attention grid ~x:content.x
          ~y:(fy + 1) ~h:2 ~theme;
        let line1 = String.concat Typography.sep_dot link_warnings
        in
        ignore
          (Ops_common.put_line ~clip:content grid ~x:(content.x + 2) ~y:(fy + 1)
             ~max_w:(Int.max 0 (content.w - 2))
             ~style:(Typography.status ~bg theme Theme.Status_attention)
             line1);
        let line2 =
          Ops_common.say model
            ~ko:"goal_id 미연결 작업은 완료 시 캔들 미귀속 상태로 기록됩니다"
            ~en:"Tasks without goal_id record unattributed Candles on completion"
        in
        ignore
          (Ops_common.put_line ~clip:content grid ~x:(content.x + 2) ~y:(fy + 2)
             ~max_w:(Int.max 0 (content.w - 2))
             ~style:(Typography.whisper ~bg theme)
             line2)
      end

let render_goal_zoomed ~sel_goal ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) grid =
  let main_card_rect, json_card_rect =
    match sel_goal with
    | Some _ -> split_dive_with_json ~model rect
    | None -> (rect, Rect.empty)
  in
  if not (Rect.is_empty main_card_rect) then begin
    let title =
      match sel_goal with
      | Some (g : Wire_work.goal) ->
          Printf.sprintf "%s %s %s: %s"
            (Say.resolve model.lang (Nav.workspace_label Nav.Work))
            (Glyph.to_utf8 Glyph.Prompt_caret)
            (Ops_common.say model ~ko:"목표" ~en:"Goal")
            g.id
      | None ->
          Ops_common.say model ~ko:"선택된 목표 상세" ~en:"Selected Goal Detail"
    in
    let badge =
      match sel_goal with
      | Some (g : Wire_work.goal) ->
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
      match sel_goal with
      | None ->
          Ops_common.say model ~ko:"[z/Esc] 목록으로" ~en:"[z/Esc] Back"
      | Some (g : Wire_work.goal) -> (
          match g.phase with
          | Wire_work.Awaiting_confirmation ->
              Ops_common.say model
                ~ko:"[a] 완료 확정 · [x] 일시정지 · [J/K] 본문 · [Space] JSON · [z/Esc] 뒤로"
                ~en:"[a] Confirm · [x] Pause · [J/K] Measure · [Space] JSON · [z/Esc] Back"
          | Wire_work.Paused _ ->
              Ops_common.say model
                ~ko:"[a] 재개 · [x] 중단 · [J/K] 본문 · [Space] JSON · [z/Esc] 뒤로"
                ~en:"[a] Resume · [x] Drop · [J/K] Measure · [Space] JSON · [z/Esc] Back"
          | Wire_work.Blocked _ ->
              Ops_common.say model
                ~ko:"[a] 차단 해제 · [x] 일시정지 · [J/K] 본문 · [Space] JSON · [z/Esc] 뒤로"
                ~en:"[a] Unblock · [x] Pause · [J/K] Measure · [Space] JSON · [z/Esc] Back"
          | Wire_work.Executing ->
              Ops_common.say model
                ~ko:"[a] 검증 요청 · [x] 일시정지 · [J/K] 본문 · [Space] JSON · [z/Esc] 뒤로"
                ~en:"[a] Verify · [x] Pause · [J/K] Measure · [Space] JSON · [z/Esc] Back"
          | Wire_work.Verifying ->
              Ops_common.say model
                ~ko:"[x] 일시정지 · [J/K] 본문 · [Space] JSON · [z/Esc] 뒤로"
                ~en:"[x] Pause · [J/K] Measure · [Space] JSON · [z/Esc] Back"
          | Wire_work.Completed | Wire_work.Dropped ->
              Ops_common.say model
                ~ko:"[a] 다시 열기 · [J/K] 본문 · [Space] JSON · [z/Esc] 뒤로"
                ~en:"[a] Reopen · [J/K] Measure · [Space] JSON · [z/Esc] Back")
    in
    let spec : Card.spec =
      {
        (Card.default_spec ~title) with
        subtitle = (match sel_goal with Some (g : Wire_work.goal) -> Some g.title | None -> None);
        badge;
        hotkey = Some header_hotkey;
        focused = main_focused;
      }
    in
    let inner = Card.draw ~cache grid ~rect:main_card_rect ~theme spec in
    if not (Rect.is_empty inner) then
      match sel_goal with
      | None ->
          Ops_common.draw_observed_empty grid ~rect:inner ~theme
            ~lang:model.lang (Work_store.goals_read model.work)
            ~empty_msg:
              (Say.make ~ko:"목표를 선택하세요" ~en:"Select a goal to inspect")
      | Some (g : Wire_work.goal) ->
          let bg = Color.of_rgb theme.surface_1 in
          let pad_x = Ops_common.pad_x_for ~model inner in
          let y = ref inner.y in
          let bot = Rect.bottom inner in
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
          if !y < body_bot then begin
            let step_h =
              draw_goal_pipeline_stepper grid
                ~rect:
                  (Rect.make ~x:content.x ~y:!y ~w:content.w
                     ~h:(Int.min 2 (body_bot - !y)))
                ~theme ~model g.phase
            in
            y := !y + step_h
          end;
          let linked = Work_store.goal_linked_tasks ~goal_id:g.id model.work in
          let verifs = Work_store.goal_linked_verifications ~goal_id:g.id model.work in
          let task_notice =
            Ops_common.observed_read_notice ~lang:model.lang model.work.planning
          in
          let verification_notice =
            List.nth_opt (Work_store.verification_read_notices model.work) 0
            |> Option.map (Say.resolve model.lang)
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
                 ~scroll:model.work.detail_scroll_offset md_src);
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
                (let status =
                   match task_notice with
                   | Some notice -> notice
                   | None -> Printf.sprintf "%d%s" t_total t_pos_suffix
                 in
                 let open_hint =
                   if t_total = 0 then ""
                   else
                     Ops_common.say model ~ko:" · [Enter] 작업 열기"
                       ~en:" · [Enter] Open Task"
                 in
                 Printf.sprintf "%s%s · %s%s"
                   (focus_prefix tasks_focused)
                   (Ops_common.say model ~ko:"표시된 연결 작업" ~en:"Linked Tasks Shown")
                   status open_hint)
              grid ~rect:tasks_r ~y:tasks_r.y ~theme;
            if linked = [] then
              Ops_common.draw_observed_empty grid ~rect:t_body ~theme
                ~lang:model.lang model.work.planning
                ~empty_msg:(Say.make ~ko:"표시할 연결 작업이 없습니다"
                              ~en:"No linked tasks in this read")
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
                  (let status =
                     match verification_notice, task_notice with
                     | Some notice, _ | None, Some notice -> notice
                     | None, None -> Printf.sprintf "%d%s" v_total v_pos_suffix
                   in
                   let open_hint =
                     if v_total = 0 then ""
                     else
                       Ops_common.say model ~ko:" · [Enter] 검증 상세"
                         ~en:" · [Enter] Inspect"
                   in
                   Printf.sprintf "%s%s · %s%s"
                     (focus_prefix verifs_focused)
                     (Ops_common.say model ~ko:"검증 실행 · 증거"
                        ~en:"Verifier Runs & Evidence")
                     status open_hint)
                grid ~rect:verif_r ~y:verif_r.y ~theme;
              let v_body =
                Rect.make ~x:verif_r.x ~y:(verif_r.y + 1) ~w:verif_r.w
                  ~h:(Int.max 0 (verif_r.h - 1))
              in
              let notices =
                Ops_common.draw_verification_read_notices grid
                  ~rect:{ v_body with h = Int.min 3 v_body.h }
                  ~theme ~lang:model.lang model.work
              in
              let v_body = { v_body with y = v_body.y + notices; h = v_body.h - notices } in
              match verifs with
              | [] ->
                  Ops_common.draw_observed_empty grid ~rect:v_body ~theme
                    ~lang:model.lang model.work.verifications
                    ~empty_msg:
                      (match task_notice with
                      | Some _ ->
                          Say.make ~ko:"연결 작업을 읽은 뒤 검증을 대조할 수 있습니다"
                            ~en:"Linked tasks needed to match verification rows"
                      | None ->
                          Say.make ~ko:"조회된 연결 작업의 검증 항목이 없습니다"
                            ~en:"No verification rows for the linked tasks shown")
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
                             (build_rejection_diff_rows ~model v))
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
                ("Enter", Ops_common.say model ~ko:"열기" ~en:"Open");
              ]
              @ phase_keys
              @ [
                  ("Space", "JSON");
                  ("z/Esc", Ops_common.say model ~ko:"뒤로" ~en:"Back");
                ]
            in
            ignore
              (Ops_common.draw_keycap_bar grid
                 ~rect:(Rect.make ~x:content.x ~y:(bot - 1) ~w:content.w ~h:1)
                 ~theme ~bg nav_keys)
  end;
  match sel_goal with
  | Some g when not (Rect.is_empty json_card_rect) ->
      render_opt_in_json_tree grid ~rect:json_card_rect ~theme ~model ~cache
        (json_of_goal g)
  | Some _ | None -> ()

let render_pipeline ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Ops_common.theme_of_model model in
    let bp = Ops_common.layout_bp model in
    let goals = Work_store.filtered_goals model.work in
    let goals_read = Work_store.goals_read model.work in
    let goal_notice =
      work_read_notice model ~label:(Ops_common.say model ~ko:"목표" ~en:"Goals")
        goals_read
    in
    let task_notice =
      work_read_notice model ~label:(Ops_common.say model ~ko:"작업" ~en:"Tasks")
        model.work.planning
    in
    let zoomed = model.nav.zoomed && Model.can_zoom_current_view model in
    let sel_goal =
      let index = model.work.selected_index in
      if index < 0 then None else List.nth_opt goals index
    in
    let sel_goal_idx = Option.map (fun _ -> model.work.selected_index) sel_goal in
    if zoomed then
      render_goal_zoomed ~sel_goal ~model ~cache ~rect ~theme grid
    else
    let left_rect, right_rect =
      if rect.w >= 96 then
        match
          Layout.split_h_bp bp rect [ Layout.Ratio 0.46; Layout.Flex 1 ]
        with
        | [ l; r ] -> (l, r)
        | _ -> (rect, Rect.empty)
      else
        let top_h =
          Int.min (Int.max 5 (rect.h / 2))
            (Layout.adaptive_list_height ~items:(List.length goals) ~overhead:4
               ~min_h:5 ~max_h:10 ())
        in
        match Layout.split_v_bp bp rect [ Layout.Fixed top_h; Layout.Flex 1 ] with
        | [ t; b ] -> (t, b)
        | _ -> (rect, Rect.empty)
    in
    let unlinked_n = Work_store.unlinked_task_count model.work in
    let total_tasks = List.length (Work_store.tasks model.work) in
    let link_warnings =
      let missing_links =
        if unlinked_n > 0 then
          Some
            (Ops_common.say model
               ~ko:(Printf.sprintf "표시 작업 %d/%d건 목표 미연결" unlinked_n total_tasks)
               ~en:(Printf.sprintf "%d/%d shown tasks lack goal links" unlinked_n total_tasks))
        else None
      in
      let unattributed =
        match Observed.to_option model.work.candle_ledger with
        | Some ledger when ledger.diagnostics.unattributed_count > 0 ->
            let count = ledger.diagnostics.unattributed_count in
            Some
              (Ops_common.say model
                 ~ko:(Printf.sprintf "미귀속 캔들 %d건" count)
                 ~en:(Printf.sprintf "%d unattributed Candles" count))
        | Some _ | None -> None
      in
      List.filter_map Fun.id [ missing_links; unattributed ]
    in
    let done_goals =
      List.fold_left
        (fun acc (g : Wire_work.goal) ->
          match g.phase with
          | Wire_work.Completed -> acc + 1
          | Wire_work.Executing
          | Wire_work.Verifying
          | Wire_work.Awaiting_confirmation
          | Wire_work.Dropped
          | Wire_work.Paused _
          | Wire_work.Blocked _ ->
              acc)
        0 goals
    in
    (* Anti-Void Adaptive Height: clamp(goal_count + 4, 6, 12) for Goals,
       reclaiming the entire bottom-left space for Linked Tasks & Verifications! *)
    let goals_rect, linked_card_rect =
      if
        Model.work_pipeline_has_linked_card model
        && rect.w >= 96 && left_rect.h >= 14
      then
        let want_h =
          Layout.adaptive_list_height ~items:(List.length goals) ~overhead:4
            ~min_h:6 ~max_h:12 ()
        in
        let clamped_h = Int.min want_h (left_rect.h - 6) in
        match
          Layout.split_v_bp bp left_rect
            [ Layout.Fixed clamped_h; Layout.Flex 1 ]
        with
        | [ t; b ] -> (t, b)
        | _ -> (left_rect, Rect.empty)
      else (left_rect, Rect.empty)
    in
    let filter_badge_lbl =
      match model.work.goal_phase_filter with
      | Work_store.Goal_filter_all -> Ops_common.say model ~ko:"전체" ~en:"All"
      | Work_store.Goal_filter_active -> Ops_common.say model ~ko:"진행" ~en:"Active"
      | Work_store.Goal_filter_verifying ->
          Ops_common.say model ~ko:"검증" ~en:"Verifying"
      | Work_store.Goal_filter_held -> Ops_common.say model ~ko:"보류" ~en:"Held"
      | Work_store.Goal_filter_closed -> Ops_common.say model ~ko:"종료" ~en:"Closed"
    in
    let sort_badge_lbl =
      match model.work.goal_sort_mode with
      | Work_store.Goal_sort_default -> Ops_common.say model ~ko:"기본순" ~en:"Default"
      | Work_store.Goal_sort_phase -> Ops_common.say model ~ko:"단계순" ~en:"Phase"
      | Work_store.Goal_sort_progress ->
          Ops_common.say model ~ko:"표시 작업 완료율순" ~en:"Task completion"
      | Work_store.Goal_sort_recent -> Ops_common.say model ~ko:"최신순" ~en:"Recent"
    in
    let filter_tone =
      if
        Work_store.equal_goal_phase_filter model.work.goal_phase_filter
          Work_store.Goal_filter_all
      then None
      else Some Theme.Status_active
    in
    let left_spec : Card.spec =
      {
        (Card.default_spec
           ~title:
             (let title =
                Ops_common.say model ~ko:"목표 파이프라인" ~en:"Goals Pipeline"
              in
              if Option.is_some goal_notice then title
              else Printf.sprintf "%s (%d/%d)" title done_goals (List.length goals)))
        with
        subtitle = goal_notice;
        badge =
          Some
            {
              Card.glyph = None;
              text = Printf.sprintf "%s · %s" filter_badge_lbl sort_badge_lbl;
              tone = filter_tone;
            };
        hotkey =
          Some
            (Ops_common.say model
               ~ko:"[Space] 단계 필터 · [S] 정렬 · [/] 검색 · [n] 새 목표"
               ~en:"[Space] Filter · [S] Sort · [/] Search · [n] New");
        focused = Model.pane_focused model 0;
      }
    in
    let l_inner = Card.draw ~cache grid ~rect:goals_rect ~theme left_spec in
    if not (Rect.is_empty l_inner) then begin
      if goals = [] then
        Ops_common.draw_observed_empty grid ~rect:l_inner ~theme ~lang:model.lang
          goals_read
          ~empty_msg:(Say.make ~ko:"조건에 맞는 목표가 없습니다" ~en:"No matching goals")
      else
        let cols : Table.column list =
          [
            {
              id = "phase";
              header = Say.make ~ko:"단계" ~en:"Phase";
              priority = 0;
              min_width = 10;
              max_width = Some 15;
              weight = 2;
              align = Table.Left;
            };
            {
              id = "goal";
              header = Say.make ~ko:"목표" ~en:"Goal";
              priority = 0;
              min_width = 14;
              max_width = None;
              weight = 5;
              align = Table.Left;
            };
            {
              id = "prog";
              header = Say.make ~ko:"완료/표시" ~en:"Done/Shown";
              priority = 1;
              min_width = 11;
              max_width = Some 16;
              weight = 2;
              align = Table.Right;
            };
            {
              id = "links";
              header = Say.make ~ko:"표시" ~en:"Shown";
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
            (fun (g : Wire_work.goal) ->
              let pg, ptok, plbl = Ops_common.goal_phase_badge g.phase in
              let linked = Work_store.goal_linked_tasks ~goal_id:g.id model.work in
              let progress_cell =
                match Work_store.linked_task_completion model.work linked with
                | None -> Table.text_cell "—"
                | Some (done_count, total) ->
                    Table.Gauge
                      {
                        ratio = Float.of_int done_count /. Float.of_int total;
                        gradient = Chart.Gradient.Efficiency;
                        label = Some (Printf.sprintf "%d/%d" done_count total);
                      }
              in
              let link_cell =
                match task_notice with
                | Some _ -> Table.text_cell "—"
                | None ->
                    Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                      (Int.to_string (List.length linked))
              in
              {
                Table.id = g.id;
                cells =
                  [
                    ( "phase"
                    , Table.Badge
                        {
                          glyph = Some pg;
                          text = Say.resolve model.lang plbl;
                          tone = ptok;
                        } );
                    ( "goal"
                    , Table.text_cell (Printf.sprintf "P%d %s" g.priority g.title)
                    );
                    ("prog", progress_cell);
                    ("links", link_cell);
                  ];
              })
            goals
        in
        ignore
          (Table.draw grid ~rect:l_inner ~theme ~caps:Ops_common.default_caps
             ~lang:model.lang ~scroll:model.work.scroll_offset
             ?selected:sel_goal_idx ~focused:(Model.pane_focused model 0)
             ~col_gap:(Layout.table_col_gap bp) ~columns:cols rows)
    end;
    (* Bottom-left peer card: Linked Tasks & Verifications for selected goal *)
    if not (Rect.is_empty linked_card_rect) then
      render_linked_tasks_card grid ~rect:linked_card_rect ~theme ~model ~cache
        ~sel_goal ~unlinked_n ~total_tasks ~link_warnings;
    let right_rect =
      if Rect.is_empty linked_card_rect && not (Rect.is_empty right_rect) then
        let notices =
          Ops_common.draw_verification_read_notices grid
            ~rect:{ right_rect with h = Int.min 3 (Int.max 1 (right_rect.h - 3)) }
            ~theme ~lang:model.lang model.work
        in
        { right_rect with y = right_rect.y + notices; h = right_rect.h - notices }
      else right_rect
    in
    (* Right/Bottom: Rich Goal Detail Inspector (54% Wide/Std) *)
    if not (Rect.is_empty right_rect) then
      match sel_goal with
      | None ->
          let r_spec : Card.spec =
            {
              (Card.default_spec
                 ~title:
                   (Ops_common.say model ~ko:"선택된 목표 상세"
                      ~en:"Selected Goal Detail"))
              with
              focused =
                Model.detail_pane_focused
                  ~detail_index:(if Rect.is_empty linked_card_rect then 1 else 2)
                  model;
            }
          in
          let r_inner = Card.draw ~cache grid ~rect:right_rect ~theme r_spec in
          Ops_common.draw_observed_empty grid ~rect:r_inner ~theme
            ~lang:model.lang goals_read
            ~empty_msg:
              (Say.make ~ko:"목표를 선택하세요" ~en:"Select a goal to inspect")
      | Some g ->
          let pg, ptok, plbl = Ops_common.goal_phase_badge g.phase in
          let r_spec : Card.spec =
            {
              (Card.default_spec
                 ~title:(Ops_common.say model ~ko:"목표 상세" ~en:"Goal Detail"))
              with
              subtitle =
                Some
                  (match List.filter_map Fun.id [ task_notice; goal_notice ] with
                  | [] -> g.id
                  | notices -> String.concat Typography.sep_dot notices);
              badge =
                Some
                  {
                    Card.glyph = Some pg;
                    text = Say.resolve model.lang plbl;
                    tone = Some ptok;
                  };
              hotkey =
                Some
                  (if model.infra.show_raw_json then
                     Ops_common.say model ~ko:"[Space] 카드 · [↑↓] 스크롤 · [Esc] 닫기"
                       ~en:"[Space] Card · [↑↓] Scroll · [Esc] Close"
                   else
                     Ops_common.say model ~ko:"[Enter/z] 확대 · [Space] JSON · [→/Tab] 스크롤"
                       ~en:"[Enter/z] Zoom · [Space] JSON · [→/Tab] Scroll");
              focused =
                Model.detail_pane_focused
                  ~detail_index:(if Rect.is_empty linked_card_rect then 1 else 2)
                  model;
            }
          in
          let r_inner = Card.draw ~cache grid ~rect:right_rect ~theme r_spec in
          if not (Rect.is_empty r_inner) then begin
            let bg = Color.of_rgb theme.surface_1 in
            let pad_x = Ops_common.pad_x_for ~model r_inner in
            let content = Card.pad_inner ~pad_x r_inner in
            if model.infra.show_raw_json then begin
              let scrubbed = Ops_common.scrub_json_secrets (json_of_goal g) in
              let lines =
                Json_tree.flatten ~max_depth:4 ~redact_secrets:true scrubbed
              in
              ignore
                (Json_tree.draw grid ~rect:content ~theme
                   ~scroll:model.nav.json_scroll_offset lines)
            end
            else begin
            let y = ref r_inner.y in
            let bottom = Rect.bottom r_inner in
            let linked = Work_store.goal_linked_tasks ~goal_id:g.id model.work in
            let related_verifs =
              Work_store.goal_linked_verifications ~goal_id:g.id model.work
            in
            let rejected_verif =
              List.find_opt is_rejected_verification related_verifs
            in
            let crit_txt, crit_tok =
              criterion_badge_text ~lang:model.lang g.criterion_verdict
            in
            (* 1. Elevated Summary Header Band (surface_2) *)
            if r_inner.h >= 8 then begin
              let right_meta =
                match g.due_date, g.updated_at with
                | Some d, _ -> Printf.sprintf "due %s" d
                | None, Some u -> u
                | None, None ->
                    (match g.criterion_revision with Some r -> r | None -> g.id)
              in
              let rev_part =
                match g.criterion_revision with
                | Some r -> Typography.sep_dot ^ r
                | None -> ""
              in
              Card.draw_section_band ~pad_x grid
                ~rect:(Rect.make ~x:r_inner.x ~y:!y ~w:r_inner.w ~h:2)
                ~theme
                ~left_title:(Printf.sprintf "P%d  %s" g.priority g.title)
                ~right_meta
                ~subtitle:(crit_txt ^ rev_part)
                ();
              y := !y + 2 + (if r_inner.h >= 16 then 1 else 0)
            end
            else if !y < bottom then begin
              Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg
                ~label_w:12
                ~key:(Ops_common.say model ~ko:"성공조건" ~en:"Criterion")
                ~value:crit_txt ~val_fg:(Theme.status_color theme crit_tok) ();
              incr y
            end;
            let action_h = if bottom - !y >= 4 then 2 else if bottom - !y >= 2 then 1 else 0 in
            let body_bot = bottom - action_h in
            (* 2. Pipeline Stage Stepper *)
            if !y < body_bot then begin
              let step_rect =
                Rect.make ~x:content.x ~y:!y ~w:content.w
                  ~h:(Int.min 2 (body_bot - !y))
              in
              let step_used =
                draw_goal_pipeline_stepper grid ~rect:step_rect ~theme ~model
                  g.phase
              in
              y := !y + step_used + (if body_bot - !y >= 12 then 1 else 0)
            end;
            (match Work_store.linked_task_completion model.work linked,
                   Observed.observed_at model.work.planning with
            | Some (done_count, total), Some observed_at when body_bot - !y >= 5 ->
              let awaiting =
                List.fold_left
                  (fun count (task : Wire_work.task) ->
                    if Ops_common.task_is_awaiting_verification task.status then
                      count + 1
                    else count)
                  0 linked
              in
              let reset_hint =
                Some
                  (Say.make
                     ~ko:(Printf.sprintf "표시된 연결 작업 %d건 · 완료 %d · 검증 대기 %d"
                            total done_count awaiting)
                     ~en:(Printf.sprintf "%d linked rows shown · %d done · %d awaiting verification"
                            total done_count awaiting))
              in
              let gauge_rect = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:2 in
              let gauge_spec : Chart.Spec.t =
                {
                  title = Say.make ~ko:"표시된 연결 작업" ~en:"Linked Task Rows";
                  kind =
                    Chart.Spec.Ratio_gauge
                      {
                        used = Observed.value ~observed_at (Float.of_int done_count);
                        limit = Observed.value ~observed_at (Float.of_int total);
                        unit = Format_val.Count;
                        gradient = Chart.Gradient.Efficiency;
                        reset_hint;
                      };
                  hotkey_hint = None;
                }
              in
              ignore
                (Chart.draw grid ~rect:gauge_rect ~theme
                   ~caps:Ops_common.default_caps ~lang:model.lang
                   ~show_title:false gauge_spec);
              y := !y + gauge_rect.h
            | Some _, (Some _ | None) | None, (Some _ | None) -> ());
            (* 4. Tier-4 italic review note & timestamps *)
            (match g.last_review_note with
            | Some note
              when !y < body_bot && not (String.equal (String.trim note) "") ->
                let ts_part =
                  match g.last_review_at with
                  | Some t -> Typography.sep_dot ^ t
                  | None -> ""
                in
                Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg
                  ~label_w:12
                  ~key:(Ops_common.say model ~ko:"심사 노트" ~en:"Review Note")
                  ~value:(note ^ ts_part) ~val_fg:theme.text_muted
                  ~val_attrs:Attr.italic ();
                incr y
            | Some _ | None -> ());
            (* 5. Compact unlinked warning on narrow viewports where bottom-left card isn't shown *)
            if
              Rect.is_empty linked_card_rect
              && link_warnings <> []
              && !y < body_bot
            then begin
              Card.draw_left_rail ~bg ~tone:Theme.Status_attention grid
                ~x:content.x ~y:!y ~h:1 ~theme;
              let w_line = String.concat Typography.sep_dot link_warnings in
              ignore
                (Ops_common.put_line ~clip:content grid ~x:(content.x + 2) ~y:!y
                   ~max_w:(Int.max 0 (content.w - 2))
                   ~style:(Typography.status ~bg theme Theme.Status_attention)
                   w_line);
              incr y
            end;
            (* 6. Criteria breakdown hairline + Markdown Measure & Procedure *)
            let rem_h = Int.max 0 (body_bot - !y) in
            let diff_h =
              match rejected_verif with
              | Some _ when rem_h >= 10 -> Int.min 6 (rem_h / 3)
              | Some _ | None -> 0
            in
            let ev_h =
              match rejected_verif, related_verifs with
              | None, _ :: _ when rem_h >= 9 -> Int.min 4 (rem_h / 3)
              | _ -> 0
            in
            let md_avail = Int.max 0 (rem_h - diff_h - ev_h) in
            if md_avail >= 3 then begin
              Card.draw_hairline ~pad_x:0 ~bg
                ~label:
                  (Ops_common.say model ~ko:"성공 조건 · 측정 절차"
                     ~en:"Success Criteria & Procedure")
                grid ~rect:content ~y:!y ~theme;
              incr y;
              let md_h = Int.max 0 (md_avail - 1) in
              let md_rect =
                Rect.make ~x:content.x ~y:!y ~w:content.w ~h:md_h
              in
              let md_src =
                Printf.sprintf "**%s:** %s\n\n**%s:** %s"
                  (Ops_common.say model ~ko:"성공 조건" ~en:"Success Measure")
                  (Ops_common.rewrite_masc_links_for_markdown g.measure)
                  (Ops_common.say model ~ko:"측정 절차" ~en:"Procedure")
                  (Ops_common.rewrite_masc_links_for_markdown g.procedure)
              in
              ignore
                (Markdown.draw grid ~rect:md_rect ~theme ~osc8:true
                   ~scroll:model.work.detail_scroll_offset md_src);
              y := !y + md_h
            end
            else if md_avail >= 1 then begin
              let md_rect =
                Rect.make ~x:content.x ~y:!y ~w:content.w ~h:md_avail
              in
              let md_src =
                Ops_common.rewrite_masc_links_for_markdown
                  (g.measure ^ " · " ^ g.procedure)
              in
              ignore
                (Markdown.draw grid ~rect:md_rect ~theme ~osc8:true
                   ~scroll:model.work.detail_scroll_offset md_src);
              y := !y + md_avail
            end;
            (* 7. Acceptance Evidence or Structured Rejection Diff (strictly scoped to THIS goal!) *)
            (match rejected_verif with
            | Some rv when diff_h >= 2 && !y < body_bot ->
                Card.draw_hairline ~pad_x:0 ~bg
                  ~label:
                    (Ops_common.say model ~ko:"검증 반려 Diff"
                       ~en:"Rejection Diff")
                  grid ~rect:content ~y:!y ~theme;
                incr y;
                let drect =
                  Rect.make ~x:content.x ~y:!y ~w:content.w
                    ~h:(Int.max 0 (Int.min (diff_h - 1) (body_bot - !y)))
                in
                let rows = build_rejection_diff_rows ~model rv in
                ignore
                  (Diff.draw grid ~rect:drect ~theme
                     ~scroll:model.work.detail_scroll_offset rows);
                y := !y + drect.h
            | Some _ | None -> (
                match related_verifs with
                | v :: _ when ev_h >= 2 && !y < body_bot ->
                    Card.draw_hairline ~pad_x:0 ~bg
                      ~label:
                        (Ops_common.say model ~ko:"수용 증거"
                           ~en:"Acceptance Evidence")
                      grid ~rect:content ~y:!y ~theme;
                    incr y;
                    List.iter
                      (fun ev ->
                        if !y < body_bot then begin
                          ignore
                            (Ops_common.put_line ~clip:content grid ~x:content.x
                               ~y:!y ~max_w:content.w
                               ~style:(Typography.status ~bg theme Theme.Status_ok)
                               (Glyph.to_utf8 Glyph.Check_mark ^ " " ^ ev));
                          incr y
                        end)
                      (List.take (Int.max 0 (body_bot - !y)) v.submitted_evidence)
                | _ -> ()));
            (* 8. Pinned Keycap Action Bar *)
            if action_h >= 1 then begin
              if action_h >= 2 then
                Card.draw_hairline ~pad_x:0 ~bg grid ~rect:content
                  ~y:(bottom - 2) ~theme;
              let stop_lbl =
                match g.phase with
                | Wire_work.Paused _ -> Ops_common.say model ~ko:"중단" ~en:"Drop"
                | Wire_work.Executing
                | Wire_work.Verifying
                | Wire_work.Awaiting_confirmation
                | Wire_work.Blocked _
                | Wire_work.Completed
                | Wire_work.Dropped ->
                    Ops_common.say model ~ko:"일시정지" ~en:"Pause"
              in
              let keys =
                match g.phase with
                | Wire_work.Awaiting_confirmation ->
                    [
                      ("a", Ops_common.say model ~ko:"완료 확정" ~en:"Confirm");
                      ("Enter/z", Ops_common.say model ~ko:"확대" ~en:"Zoom");
                      ("x", stop_lbl);
                    ]
                | Wire_work.Paused _ ->
                    [
                      ("a", Ops_common.say model ~ko:"재개" ~en:"Resume");
                      ("Enter/z", Ops_common.say model ~ko:"확대" ~en:"Zoom");
                      ("x", stop_lbl);
                    ]
                | Wire_work.Blocked _ ->
                    [
                      ("a", Ops_common.say model ~ko:"차단 해제" ~en:"Unblock");
                      ("Enter/z", Ops_common.say model ~ko:"확대" ~en:"Zoom");
                      ("x", stop_lbl);
                    ]
                | Wire_work.Completed | Wire_work.Dropped ->
                    [
                      ("a", Ops_common.say model ~ko:"다시 열기" ~en:"Reopen");
                      ("Enter/z", Ops_common.say model ~ko:"확대" ~en:"Zoom");
                    ]
                | Wire_work.Executing | Wire_work.Verifying ->
                    [
                      ("Enter/z", Ops_common.say model ~ko:"확대" ~en:"Zoom");
                      ("c", Ops_common.say model ~ko:"검증 요청" ~en:"Verify");
                      ("x", stop_lbl);
                    ]
              in
              ignore
                (Ops_common.draw_keycap_bar grid
                   ~rect:
                     (Rect.make ~x:content.x ~y:(bottom - 1) ~w:content.w ~h:1)
                   ~theme ~bg keys)
            end
            end
          end

(* --- Sub-Tab 2: Tasks --- *)

let render_task_zoomed ~sel_task ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) grid =
  let main_card_rect, json_card_rect =
    match sel_task with
    | Some _ -> split_dive_with_json ~model rect
    | None -> (rect, Rect.empty)
  in
  if not (Rect.is_empty main_card_rect) then begin
    let title =
      match sel_task with
      | Some (tk : Wire_work.task) ->
          Printf.sprintf "%s %s %s: %s"
            (Say.resolve model.lang (Nav.workspace_label Nav.Work))
            (Glyph.to_utf8 Glyph.Prompt_caret)
            (Ops_common.say model ~ko:"작업" ~en:"Task")
            tk.id
      | None -> Ops_common.say model ~ko:"작업 상세" ~en:"Task Detail"
    in
    let badge =
      match sel_task with
      | Some (tk : Wire_work.task) ->
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
        subtitle = (match sel_task with Some (tk : Wire_work.task) -> Some tk.title | None -> None);
        badge;
        hotkey =
          Some
            (Ops_common.say model ~ko:"[x] 취소 · [g] 목표 연결 · [Space] JSON · [z/Esc] 뒤로"
               ~en:"[x] Cancel · [g] Link Goal · [Space] JSON · [z/Esc] Back");
        focused = task_main_focused;
      }
    in
    let inner = Card.draw ~cache grid ~rect:main_card_rect ~theme spec in
    if not (Rect.is_empty inner) then
      match sel_task with
      | None ->
          Ops_common.draw_observed_empty grid ~rect:inner ~theme
            ~lang:model.lang model.work.planning
            ~empty_msg:(Say.make ~ko:"작업을 선택하세요" ~en:"Select a task")
      | Some (tk : Wire_work.task) ->
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
              let notices =
                Ops_common.draw_verification_read_notices grid
                  ~rect:{ content with y = !y; h = Int.min 2 (body_bot - !y - 1) }
                  ~theme ~lang:model.lang model.work
              in
              y := !y + notices;
              let v_scroll = Int.max 0 model.work.task_dive_verif_scroll in
              let vr_h = Int.max 0 (body_bot - !y - 1) in
              let diff_rows = build_rejection_diff_rows ~model v in
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
                     (Ops_common.say model ~ko:"검증 상세" ~en:"Inspect"))
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
                  ("z/Esc", Ops_common.say model ~ko:"뒤로" ~en:"Back");
                ]
            in
            ignore
              (Ops_common.draw_keycap_bar grid
                 ~rect:(Rect.make ~x:content.x ~y:(bot - 1) ~w:content.w ~h:1)
                 ~theme ~bg keys)
  end;
  match sel_task with
  | Some tk when not (Rect.is_empty json_card_rect) ->
      render_opt_in_json_tree grid ~rect:json_card_rect ~theme ~model ~cache
        (json_of_task tk)
  | Some _ | None -> ()

let render_tasks ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Ops_common.theme_of_model model in
    let bp = Ops_common.layout_bp model in
    let zoomed = model.nav.zoomed && Model.can_zoom_current_view model in
    let filtered_tasks = Work_store.filtered_tasks model.work in
    let n_tasks = List.length filtered_tasks in
    let task_sel_opt =
      if n_tasks > 0 then
        Some (Int.max 0 (Int.min (n_tasks - 1) model.work.selected_index))
      else None
    in
    let sel_task = Option.bind task_sel_opt (List.nth_opt filtered_tasks) in
    if zoomed then
      render_task_zoomed ~sel_task ~model ~cache ~rect ~theme grid
    else
    let bg = Color.of_rgb theme.surface_0 in
    let all_tasks = Work_store.tasks model.work in
    let eff_counts = Work_store.effective_task_counts model.work in
    let v_pass, v_rej, v_wait = Work_store.verification_pass_summary model.work in
    let active_n, verify_n, todo_n, done_n =
      match eff_counts with
      | Some c ->
          ( c.claimed + c.in_progress + c.awaiting_verification
          , c.awaiting_verification
          , c.todo
          , c.done_total )
      | None ->
          let act =
            List.fold_left
              (fun a (tk : Wire_work.task) ->
                if Ops_common.task_is_active tk.status then a + 1 else a)
              0 all_tasks
          in
          let ver =
            List.fold_left
              (fun a (tk : Wire_work.task) ->
                if Ops_common.task_is_awaiting_verification tk.status then a + 1
                else a)
              0 all_tasks
          in
          let td =
            List.fold_left
              (fun a (tk : Wire_work.task) ->
                match tk.status with
                | Wire_work.Todo -> a + 1
                | Wire_work.Claimed _
                | Wire_work.InProgress _
                | Wire_work.AwaitingVerification _
                | Wire_work.Done _
                | Wire_work.Cancelled _ ->
                    a)
              0 all_tasks
          in
          let dn =
            List.fold_left
              (fun a (tk : Wire_work.task) ->
                if Ops_common.task_is_done tk.status then a + 1 else a)
              0 all_tasks
          in
          (act, ver, td, dn)
    in
    let unlinked_n = Work_store.unlinked_task_count model.work in
    let pill_rect, body_rect = Rect.split_v rect ~top_h:1 in
    let status = model.work.task_status_filter in
    let is_status f = Work_store.equal_task_status_filter status f in
    let pills =
      [
        ( Printf.sprintf "%s %d"
            (Ops_common.say model ~ko:"전체" ~en:"All")
            (List.length all_tasks)
        , is_status Work_store.Status_all
        , None );
        ( Printf.sprintf "%s %d"
            (Ops_common.say model ~ko:"진행" ~en:"Active")
            active_n
        , is_status Work_store.Status_active
        , Some Theme.Status_active );
        ( Printf.sprintf "%s %d"
            (Ops_common.say model ~ko:"검증대기" ~en:"AwaitingVerify")
            verify_n
        , is_status Work_store.Status_awaiting_verification
        , Some Theme.Status_attention );
        ( Printf.sprintf "%s %d"
            (Ops_common.say model ~ko:"대기" ~en:"Todo")
            todo_n
        , is_status Work_store.Status_todo
        , None );
        ( Printf.sprintf "%s %d"
            (Ops_common.say model ~ko:"미연결" ~en:"Unlinked")
            unlinked_n
        , is_status Work_store.Status_unlinked
        , Some Theme.Status_attention );
        ( Printf.sprintf "%s %d"
            (Ops_common.say model ~ko:"완료" ~en:"Done")
            done_n
        , is_status Work_store.Status_done
        , Some Theme.Status_ok );
      ]
    in
    let pill_adv = Ops_common.draw_pills grid ~rect:pill_rect ~theme ~bg pills in
    if Option.is_none (verification_notice model)
       && v_pass + v_rej + v_wait > 0 && pill_rect.w - pill_adv >= 22 then begin
      let summary =
        Printf.sprintf "%s%d  %s%d  %s%d"
          (Glyph.to_utf8 Glyph.Check_mark) v_pass
          (Glyph.to_utf8 Glyph.Live_failing) v_rej
          (Glyph.to_utf8 Glyph.Action_required) v_wait
      in
      let sw = Grapheme.display_width summary in
      ignore
        (Ops_common.put_line ~clip:pill_rect grid
           ~x:(Rect.right pill_rect - sw - 1)
           ~y:pill_rect.y ~max_w:sw
           ~style:(Typography.whisper ~bg theme)
           summary)
    end;
    if Rect.is_empty body_rect then ()
    else
      let tasks_rect, detail_rect =
        if body_rect.w >= 96 then
          match
            Layout.split_h_bp bp body_rect [ Layout.Ratio 0.54; Layout.Flex 1 ]
          with
          | [ tl; tr ] -> (tl, tr)
          | _ -> (body_rect, Rect.empty)
        else
          match
            Layout.split_v_bp bp body_rect [ Layout.Ratio 0.52; Layout.Flex 1 ]
          with
          | [ t; b ] -> (t, b)
          | _ -> (body_rect, Rect.empty)
      in
      (* 1. Tasks Table *)
      let t_spec : Card.spec =
        {
          (Card.default_spec
             ~title:
               (Printf.sprintf "%s (%d)"
                  (Ops_common.say model ~ko:"작업 목록" ~en:"Tasks")
                  n_tasks))
          with
          hotkey =
            Some
              (Ops_common.say model ~ko:"[v/Space] 상태 · [x] 취소 · [h] 재정의 · [Enter/z] 확대"
                 ~en:"[v/Space] Status · [x] Cancel · [h] Overrule · [Enter/z] Zoom");
          focused = Model.pane_focused model 0;
        }
      in
      let t_inner = Card.draw ~cache grid ~rect:tasks_rect ~theme t_spec in
      if not (Rect.is_empty t_inner) then begin
        if filtered_tasks = [] then
          Ops_common.draw_observed_empty grid ~rect:t_inner ~theme
            ~lang:model.lang model.work.planning
            ~empty_msg:(Say.make ~ko:"해당 작업 없음" ~en:"No matching tasks")
        else
          let cols : Table.column list =
            [
              {
                id = "st";
                header = Say.make ~ko:"상태" ~en:"Status";
                priority = 0;
                min_width = 10;
                max_width = Some 15;
                weight = 2;
                align = Table.Left;
              };
              {
                id = "title";
                header = Say.make ~ko:"작업" ~en:"Task";
                priority = 0;
                min_width = 16;
                max_width = None;
                weight = 5;
                align = Table.Left;
              };
              {
                id = "who";
                header = Say.make ~ko:"담당" ~en:"Assignee";
                priority = 1;
                min_width = 10;
                max_width = Some 18;
                weight = 2;
                align = Table.Left;
              };
              {
                id = "goal";
                header = Say.make ~ko:"목표" ~en:"Goal";
                priority = 2;
                min_width = 8;
                max_width = Some 14;
                weight = 1;
                align = Table.Left;
              };
            ]
          in
          let rows =
            List.map
              (fun (tk : Wire_work.task) ->
                let g, tok, lbl = Ops_common.task_status_badge tk.status in
                let who =
                  match Ops_common.task_assignee_opt tk.status with
                  | Some a -> a
                  | None -> Glyph.to_utf8 Glyph.Missing_absent
                in
                let goal_cell =
                  match tk.goal_link with
                  | Wire_work.Linked gid ->
                      Table.text_cell ~fg:(Color.of_rgb theme.status_ok) gid
                  | Wire_work.Unlinked ->
                      Table.Badge
                        {
                          glyph = Some Glyph.Warning_triangle;
                          text = Ops_common.say model ~ko:"미연결" ~en:"Unlinked";
                          tone = Theme.Status_attention;
                        }
                in
                {
                  Table.id = tk.id;
                  cells =
                    [
                      ( "st"
                      , Table.Badge
                          {
                            glyph = Some g;
                            text = Say.resolve model.lang lbl;
                            tone = tok;
                          } );
                      ("title", Table.text_cell (Printf.sprintf "%s %s" tk.id tk.title));
                      ("who", Table.text_cell ~fg:(Color.of_rgb theme.text_secondary) who);
                      ("goal", goal_cell);
                    ];
                })
              filtered_tasks
          in
          ignore
            (Table.draw grid ~rect:t_inner ~theme ~caps:Ops_common.default_caps
               ~lang:model.lang ~scroll:model.work.scroll_offset
               ?selected:task_sel_opt ~focused:(Model.pane_focused model 0)
               ~col_gap:(Layout.table_col_gap bp) ~columns:cols rows)
      end;
      (* 2. Task Detail Inspector *)
      if not (Rect.is_empty detail_rect) then begin
        let d_title, d_badge =
          match sel_task with
          | Some tk ->
              let g, tok, lbl = Ops_common.task_status_badge tk.status in
              ( Ops_common.say model ~ko:"작업 상세" ~en:"Task Detail"
              , Some { Card.glyph = Some g; text = Say.resolve model.lang lbl; tone = Some tok } )
          | None ->
              (Ops_common.say model ~ko:"작업 상세" ~en:"Task Detail", None)
        in
        let d_spec : Card.spec =
          {
            (Card.default_spec ~title:d_title) with
            badge = d_badge;
            hotkey =
              Some
                (if model.infra.show_raw_json then
                   Ops_common.say model ~ko:"[Space] 카드 · [↑↓] 스크롤 · [Esc] 닫기"
                     ~en:"[Space] Card · [↑↓] Scroll · [Esc] Close"
                 else
                   Ops_common.say model ~ko:"[Enter/z] 확대 · [Space] JSON · [x] 취소"
                     ~en:"[Enter/z] Zoom · [Space] JSON · [x] Cancel");
            focused = Model.detail_pane_focused ~detail_index:1 model;
          }
        in
        let d_inner = Card.draw ~cache grid ~rect:detail_rect ~theme d_spec in
        if not (Rect.is_empty d_inner) then
          let pad_x = Ops_common.pad_x_for ~model d_inner in
          let content = Card.pad_inner ~pad_x d_inner in
          let card_bg = Color.of_rgb theme.surface_1 in
          match sel_task with
          | None ->
              Ops_common.draw_observed_empty grid ~rect:d_inner ~theme
                ~lang:model.lang model.work.planning
                ~empty_msg:(Say.make ~ko:"작업을 선택하세요" ~en:"Select a task")
          | Some tk when model.infra.show_raw_json ->
              let scrubbed = Ops_common.scrub_json_secrets (json_of_task tk) in
              let lines =
                Json_tree.flatten ~max_depth:4 ~redact_secrets:true scrubbed
              in
              ignore
                (Json_tree.draw grid ~rect:content ~theme
                   ~scroll:model.nav.json_scroll_offset lines)
          | Some tk ->
              let y = ref d_inner.y in
              let bot = Rect.bottom d_inner in
              if d_inner.h >= 7 then begin
                let who_sub =
                  match Ops_common.task_assignee_opt tk.status with
                  | Some a -> Printf.sprintf "%s · @%s" tk.id a
                  | None -> tk.id
                in
                Card.draw_section_band ~pad_x grid
                  ~rect:(Rect.make ~x:d_inner.x ~y:!y ~w:d_inner.w ~h:2)
                  ~theme ~left_title:tk.title
                  ~right_meta:(Printf.sprintf "P%d" tk.priority)
                  ~subtitle:who_sub ();
                y := !y + 2 + (if d_inner.h >= 12 then 1 else 0)
              end;
              let started_str =
                match Ops_common.task_started_at_opt tk.status with
                | Some s -> s
                | None -> Glyph.to_utf8 Glyph.Missing_absent
              in
              if !y < bot then begin
                Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                  ~bg:card_bg ~label_w:12 ~key:"started_at" ~value:started_str
                  ~val_fg:theme.text_muted ~val_attrs:Attr.italic ();
                incr y
              end;
              if !y < bot then begin
                let gl_str, gl_fg =
                  match tk.goal_link with
                  | Wire_work.Linked gid ->
                      (Glyph.to_utf8 Glyph.Check_mark ^ " " ^ gid, theme.status_ok)
                  | Wire_work.Unlinked ->
                      ( Glyph.to_utf8 Glyph.Warning_triangle ^ " "
                        ^ Ops_common.say model ~ko:"미연결 (1회 연결 가능)"
                            ~en:"Unlinked (assignable once)"
                      , theme.status_attention )
                in
                Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                  ~bg:card_bg ~label_w:12
                  ~key:(Ops_common.say model ~ko:"목표 연결" ~en:"Goal Link")
                  ~value:gl_str ~val_fg:gl_fg ();
                incr y
              end;
              (match tk.status with
              | Wire_work.AwaitingVerification
                  { verification_id; submitted_at; _ }
                when !y < bot ->
                  Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                    ~bg:card_bg ~label_w:12
                    ~key:(Ops_common.say model ~ko:"검증 ID" ~en:"Verify ID")
                    ~value:(Printf.sprintf "%s · %s" verification_id submitted_at)
                    ~val_fg:theme.status_attention ();
                  incr y
              | Wire_work.Done { completed_at; notes; _ } when !y < bot ->
                  let note_s =
                    match notes with Some n -> " · " ^ n | None -> ""
                  in
                  Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                    ~bg:card_bg ~label_w:12
                    ~key:(Ops_common.say model ~ko:"완료 시각" ~en:"Completed")
                    ~value:(completed_at ^ note_s) ~val_fg:theme.text_muted
                    ~val_attrs:Attr.italic ();
                  incr y
              | Wire_work.Todo
              | Wire_work.Claimed _
              | Wire_work.InProgress _
              | Wire_work.AwaitingVerification _
              | Wire_work.Done _
              | Wire_work.Cancelled _ ->
                  ());
              let matching_v =
                List.find_opt
                  (fun (v : Wire_work.verification_request) ->
                    String.equal v.task_id tk.id)
                  (Work_store.verifications_list model.work)
              in
              (match matching_v with
              | Some v when !y < bot ->
                  let ev_str =
                    if v.submitted_evidence = [] then
                      Ops_common.say model ~ko:"증거 없음" ~en:"no evidence"
                    else String.concat ", " v.submitted_evidence
                  in
                  let value, color =
                    match verification_notice model with
                    | None -> ev_str, theme.status_active
                    | Some notice ->
                        Say.resolve model.lang notice ^ Typography.sep_dot ^ ev_str,
                        theme.status_attention
                  in
                  Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                    ~bg:card_bg ~label_w:12
                    ~key:(Ops_common.say model ~ko:"검증 증거" ~en:"Evidence")
                    ~value ~val_fg:color ();
                  incr y
              | Some _ | None -> ());
              (match tk.description with
              | Some desc when !y < bot ->
                  if bot - !y >= 3 then begin
                    Card.draw_hairline ~pad_x:0 ~bg:card_bg
                      ~label:(Ops_common.say model ~ko:"설명" ~en:"Description")
                      grid ~rect:content ~y:!y ~theme;
                    incr y
                  end;
                  let md_avail = Int.max 0 (bot - !y) in
                  let md_text = Ops_common.rewrite_masc_links_for_markdown desc in
                  let md_rect =
                    Rect.make ~x:content.x ~y:!y ~w:content.w ~h:md_avail
                  in
                  let total_md =
                    Markdown.draw grid ~rect:md_rect ~theme ~osc8:true
                      ~scroll:model.work.detail_scroll_offset md_text
                  in
                  if total_md > md_avail && md_avail >= 2 then begin
                    let more_n = total_md - (md_avail - 1) in
                    let more_s =
                      Ops_common.say model
                        ~ko:
                          (Printf.sprintf "▼ %d줄 더 · [Enter] 전체 보기" more_n)
                        ~en:
                          (Printf.sprintf "▼ %d more lines · [Enter] Full view"
                             more_n)
                    in
                    let footer_row =
                      Rect.make ~x:content.x ~y:(bot - 1) ~w:content.w ~h:1
                    in
                    Cell_grid.fill_rect ~clip:content grid ~rect:footer_row
                      ~style:(Typography.whisper ~bg:card_bg theme) ();
                    ignore
                      (Ops_common.put_line ~clip:footer_row grid ~x:content.x
                         ~y:(bot - 1) ~max_w:content.w
                         ~style:(Typography.whisper ~bg:card_bg theme)
                         more_s);
                    y := bot
                  end
                  else y := !y + Int.min md_avail total_md
              | Some _ | None -> ());
              if !y + 3 <= bot then begin
                incr y;
                Card.draw_hairline ~pad_x:0 ~bg:card_bg
                  ~label:
                    (Ops_common.say model ~ko:"연관 컨텍스트"
                       ~en:"Task Context")
                  grid ~rect:content ~y:!y ~theme;
                incr y;
                (match tk.created_at with
                | Some ts when !y < bot ->
                    Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                      ~bg:card_bg ~label_w:12
                      ~key:(Ops_common.say model ~ko:"생성 시각" ~en:"Created")
                      ~value:ts ~val_fg:theme.text_muted ~val_attrs:Attr.italic
                      ();
                    incr y
                | Some _ | None -> ());
                (match tk.updated_at with
                | Some ts when !y < bot ->
                    Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                      ~bg:card_bg ~label_w:12
                      ~key:(Ops_common.say model ~ko:"갱신 시각" ~en:"Updated")
                      ~value:ts ~val_fg:theme.text_muted ~val_attrs:Attr.italic
                      ();
                    incr y
                | Some _ | None -> ());
                (match tk.goal_link with
                | Wire_work.Linked gid -> (
                    match
                      List.find_opt
                        (fun (g : Wire_work.goal) -> String.equal g.id gid)
                        (Work_store.goals model.work)
                    with
                    | Some g when !y < bot ->
                        Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                          ~bg:card_bg ~label_w:12
                          ~key:(Ops_common.say model ~ko:"상위 목표" ~en:"Goal")
                          ~value:(Printf.sprintf "P%d %s" g.priority g.title)
                          ~val_fg:theme.status_ok ();
                        incr y;
                        if !y < bot && not (String.equal (String.trim g.measure) "")
                        then begin
                          Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                            ~bg:card_bg ~label_w:12
                            ~key:
                              (Ops_common.say model ~ko:"성공 조건" ~en:"Measure")
                            ~value:g.measure ~val_fg:theme.text_secondary ();
                          incr y
                        end
                    | Some _ | None -> ())
                | Wire_work.Unlinked ->
                    if !y < bot then begin
                      Card.draw_left_rail ~bg:card_bg ~tone:Theme.Status_attention
                        grid ~x:content.x ~y:!y ~h:1 ~theme;
                      ignore
                        (Ops_common.put_line ~clip:content grid ~x:(content.x + 2)
                           ~y:!y ~max_w:(Int.max 0 (content.w - 2))
                           ~style:(Typography.whisper ~bg:card_bg theme)
                           (Ops_common.say model
                              ~ko:"목표 미연결 · 완료 시 캔들 미귀속 ([Enter/z] 확대)"
                              ~en:"Unlinked · unattributed Candle on completion ([Enter/z] Zoom)"));
                      incr y
                    end;
                    let active_goals =
                      Work_store.goals model.work
                      |> List.filter (fun (g : Wire_work.goal) ->
                             match g.phase with
                             | Wire_work.Executing | Wire_work.Verifying
                             | Wire_work.Awaiting_confirmation ->
                                 true
                             | Wire_work.Completed | Wire_work.Dropped
                             | Wire_work.Paused _ | Wire_work.Blocked _ ->
                                 false)
                      |> List.take 3
                    in
                    List.iter
                      (fun (g : Wire_work.goal) ->
                        if !y < bot then begin
                          Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                            ~bg:card_bg ~label_w:12
                            ~key:(Printf.sprintf "P%d %s" g.priority g.id)
                            ~value:g.title ~val_fg:theme.text_secondary ();
                          incr y
                        end)
                      active_goals);
                (match matching_v with
                | Some v when !y < bot && v.completion_contract <> [] ->
                    List.iter
                      (fun item ->
                        if !y < bot then begin
                          Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                            ~bg:card_bg ~label_w:12
                            ~key:
                              (Ops_common.say model ~ko:"완료 계약"
                                 ~en:"Contract")
                            ~value:item ~val_fg:theme.text_secondary ();
                          incr y
                        end)
                      (List.take 3 v.completion_contract)
                | Some _ | None -> ())
              end
      end

(* --- Sub-Tab 3: Schedules (1st-class tab — always reachable even when empty) --- *)

let render_schedules ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Ops_common.theme_of_model model in
    let bp = Ops_common.layout_bp model in
    let filtered_scheds = Work_store.filtered_schedules model.work in
    let n_scheds = List.length filtered_scheds in
    let sched_sel_opt =
      if n_scheds > 0 then
        Some (Int.max 0 (Int.min (n_scheds - 1) model.work.selected_index))
      else None
    in
    let sched_rect, detail_rect =
      if model.nav.zoomed && Model.can_zoom_current_view model then
        (Rect.empty, rect)
      else if rect.w >= 96 then
        match
          Layout.split_h_bp bp rect [ Layout.Ratio 0.60; Layout.Flex 1 ]
        with
        | [ l; r ] -> (l, r)
        | _ -> (rect, Rect.empty)
      else
        match
          Layout.split_v_bp bp rect [ Layout.Ratio 0.58; Layout.Flex 1 ]
        with
        | [ t; b ] -> (t, b)
        | _ -> (rect, Rect.empty)
    in
    let has_more_scheds =
      match Observed.to_option model.work.schedules with
      | Some (_, Some _) -> true
      | Some (_, None) | None -> false
    in
    let s_spec : Card.spec =
      {
        (Card.default_spec
           ~title:
             (Printf.sprintf "%s (%d%s)"
                (Ops_common.say model ~ko:"예약 일정 · 최근 기상 판정"
                   ~en:"Schedules & Last Wake Disposition")
                n_scheds
                (if has_more_scheds then "+" else "")))
        with
        subtitle =
          (if has_more_scheds then
             Some (Ops_common.say model ~ko:"+더 있음" ~en:"+more")
           else None);
        hotkey =
          Some
            (Ops_common.say model ~ko:"[n] 일정 추가 · [/] 필터"
               ~en:"[n] New Schedule · [/] Filter");
        focused = Model.pane_focused model 0;
      }
    in
    let s_inner = Card.draw ~cache grid ~rect:sched_rect ~theme s_spec in
    if not (Rect.is_empty s_inner) then begin
      if filtered_scheds = [] then
        Ops_common.draw_observed_empty grid ~rect:s_inner ~theme
          ~lang:model.lang model.work.schedules
          ~empty_msg:
            (Say.make ~ko:"예약된 일정이 없습니다 · [n] 키로 새 일정 추가"
               ~en:"No scheduled automations · Press [n] to create one")
      else
        let cols : Table.column list =
          [
            {
              id = "st";
              header = Say.make ~ko:"상태" ~en:"Status";
              priority = 0;
              min_width = 9;
              max_width = Some 13;
              weight = 1;
              align = Table.Left;
            };
            {
              id = "target";
              header = Say.make ~ko:"키퍼/대상" ~en:"Keeper";
              priority = 0;
              min_width = 12;
              max_width = Some 20;
              weight = 2;
              align = Table.Left;
            };
            {
              id = "due";
              header = Say.make ~ko:"예정" ~en:"Next Due";
              priority = 1;
              min_width = 9;
              max_width = Some 13;
              weight = 1;
              align = Table.Left;
            };
            {
              id = "rec";
              header = Say.make ~ko:"주기" ~en:"Recurrence";
              priority = 2;
              min_width = 10;
              max_width = Some 18;
              weight = 2;
              align = Table.Left;
            };
            {
              id = "wake";
              header = Say.make ~ko:"최근 기상 결과" ~en:"Last Wake Disposition";
              priority = 1;
              min_width = 14;
              max_width = Some 26;
              weight = 3;
              align = Table.Left;
            };
            {
              id = "out";
              header = Say.make ~ko:"출력 요약" ~en:"Output Summary";
              priority = 3;
              min_width = 14;
              max_width = None;
              weight = 4;
              align = Table.Left;
            };
          ]
        in
        let now_unix = model.freshness.last_wall_unix in
        let rows =
          List.map
            (fun (sc : Wire_work.schedule_row) ->
              let sg, stok, slbl = Ops_common.schedule_status_badge sc.status in
              let target =
                match sc.payload_keeper_name, sc.payload_target with
                | Some k, _ -> k
                | None, Some t -> t
                | None, None -> sc.source
              in
              let is_terminal =
                match sc.status with
                | Wire_work.Sched_succeeded | Wire_work.Sched_cancelled
                | Wire_work.Sched_expired ->
                    true
                | Wire_work.Sched_scheduled | Wire_work.Sched_due
                | Wire_work.Sched_running | Wire_work.Sched_failed ->
                    false
              in
              let due_cell =
                if is_terminal && Option.is_none sc.next_due_at_unix then
                  Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                    (Glyph.to_utf8 Glyph.Missing_absent)
                else
                  let due_ts =
                    Option.value sc.next_due_at_unix ~default:sc.due_at_unix
                  in
                  let due_txt =
                    Ops_common.format_due_delta ~now_unix due_ts ~lang:model.lang
                  in
                  if
                    match sc.status with
                    | Wire_work.Sched_due -> true
                    | Wire_work.Sched_scheduled ->
                        now_unix > 0.0 && due_ts < now_unix
                    | Wire_work.Sched_running | Wire_work.Sched_succeeded
                    | Wire_work.Sched_failed | Wire_work.Sched_cancelled
                    | Wire_work.Sched_expired ->
                        false
                  then
                    Table.Badge
                      {
                        glyph = Some Glyph.Warning_triangle;
                        text = due_txt;
                        tone = Theme.Status_attention;
                      }
                  else
                    Table.text_cell ~fg:(Color.of_rgb theme.text_secondary) due_txt
              in
              let wake_txt, wake_tok =
                Ops_common.wake_disposition_text ~lang:model.lang
                  sc.last_disposition
              in
              let summary =
                match sc.payload_summary with
                | Some s -> s
                | None -> Glyph.to_utf8 Glyph.Missing_absent
              in
              {
                Table.id = sc.schedule_instance_id;
                cells =
                  [
                    ( "st"
                    , Table.Badge
                        {
                          glyph = Some sg;
                          text = Say.resolve model.lang slbl;
                          tone = stok;
                        } );
                    ("target", Table.text_cell target);
                    ("due", due_cell);
                    ( "rec"
                    , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                        ~attrs:Attr.italic sc.recurrence_summary );
                    ( "wake"
                    , Table.Badge
                        { glyph = None; text = wake_txt; tone = wake_tok } );
                    ("out", Table.text_cell summary);
                  ];
              })
            filtered_scheds
        in
        ignore
          (Table.draw grid ~rect:s_inner ~theme ~caps:Ops_common.default_caps
             ~lang:model.lang ~scroll:model.work.schedules_scroll_offset
             ?selected:sched_sel_opt ~focused:(Model.pane_focused model 0)
             ~col_gap:(Layout.table_col_gap bp) ~columns:cols rows)
    end;
    if not (Rect.is_empty detail_rect) then begin
      let sel_sched = Option.bind sched_sel_opt (List.nth_opt filtered_scheds) in
      let d_badge =
        match sel_sched with
        | Some sc ->
            let g, tok, lbl = Ops_common.schedule_status_badge sc.status in
            Some
              {
                Card.glyph = Some g;
                text = Say.resolve model.lang lbl;
                tone = Some tok;
              }
        | None -> None
      in
      let d_spec : Card.spec =
        {
          (Card.default_spec
             ~title:(Ops_common.say model ~ko:"일정 상세" ~en:"Schedule Detail"))
          with
          badge = d_badge;
          hotkey = Some (Ops_common.say model ~ko:"[n] 새 일정" ~en:"[n] New");
          focused = Model.detail_pane_focused ~detail_index:1 model;
        }
      in
      let d_inner = Card.draw ~cache grid ~rect:detail_rect ~theme d_spec in
      if not (Rect.is_empty d_inner) then
        let pad_x = Ops_common.pad_x_for ~model d_inner in
        let content = Card.pad_inner ~pad_x d_inner in
        let card_bg = Color.of_rgb theme.surface_1 in
        match sel_sched with
        | None ->
            Ops_common.draw_observed_empty grid ~rect:d_inner ~theme
              ~lang:model.lang model.work.schedules
              ~empty_msg:
                (Say.make ~ko:"일정을 선택하거나 [n]으로 새 일정을 만드세요"
                   ~en:"Select a schedule or press [n] to create one")
        | Some sc ->
            let y = ref d_inner.y in
            let bot = Rect.bottom d_inner in
            if d_inner.h >= 6 then begin
              Card.draw_section_band ~pad_x grid
                ~rect:(Rect.make ~x:d_inner.x ~y:!y ~w:d_inner.w ~h:2)
                ~theme ~left_title:sc.schedule_id
                ~right_meta:sc.recurrence_summary
                ~subtitle:
                  (match sc.payload_keeper_name with
                  | Some k -> "@" ^ k ^ " · " ^ sc.source
                  | None -> sc.source)
                ();
              y := !y + 2 + (if d_inner.h >= 10 then 1 else 0)
            end;
            let sg, stok, slbl = Ops_common.schedule_status_badge sc.status in
            if !y < bot then begin
              Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg:card_bg
                ~label_w:12
                ~key:(Ops_common.say model ~ko:"일정 상태" ~en:"Schedule")
                ~value:(Glyph.to_utf8 sg ^ " " ^ Say.resolve model.lang slbl)
                ~val_fg:(Theme.status_color theme stok) ();
              incr y
            end;
            let wake_txt, wake_tok =
              Ops_common.wake_disposition_text ~lang:model.lang
                sc.last_disposition
            in
            if !y < bot then begin
              Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg:card_bg
                ~label_w:12
                ~key:(Ops_common.say model ~ko:"최근 기상" ~en:"Last Wake")
                ~value:wake_txt ~val_fg:(Theme.status_color theme wake_tok) ();
              incr y
            end;
            if !y < bot then begin
              let is_terminal =
                match sc.status with
                | Wire_work.Sched_succeeded | Wire_work.Sched_cancelled
                | Wire_work.Sched_expired ->
                    true
                | Wire_work.Sched_scheduled | Wire_work.Sched_due
                | Wire_work.Sched_running | Wire_work.Sched_failed ->
                    false
              in
              let due_str =
                if is_terminal && Option.is_none sc.next_due_at_unix then
                  Ops_common.format_age
                    ~now_unix:model.freshness.last_wall_unix sc.due_at_unix
                    ~lang:model.lang
                else
                  let due_ts =
                    Option.value sc.next_due_at_unix ~default:sc.due_at_unix
                  in
                  Ops_common.format_due_delta
                    ~now_unix:model.freshness.last_wall_unix due_ts
                    ~lang:model.lang
              in
              Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg:card_bg
                ~label_w:12
                ~key:(Ops_common.say model ~ko:"예정 시각" ~en:"Due At")
                ~value:due_str
                ~val_fg:theme.text_muted ~val_attrs:Attr.italic ();
              incr y
            end;
            (match sc.last_wake_unix with
            | Some ts when !y < bot ->
                Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                  ~bg:card_bg ~label_w:12
                  ~key:(Ops_common.say model ~ko:"기상 시각" ~en:"Woke At")
                  ~value:
                    (Ops_common.format_age
                       ~now_unix:model.freshness.last_wall_unix ts
                       ~lang:model.lang)
                  ~val_fg:theme.text_muted ~val_attrs:Attr.italic ();
                incr y
            | Some _ | None -> ());
            if !y < bot then begin
              let summary_txt =
                match sc.payload_summary with
                | Some s when not (String.equal (String.trim s) "") -> s
                | Some _ | None -> Glyph.to_utf8 Glyph.Missing_absent
              in
              if bot - !y >= 3 then begin
                Card.draw_hairline ~pad_x:0 ~bg:card_bg
                  ~label:(Ops_common.say model ~ko:"출력 요약" ~en:"Summary")
                  grid ~rect:content ~y:!y ~theme;
                incr y;
                let md_rect =
                  Rect.make ~x:content.x ~y:!y ~w:content.w
                    ~h:(Int.max 0 (bot - !y))
                in
                ignore
                  (Markdown.draw grid ~rect:md_rect ~theme ~osc8:true
                     ~scroll:model.work.detail_scroll_offset summary_txt)
              end
              else
                Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg:card_bg
                  ~label_w:12
                  ~key:(Ops_common.say model ~ko:"출력 요약" ~en:"Summary")
                  ~value:summary_txt ()
            end
    end

(* --- Sub-Tab 3: Inbox (Rapid-Fire Triage + Clean Empty 24h Audit & Policy) --- *)

let decision_kind_label = function
  | Work_store.Decision_ask_answered ->
      (Glyph.Check_mark, Theme.Status_ok, Say.make ~ko:"질문 응답" ~en:"Ask Answered")
  | Work_store.Decision_tool_approved ->
      (Glyph.Check_mark, Theme.Status_ok, Say.make ~ko:"도구 승인" ~en:"Tool Approved")
  | Work_store.Decision_tool_denied ->
      (Glyph.Live_failing, Theme.Status_critical, Say.make ~ko:"도구 거절" ~en:"Tool Denied")
  | Work_store.Decision_gate_approved ->
      (Glyph.Check_mark, Theme.Status_ok, Say.make ~ko:"게이트 승인" ~en:"Gate Approved")
  | Work_store.Decision_gate_rejected ->
      (Glyph.Live_failing, Theme.Status_critical, Say.make ~ko:"게이트 거절" ~en:"Gate Rejected")
  | Work_store.Decision_goal_confirmed ->
      (Glyph.Check_mark, Theme.Status_ok, Say.make ~ko:"목표 확정" ~en:"Goal Confirmed")
  | Work_store.Decision_verification_approved ->
      (Glyph.Check_mark, Theme.Status_ok, Say.make ~ko:"검증 승인" ~en:"Verify Approved")
  | Work_store.Decision_verification_rejected ->
      (Glyph.Live_failing, Theme.Status_critical, Say.make ~ko:"검증 반려" ~en:"Verify Rejected")

let parse_json_or_wrap ~key raw =
  let trimmed = String.trim raw in
  if String.equal trimmed "" then `Assoc [ (key, `String "(empty)") ]
  else
    match Yojson.Safe.from_string trimmed with
    | json -> Ops_common.scrub_json_secrets json
    | exception Yojson.Json_error _ ->
        `Assoc [ (key, `String (Ops_common.scrub_secrets_in_text raw)) ]

let inbox_queue_status (model : Model.t) =
  let say = Ops_common.say model in
  let label = function
    | Work_store.Inbox_approvals -> say ~ko:"도구 승인" ~en:"Tool Approvals"
    | Work_store.Inbox_asks -> say ~ko:"Keeper 질문" ~en:"Keeper Asks"
    | Work_store.Inbox_gate -> "Channel Gate"
    | Work_store.Inbox_goals -> say ~ko:"Goal 확인" ~en:"Goal Confirm"
  in
  let status = function
    | Observed.Failed _ ->
        Some (0, Theme.Status_critical, Glyph.Live_failing, say ~ko:"조회 불가" ~en:"unavailable")
    | Observed.Value { stale = true; _ } ->
        Some (1, Theme.Status_attention, Glyph.Transport_stale, say ~ko:"마지막 조회" ~en:"last read")
    | Observed.Loading _ ->
        Some (2, Theme.Status_active, Glyph.Live_working, say ~ko:"불러오는 중" ~en:"loading")
    | Observed.Unreported ->
        Some (3, Theme.Status_historical, Glyph.Missing_unreported, say ~ko:"미관측" ~en:"unobserved")
    | Observed.Value _ | Observed.Absent -> None
  in
  let notices =
    Work_store.inbox_queue_reads model.work
    |> List.filter_map (fun (source, observed) ->
           Option.map
             (fun (priority, tone, glyph, state) ->
               priority, tone, glyph, label source ^ " " ^ state)
             (status observed))
    |> List.stable_sort (fun (left, _, _, _) (right, _, _, _) -> Int.compare left right)
  in
  match notices with
  | [] -> None
  | (_, tone, glyph, _) :: _ ->
      let text = notices |> List.map (fun (_, _, _, text) -> text) |> String.concat " · " in
      Some (tone, glyph, text)

let draw_inbox_queue_status ~(model : Model.t) ~banner_rect
    ~(theme : Theme.t) ~show_verifications grid (banner_tone, banner_glyph, banner_txt) =
  let bg = Color.of_rgb theme.surface_2 in
  let banner_st = Typography.status ~bg ~bold:true theme banner_tone in
  Cell_grid.fill_rect ~clip:banner_rect grid ~rect:banner_rect ~style:banner_st ();
  Card.draw_left_rail ~bg ~tone:banner_tone grid ~x:banner_rect.x
    ~y:banner_rect.y ~h:1 ~theme;
  let vp, vr, vw = Work_store.verification_pass_summary model.work in
  let verify_summary =
    if show_verifications && Option.is_none (verification_notice model)
       && vp + vr + vw > 0 && banner_rect.w >= 72 then
      let vs =
        Printf.sprintf "%s %d  ·  %s %d"
          (Ops_common.say model ~ko:"검증 통과" ~en:"Verify pass") vp
          (Ops_common.say model ~ko:"반려" ~en:"rej") vr
      in
      Some (vs, Grapheme.display_width vs)
    else None
  in
  let left_max_w =
    match verify_summary with
    | Some (_, sw) -> Int.max 0 (banner_rect.w - sw - 6)
    | None -> Int.max 0 (banner_rect.w - 3)
  in
  ignore
    (Ops_common.put_line ~clip:banner_rect grid ~x:(banner_rect.x + 2)
       ~y:banner_rect.y
       ~max_w:left_max_w
       ~style:banner_st
       (Glyph.to_utf8 banner_glyph ^ " " ^ banner_txt));
  (match verify_summary with
   | Some (vs, sw) ->
       ignore
         (Ops_common.put_line ~clip:banner_rect grid
            ~x:(Rect.right banner_rect - sw - 2)
            ~y:banner_rect.y ~max_w:sw
            ~style:(Typography.whisper ~bg theme)
            vs)
   | None -> ())

let render_inbox_empty ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~queue_status grid =
  let bp = Ops_common.layout_bp model in
  let banner_rect, split_rect =
    match Layout.split_v_bp bp rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ t; b ] -> (t, b)
    | _ -> Rect.split_v rect ~top_h:1
  in
  let status =
    Option.value queue_status
      ~default:
        ( Theme.Status_ok
        , Glyph.Live_healthy
        , Ops_common.say model ~ko:"수신함 모두 처리됨 · 대기 중인 승인/질문 0건"
            ~en:"Inbox Clear — 0 items awaiting operator decision" )
  in
  draw_inbox_queue_status ~model ~banner_rect ~theme ~show_verifications:true
    grid status;
  if Rect.is_empty split_rect then ()
  else
    let left_rect, right_rect =
      if split_rect.w >= 96 then
        match
          Layout.split_h_bp bp split_rect [ Layout.Ratio 0.56; Layout.Flex 1 ]
        with
        | [ l; r ] -> (l, r)
        | _ -> (split_rect, Rect.empty)
      else
        match
          Layout.split_v_bp bp split_rect [ Layout.Ratio 0.55; Layout.Flex 1 ]
        with
        | [ t; b ] -> (t, b)
        | _ -> (split_rect, Rect.empty)
    in
    (* Left/Top: Session Decisions + Server Gate Resolved Audit (honest provenance) *)
    let server_resolved, server_resolved_err, gate_loading, history_partial =
      match model.work.gate_snapshot with
      | Observed.Value { data = gs; _ } ->
          (gs.recent_resolved, gs.recent_resolved_error, false, gs.recent_resolved_partial)
      | Observed.Failed { reason; _ } -> ([], Some reason, false, false)
      | Observed.Loading _ -> ([], None, true, false)
      | Observed.Absent | Observed.Unreported -> ([], None, false, false)
    in
    let session_n = List.length model.work.recent_decisions_24h in
    let server_n = List.length server_resolved in
    let audit_title =
      if session_n > 0 then
        Printf.sprintf "%s (%d)"
          (Ops_common.say model ~ko:"이번 세션 결정 기록"
             ~en:"Session Decisions")
          session_n
      else if server_n > 0 then
        Printf.sprintf "%s (%d)"
          (Ops_common.say model ~ko:"서버 게이트 결정 이력"
             ~en:"Server Gate Decisions")
          server_n
      else
        Ops_common.say model ~ko:"이번 세션 결정 기록 (0)"
          ~en:"Session Decisions (0)"
    in
    let audit_subtitle =
      if server_n > 0
         && (Option.is_some server_resolved_err || Observed.is_stale model.work.gate_snapshot)
      then
        Some (Ops_common.say model ~ko:"서버 이력 · 마지막 조회" ~en:"Server history · last read")
      else if history_partial then
        Some (Ops_common.say model ~ko:"서버 이력 일부" ~en:"Partial server history")
      else if session_n > 0 then
        match server_resolved_err with
        | Some _ ->
            Some (Ops_common.say model ~ko:"서버 게이트 오류" ~en:"gate err")
        | None ->
            if server_n > 0 then
              Some
                (Ops_common.say model
                   ~ko:(Printf.sprintf "서버 %d건" server_n)
                   ~en:(Printf.sprintf "+%d server" server_n))
            else None
      else None
    in
    let audit_spec : Card.spec =
      {
        (Card.default_spec ~title:audit_title) with
        subtitle = audit_subtitle;
        focused = Model.body_has_focus model;
      }
    in
    let a_inner = Card.draw ~cache grid ~rect:left_rect ~theme audit_spec in
    if not (Rect.is_empty a_inner) then begin
      if session_n = 0 && server_n = 0 then begin
        let card_bg = Color.of_rgb theme.surface_1 in
        let pad_x = Ops_common.pad_x_for ~model a_inner in
        let content = Card.pad_inner ~pad_x ~pad_y:1 a_inner in
        (match server_resolved_err with
         | Some err ->
             let err = Ops_common.scrub_secrets_in_text err in
             ignore
               (Ops_common.put_line ~clip:content grid ~x:content.x ~y:content.y
                  ~max_w:content.w
                  ~style:(Typography.status ~bg:card_bg theme Theme.Status_critical)
                  (Glyph.to_utf8 Glyph.Live_failing ^ " "
                   ^ Ops_common.say model
                       ~ko:("서버 게이트 이력 조회 실패: " ^ err)
                       ~en:("Server gate history read failed: " ^ err)))
         | None ->
             if gate_loading then
               ignore
                 (Ops_common.put_line ~clip:content grid ~x:content.x ~y:content.y
                    ~max_w:content.w
                    ~style:(Typography.status ~bg:card_bg theme Theme.Status_active)
                    (Glyph.to_utf8 Glyph.Transport_reconnecting ^ " "
                     ^ Ops_common.say model
                         ~ko:"서버 게이트 이력 불러오는 중..."
                         ~en:"Loading server gate decision history..."))
             else
               ignore
                 (Ops_common.put_line ~clip:content grid ~x:content.x ~y:content.y
                    ~max_w:content.w
                    ~style:(Typography.primary ~bg:card_bg theme)
                    (Glyph.to_utf8 Glyph.Live_idle ^ " "
                     ^ Ops_common.say model
                       ~ko:"이번 TUI 세션에서 기록된 운영자 결정이 없습니다."
                       ~en:"No operator decisions recorded in this TUI session.")));
        if content.h >= 2 then
          ignore
            (Ops_common.put_line ~clip:content grid ~x:content.x
               ~y:(content.y + 1) ~max_w:content.w
               ~style:(Typography.whisper ~bg:card_bg theme)
               (Ops_common.say model
                  ~ko:"도구 승인·질문 응답·목표 확정·검증 판정 시 여기에 세션 기록이 남습니다."
                  ~en:"Session tool approvals, Ask answers, Goal confirmations & verdicts appear here."))
      end
      else
        let cols : Table.column list =
          [
            {
              id = "time";
              header = Say.make ~ko:"시각" ~en:"Time";
              priority = 1;
              min_width = 6;
              max_width = Some 8;
              weight = 1;
              align = Table.Right;
            };
            {
              id = "kind";
              header = Say.make ~ko:"결정" ~en:"Decision";
              priority = 0;
              min_width = 12;
              max_width = Some 17;
              weight = 2;
              align = Table.Left;
            };
            {
              id = "keeper";
              header = Say.make ~ko:"키퍼" ~en:"Keeper";
              priority = 2;
              min_width = 10;
              max_width = Some 18;
              weight = 2;
              align = Table.Left;
            };
            {
              id = "summary";
              header = Say.make ~ko:"요약" ~en:"Summary";
              priority = 0;
              min_width = 14;
              max_width = None;
              weight = 4;
              align = Table.Left;
            };
          ]
        in
        let rows =
          if session_n > 0 then
            List.map
              (fun (d : Work_store.decision_audit_entry) ->
                let g, tok, lbl = decision_kind_label d.kind in
                {
                  Table.id = d.target_id;
                  cells =
                    [
                      ( "time"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                          ~attrs:Attr.italic
                          (Ops_common.format_hhmm ~tz_offset_sec:model.tz_offset_sec
                             d.at_unix) );
                      ( "kind"
                      , Table.Badge
                          {
                            glyph = Some g;
                            text = Say.resolve model.lang lbl;
                            tone = tok;
                          } );
                      ( "keeper"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                          (match d.keeper with
                          | Some k -> k
                          | None -> Glyph.to_utf8 Glyph.Missing_absent) );
                      ("summary", Table.text_cell d.summary);
                    ];
                })
              model.work.recent_decisions_24h
          else
            List.map
              (fun (r : Wire_work.gate_resolved_row) ->
                let kind_raw = Option.value r.decision_kind ~default:r.decision in
                let kind_s = String.lowercase_ascii (String.trim kind_raw) in
                let approved =
                  String.equal kind_s "approve"
                  || String.equal kind_s "approved"
                  || String.equal kind_s "allow"
                in
                let g =
                  if approved then Glyph.Check_mark else Glyph.Live_failing
                in
                let tok =
                  if approved then Theme.Status_ok else Theme.Status_critical
                in
                let summary =
                  match r.decision_reason with
                  | Some reason when not (String.equal (String.trim reason) "") ->
                      r.tool ^ " · " ^ reason
                  | Some _ | None -> r.tool
                in
                {
                  Table.id = r.id;
                  cells =
                    [
                      ( "time"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                          ~attrs:Attr.italic
                          (Ops_common.format_hhmm ~tz_offset_sec:model.tz_offset_sec
                             r.ts) );
                      ( "kind"
                      , Table.Badge { glyph = Some g; text = kind_raw; tone = tok } );
                      ( "keeper"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                          r.keeper );
                      ("summary", Table.text_cell summary);
                    ];
                })
              server_resolved
        in
        ignore
          (Table.draw grid ~rect:a_inner ~theme ~caps:Ops_common.default_caps
             ~lang:model.lang ~scroll:model.work.detail_scroll_offset
             ~col_gap:(Layout.table_col_gap bp) ~columns:cols rows)
    end;
    (* Right/Bottom: Active Approval & Sandbox Policy Summary *)
    if not (Rect.is_empty right_rect) then begin
      let pol_spec : Card.spec =
        {
          (Card.default_spec
             ~title:
               (Ops_common.say model ~ko:"승인 · 샌드박스 정책 요약"
                  ~en:"Active Approval & Sandbox Policy"))
          with
          hotkey = Some "[Ctrl+,] Settings";
        }
      in
      let p_inner = Card.draw ~cache grid ~rect:right_rect ~theme pol_spec in
      if not (Rect.is_empty p_inner) then begin
        let p_bg = Color.of_rgb theme.surface_1 in
        let pad_x = Ops_common.pad_x_for ~model p_inner in
        let content = Card.pad_inner ~pad_x ~pad_y:1 p_inner in
        let y = ref content.y in
        let bot = Rect.bottom content in
        let sb_summary, net_summary =
          match Observed.to_option model.infra.sandboxes with
          | Some sb ->
              let net_none =
                List.fold_left
                  (fun acc (g : Wire_infra.microvm_guest) ->
                    match g.network_mode with
                    | Wire_infra.Net_none -> acc + 1
                    | Wire_infra.Net_inherit | Wire_infra.Net_policy -> acc)
                  0 sb.microvm_guests
              in
              ( Printf.sprintf "%d/%d microVM · %d SSH pools (%d keepers)"
                  sb.microvm_running sb.microvm_declared sb.ssh_pools_count
                  sb.ssh_keepers_count
              , Printf.sprintf "%d isolated (net=none) · %d shim mismatch"
                  net_none sb.microvm_shim_mismatch )
          | None ->
              let vm_n, ssh_n, dkr_n = Fleet_store.fleet_infra_counts model.fleet in
              if vm_n + ssh_n + dkr_n > 0 then
                ( Printf.sprintf "%dvm · %dssh · %ddkr" vm_n ssh_n dkr_n
                , Ops_common.say model ~ko:"상세 프로브 대기 중" ~en:"Detailed probe pending" )
              else
                ( Ops_common.say model ~ko:"샌드박스 스냅샷 대기 중"
                    ~en:"Sandbox snapshot pending"
                , Glyph.to_utf8 Glyph.Missing_absent )
        in
        Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg:p_bg
          ~label_w:14
          ~key:(Ops_common.say model ~ko:"샌드박스 플릿" ~en:"Sandbox Fleet")
          ~value:sb_summary ~val_fg:theme.status_ok ();
        incr y;
        Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg:p_bg
          ~label_w:14
          ~key:(Ops_common.say model ~ko:"네트워크 격리" ~en:"Net Isolation")
          ~value:net_summary ();
        incr y;
        let unfiltered_fleet = { model.fleet with filter_query = "" } in
        let auto_n, demand_n, manual_n =
          List.fold_left
            (fun (a, d, m) (k : Wire_fleet.keeper_summary) ->
              match k.activation_mode with
              | Wire_fleet.Activation_autonomous -> (a + 1, d, m)
              | Wire_fleet.Activation_on_demand -> (a, d + 1, m)
              | Wire_fleet.Activation_manual -> (a, d, m + 1))
            (0, 0, 0)
            (Fleet_store.filtered_keepers unfiltered_fleet)
        in
        Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme ~bg:p_bg
          ~label_w:14
          ~key:(Ops_common.say model ~ko:"활성화 정책" ~en:"Activation")
          ~value:
            (Printf.sprintf "AUTO %d  ·  ON-DEMAND %d  ·  MANUAL %d" auto_n
               demand_n manual_n)
          ();
        incr y;
        if !y + 1 < bot then begin
          Card.draw_hairline ~pad_x:0 ~bg:p_bg
            ~label:(Ops_common.say model ~ko:"빠른 트리아지 단축키" ~en:"Fast-Path Keys")
            grid ~rect:content ~y:!y ~theme;
          incr y;
          ignore
            (Ops_common.draw_keycap_bar grid
               ~rect:(Rect.make ~x:content.x ~y:!y ~w:content.w ~h:1)
               ~theme ~bg:p_bg
               [
                 ("Y", Ops_common.say model ~ko:"승인" ~en:"Approve");
                 ("N", Ops_common.say model ~ko:"거절" ~en:"Deny");
                 ("a..d", Ops_common.say model ~ko:"질문 선택" ~en:"Ask Choice");
               ])
        end
      end
    end

let attention_tag = function
  | Health.Held_tool_approval _ -> ("TOOL", Theme.Status_critical)
  | Health.Pending_ask _ -> ("ASK", Theme.Status_attention)
  | Health.Goal_confirmation _ -> ("GOAL", Theme.Status_active)

let render_inbox_gate_bar ~(model : Model.t) ~(rect : Rect.t) ~(theme : Theme.t)
    ~queue_current grid =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_0 in
    let rules_n = List.length (Work_store.gate_rules_list model.work) in
    let hist_n = List.length (Work_store.gate_resolved_list model.work) in
    let late_n = List.length (Work_store.late_approval_attempts_list model.work) in
    let queue_n = List.length model.attention.items in
    let pills =
      [
        ( Printf.sprintf "%s (%s)"
            (Ops_common.say model ~ko:"대기열" ~en:"Queue")
            (if queue_current then Int.to_string queue_n else "—")
        , Work_store.equal_inbox_subview model.work.inbox_subview
            Work_store.Inbox_queue
        , Some Theme.Status_attention );
        ( Printf.sprintf "%s (%d)"
            (Ops_common.say model ~ko:"Always-Approve 규칙" ~en:"Always Rules")
            rules_n
        , Work_store.equal_inbox_subview model.work.inbox_subview
            Work_store.Inbox_rules
        , Some Theme.Status_ok );
        ( Printf.sprintf "%s (%d%s)"
            (Ops_common.say model ~ko:"결정 이력" ~en:"History")
            hist_n
            (if late_n > 0 then Printf.sprintf " · !%d" late_n else "")
        , Work_store.equal_inbox_subview model.work.inbox_subview
            Work_store.Inbox_history
        , if late_n > 0 then Some Theme.Status_critical else Some Theme.Status_active );
      ]
    in
    let used = Ops_common.draw_pills grid ~rect ~theme ~bg pills in
    let status_txt =
      let mode_part =
        match Work_store.hitl_status model.work with
        | None -> ""
        | Some h ->
            let jl =
              match h.judge_lane with
              | Wire_work.Judge_lane_available { lane_id; _ } -> lane_id
              | Wire_work.Judge_lane_unavailable { reason; _ } ->
                  "off:" ^ Ops_common.scrub_secrets_in_text reason
            in
            Printf.sprintf "WS:%s · Ext:%s · Judge:%s"
              (Wire_work.gate_mode_to_string h.gate_mode.mode)
              (Wire_work.gate_mode_to_string h.external_gate_mode.mode)
              jl
      in
      let yolo_part =
        match Observed.to_option model.work.tool_approval_modes with
        | Some m when m.overrides <> [] ->
            let yolos =
              List.filter_map
                (fun (k, md) ->
                  match md with
                  | Wire_work.Approval_yolo -> Some k
                  | Wire_work.Approval_auto -> None)
                m.overrides
            in
            if yolos = [] then ""
            else Printf.sprintf " · YOLO(%d)" (List.length yolos)
        | Some _ | None -> ""
      in
      let hint =
        Ops_common.say model ~ko:"[v] 전환 · /gate" ~en:"[v] View · /gate"
      in
      if String.equal mode_part "" then hint ^ yolo_part
      else mode_part ^ yolo_part ^ " · " ^ hint
    in
    let avail = rect.w - used - 2 in
    if avail >= 8 then
      ignore
        (Ops_common.put_line ~clip:rect grid ~x:(rect.x + used + 2) ~y:rect.y
           ~max_w:avail ~style:(Typography.whisper ~bg theme) status_txt)

let render_inbox_rules ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) grid =
  let bp = Ops_common.layout_bp model in
  let rules = Work_store.filtered_gate_rules model.work in
  let rules_err =
    match Observed.to_option model.work.gate_snapshot with
    | Some s -> s.rules_error
    | None -> None
  in
  let left_rect, right_rect =
    if model.nav.zoomed && Model.can_zoom_current_view model then
      (Rect.empty, rect)
    else if rect.w >= 96 then
      match Layout.split_h_bp bp rect [ Layout.Ratio 0.56; Layout.Flex 1 ] with
      | [ l; r ] -> (l, r)
      | _ -> (rect, Rect.empty)
    else
      match Layout.split_v_bp bp rect [ Layout.Ratio 0.52; Layout.Flex 1 ] with
      | [ t; b ] -> (t, b)
      | _ -> (rect, Rect.empty)
  in
  let l_spec : Card.spec =
    {
      (Card.default_spec
         ~title:
           (Printf.sprintf "%s (%d)"
              (Ops_common.say model ~ko:"Always-Approve 규칙"
                 ~en:"Always-Approve Rules")
              (List.length rules)))
      with
      hotkey =
        Some
          (Ops_common.say model
             ~ko:"[x] 삭제 · /gate del-rule <id> · /gate mode <m>"
             ~en:"[x] Delete · /gate del-rule <id> · /gate mode <m>");
      focused = Model.pane_focused model 0;
    }
  in
  let l_inner = Card.draw ~cache grid ~rect:left_rect ~theme l_spec in
  if not (Rect.is_empty l_inner) then begin
    match rules_err with
    | Some raw_err ->
        let err = Ops_common.scrub_secrets_in_text raw_err in
        Ops_common.draw_observed_empty grid ~rect:l_inner ~theme ~lang:model.lang
          (Observed.failed ~reason:err ~retryable:true ~at:Clock.Mono.zero)
          ~empty_msg:(Say.make ~ko:err ~en:err)
    | None when rules = [] ->
        Ops_common.draw_observed_empty grid ~rect:l_inner ~theme ~lang:model.lang
          model.work.gate_snapshot
          ~empty_msg:
            (Say.make
               ~ko:"저장된 Always-Approve 규칙이 없습니다 (/gate approve-always <id>)"
               ~en:"No Always-Approve rules saved (/gate approve-always <id>)")
    | None ->
        let cols : Table.column list =
          [
            {
              id = "keeper";
              header = Say.make ~ko:"키퍼" ~en:"Keeper";
              priority = 0;
              min_width = 10;
              max_width = Some 18;
              weight = 2;
              align = Table.Left;
            };
            {
              id = "tool";
              header = Say.make ~ko:"도구" ~en:"Tool";
              priority = 0;
              min_width = 14;
              max_width = None;
              weight = 4;
              align = Table.Left;
            };
            {
              id = "exp";
              header = Say.make ~ko:"만료" ~en:"Expires";
              priority = 1;
              min_width = 8;
              max_width = Some 14;
              weight = 1;
              align = Table.Right;
            };
            {
              id = "id";
              header = Say.make ~ko:"ID" ~en:"ID";
              priority = 2;
              min_width = 8;
              max_width = Some 14;
              weight = 2;
              align = Table.Left;
            };
          ]
        in
        let rows =
          List.map
            (fun (r : Wire_work.gate_rule) ->
              let exp_s =
                match r.expires_at with
                | None -> Ops_common.say model ~ko:"영구" ~en:"never"
                | Some ts ->
                    if ts <= model.freshness.last_wall_unix then
                      Ops_common.say model ~ko:"만료됨" ~en:"expired"
                    else
                      let rem =
                        Float.max 0.0 (ts -. model.freshness.last_wall_unix)
                      in
                      let dur = Format_val.format_duration_s rem in
                      Ops_common.say model ~ko:(dur ^ " 후") ~en:("in " ^ dur)
              in
              {
                Table.id = r.id;
                cells =
                  [
                    ("keeper", Table.text_cell ("@" ^ r.keeper_name));
                    ("tool", Table.text_cell r.tool_name);
                    ("exp", Table.text_cell exp_s);
                    ( "id"
                    , Table.text_cell ~fg:(Color.of_rgb theme.text_muted) r.id );
                  ];
              })
            rules
        in
        let sel =
          Int.max 0
            (Int.min (List.length rules - 1) model.work.rule_selected_index)
        in
        ignore
          (Table.draw grid ~rect:l_inner ~theme ~caps:Ops_common.default_caps
             ~lang:model.lang ~scroll:model.work.rule_scroll_offset ~selected:sel
             ~focused:(Model.pane_focused model 0)
             ~col_gap:(Layout.table_col_gap bp) ~columns:cols rows)
  end;
  if not (Rect.is_empty right_rect) then begin
    let r_spec : Card.spec =
      {
        (Card.default_spec
           ~title:
             (Ops_common.say model ~ko:"규칙 상세 · Gate 정책"
                ~en:"Rule Detail · Gate Policy"))
        with
        focused = Model.detail_pane_focused ~detail_index:1 model;
      }
    in
    let r_inner = Card.draw ~cache grid ~rect:right_rect ~theme r_spec in
    if not (Rect.is_empty r_inner) then begin
      let card_bg = Color.of_rgb theme.surface_1 in
      let pad_x = Ops_common.pad_x_for ~model r_inner in
      let content = Card.pad_inner ~pad_x r_inner in
      let rows_to_draw = ref [] in
      let push_row row = rows_to_draw := row :: !rows_to_draw in
      (match Work_store.selected_gate_rule model.work with
       | None -> ()
       | Some r ->
           push_row (`Kv ("Rule ID", r.id));
           push_row (`Kv ("Keeper", "@" ^ r.keeper_name));
           push_row (`Kv ("Tool", r.tool_name));
           push_row (`Kv ("Fingerprint", r.request_fingerprint));
           push_row (`Kv ("Created By", Option.value r.created_by ~default:"—"));
           push_row `Blank);
      push_row
        (`Rule
           (Ops_common.say model ~ko:"Gate 모드 & 키퍼 오버라이드"
              ~en:"Gate Modes & Keeper Overrides"));
      (match Work_store.hitl_status model.work with
       | Some h ->
           push_row
             (`Kv
                ( "Workspace"
                , Printf.sprintf "%s (%s)"
                    (Wire_work.gate_mode_to_string h.gate_mode.mode)
                    h.gate_mode.state ));
           push_row
             (`Kv
                ( "External"
                , Printf.sprintf "%s (%s)"
                    (Wire_work.gate_mode_to_string h.external_gate_mode.mode)
                    h.external_gate_mode.state ))
       | None -> ());
      (match Observed.to_option model.work.tool_approval_modes with
       | Some tm ->
           let ov_s =
             if tm.overrides = [] then
               Ops_common.say model ~ko:"없음 (전체 auto)" ~en:"none (all auto)"
             else
               tm.overrides
               |> List.map (fun (k, md) ->
                      Printf.sprintf "%s=%s" k
                        (Wire_work.keeper_tool_approval_mode_to_string md))
               |> String.concat ", "
           in
           push_row (`Kv ("Overrides", ov_s))
       | None -> ());
      let ordered = List.rev !rows_to_draw in
      let skip =
        Int.max 0
          (Int.min
             (Int.max 0 (List.length ordered - content.h))
             model.work.detail_scroll_offset)
      in
      let bot = Rect.bottom content in
      List.iteri
        (fun idx row ->
          if idx >= skip && content.y + idx - skip < bot then
            let y = content.y + idx - skip in
            match row with
            | `Blank -> ()
            | `Rule title ->
                Ops_common.draw_hrule grid ~rect:content ~y ~theme ~bg:card_bg
                  ~title ()
            | `Kv (key, value) ->
                Ops_common.draw_kv_row grid ~rect:content ~y ~theme ~bg:card_bg
                  ~label_w:12 ~key ~value ())
        ordered
    end
  end

let render_inbox_history ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) grid =
  let bp = Ops_common.layout_bp model in
  let rows_data = Work_store.filtered_gate_resolved model.work in
  let late_rows = Work_store.late_approval_attempts_list model.work in
  let hist_err, history_partial =
    match Observed.to_option model.work.gate_snapshot with
    | Some s -> s.recent_resolved_error, s.recent_resolved_partial
    | None -> None, false
  in
  let history_is_last_read =
    Observed.is_stale model.work.gate_snapshot
    || (Option.is_some hist_err && Work_store.gate_resolved_list model.work <> [])
  in
  let history_status =
    match history_is_last_read, history_partial with
    | true, true ->
        Some (Ops_common.say model ~ko:"마지막 조회 · 일부 범위" ~en:"Last read · partial range")
    | true, false -> Some (Ops_common.say model ~ko:"마지막 조회" ~en:"Last read")
    | false, true ->
        Some (Ops_common.say model ~ko:"서버 이력 일부" ~en:"Partial server history")
    | false, false -> None
  in
  let top_rect, bot_rect =
    if late_rows <> [] || Observed.is_failed model.work.late_approval_attempts
    then
      match Layout.split_v_bp bp rect [ Layout.Ratio 0.65; Layout.Flex 1 ] with
      | [ t; b ] -> (t, b)
      | _ -> (rect, Rect.empty)
    else (rect, Rect.empty)
  in
  let t_spec : Card.spec =
    {
      (Card.default_spec
         ~title:
           (Printf.sprintf "%s (%d)"
              (Ops_common.say model ~ko:"최근 Gate 결정 이력"
                 ~en:"Recent Gate Decisions")
              (List.length rows_data)))
      with
      focused = Model.pane_focused model 0;
      subtitle = history_status;
    }
  in
  let t_inner = Card.draw ~cache grid ~rect:top_rect ~theme t_spec in
  if not (Rect.is_empty t_inner) then begin
    match hist_err with
    | Some raw_err when rows_data = [] ->
        let err = Ops_common.scrub_secrets_in_text raw_err in
        Ops_common.draw_observed_empty grid ~rect:t_inner ~theme ~lang:model.lang
          (Observed.failed ~reason:err ~retryable:true ~at:Clock.Mono.zero)
          ~empty_msg:(Say.make ~ko:err ~en:err)
    | None when rows_data = [] ->
        Ops_common.draw_observed_empty grid ~rect:t_inner ~theme ~lang:model.lang
          model.work.gate_snapshot
          ~empty_msg:
            (if history_partial then
               Say.make ~ko:"확인된 범위에 Gate 결정이 없습니다"
                 ~en:"No Gate decisions in the observed range"
             else
               Say.make ~ko:"최근 처리된 Gate 결정이 없습니다"
                 ~en:"No recent resolved Gate decisions")
    | Some _ | None ->
        let cols : Table.column list =
          [
            {
              id = "dec";
              header = Say.make ~ko:"결정" ~en:"Decision";
              priority = 0;
              min_width = 8;
              max_width = Some 12;
              weight = 1;
              align = Table.Left;
            };
            {
              id = "keeper";
              header = Say.make ~ko:"키퍼" ~en:"Keeper";
              priority = 0;
              min_width = 10;
              max_width = Some 16;
              weight = 2;
              align = Table.Left;
            };
            {
              id = "tool";
              header = Say.make ~ko:"도구" ~en:"Tool";
              priority = 0;
              min_width = 14;
              max_width = None;
              weight = 4;
              align = Table.Left;
            };
            {
              id = "src";
              header = Say.make ~ko:"출처" ~en:"Source";
              priority = 1;
              min_width = 10;
              max_width = Some 18;
              weight = 2;
              align = Table.Left;
            };
            {
              id = "age";
              header = Say.make ~ko:"시각" ~en:"Age";
              priority = 2;
              min_width = 6;
              max_width = Some 10;
              weight = 1;
              align = Table.Right;
            };
          ]
        in
        let tbl_rows =
          List.map
            (fun (r : Wire_work.gate_resolved_row) ->
              let kind_s =
                Option.value r.decision_kind ~default:r.decision
              in
              let tone =
                if String.equal kind_s "approve" then Theme.Status_ok
                else Theme.Status_critical
              in
              let src_s =
                match (r.decision_source, r.actor) with
                | Some s, Some a -> Printf.sprintf "%s (%s)" s a
                | Some s, None -> s
                | None, Some a -> a
                | None, None -> "—"
              in
              {
                Table.id = r.id;
                cells =
                  [
                    ( "dec"
                    , Table.Badge { glyph = None; text = kind_s; tone } );
                    ("keeper", Table.text_cell ("@" ^ r.keeper));
                    ("tool", Table.text_cell r.tool);
                    ( "src"
                    , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                        src_s );
                    ( "age"
                    , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                        (Ops_common.format_age
                           ~now_unix:model.freshness.last_wall_unix r.ts
                           ~lang:model.lang) );
                  ];
              })
            rows_data
        in
        let sel =
          Int.max 0
            (Int.min (List.length rows_data - 1) model.work.history_selected_index)
        in
        ignore
          (Table.draw grid ~rect:t_inner ~theme ~caps:Ops_common.default_caps
             ~lang:model.lang ~scroll:model.work.history_scroll_offset
             ~selected:sel ~focused:(Model.pane_focused model 0)
             ~col_gap:(Layout.table_col_gap bp) ~columns:cols tbl_rows)
  end;
  if not (Rect.is_empty bot_rect) then begin
    let b_spec : Card.spec =
      {
        (Card.default_spec
           ~title:
             (Printf.sprintf "%s (%d)"
                (Ops_common.say model ~ko:"불확실 늦은 승인 시도 (HITL Recovery)"
                   ~en:"Uncertain Late-Approval Attempts (HITL Recovery)")
                (List.length late_rows)))
        with
        hotkey =
          Some
            "/gate ack-uncertain <keeper> <consume_id> · /gate restore-late";
      }
    in
    let b_inner = Card.draw ~cache grid ~rect:bot_rect ~theme b_spec in
    if not (Rect.is_empty b_inner) then begin
      match model.work.late_approval_attempts with
      | Observed.Failed { reason; retryable; at } ->
          let clean = Ops_common.scrub_secrets_in_text reason in
          Ops_common.draw_observed_empty grid ~rect:b_inner ~theme
            ~lang:model.lang
            (Observed.failed ~reason:clean ~retryable ~at)
            ~empty_msg:(Say.make ~ko:clean ~en:clean)
      | Observed.Value _ | Observed.Loading _ | Observed.Absent
      | Observed.Unreported ->
          let card_bg = Color.of_rgb theme.surface_1 in
          let content = Card.pad_inner ~pad_x:(Ops_common.pad_x_for ~model b_inner) b_inner in
          List.iteri
            (fun i (a : Wire_work.late_approval_attempt) ->
              if content.y + i < Rect.bottom content then
                ignore
                  (Ops_common.put_line ~clip:content grid ~x:content.x
                     ~y:(content.y + i) ~max_w:content.w
                     ~style:(Typography.primary ~bg:card_bg theme)
                     (Printf.sprintf "@%s · %s · consume=%s · %s" a.keeper_name
                        a.tool_name a.consume_id a.outcome)))
            late_rows
    end
  end

let render_inbox ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Ops_common.theme_of_model model in
    let bp = Ops_common.layout_bp model in
    let bar_rect, body_rect = Work_store.inbox_subview_rects rect in
    let queue_status = inbox_queue_status model in
    let queue_current = Option.is_none queue_status in
    render_inbox_gate_bar ~model ~rect:bar_rect ~theme ~queue_current grid;
    match model.work.inbox_subview with
    | Work_store.Inbox_rules ->
        render_inbox_rules ~model ~cache ~rect:body_rect ~theme grid
    | Work_store.Inbox_history ->
        render_inbox_history ~model ~cache ~rect:body_rect ~theme grid
    | Work_store.Inbox_queue ->
    if Attention.is_empty model.attention then
      render_inbox_empty ~model ~cache ~rect:body_rect ~theme ~queue_status grid
    else
      let banner_rect, rect = Work_store.inbox_queue_rects body_rect model.work in
      if not (Rect.is_empty banner_rect) then
        Option.iter (draw_inbox_queue_status ~model ~banner_rect ~theme
                       ~show_verifications:false grid) queue_status;
      let filtered_attn =
        Attention.filtered_items ~query:model.work.filter_query model.attention
      in
      let sel_attn =
        Attention.selected_index_in_filtered ~query:model.work.filter_query
          model.attention
      in
      let selected_attn = Option.bind sel_attn (List.nth_opt filtered_attn) in
      let left_rect, right_rect =
        if Option.is_none selected_attn then (rect, Rect.empty)
        else if model.nav.zoomed && Model.can_zoom_current_view model then
          (Rect.empty, rect)
        else if rect.w >= 96 then
          match
            Layout.split_h_bp bp rect [ Layout.Ratio 0.42; Layout.Flex 1 ]
          with
          | [ l; r ] -> (l, r)
          | _ -> (rect, Rect.empty)
        else
          match
            Layout.split_v_bp bp rect [ Layout.Ratio 0.38; Layout.Flex 1 ]
          with
          | [ t; b ] -> (t, b)
          | _ -> (rect, Rect.empty)
      in
      let q_spec : Card.spec =
        {
          (Card.default_spec
             ~title:
               (Ops_common.say model ~ko:"긴급도순 대기열" ~en:"Urgency Queue"))
          with
          badge =
            (if queue_current then
               Some
                 {
                   Card.glyph = Some Glyph.Action_required;
                   text = Int.to_string (List.length filtered_attn);
                   tone = Some Theme.Status_attention;
                 }
             else None);
          focused = Model.pane_focused model 0;
        }
      in
      let l_inner = Card.draw ~cache grid ~rect:left_rect ~theme q_spec in
      if not (Rect.is_empty l_inner) then begin
        if filtered_attn = [] then
          Ops_common.draw_observed_empty grid ~rect:l_inner ~theme
            ~lang:model.lang (Observed.value ~observed_at:Clock.Mono.zero ())
            ~empty_msg:
              (Say.make ~ko:"필터와 일치하는 수신함 항목이 없습니다"
                 ~en:"No inbox items match the filter")
        else
          let cols : Table.column list =
            [
              {
                id = "kind";
                header = Say.make ~ko:"유형" ~en:"Type";
                priority = 0;
                min_width = 7;
                max_width = Some 8;
                weight = 1;
                align = Table.Left;
              };
              {
                id = "title";
                header = Say.make ~ko:"내용" ~en:"Item";
                priority = 0;
                min_width = 14;
                max_width = None;
                weight = 4;
                align = Table.Left;
              };
              {
                id = "keeper";
                header = Say.make ~ko:"키퍼" ~en:"Keeper";
                priority = 1;
                min_width = 10;
                max_width = Some 16;
                weight = 2;
                align = Table.Left;
              };
              {
                id = "age";
                header = Say.make ~ko:"경과" ~en:"Age";
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
              (fun (e : Attention.entry) ->
                let tag, tok = attention_tag e.kind in
                let inflight =
                  if Attention.is_in_flight ~id:e.id model.attention then " …"
                  else ""
                in
                let age_s =
                  match e.created_at_unix with
                  | Some ts ->
                      Ops_common.format_age
                        ~now_unix:model.freshness.last_wall_unix ts
                        ~lang:model.lang
                  | None -> Glyph.to_utf8 Glyph.Missing_absent
                in
                {
                  Table.id = e.id;
                  cells =
                    [
                      ( "kind"
                      , Table.Badge
                          {
                            glyph = Some Glyph.Action_required;
                            text = tag;
                            tone = tok;
                          } );
                      ("title", Table.text_cell (e.title ^ inflight));
                      ( "keeper"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                          (match e.keeper with Some k -> k | None -> "-") );
                      ( "age"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                          ~attrs:Attr.italic age_s );
                    ];
                })
              filtered_attn
          in
          ignore
            (Table.draw grid ~rect:l_inner ~theme ~caps:Ops_common.default_caps
               ~lang:model.lang ~scroll:model.attention.triage_scroll_offset
               ?selected:sel_attn ~focused:(Model.pane_focused model 0)
               ~col_gap:(Layout.table_col_gap bp) ~columns:cols rows)
      end;
      if not (Rect.is_empty right_rect) then
        match selected_attn with
        | None ->
            let p_spec : Card.spec =
              {
                (Card.default_spec
                   ~title:
                     (Ops_common.say model ~ko:"승인 · 응답 인스펙터"
                        ~en:"Triage Inspector"))
                with
                focused = Model.pane_focused model 1;
              }
            in
            let p_inner = Card.draw ~cache grid ~rect:right_rect ~theme p_spec in
            if not (Rect.is_empty p_inner) then
              if not (String.equal (String.trim model.work.filter_query) "") then
                Ops_common.draw_observed_empty grid ~rect:p_inner ~theme
                  ~lang:model.lang
                  (Observed.value ~observed_at:Clock.Mono.zero ())
                  ~empty_msg:
                    (Say.make ~ko:"필터 결과 없음 — [Esc]로 필터 초기화"
                       ~en:"No matching items — press [Esc] to clear filter")
              else
                Ops_common.draw_observed_empty grid ~rect:p_inner ~theme
                  ~lang:model.lang model.work.asks
                  ~empty_msg:
                    (Say.make ~ko:"선택된 항목이 없습니다"
                       ~en:"No item selected")
        | Some entry ->
            let tag, tok = attention_tag entry.kind in
            let p_spec : Card.spec =
              {
                (Card.default_spec
                   ~title:
                     (Ops_common.say model ~ko:"승인 · 응답 인스펙터"
                        ~en:"Triage Inspector"))
                with
                subtitle = entry.keeper;
                badge =
                  Some
                    {
                      Card.glyph = Some Glyph.Action_required;
                      text = tag;
                      tone = Some tok;
                    };
                hotkey =
                  Some
                    (match entry.payload with
                    | Attention.Payload_ask ask ->
                        let instant_single =
                          match ask.questions with
                          | [ q ] -> (
                              match q.mode with
                              | Wire_work.Ask_single -> true
                              | Wire_work.Ask_multi -> false)
                          | [] | _ :: _ :: _ -> false
                        in
                        if instant_single then
                          if Model.detail_pane_focused ~detail_index:1 model then
                            Ops_common.say model
                              ~ko:"[a..d] 선택 · [Enter/Y] 모달 · [N] 건너뛰기 · [^B] 메뉴"
                              ~en:"[a..d] Choose · [Enter/Y] Modal · [N] Skip · [^B] Menu"
                          else
                            Ops_common.say model
                              ~ko:"[Enter/Y] 답변 · [Tab] 선택지[a..d] · [N] 건너뛰기"
                              ~en:"[Enter/Y] Answer · [Tab] Choices[a..d] · [N] Skip"
                        else
                          Ops_common.say model
                            ~ko:"[Enter/Y] 답변 모달 · [N] 건너뛰기"
                            ~en:"[Enter/Y] Answer Modal · [N] Skip"
                    | Attention.Payload_tool_approval _ ->
                        Ops_common.say model
                          ~ko:"[Y] 승인 · [N] 거절"
                          ~en:"[Y] Approve · [N] Deny"
                    | Attention.Payload_gate _ ->
                        Ops_common.say model
                          ~ko:"[Y] 승인 · [N] 거절 (사유)"
                          ~en:"[Y] Approve · [N] Reject"
                    | Attention.Payload_goal_confirmation _ ->
                        Ops_common.say model
                          ~ko:"[Enter/Y] 목표 상세"
                          ~en:"[Enter/Y] Goal Detail");
                focused = Model.detail_pane_focused ~detail_index:1 model;
              }
            in
            let r_inner = Card.draw ~cache grid ~rect:right_rect ~theme p_spec in
            if not (Rect.is_empty r_inner) then begin
              let card_bg = Color.of_rgb theme.surface_1 in
              let pad_x = Ops_common.pad_x_for ~model r_inner in
              let content = Card.pad_inner ~pad_x r_inner in
              let y = ref r_inner.y in
              let bot = Rect.bottom r_inner in
              if r_inner.h >= 7 then begin
                let age_meta =
                  match entry.created_at_unix with
                  | Some ts ->
                      Ops_common.format_age
                        ~now_unix:model.freshness.last_wall_unix ts
                        ~lang:model.lang
                  | None -> tag
                in
                let sub =
                  match entry.keeper with
                  | Some k -> Some (Printf.sprintf "@%s · %s" k entry.summary)
                  | None -> Some entry.summary
                in
                Card.draw_section_band ~pad_x grid
                  ~rect:(Rect.make ~x:r_inner.x ~y:!y ~w:r_inner.w ~h:2)
                  ~theme ~left_title:entry.title ~right_meta:age_meta
                  ?subtitle:sub ();
                y := !y + 2 + (if r_inner.h >= 12 then 1 else 0)
              end;
              match entry.payload with
              | Attention.Payload_tool_approval ta ->
                  Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                    ~bg:card_bg ~label_w:12
                    ~key:(Ops_common.say model ~ko:"도구" ~en:"Tool")
                    ~value:(Printf.sprintf "%s (@%s)" ta.tool ta.keeper)
                    ~val_fg:theme.status_critical ~val_attrs:Attr.bold ();
                  incr y;
                  let remaining = bot - !y in
                  let q_h =
                    if remaining < 2 then 0
                    else Int.min 4 (Int.max 1 (remaining - 4))
                  in
                  if q_h >= 1 then begin
                    let q_rect =
                      Rect.make ~x:content.x ~y:!y ~w:content.w ~h:q_h
                    in
                    ignore
                      (Markdown.draw grid ~rect:q_rect ~theme ~osc8:true
                         ~scroll:model.work.detail_scroll_offset
                         (Ops_common.rewrite_masc_links_for_markdown
                            (Model.tool_approval_markdown ~lang:model.lang ta)));
                    y := !y + q_h
                  end;
                  if !y < bot - 2 then begin
                    Card.draw_hairline ~pad_x:0 ~bg:card_bg
                      ~label:
                        (Ops_common.say model ~ko:"도구 인자 (Json_tree)"
                           ~en:"Tool Arguments (Json_tree)")
                      grid ~rect:content ~y:!y ~theme;
                    incr y;
                    let jt_rect =
                      Rect.make ~x:content.x ~y:!y ~w:content.w
                        ~h:(Int.max 0 (bot - !y - 1))
                    in
                    let json = parse_json_or_wrap ~key:"args" ta.args_preview in
                    let lines =
                      Json_tree.flatten ~max_depth:3 ~redact_secrets:true json
                    in
                    ignore
                      (Json_tree.draw grid ~rect:jt_rect ~theme
                         ~scroll:model.work.detail_scroll_offset lines)
                  end;
                  if bot > r_inner.y then
                    ignore
                      (Ops_common.draw_keycap_bar grid
                         ~rect:
                           (Rect.make ~x:content.x ~y:(bot - 1) ~w:content.w
                              ~h:1)
                         ~theme ~bg:card_bg
                         [
                           ("Y", Ops_common.say model ~ko:"승인" ~en:"Approve");
                           ("N", Ops_common.say model ~ko:"거절" ~en:"Deny");
                         ])
              | Attention.Payload_gate g ->
                  Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                    ~bg:card_bg ~label_w:12
                    ~key:(Ops_common.say model ~ko:"게이트" ~en:"Gate")
                    ~value:(Printf.sprintf "@%s · %s (%s)" g.keeper g.tool_name g.phase)
                    ~val_fg:theme.status_attention ~val_attrs:Attr.bold ();
                  incr y;
                  (match Work_store.retry_meta_for_id ~id:g.id model.work with
                   | Some rm when !y < bot ->
                       let jdg =
                         Option.value rm.summary_judgment ~default:"pending"
                       in
                       let txt =
                         Option.value rm.summary_text ~default:""
                         |> Ops_common.scrub_secrets_in_text
                       in
                       Ops_common.draw_kv_row grid ~rect:content ~y:!y ~theme
                         ~bg:card_bg ~label_w:12
                         ~key:(Ops_common.say model ~ko:"자동판정" ~en:"AutoJudge")
                         ~value:
                           (if String.equal txt "" then jdg
                            else Printf.sprintf "[%s] %s" jdg txt)
                         ();
                       incr y
                   | Some _ | None -> ());
                  let raw_in =
                    match g.input_preview with Some s -> s | None -> "{}"
                  in
                  let jt_rect =
                    Rect.make ~x:content.x ~y:!y ~w:content.w
                      ~h:(Int.max 0 (bot - !y - 1))
                  in
                  let lines =
                    Json_tree.flatten ~max_depth:3 ~redact_secrets:true
                      (parse_json_or_wrap ~key:"input" raw_in)
                  in
                  ignore
                    (Json_tree.draw grid ~rect:jt_rect ~theme
                       ~scroll:model.work.detail_scroll_offset lines);
                  if bot > r_inner.y then
                    ignore
                      (Ops_common.draw_keycap_bar grid
                         ~rect:
                           (Rect.make ~x:content.x ~y:(bot - 1) ~w:content.w
                              ~h:1)
                         ~theme ~bg:card_bg
                         [
                           ("Y", Ops_common.say model ~ko:"승인" ~en:"Approve");
                           ("N", Ops_common.say model ~ko:"거절" ~en:"Reject");
                           ( "/gate"
                           , Ops_common.say model
                               ~ko:"approve-always / retry"
                               ~en:"approve-always / retry" );
                         ])
              | Attention.Payload_ask ask ->
                  let q_total = List.length ask.questions in
                  let ctx_md =
                    match ask.context with
                    | Some c when not (String.equal (String.trim c) "") ->
                        c ^ "\n\n"
                    | Some _ | None -> ""
                  in
                  let q_opt =
                    match ask.questions with q :: _ -> Some q | [] -> None
                  in
                  if !y < bot then begin
                    let badges =
                      match q_opt with
                      | None -> []
                      | Some q ->
                          let mode_b =
                            match q.mode with
                            | Wire_work.Ask_multi ->
                                [ Ops_common.say model ~ko:"[다중 선택]" ~en:"[Multi-select]" ]
                            | Wire_work.Ask_single -> []
                          in
                          let free_b =
                            if q.allow_free_text then
                              [ Ops_common.say model ~ko:"[직접 입력 가능]" ~en:"[Free-text]" ]
                            else []
                          in
                          mode_b @ free_b
                    in
                    let meta_line =
                      let base_q =
                        Ops_common.say model
                          ~ko:(Printf.sprintf "질문 1/%d · @%s" (Int.max 1 q_total) ask.keeper)
                          ~en:(Printf.sprintf "Question 1/%d · @%s" (Int.max 1 q_total) ask.keeper)
                      in
                      if badges = [] then base_q
                      else base_q ^ "  " ^ String.concat " " badges
                    in
                    ignore
                      (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                         ~max_w:content.w
                         ~style:(Typography.accent ~bg:card_bg ~bold:true theme)
                         meta_line);
                    incr y
                  end;
                  let prompt_md =
                    match q_opt with
                    | Some q ->
                        Printf.sprintf "%s**%s**\n\n%s" ctx_md q.header
                          (Ops_common.rewrite_masc_links_for_markdown q.prompt)
                    | None -> ctx_md
                  in
                  let keycap_h = if bot > r_inner.y then 1 else 0 in
                  let content_bot = Int.max !y (bot - keycap_h) in
                  let choices_h =
                    match q_opt with
                    | Some q ->
                        let desired = List.length q.choices + 2 in
                        Int.min (Int.max 3 ((content_bot - !y) / 2)) desired
                    | None -> 0
                  in
                  let avail_h = Int.max 0 (content_bot - !y) in
                  let md_h =
                    if avail_h = 0 then 0
                    else Int.min avail_h (Int.max 1 (avail_h - choices_h))
                  in
                  if md_h > 0 then begin
                    let md_rect =
                      Rect.make ~x:content.x ~y:!y ~w:content.w ~h:md_h
                    in
                    ignore
                      (Markdown.draw grid ~rect:md_rect ~theme ~osc8:true
                         ~scroll:model.work.detail_scroll_offset prompt_md);
                    y := !y + md_h
                  end;
                  (match q_opt with
                  | None -> ()
                  | Some q ->
                      let instant_single =
                        Int.equal q_total 1
                        &&
                        match q.mode with
                        | Wire_work.Ask_single -> true
                        | Wire_work.Ask_multi -> false
                      in
                      if !y < content_bot then begin
                        let lbl =
                          if instant_single then
                            Ops_common.say model
                              ~ko:"선택지 (a..d 즉시 응답 · Enter/Y 모달)"
                              ~en:"Choices (a..d instant · Enter/Y modal)"
                          else
                            Ops_common.say model
                              ~ko:"선택지 (Enter/Y 질문 답변 모달에서 응답)"
                              ~en:"Choices (press Enter/Y to answer in modal)"
                        in
                        Card.draw_hairline ~pad_x:0 ~bg:card_bg ~label:lbl
                          grid ~rect:content ~y:!y ~theme;
                        incr y
                      end;
                      let total_choices = List.length q.choices in
                      let rows_left = Int.max 0 (content_bot - !y) in
                      let multi_q_h =
                        if q_total > 1 && rows_left >= 2 then 1 else 0
                      in
                      let choice_rows_budget =
                        Int.max 0 (rows_left - multi_q_h)
                      in
                      let max_show, more_count =
                        if total_choices <= choice_rows_budget then
                          (total_choices, 0)
                        else if choice_rows_budget >= 2 then
                          ( choice_rows_budget - 1
                          , total_choices - (choice_rows_budget - 1) )
                        else
                          ( choice_rows_budget
                          , total_choices - choice_rows_budget )
                      in
                      List.iteri
                        (fun idx (ch : Wire_work.ask_choice) ->
                          if idx < max_show && !y < content_bot then begin
                            let marker =
                              match q.mode with
                              | Wire_work.Ask_single -> "○"
                              | Wire_work.Ask_multi -> "[ ]"
                            in
                            let key_prefix =
                              if instant_single && idx < 4 then
                                Printf.sprintf "%s [%c] " marker
                                  (Char.chr (Char.code 'a' + idx))
                              else Printf.sprintf "%s " marker
                            in
                            let main_txt = key_prefix ^ ch.label in
                            let start_x = content.x + 1 in
                            let max_w = Int.max 0 (content.w - 1) in
                            let adv =
                              Ops_common.put_line ~clip:content grid ~x:start_x
                                ~y:!y ~max_w
                                ~style:(Typography.primary ~bg:card_bg theme)
                                main_txt
                            in
                            (match ch.description with
                            | Some d when max_w - adv >= 6 ->
                                ignore
                                  (Ops_common.put_line ~clip:content grid
                                     ~x:(start_x + adv) ~y:!y
                                     ~max_w:(max_w - adv)
                                     ~style:(Typography.whisper ~bg:card_bg theme)
                                     (" — " ^ d))
                            | Some _ | None -> ());
                            incr y
                          end)
                        q.choices;
                      if more_count > 0 && !y < content_bot then begin
                        ignore
                          (Ops_common.put_line ~clip:content grid
                             ~x:(content.x + 1) ~y:!y
                             ~max_w:(Int.max 0 (content.w - 1))
                             ~style:(Typography.whisper ~bg:card_bg theme)
                             (Ops_common.say model
                                ~ko:(Printf.sprintf "+%d개 선택지 더 있음 (Enter/Y 모달에서 전체 보기)" more_count)
                                ~en:(Printf.sprintf "+%d more choice(s) (open Enter/Y modal to view all)" more_count)));
                        incr y
                      end;
                      if q_total > 1 && !y < content_bot then begin
                        ignore
                          (Ops_common.put_line ~clip:content grid
                             ~x:(content.x + 1) ~y:!y
                             ~max_w:(Int.max 0 (content.w - 1))
                             ~style:(Typography.status ~bg:card_bg theme Theme.Status_attention)
                             (Ops_common.say model
                                ~ko:(Printf.sprintf "총 %d개 질문 — Enter/Y 모달에서 순서대로 답변하세요" q_total)
                                ~en:(Printf.sprintf "%d questions total — open Enter/Y modal to answer all" q_total)));
                        incr y
                      end);
                  if keycap_h = 1 then
                    ignore
                      (Ops_common.draw_keycap_bar grid
                         ~rect:
                           (Rect.make ~x:content.x ~y:(bot - 1) ~w:content.w
                              ~h:1)
                         ~theme ~bg:card_bg
                         [
                           ( "Enter/Y"
                           , Ops_common.say model ~ko:"질문 답변 열기"
                               ~en:"Open Ask Modal" );
                           ("N", Ops_common.say model ~ko:"건너뛰기" ~en:"Skip");
                           ( "C"
                           , Ops_common.say model ~ko:"키퍼 채팅"
                               ~en:"Keeper Chat" );
                         ])
              | Attention.Payload_goal_confirmation g ->
                  let step_h =
                    draw_goal_pipeline_stepper grid
                      ~rect:
                        (Rect.make ~x:content.x ~y:!y ~w:content.w
                           ~h:(Int.min 2 (Int.max 0 (bot - !y))))
                      ~theme ~model g.phase
                  in
                  y := !y + step_h;
                  let md_rect =
                    Rect.make ~x:content.x ~y:!y ~w:content.w
                      ~h:(Int.max 0 (bot - !y - 1))
                  in
                  ignore
                    (Markdown.draw grid ~rect:md_rect ~theme ~osc8:true
                       ~scroll:model.work.detail_scroll_offset
                       (Ops_common.rewrite_masc_links_for_markdown
                          (g.measure ^ "\n\n" ^ g.procedure)));
                  if bot > r_inner.y then
                    ignore
                      (Ops_common.draw_keycap_bar grid
                         ~rect:
                           (Rect.make ~x:content.x ~y:(bot - 1) ~w:content.w
                              ~h:1)
                         ~theme ~bg:card_bg
                         [
                           ( "Enter"
                           , Ops_common.say model
                               ~ko:"목표 상세에서 증명 확인 후 완료 확정"
                               ~en:"Review proof in Goal Detail to confirm" );
                         ])
            end

(* --- Sub-Tab 4: Candle Economy & Scorecard (ZERO Nested Boxes!) --- *)

let candle_event_summary ~lang = function
  | Wire_work.Candle_paid { goal_id; total_milli; allocations } ->
      ( "paid"
      , Theme.Status_ai
      , Printf.sprintf "%s · %s (%d keepers)" goal_id
          (Ops_common.format_milli_candles total_milli)
          (List.length allocations) )
  | Wire_work.Candle_purchased { keeper; item; amount_milli } ->
      ( "purchase"
      , Theme.Status_active
      , Printf.sprintf "%s bought %s (%s)" keeper item
          (Ops_common.format_milli_candles amount_milli) )
  | Wire_work.Candle_granted { keeper; amount_milli; reason } ->
      ( "grant"
      , Theme.Status_ai
      , Printf.sprintf "%s +%s (%s)" keeper
          (Ops_common.format_milli_candles amount_milli)
          reason )
  | Wire_work.Candle_gifted { from_keeper; to_keeper; amount_milli; _ } ->
      ( "gift"
      , Theme.Status_active
      , Printf.sprintf "%s -> %s (%s)" from_keeper to_keeper
          (Ops_common.format_milli_candles amount_milli) )
  | Wire_work.Candle_gifted_item { from_keeper; to_keeper; item } ->
      ( "gift-item"
      , Theme.Status_active
      , Printf.sprintf "%s -> %s (%s)" from_keeper to_keeper item )
  | Wire_work.Candle_equipped { keeper; slot; choice } ->
      ("equip", Theme.Status_ok, Printf.sprintf "%s [%s=%s]" keeper slot choice)
  | Wire_work.Candle_half_life_set { mode; half_life_hours; _ } ->
      let h =
        match half_life_hours with
        | Some n -> Printf.sprintf " %dh" n
        | None -> ""
      in
      ("half-life", Theme.Status_historical, mode ^ h)
  | Wire_work.Candle_snapshot { goal_id; title; linked_task_count } ->
      ( "snapshot"
      , Theme.Status_historical
      , Printf.sprintf "%s (%d tasks) %s" goal_id linked_task_count title )
  | Wire_work.Candle_payout_owed { goal_id } ->
      ("owed", Theme.Status_attention, goal_id)
  | Wire_work.Candle_candidates
      { goal_id; candidate_task_count; candidate_keeper_count; _ } ->
      ( "candidates"
      , Theme.Status_active
      , Printf.sprintf "%s (%dt / %dk)" goal_id candidate_task_count
          candidate_keeper_count )
  | Wire_work.Candle_candidates_fenced { goal_id; observation; _ } ->
      ( "fenced"
      , Theme.Status_attention
      , Printf.sprintf "%s · %s" goal_id observation )
  | Wire_work.Candle_window_held { goal_id; task_count } ->
      ( "held"
      , Theme.Status_attention
      , Printf.sprintf "%s (%d tasks)" goal_id task_count )
  | Wire_work.Candle_window_released { goal_id } ->
      ("released", Theme.Status_ok, goal_id)
  | Wire_work.Candle_unattributed { goal_id; reason; diagnostic_hint; _ } ->
      let hint =
        match diagnostic_hint with
        | Some h -> " · " ^ h
        | None ->
            " · "
            ^ Say.resolve lang
                (Say.make ~ko:"연결 작업 없음" ~en:"no linked tasks")
      in
      ( "unattrib"
      , Theme.Status_critical
      , Printf.sprintf "%s (%s)%s" goal_id reason hint )
  | Wire_work.Candle_payout_failed { goal_id; due_date } ->
      ("failed", Theme.Status_critical, Printf.sprintf "%s (due %s)" goal_id due_date)

let build_decay_curve_samples ~circulating_c ~half_life_sec =
  if (not (Float.is_finite circulating_c)) || circulating_c <= 0.0 then
    Array.make 28 Chart.Series.Zero
  else
    let hl_days =
      match half_life_sec with
      | Some s when Float.is_finite s && s > 0.0 -> s /. 86400.0
      | Some _ | None -> 7.0
    in
    Array.init 28 (fun i ->
        let day = Float.of_int i *. 0.25 in
        let v = circulating_c *. Float.pow 0.5 (day /. hl_days) in
        Chart.Series.Value v)

let draw_candle_kpi_strip grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(model : Model.t) ~cache ~ledger_opt ~unlinked_n ~unattrib_n ~fenced_n =
  let circ_str, issued_str, burned_str, hl_label, active_k, policy_s =
    match ledger_opt with
    | Some (l : Wire_work.candle_ledger) ->
        let hl =
          match l.half_life_sec with
          | Some s when Float.is_finite s && s > 0.0 ->
              Format_val.format_duration_s s
          | Some _ | None -> Glyph.to_utf8 Glyph.Missing_absent
        in
        ( Ops_common.format_milli_string l.circulating_milli
        , Ops_common.format_milli_string l.issued_milli
        , Ops_common.format_milli_string l.burned_milli
        , hl
        , l.active_keepers
        , l.policy_configuration )
    | None ->
        let dash = Glyph.to_utf8 Glyph.Missing_absent in
        (dash, dash, dash, dash, 0, dash)
  in
  let spec : Card.spec =
    {
      (Card.default_spec
         ~title:
           (Ops_common.say model ~ko:"캔들 경제 · 반감기 요약"
              ~en:"Candle Economy · Half-Life"))
      with
      subtitle =
        Some
          (if fenced_n > 0 then
             Printf.sprintf "Circulating %s · %d backlog_fenced" circ_str
               fenced_n
           else Printf.sprintf "Circulating %s" circ_str);
      badge =
        Some
          {
            Card.glyph = Some Glyph.Ai_spark;
            text = circ_str;
            tone = Some Theme.Status_ai;
          };
      footer_hint =
        Some
          (Ops_common.say model
             ~ko:"계약: 초상화 장신구 전용 · 추가 전용 원장 (candle-ledger.jsonl)"
             ~en:"Contract: portrait accessories only · append-only candle-ledger.jsonl");
    }
  in
  let inner = Card.draw ~cache grid ~rect ~theme spec in
  if not (Rect.is_empty inner) then begin
    let bg = Color.of_rgb theme.surface_1 in
    let pad_x = Ops_common.pad_x_for ~model inner in
    let content = Card.pad_inner ~pad_x inner in
    let col_count = if content.w >= 88 then 4 else if content.w >= 48 then 2 else 1 in
    let constraints = List.init col_count (fun _ -> Layout.Flex 1) in
    let cols = Layout.split_h ~gap:3 content constraints in
    let paint_kpi col_r ~label ~hero ~hero_style ~sub ~sub_style =
      if not (Rect.is_empty col_r) then begin
        let lbl_fit = label ^ "  " in
        let adv =
          Ops_common.put_line ~clip:col_r grid ~x:col_r.x ~y:col_r.y
            ~max_w:(Int.min (col_r.w / 2) (Grapheme.display_width lbl_fit))
            ~style:(Typography.structure ~bg theme)
            lbl_fit
        in
        ignore
          (Ops_common.put_line ~clip:col_r grid ~x:(col_r.x + adv) ~y:col_r.y
             ~max_w:(Int.max 0 (col_r.w - adv))
             ~style:hero_style hero);
        if col_r.h >= 2 then
          ignore
            (Ops_common.put_line ~clip:col_r grid ~x:col_r.x ~y:(col_r.y + 1)
               ~max_w:col_r.w ~style:sub_style sub)
      end
    in
    let diag_hero, diag_st, diag_sub =
      if unattrib_n > 0 || fenced_n > 0 || unlinked_n > 0 then
        ( Printf.sprintf "%s %d backlog_fenced"
            (Glyph.to_utf8 Glyph.Warning_triangle) fenced_n
        , Typography.status ~bg ~bold:true theme Theme.Status_attention
        , Ops_common.say model
            ~ko:(Printf.sprintf "미귀속 %d · 미연결 작업 %d건" unattrib_n unlinked_n)
            ~en:(Printf.sprintf "%d unattrib · %d unlinked tasks" unattrib_n unlinked_n) )
      else
        ( Glyph.to_utf8 Glyph.Live_healthy ^ " "
          ^ Ops_common.say model ~ko:"정상 귀속" ~en:"Attributed OK"
        , Typography.status ~bg ~bold:true theme Theme.Status_ok
        , Ops_common.say model
            ~ko:"초상화 장신구 전용 (도구·모델 불가)"
            ~en:"portrait accessories only (no tools/models)" )
    in
    let items =
      [
        ( Ops_common.say model ~ko:"유통량" ~en:"Circulating"
        , Glyph.to_utf8 Glyph.Ai_spark ^ " " ^ circ_str
        , Typography.ai ~bg ~bold:true theme
        , Printf.sprintf "Circulating %s · %d %s" circ_str active_k
            (Ops_common.say model ~ko:"보유 키퍼" ~en:"keepers")
        , Typography.whisper ~bg theme );
        ( Ops_common.say model ~ko:"발행" ~en:"Issued"
        , issued_str
        , Typography.anchor ~bg theme
        , Printf.sprintf "%s %s"
            (Ops_common.say model ~ko:"소각" ~en:"Burned") burned_str
        , Typography.whisper ~bg theme );
        ( Ops_common.say model ~ko:"반감기" ~en:"Half-Life"
        , hl_label
        , Typography.anchor ~bg theme
        , Printf.sprintf "%s: %s"
            (Ops_common.say model ~ko:"정책" ~en:"Policy") policy_s
        , Typography.whisper ~bg theme );
        ( Ops_common.say model ~ko:"진단" ~en:"Health"
        , diag_hero
        , diag_st
        , diag_sub
        , Typography.whisper ~bg theme );
      ]
    in
    List.iteri
      (fun idx (col_r : Rect.t) ->
        if idx > 0 && col_r.x >= 2 then
          Card.draw_v_hairline ~bg grid ~x:(col_r.x - 2) ~y:content.y
            ~h:content.h ~theme;
        match List.nth_opt items idx with
        | Some (label, hero, hero_style, sub, sub_style) ->
            paint_kpi col_r ~label ~hero ~hero_style ~sub ~sub_style
        | None -> ())
      cols
  end

let render_candle_scorecard ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Ops_common.theme_of_model model in
    let bp = Ops_common.layout_bp model in
    let ledger_opt = Observed.to_option model.work.candle_ledger in
    let unlinked_n = Work_store.unlinked_task_count model.work in
    let unattrib_n, fenced_n =
      match ledger_opt with
      | Some l -> (l.diagnostics.unattributed_count, l.diagnostics.backlog_fenced_count)
      | None -> (0, 0)
    in
    (* Peer sibling layout: Top 4-KPI Summary Strip + Main 2-Column Split (ZERO nested boxes!) *)
    let kpi_rect, main_rect =
      if rect.h >= 14 then
        match Layout.split_v_bp bp rect [ Layout.Fixed 4; Layout.Flex 1 ] with
        | [ t; b ] -> (t, b)
        | _ -> (Rect.empty, rect)
      else (Rect.empty, rect)
    in
    if not (Rect.is_empty kpi_rect) then
      draw_candle_kpi_strip grid ~rect:kpi_rect ~theme ~model ~cache ~ledger_opt
        ~unlinked_n ~unattrib_n ~fenced_n;
    if Rect.is_empty main_rect then ()
    else
      let left_rect, right_rect =
        if main_rect.w >= 96 then
          match
            Layout.split_h_bp bp main_rect [ Layout.Ratio 0.56; Layout.Flex 1 ]
          with
          | [ l; r ] -> (l, r)
          | _ -> (main_rect, Rect.empty)
        else
          match
            Layout.split_v_bp bp main_rect [ Layout.Ratio 0.55; Layout.Flex 1 ]
          with
          | [ t; b ] -> (t, b)
          | _ -> (main_rect, Rect.empty)
      in
      (* Left Column: TWO peer sibling cards with gap_y = 1 (Wide/Std) *)
      let bal_rect, ev_rect =
        match
          Layout.split_v_bp bp left_rect [ Layout.Ratio 0.54; Layout.Flex 1 ]
        with
        | [ t; b ] -> (t, b)
        | _ -> (left_rect, Rect.empty)
      in
      let hl_label =
        match ledger_opt with
        | Some { half_life_sec = Some s; _ } when Float.is_finite s && s > 0.0 ->
            Format_val.format_duration_s s
        | Some _ | None -> Glyph.to_utf8 Glyph.Missing_absent
      in
      let bal_spec : Card.spec =
        {
          (Card.default_spec
             ~title:
               (Printf.sprintf "%s (%s)"
                  (Ops_common.say model ~ko:"반감기 감쇠 곡선 · 키퍼 잔액"
                     ~en:"Half-Life Decay & Balances")
                  hl_label))
          with
          badge =
            (match ledger_opt with
            | Some l ->
                Some
                  {
                    Card.glyph = Some Glyph.Ai_spark;
                    text =
                      Printf.sprintf "Circulating %s"
                        (Ops_common.format_milli_string l.circulating_milli);
                    tone = Some Theme.Status_ai;
                  }
            | None -> None);
          focused = Model.pane_focused model 0;
        }
      in
      let b_inner = Card.draw ~cache grid ~rect:bal_rect ~theme bal_spec in
      if not (Rect.is_empty b_inner) then begin
        let bg = Color.of_rgb theme.surface_1 in
        let pad_x = Ops_common.pad_x_for ~model b_inner in
        let content = Card.pad_inner ~pad_x b_inner in
        match ledger_opt with
        | None ->
            Ops_common.draw_observed_empty grid ~rect:b_inner ~theme
              ~lang:model.lang model.work.candle_ledger
              ~empty_msg:
                (Say.make ~ko:"캔들 원장 데이터 없음" ~en:"No candle ledger data")
        | Some ledger ->
            let circ_c =
              match float_of_string_opt (String.trim ledger.circulating_milli) with
              | Some v when Float.is_finite v -> v /. 1000.0
              | Some _ | None -> 0.0
            in
            let chart_h =
              if content.h >= 10 then 6
              else if content.h >= 6 then 4
              else if content.h >= 3 then 2
              else 0
            in
            let chart_r, rest_r = Rect.split_v content ~top_h:chart_h in
            if chart_h > 0 then begin
              let samples =
                build_decay_curve_samples ~circulating_c:circ_c
                  ~half_life_sec:ledger.half_life_sec
              in
              let safe_circ = Float.max 0.0 circ_c in
              let decay_avg =
                let sum, cnt =
                  Array.fold_left
                    (fun (s, c) sample ->
                      match sample with
                      | Chart.Series.Value v when Float.is_finite v -> (s +. v, c + 1)
                      | Chart.Series.Zero -> (s, c + 1)
                      | Chart.Series.Value _ | Chart.Series.Unread
                      | Chart.Series.Absent ->
                          (s, c))
                    (0.0, 0) samples
                in
                if cnt > 0 then sum /. float_of_int cnt else safe_circ
              in
              let spec : Chart.Spec.t =
                {
                  title =
                    Say.make
                      ~ko:(Printf.sprintf "반감기 감쇠 곡선 (%s)" hl_label)
                      ~en:(Printf.sprintf "Half-Life Decay (%s)" hl_label);
                  kind =
                    Chart.Spec.Time_series
                      {
                        series =
                          {
                            Chart.Series.label = Say.literal "";
                            unit = Format_val.Candles;
                            gradient = Chart.Gradient.Ai_flow;
                            samples;
                            current =
                              Observed.value ~observed_at:Clock.Mono.zero
                                safe_circ;
                            peak =
                              Observed.value ~observed_at:Clock.Mono.zero
                                safe_circ;
                            avg =
                              Observed.value ~observed_at:Clock.Mono.zero
                                decay_avg;
                            delta_pct = None;
                          };
                        scale =
                          Chart.Scale.Auto_ceil { floor = 0.0; nice_step = true };
                        window = Chart.Time_window.Last_7d;
                      };
                  hotkey_hint = None;
                }
              in
              ignore
                (Chart.draw grid ~rect:chart_r ~theme
                   ~caps:Ops_common.default_caps ~lang:model.lang
                   ~show_title:false spec)
            end;
            if not (Rect.is_empty rest_r) then begin
              let tbl_y =
                if rest_r.h >= 3 then begin
                  Card.draw_hairline ~pad_x:0 ~bg
                    ~label:
                      (Ops_common.say model ~ko:"키퍼별 잔액"
                         ~en:"Keeper Balances")
                    grid ~rect:rest_r ~y:rest_r.y ~theme;
                  rest_r.y + 1
                end
                else rest_r.y
              in
              let tbl_r =
                Rect.make ~x:b_inner.x ~y:tbl_y ~w:b_inner.w
                  ~h:(Int.max 0 (Rect.bottom rest_r - tbl_y))
              in
              let filtered_balances = Work_store.filtered_candle_balances model.work in
              if filtered_balances = [] then begin
                let empty_r = Card.pad_inner ~pad_x tbl_r in
                if not (Rect.is_empty empty_r) then begin
                  Card.draw_left_rail ~bg ~tone:Theme.Status_attention grid
                    ~x:empty_r.x ~y:empty_r.y ~h:1 ~theme;
                  let msg =
                    if not (String.equal (String.trim model.work.filter_query) "")
                    then
                      Ops_common.say model
                        ~ko:"필터와 일치하는 캔들 잔액이 없습니다"
                        ~en:"No candle balances match the filter"
                    else
                      Ops_common.say model
                        ~ko:
                          (Printf.sprintf
                             "발행된 잔액 없음 · 미연결 작업 %d건을 목표에 연결하면 캔들이 발행됩니다"
                             unlinked_n)
                        ~en:
                          (Printf.sprintf
                             "No minted balances · link %d unlinked tasks to Goals to mint Candles"
                             unlinked_n)
                  in
                  ignore
                    (Ops_common.put_line ~clip:empty_r grid ~x:(empty_r.x + 2)
                       ~y:empty_r.y
                       ~max_w:(Int.max 0 (empty_r.w - 2))
                       ~style:(Typography.whisper ~bg theme)
                       msg)
                end
              end
              else
                let max_bal =
                  List.fold_left
                    (fun acc (b : Wire_work.candle_balance_row) ->
                      Int.max acc b.balance_milli)
                    1 filtered_balances
                in
                let cols : Table.column list =
                  [
                    {
                      id = "keeper";
                      header = Say.make ~ko:"키퍼" ~en:"Keeper";
                      priority = 0;
                      min_width = 12;
                      max_width = Some 20;
                      weight = 3;
                      align = Table.Left;
                    };
                    {
                      id = "bar";
                      header = Say.make ~ko:"비중" ~en:"Share";
                      priority = 1;
                      min_width = 10;
                      max_width = Some 16;
                      weight = 2;
                      align = Table.Right;
                    };
                    {
                      id = "decayed";
                      header = Say.make ~ko:"잔액" ~en:"Decayed";
                      priority = 0;
                      min_width = 9;
                      max_width = Some 12;
                      weight = 2;
                      align = Table.Right;
                    };
                    {
                      id = "items";
                      header = Say.make ~ko:"장신구" ~en:"Ornaments";
                      priority = 2;
                      min_width = 8;
                      max_width = Some 16;
                      weight = 2;
                      align = Table.Left;
                    };
                  ]
                in
                let rows =
                  List.map
                    (fun (b : Wire_work.candle_balance_row) ->
                      let items_s =
                        if b.owned_items = [] then
                          Glyph.to_utf8 Glyph.Missing_absent
                        else String.concat ", " b.owned_items
                      in
                      let ratio =
                        Float.max 0.0
                          (Float.min 1.0
                             (Float.of_int b.balance_milli /. Float.of_int max_bal))
                      in
                      {
                        Table.id = b.keeper;
                        cells =
                          [
                            ("keeper", Table.text_cell b.keeper);
                            ( "bar"
                            , Table.Gauge
                                {
                                  ratio;
                                  gradient = Chart.Gradient.Ai_flow;
                                  label = None;
                                } );
                            ( "decayed"
                            , Table.text_cell ~fg:(Color.of_rgb theme.status_ai)
                                ~attrs:Attr.bold
                                (Ops_common.format_milli_string b.decayed_milli) );
                            ( "items"
                            , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                                ~attrs:Attr.italic items_s );
                          ];
                      })
                    filtered_balances
                in
                ignore
                  (Table.draw grid ~rect:tbl_r ~theme
                     ~caps:Ops_common.default_caps ~lang:model.lang
                     ~scroll:model.work.scroll_offset
                     ~selected:model.work.selected_index
                     ~focused:(Model.pane_focused model 0)
                     ~col_gap:(Layout.table_col_gap bp) ~columns:cols rows)
            end
      end;
      (* Bottom-Left Peer Card: Append-only Ledger Events *)
      if not (Rect.is_empty ev_rect) then begin
        let ev_spec : Card.spec =
          {
            (Card.default_spec
               ~title:
                 (Ops_common.say model ~ko:"원장 이벤트"
                    ~en:"Ledger Events"))
            with
            subtitle = Some "candle-ledger.jsonl";
            hotkey =
              Some
                (if Model.pane_focused model 1 then
                   Ops_common.say model ~ko:"[↑↓] 스크롤 · [Tab] 잔액"
                     ~en:"[↑↓] Scroll · [Tab] Balances"
                 else Ops_common.say model ~ko:"[Tab] 원장" ~en:"[Tab] Events");
            focused = Model.pane_focused model 1;
          }
        in
        let e_inner = Card.draw ~cache grid ~rect:ev_rect ~theme ev_spec in
        if not (Rect.is_empty e_inner) then
          match ledger_opt with
          | None ->
              Ops_common.draw_observed_empty grid ~rect:e_inner ~theme
                ~lang:model.lang model.work.candle_ledger
                ~empty_msg:(Say.make ~ko:"원장 이벤트 없음" ~en:"No ledger events")
          | Some ledger ->
              let cols : Table.column list =
                [
                  {
                    id = "seq";
                    header = Say.literal "#";
                    priority = 2;
                    min_width = 4;
                    max_width = Some 5;
                    weight = 1;
                    align = Table.Right;
                  };
                  {
                    id = "kind";
                    header = Say.make ~ko:"유형" ~en:"Event";
                    priority = 0;
                    min_width = 9;
                    max_width = Some 12;
                    weight = 1;
                    align = Table.Left;
                  };
                  {
                    id = "time";
                    header = Say.make ~ko:"시각" ~en:"Time";
                    priority = 3;
                    min_width = 5;
                    max_width = Some 6;
                    weight = 1;
                    align = Table.Right;
                  };
                  {
                    id = "detail";
                    header = Say.make ~ko:"세부 내용" ~en:"Detail";
                    priority = 0;
                    min_width = 16;
                    max_width = None;
                    weight = 5;
                    align = Table.Left;
                  };
                ]
              in
              let rows =
                List.map
                  (fun (ev : Wire_work.candle_event) ->
                    let kind_s, tok, detail =
                      candle_event_summary ~lang:model.lang ev.kind
                    in
                    {
                      Table.id = Int.to_string ev.seq;
                      cells =
                        [
                          ( "seq"
                          , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                              (Int.to_string ev.seq) );
                          ( "kind"
                          , Table.Badge { glyph = None; text = kind_s; tone = tok } );
                          ( "time"
                          , Table.text_cell ~fg:(Color.of_rgb theme.text_muted)
                              ~attrs:Attr.italic
                              (Ops_common.format_hhmm
                                 ~tz_offset_sec:model.tz_offset_sec ev.at_unix) );
                          ("detail", Table.text_cell detail);
                        ];
                    })
                  ledger.recent_events
              in
              if rows = [] then
                Ops_common.draw_observed_empty grid ~rect:e_inner ~theme
                  ~lang:model.lang model.work.candle_ledger
                  ~empty_msg:
                    (Say.make ~ko:"기록된 원장 이벤트가 없습니다"
                       ~en:"No ledger events recorded")
              else
                ignore
                  (Table.draw grid ~rect:e_inner ~theme
                     ~caps:Ops_common.default_caps ~lang:model.lang
                     ~scroll:model.work.ledger_scroll_offset
                     ~focused:(Model.pane_focused model 1)
                     ~col_gap:(Layout.table_col_gap bp) ~columns:cols rows)
      end;
      (* Right Peer Card: Daily / 7d Group & Top Keeper Leaderboard *)
      if not (Rect.is_empty right_rect) then begin
        let lb_spec : Card.spec =
          {
            (Card.default_spec
               ~title:
                 (Ops_common.say model ~ko:"일간 · 7일 조직 · 키퍼 성과"
                    ~en:"Daily / 7d Achievement Board"))
            with
            footer_hint =
              (if Rect.is_empty kpi_rect then
                 Some
                   (Ops_common.say model ~ko:"초상화 전용 · backlog_fenced 진단"
                      ~en:"Portrait only · backlog_fenced diagnostics")
               else None);
          }
        in
        let r_inner = Card.draw ~cache grid ~rect:right_rect ~theme lb_spec in
        if not (Rect.is_empty r_inner) then begin
          let r_bg = Color.of_rgb theme.surface_1 in
          let pad_x = Ops_common.pad_x_for ~model r_inner in
          let content = Card.pad_inner ~pad_x r_inner in
          let y = ref content.y in
          let bot = Rect.bottom content in
          (* 1. Authoritative 24h KPI strip via Model.effective_scorecard *)
          let sc = Model.effective_scorecard model in
          let fmt_i o =
            Format_val.format_observed Format_val.Count
              (Observed.map Float.of_int o)
              ~lang:model.lang
          in
          if content.h >= 4 && content.w >= 32 then begin
            let kpi_gap = if content.w >= 54 then 3 else 2 in
            let kcols =
              Layout.split_h ~gap:kpi_gap
                (Rect.make ~x:content.x ~y:!y ~w:content.w ~h:2)
                [ Layout.Flex 1; Layout.Flex 1; Layout.Flex 1 ]
            in
            let done_sub =
              let posts_part =
                match Observed.to_option sc.board_posts_24h with
                | Some n ->
                    Some
                      (Printf.sprintf "%s %s"
                         (Ops_common.say model ~ko:"게시" ~en:"Posts")
                         (Format_val.format_value Format_val.Count
                            (Float.of_int n)))
                | None -> None
              in
              let goals_part =
                match Observed.to_option sc.goals_completed_24h with
                | Some n ->
                    Some
                      (Printf.sprintf "%s %s"
                         (Ops_common.say model ~ko:"목표" ~en:"Goals")
                         (Format_val.format_value Format_val.Count
                            (Float.of_int n)))
                | None -> None
              in
              match (posts_part, goals_part) with
              | Some p, Some g -> p ^ " · " ^ g
              | Some p, None -> p
              | None, Some g -> g
              | None, None ->
                  Printf.sprintf "%s %s"
                    (Ops_common.say model ~ko:"목표" ~en:"Goals")
                    (fmt_i sc.goals_completed_24h)
            in
            let kpis =
              [
                ( Ops_common.say model ~ko:"완료(24h)" ~en:"Done 24h"
                , Ops_common.say model ~ko:"완료" ~en:"Done"
                , fmt_i sc.tasks_done_24h
                , Typography.status ~bg:r_bg ~bold:true theme Theme.Status_ok
                , done_sub );
                ( Ops_common.say model ~ko:"검증 통과" ~en:"Verify"
                , Ops_common.say model ~ko:"검증" ~en:"Ver"
                , Printf.sprintf "%s/%s"
                    (fmt_i sc.verifications_passed_24h)
                    (fmt_i sc.verifications_rejected_24h)
                , Typography.accent ~bg:r_bg ~bold:true theme
                , Ops_common.say model ~ko:"통과 / 반려" ~en:"pass / rej" );
                ( Ops_common.say model ~ko:"24h 턴" ~en:"24h Turns"
                , Ops_common.say model ~ko:"턴" ~en:"Trn"
                , fmt_i sc.turns_24h
                , Typography.anchor ~bg:r_bg theme
                , Format_val.format_observed Format_val.Usd sc.cost_24h_usd
                    ~lang:model.lang );
              ]
            in
            List.iteri
              (fun idx (cr : Rect.t) ->
                if
                  idx > 0 && not (Rect.is_empty cr) && cr.x - 2 >= content.x
                  && cr.x - 2 < Rect.right content
                then
                  Card.draw_v_hairline ~bg:r_bg grid ~x:(cr.x - 2) ~y:cr.y
                    ~h:2 ~theme;
                match List.nth_opt kpis idx with
                | Some (lbl, short_lbl, v, v_st, sub) ->
                    Ops_common.draw_kpi_line grid ~rect:cr ~y:cr.y ~theme
                      ~bg:r_bg ~label:lbl ~short_label:short_lbl ~value:v
                      ~val_style:v_st;
                    ignore
                      (Ops_common.put_line ~clip:cr grid ~x:cr.x ~y:(cr.y + 1)
                         ~max_w:cr.w
                         ~style:(Typography.whisper ~bg:r_bg theme)
                         sub)
                | None -> ())
              kcols;
            y := !y + 2
          end;
          (* 2. Company/Group Ranked Bars (unfiltered, using company_groups_with_costs!) *)
          let unfiltered_fleet = { model.fleet with filter_query = "" } in
          let costs_assoc = Runtime_store.keeper_costs_24h_assoc model.runtime in
          let groups =
            Fleet_store.company_groups_with_costs
              ~now_unix:model.freshness.last_wall_unix
              ~keeper_costs_24h:costs_assoc unfiltered_fleet
          in
          let grp_cnt = List.length groups in
          if !y < bot then begin
            let lb_label =
              if grp_cnt > 0 then
                Ops_common.say model
                  ~ko:(Printf.sprintf "조직별 성과 (%d개 조직)" grp_cnt)
                  ~en:(Printf.sprintf "Company Leaderboard (%d)" grp_cnt)
              else
                Ops_common.say model ~ko:"조직별 성과" ~en:"Company Leaderboard"
            in
            Card.draw_hairline ~pad_x:0 ~bg:r_bg ~label:lb_label grid
              ~rect:content ~y:!y ~theme;
            incr y
          end;
          let tasks = Work_store.tasks model.work in
          let company_done_count (grp : Wire_fleet.company_group) =
            let names =
              List.map (fun (k : Wire_fleet.keeper_summary) -> k.name) grp.keepers
            in
            List.fold_left
              (fun acc (tk : Wire_work.task) ->
                if Ops_common.task_is_done tk.status then
                  match Ops_common.task_assignee_opt tk.status with
                  | Some a when List.exists (String.equal a) names -> acc + 1
                  | Some _ | None -> acc
                else acc)
              0 tasks
          in
          let sorted_groups =
            List.stable_sort
              (fun a b ->
                let c = Int.compare (company_done_count b) (company_done_count a) in
                if c <> 0 then c
                else
                  let t = Int.compare b.turns_24h a.turns_24h in
                  if t <> 0 then t
                  else Int.compare b.working_count a.working_count)
              groups
          in
          let max_g_score =
            List.fold_left
              (fun acc g ->
                Int.max acc (Int.max (company_done_count g) g.running_count))
              1 sorted_groups
          in
          List.iteri
            (fun idx (grp : Wire_fleet.company_group) ->
              if !y < bot then begin
                let done_n = company_done_count grp in
                let bar_w = if content.w >= 48 then 8 else 0 in
                let rank_name = Printf.sprintf "%d. %s" (idx + 1) grp.company in
                let meta =
                  Printf.sprintf "%dt · %d/%d" done_n grp.running_count
                    (List.length grp.keepers)
                in
                let meta_w = Grapheme.display_width meta in
                let name_w =
                  Int.max 10
                    (content.w - meta_w - (if bar_w > 0 then bar_w + 3 else 2))
                in
                let name_st =
                  if idx = 0 then Typography.anchor ~bg:r_bg theme
                  else Typography.primary ~bg:r_bg theme
                in
                ignore
                  (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                     ~max_w:name_w ~style:name_st rank_name);
                if bar_w > 0 then begin
                  let score = Int.max done_n grp.running_count in
                  let ratio =
                    Float.max 0.0
                      (Float.min 1.0
                         (Float.of_int score /. Float.of_int max_g_score))
                  in
                  let bx = Rect.right content - meta_w - bar_w - 2 in
                  if bx > content.x + 8 then
                    ignore
                      (Chart.draw_ratio_bar_run ~clip:content grid ~x:bx ~y:!y
                         ~width:bar_w ~theme ~bg:r_bg ~unicode:true
                         ~gradient:Chart.Gradient.Efficiency ~ratio)
                end;
                ignore
                  (Ops_common.put_line ~clip:content grid
                     ~x:(Rect.right content - meta_w)
                     ~y:!y ~max_w:meta_w
                     ~style:(Typography.whisper ~bg:r_bg theme)
                     meta);
                incr y
              end)
            (List.take 5 sorted_groups);
          (* 3. Top Contributing Keepers *)
          if !y < bot then begin
            Card.draw_hairline ~pad_x:0 ~bg:r_bg
              ~label:
                (Ops_common.say model ~ko:"상위 기여 키퍼" ~en:"Top Keepers")
              grid ~rect:content ~y:!y ~theme;
            incr y
          end;
          let keepers = Fleet_store.filtered_keepers unfiltered_fleet in
          let keeper_score (k : Wire_fleet.keeper_summary) =
            let done_t =
              List.fold_left
                (fun acc (tk : Wire_work.task) ->
                  if Ops_common.task_is_done tk.status then
                    match Ops_common.task_assignee_opt tk.status with
                    | Some a when String.equal a k.name -> acc + 1
                    | Some _ | None -> acc
                  else acc)
                0 tasks
            in
            let turns =
              match k.total_turns with
              | Observed.Value { data; _ } -> data
              | Observed.Loading _
              | Observed.Absent
              | Observed.Unreported
              | Observed.Failed _ ->
                  0
            in
            (done_t, turns)
          in
          let top_keepers =
            List.stable_sort
              (fun a b ->
                let da, ta = keeper_score a in
                let db, tb = keeper_score b in
                let c = Int.compare db da in
                if c <> 0 then c else Int.compare tb ta)
              keepers
          in
          List.iteri
            (fun idx (k : Wire_fleet.keeper_summary) ->
              if !y < bot then begin
                let d_n, t_n = keeper_score k in
                let c_str =
                  match Ops_common.keeper_candle_milli ~model k.name with
                  | Some (_, dec_s) ->
                      Printf.sprintf "  %s %s"
                        (Glyph.to_utf8 Glyph.Ai_spark)
                        (Ops_common.format_milli_string dec_s)
                  | None -> ""
                in
                let left_s = Printf.sprintf "%d. %s" (idx + 1) k.name in
                let stats_s = Printf.sprintf "%dt · %d turns" d_n t_n in
                let c_w = Grapheme.display_width c_str in
                let st_w = Grapheme.display_width stats_s in
                let name_max = Int.max 8 (content.w - st_w - c_w - 2) in
                let name_st =
                  if idx = 0 then Typography.anchor ~bg:r_bg theme
                  else Typography.primary ~bg:r_bg theme
                in
                ignore
                  (Ops_common.put_line ~clip:content grid ~x:content.x ~y:!y
                     ~max_w:name_max ~style:name_st left_s);
                let rx = ref (Rect.right content) in
                if c_w > 0 && !rx - c_w > content.x + 10 then begin
                  rx := !rx - c_w;
                  ignore
                    (Ops_common.put_line ~clip:content grid ~x:!rx ~y:!y
                       ~max_w:c_w ~style:(Typography.ai ~bg:r_bg theme) c_str)
                end;
                if !rx - st_w > content.x + 10 then begin
                  rx := !rx - st_w;
                  ignore
                    (Ops_common.put_line ~clip:content grid ~x:!rx ~y:!y
                       ~max_w:st_w ~style:(Typography.whisper ~bg:r_bg theme)
                       stats_s)
                end;
                incr y
              end)
            (List.take (Int.max 0 (bot - !y)) top_keepers)
        end
      end

let render_harness ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Ops_common.theme_of_model model in
    let bp = Ops_common.layout_bp model in
    let left_rect, right_rect =
      if model.nav.zoomed && Model.can_zoom_current_view model then
        (Rect.empty, rect)
      else
        Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.48
          ~top_ratio:0.48 bp rect
    in
    let hh_opt = Observed.to_option model.work.harness_health in
    let status_badge =
      match hh_opt with
      | Some hh ->
          let tone =
            if hh.fallback_ratio > 0.2 then Theme.Status_attention
            else if String.equal (String.lowercase_ascii hh.evaluator_status) "ok"
                    || String.equal (String.lowercase_ascii hh.evaluator_status) "healthy"
            then Theme.Status_ok
            else Theme.Status_active
          in
          Some
            {
              Card.glyph = Some Glyph.Live_healthy;
              text =
                Printf.sprintf "%s · agr %.0f%% · fb %.0f%%" hh.evaluator_status
                  (hh.calibration.agreement_rate *. 100.0)
                  (hh.fallback_ratio *. 100.0);
              tone = Some tone;
            }
      | None -> None
    in
    let left_spec : Card.spec =
      {
        (Card.default_spec
           ~title:
             (Ops_common.say model ~ko:"하네스 판정 이력"
                ~en:"Harness Health & Verdicts"))
        with
        badge = status_badge;
        hotkey = Some "[y] Approve · [n] Reject · [H] Hash";
        focused = Model.pane_focused model 0;
      }
    in
    let l_inner = Card.draw ~cache grid ~rect:left_rect ~theme left_spec in
    if not (Rect.is_empty l_inner) then begin
      let verdicts = Work_store.filtered_harness_verdicts model.work in
      match model.work.harness_health with
      | Observed.Value _ when verdicts <> [] ->
          let columns : Table.column list =
            [
              {
                id = "verdict";
                header = Say.make ~ko:"판정" ~en:"Verdict";
                priority = 0;
                min_width = 7;
                max_width = Some 10;
                weight = 1;
                align = Table.Left;
              };
              {
                id = "task";
                header = Say.make ~ko:"작업" ~en:"Task";
                priority = 0;
                min_width = 14;
                max_width = None;
                weight = 3;
                align = Table.Left;
              };
              {
                id = "agent";
                header = Say.make ~ko:"키퍼" ~en:"Keeper";
                priority = 1;
                min_width = 10;
                max_width = Some 16;
                weight = 2;
                align = Table.Left;
              };
              {
                id = "eval";
                header = Say.make ~ko:"평가기" ~en:"Eval";
                priority = 2;
                min_width = 8;
                max_width = Some 14;
                weight = 1;
                align = Table.Left;
              };
            ]
          in
          let rows =
            List.mapi
              (fun i (v : Wire_work.harness_verdict_row) ->
                let vl = String.lowercase_ascii v.verdict in
                let tone =
                  if String.equal vl "approve" || String.equal vl "approved" then
                    Theme.Status_ok
                  else if String.equal vl "reject" || String.equal vl "rejected" then
                    Theme.Status_critical
                  else Theme.Status_attention
                in
                {
                  Table.id = Printf.sprintf "%d:%s:%s" i v.task_id v.notes_hash;
                  cells =
                    [
                      ( "verdict"
                      , Table.Badge { glyph = None; text = v.verdict; tone } );
                      ("task", Table.text_cell v.task_title);
                      ("agent", Table.text_cell ("@" ^ v.agent_name));
                      ( "eval"
                      , Table.text_cell ~fg:(Color.of_rgb theme.text_secondary)
                          v.evaluator_runtime );
                    ];
                })
              verdicts
          in
          ignore
            (Table.draw grid ~rect:l_inner ~theme ~caps:Ops_common.default_caps
               ~lang:model.lang ~col_gap:(Layout.table_col_gap bp)
               ~scroll:model.work.harness_scroll_offset
               ?selected:model.work.harness_selected_index
               ~focused:(Model.pane_focused model 0) ~columns rows)
      | Observed.Value _ ->
          Ops_common.draw_observed_empty grid ~rect:l_inner ~theme
            ~lang:model.lang model.work.harness_health
            ~empty_msg:
              (Say.make ~ko:"기록된 하네스 판정이 없습니다"
                 ~en:"No harness verdicts recorded")
      | ( Observed.Loading _
        | Observed.Absent
        | Observed.Unreported
        | Observed.Failed _ ) as obs ->
          Ops_common.draw_observed_empty grid ~rect:l_inner ~theme
            ~lang:model.lang obs
            ~empty_msg:
              (Say.make ~ko:"하네스 헬스 불러오는 중..."
                 ~en:"Loading harness health...")
    end;
    let right_spec : Card.spec =
      {
        (Card.default_spec
           ~title:
             (Ops_common.say model ~ko:"판정 상세 · 교정 지표"
                ~en:"Verdict Detail & Calibration"))
        with
        hotkey =
          Some
            (Ops_common.say model ~ko:"[→/Tab] 상세 스크롤 · [y] 승인 · [n] 반려"
               ~en:"[→/Tab] Scroll Detail · [y] Approve · [n] Reject");
        focused = Model.detail_pane_focused ~detail_index:1 model;
      }
    in
    let r_inner = Card.draw ~cache grid ~rect:right_rect ~theme right_spec in
    if not (Rect.is_empty r_inner) then begin
      let pad_x = Ops_common.pad_x_for ~model r_inner in
      let content = Card.pad_inner ~pad_x r_inner in
      if not (Rect.is_empty content) then begin
        let bg = Color.of_rgb theme.surface_1 in
        let lines =
          Update_nav.harness_verdict_detail_lines ~width:content.w model
        in
        let max_s = Int.max 0 (List.length lines - Int.max 1 content.h) in
        let scroll =
          Int.min max_s (Int.max 0 model.work.detail_scroll_offset)
        in
        List.iteri
          (fun i ln ->
            let py = content.y + i in
            if py < Rect.bottom content then
              let st =
                if String.starts_with ~prefix:"──" ln then
                  Typography.accent ~bg ~bold:true theme
                else if String.starts_with ~prefix:"notes_hash (valid" ln then
                  Typography.status ~bg ~bold:true theme Theme.Status_ok
                else if String.starts_with ~prefix:"notes_hash (invalid" ln then
                  Typography.status ~bg ~bold:true theme Theme.Status_attention
                else Typography.primary ~bg theme
              in
              ignore
                (Ops_common.put_line ~clip:content grid ~x:content.x ~y:py
                   ~max_w:content.w ~style:st ln))
          (Store_scroll.drop scroll lines |> List.take content.h)
      end
    end
