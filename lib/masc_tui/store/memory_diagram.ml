open Masc_tui_core
open Masc_tui_protocol
open Masc_tui_ui

let min_graphic_cols = 12
let min_graphic_rows = 4

let lineage_kind_of_wire = function
  | Wire_knowledge.Activity_created -> Memory_lineage.Created
  | Wire_knowledge.Activity_reobserved -> Memory_lineage.Reobserved
  | Wire_knowledge.Activity_revised -> Memory_lineage.Revised
  | Wire_knowledge.Activity_absorbed -> Memory_lineage.Absorbed
  | Wire_knowledge.Activity_retracted -> Memory_lineage.Retracted
  | Wire_knowledge.Activity_removed -> Memory_lineage.Removed
  | Wire_knowledge.Activity_invalidated -> Memory_lineage.Invalidated
  | Wire_knowledge.Activity_relation_unavailable ->
      Memory_lineage.Relation_unavailable

let nonblank_opt = function
  | Some s when not (String.equal (String.trim s) "") -> Some s
  | Some _ | None -> None

let ordinary_claims_table ~keeper
    (facts_opt : Wire_knowledge.keeper_memory_facts option) =
  let tbl : (string, string) Hashtbl.t = Hashtbl.create 32 in
  (match facts_opt with
  | Some mf when String.equal mf.keeper keeper -> (
      match mf.ordinary with
      | Wire_knowledge.Memory_store_present ord ->
          List.iter
            (fun (f : Wire_knowledge.keeper_ordinary_fact) ->
              if not (String.equal (String.trim f.claim) "") then
                Hashtbl.replace tbl f.memory_id f.claim)
            ord.facts
      | Wire_knowledge.Memory_store_absent
      | Wire_knowledge.Memory_store_read_error _ ->
          ())
  | Some _ | None -> ());
  tbl

let convert_fact claims_tbl (f : Wire_knowledge.memory_activity_fact) :
    Memory_lineage.fact =
  let claim =
    match nonblank_opt f.claim with
    | Some _ as c -> c
    | None -> Hashtbl.find_opt claims_tbl f.memory_id
  in
  { Memory_lineage.memory_id = f.memory_id; claim }

let convert_event claims_tbl (ev : Wire_knowledge.memory_activity_event) :
    Memory_lineage.event =
  {
    Memory_lineage.identity = ev.identity;
    recorded_at = ev.recorded_at_unix;
    revision = ev.revision;
    kind = lineage_kind_of_wire ev.kind;
    before = List.map (convert_fact claims_tbl) ev.before;
    after = List.map (convert_fact claims_tbl) ev.after;
    reason = ev.reason;
  }

let chart_of_activity ~keeper ~(activity : Wire_knowledge.keeper_memory_activity)
    ~facts ~(selected : Wire_knowledge.memory_activity_event) =
  if not (String.equal activity.keeper keeper) then None
  else
    let claims_tbl = ordinary_claims_table ~keeper facts in
    let lineage_activity : Memory_lineage.activity =
      {
        events = List.map (convert_event claims_tbl) activity.events;
        limit = activity.limit;
        journal_lines = activity.journal_lines;
        notes = activity.notes;
      }
    in
    Memory_lineage.select ~event_id:selected.identity lineage_activity

let snapshot_of_ordinary_fact ~revision
    ~(activity : Wire_knowledge.keeper_memory_activity option)
    (fact : Wire_knowledge.keeper_ordinary_fact) : Memory_lineage.snapshot =
  {
    fact = { memory_id = fact.memory_id; claim = nonblank_opt (Some fact.claim) };
    revision;
    category = Wire_knowledge.memory_fact_category_to_string fact.category;
    origin = Wire_knowledge.memory_fact_origin_to_string fact.origin;
    first_seen = fact.first_seen_unix;
    last_seen = fact.last_seen_unix;
    activity_entries = Option.map (fun (a : Wire_knowledge.keeper_memory_activity) ->
        List.length a.events) activity;
  }

let event_references_fact ~memory_id (ev : Wire_knowledge.memory_activity_event)
    =
  let has_id xs =
    List.exists
      (fun (f : Wire_knowledge.memory_activity_fact) ->
        String.equal f.memory_id memory_id)
      xs
  in
  has_id ev.after || has_id ev.before

let find_latest_event_for_fact ~memory_id
    (activity : Wire_knowledge.keeper_memory_activity) =
  let better (best : Wire_knowledge.memory_activity_event)
      (cur : Wire_knowledge.memory_activity_event) =
    let tc = Float.compare cur.recorded_at_unix best.recorded_at_unix in
    if tc > 0 then true
    else if tc < 0 then false
    else cur.revision >= best.revision
  in
  List.fold_left
    (fun acc ev ->
      if not (event_references_fact ~memory_id ev) then acc
      else
        match acc with
        | None -> Some ev
        | Some prev -> if better prev ev then Some ev else acc)
    None activity.events

let parse_png_dimensions = Masc_tui_term.Graphics.png_dimensions

let mermaid_source ?tz_offset_sec ~ko ?now ~kind chart =
  match chart, kind with
  | Memory_lineage.Current_snapshot snapshot,
    (Knowledge_store.Diagram_pele_card | Knowledge_store.Diagram_formation_tree) ->
      Memory_lineage.snapshot_mermaid ?tz_offset_sec ~ko ?now snapshot
  | Memory_lineage.Lineage chart, Knowledge_store.Diagram_pele_card ->
      Memory_lineage.transition_mermaid ?tz_offset_sec ~ko ?now chart
  | Memory_lineage.Lineage chart, Knowledge_store.Diagram_formation_tree ->
      Memory_lineage.mermaid ?tz_offset_sec ~ko ?now chart

let mermaid_failure_note ~ko = function
  | Mermaid.Too_wide { cells; cols; _ } ->
      if ko then
        Printf.sprintf "Mermaid 폭 초과 (%d > %d열) · 원문 표시" cells cols
      else
        Printf.sprintf "Mermaid too wide (%d > %d cols) · showing source" cells
          cols
  | Mermaid.Parse_error { line; what } ->
      if ko then
        Printf.sprintf "Mermaid 파싱 오류 (줄 %d: %s) · 원문 표시" line what
      else
        Printf.sprintf "Mermaid parse error (line %d: %s) · showing source" line
          what
  | Mermaid.Unsupported kind_word ->
      if ko then
        Printf.sprintf "미지원 Mermaid 유형 (%s) · 원문 표시" kind_word
      else
        Printf.sprintf "Unsupported Mermaid kind (%s) · showing source"
          kind_word

let render_mermaid_fallback ?tz_offset_sec ~ko ?now ~max_width ~kind chart =
  let cols = Int.max 12 max_width in
  let src = mermaid_source ?tz_offset_sec ~ko ?now ~kind chart in
  match Mermaid.render_adaptive ~cols src with
  | Ok rows -> (rows, None)
  | Error failure -> (
      match chart with
      | Memory_lineage.Current_snapshot snapshot ->
          let note =
            if ko then "현재 스냅샷을 텍스트로 표시합니다"
            else "Showing the current snapshot as text"
          in
          (Memory_lineage.snapshot_lines ?tz_offset_sec ~ko ?now ~max_width:cols snapshot, Some note)
      | Memory_lineage.Lineage _ ->
          let raw_lines = Knowledge_store.wrap_lines ~max_width:cols src in
          (raw_lines, Some (mermaid_failure_note ~ko failure)))

let render_tree_lines ?tz_offset_sec ~ko ?now ?keeper_name ~max_width chart =
  match chart with
  | Memory_lineage.Lineage lineage ->
      Memory_tree.render_lines ?tz_offset_sec ~ko ?now ?keeper_name
        ~max_width:(Int.max 12 max_width) lineage
  | Memory_lineage.Current_snapshot snapshot ->
      Memory_lineage.snapshot_lines ?tz_offset_sec ~ko ?now ~max_width snapshot
      |> List.map (fun text -> { Memory_tree.kind = Memory_tree.Scope; text })

let copy_source_of_chart ?tz_offset_sec ~ko ?now ?keeper_name ~max_width ~kind
    ~mode chart =
  let tree_text () =
    render_tree_lines ?tz_offset_sec ~ko ?now ?keeper_name ~max_width chart
    |> List.map (fun (ln : Memory_tree.line) -> ln.text)
    |> String.concat "\n"
  in
  match mode with
  | Knowledge_store.Diagram_mode_tree -> tree_text ()
  | Knowledge_store.Diagram_mode_mermaid ->
      mermaid_source ?tz_offset_sec ~ko ?now ~kind chart
  | Knowledge_store.Diagram_mode_auto -> (
      match kind with
      | Knowledge_store.Diagram_pele_card ->
          mermaid_source ?tz_offset_sec ~ko ?now ~kind chart
      | Knowledge_store.Diagram_formation_tree -> tree_text ())

(* --- Single-SSOT Screen Geometry (matches Chrome + Knowledge + Keepers) --- *)

let model_bp_of_layout = function
  | Layout.Wide -> Model.Wide
  | Layout.Standard -> Model.Standard
  | Layout.Compact -> Model.Compact
  | Layout.Micro -> Model.Micro

let voice_state_of_drafts (drafts : Drafts.t) =
  match drafts.voice with
  | Drafts.Voice_off | Drafts.Voice_error _ ->
      Composer.Voice_off
  | Drafts.Voice_recording { levels; elapsed_s; _ } ->
      Composer.Voice_recording { levels = Array.of_list levels; elapsed_s }
  | Drafts.Voice_transcribing -> Composer.Voice_transcribing

let chrome_body_rect (m : Model.t) =
  let cols = Int.max 0 m.viewport.cols in
  let rows = Int.max 0 m.viewport.rows in
  let bp = Layout.classify_viewport ~cols ~rows in
  if
    Layout.is_too_small_blocker ~cols ~rows
    || Layout.equal_breakpoint bp Layout.Micro
  then None
  else
    let top_h = (if rows >= 1 then 1 else 0) + (if rows >= 5 then 1 else 0) in
    let footer_h = if rows >= 2 then 1 else 0 in
    let sized_model =
      { m with viewport = { cols; rows }; breakpoint = model_bp_of_layout bp }
    in
    let comp_mode = Model.composer_mode sized_model in
    let comp_h_raw =
      match comp_mode with
      | Model.Auto_folded_pill -> 0
      | Model.Collapsed_bar -> 1
      | Model.Expanded_multiline ->
          let max_h = Int.max 2 (Int.min 6 (rows / 4)) in
          let draft = Drafts.current_draft sized_model.drafts in
          let keeper =
            match sized_model.drafts.active_keeper with
            | Some k when not (String.equal (String.trim k) "") ->
                String.trim k
            | Some _ | None -> (
                match Model.selected_keeper_name sized_model with
                | Some name -> name
                | None -> Drafts.target_keeper_key sized_model.drafts)
          in
          let phase = Chat_transcript.live_chat_phase ~model:sized_model ~keeper in
          let pending_tx = Chat_transcript.composer_pending_tx_of_phase phase in
          let comp_st : Composer.state =
            {
              target_keeper = keeper;
              draft = draft.text;
              cursor = draft.cursor;
              focused = Drafts.is_focused sized_model.drafts;
              pending_tx;
              voice = voice_state_of_drafts sized_model.drafts;
              popup = Composer.Popup_none;
              draft_count_other_keepers =
                Drafts.other_keepers_draft_count sized_model.drafts;
            }
          in
          Composer.desired_height ~breakpoint:bp ~max_height:max_h comp_st
    in
    let has_approval = Option.is_some (Model.fast_approval_strip_item m) in
    let avail = Int.max 0 (rows - top_h - footer_h) in
    let comp_h = Int.min comp_h_raw (Int.max 0 (avail - 3)) in
    let approval_h =
      if has_approval && avail - comp_h >= 4 then 1 else 0
    in
    let footer_sep_h =
      if
        Layout.equal_breakpoint bp Layout.Wide
        && rows >= 36
        && avail - comp_h - approval_h >= 24
      then 1
      else 0
    in
    let approval_y = rows - footer_h - footer_sep_h - comp_h - approval_h in
    let body_h = Int.max 0 (approval_y - top_h) in
    let full_body =
      Layout.inset_body bp (Rect.make ~x:0 ~y:top_h ~w:cols ~h:body_h)
    in
    let body =
      if
        Model.sidebar_docked sized_model
        && full_body.w >= Model.sidebar_width + 20
      then
        let sw = Model.sidebar_width in
        let gap = Model.sidebar_gap in
        Rect.make ~x:(full_body.x + sw + gap) ~y:full_body.y
          ~w:(Int.max 0 (full_body.w - sw - gap))
          ~h:full_body.h
      else full_body
    in
    Some (bp, body)

let keeper_memory_content_of_tabs_body ~(model : Model.t) ~name ~bp ~embedded
    ~has_keeper (target_rect : Rect.t) =
  let inner = Card.inner_rect target_rect in
  if Rect.is_empty inner then Rect.empty
  else
    let after_hero =
      if embedded && has_keeper && inner.h >= 16 then
        snd (Rect.split_v inner ~top_h:5)
      else inner
    in
    let content_rect =
      if embedded && model.nav.pane_index = 0 && after_hero.h >= 3 then
        let _, body_rect = Rect.split_v after_hero ~top_h:1 in
        if body_rect.h >= 6 then
          Rect.make ~x:body_rect.x ~y:(body_rect.y + 1) ~w:body_rect.w
            ~h:(body_rect.h - 1)
        else body_rect
      else after_hero
    in
    let content_rect =
      if Rect.is_empty content_rect then content_rect
      else
        let banner_h =
          Model.keeper_diagnostic_banner_height ~name ~avail_h:content_rect.h
            model
        in
        if banner_h <= 0 then content_rect
        else snd (Rect.split_v content_rect ~top_h:banner_h)
    in
    if Rect.is_empty content_rect then Rect.empty
    else
      let pad_x =
        if content_rect.w < 20 then 0
        else if content_rect.w < 44 then 1
        else Layout.card_pad_x bp
      in
      let subbar_h = if content_rect.h >= 4 then 1 else 0 in
      let after_subbar =
        if subbar_h = 1 then snd (Rect.split_v content_rect ~top_h:1)
        else content_rect
      in
      Card.pad_inner ~pad_x after_subbar

let active_memory_content_rect (m : Model.t) =
  if Option.is_some m.nav.overlay then None
  else
    match chrome_body_rect m with
    | None -> None
    | Some (bp, body) -> (
        match Model.active_dive m with
        | Some
            ( Nav.Dive_work _
            | Nav.Dive_knowledge _
            | Nav.Dive_runtime _ ) ->
            None
        | None -> (
            match m.nav.workspace with
            | Nav.Keepers
              when Nav.equal_keeper_tab m.fleet.keeper_dive_tab Nav.Keeper_memory
              -> (
                match Model.selected_keeper_name m with
                | None -> None
                | Some name ->
                    (* Open Memory Diagrams on [4 Keepers > Memory] always
                       expand into the full body card ([~embedded:false]), so
                       compact widths (< 104 cols) and wide panes share the
                       exact same geometry and never drop [.] / [Ctrl+O]. *)
                    let has_keeper =
                      Option.is_some (Fleet_store.find_keeper ~name m.fleet)
                    in
                    let content =
                      keeper_memory_content_of_tabs_body ~model:m ~name
                        ~bp ~embedded:false ~has_keeper body
                    in
                    if Rect.is_empty content then None
                    else Some (name, content))
            | Nav.Knowledge
              when Nav.equal_knowledge_tab m.knowledge.active_tab
                     Nav.Knowledge_memory
              -> (
                match m.knowledge.memory_diff_keeper with
                | None -> None
                | Some keeper ->
                    let k_body =
                      if body.x = 0 then Layout.inset_body bp body else body
                    in
                    let mem_body =
                      match
                        Layout.split_v k_body [ Layout.Fixed 1; Layout.Flex 1 ]
                      with
                      | [ _; b ] -> b
                      | _ -> k_body
                    in
                    (* Open Memory Diagrams in [3 Knowledge > Memory] expand
                       into the full [mem_body] card across all subviews
                       (Diff/Flow, Health & Ledger, Context). *)
                    let inner = Card.inner_rect mem_body in
                    let content =
                      Card.pad_inner ~pad_x:(Layout.card_pad_x bp) ~pad_y:0
                        inner
                    in
                    if Rect.is_empty content then None
                    else Some (keeper, content))
            | Nav.Pulse
            | Nav.Work
            | Nav.Keepers
            | Nav.Knowledge
            | Nav.Runtime
            | Nav.Infra ->
                None))

let active_memory_keeper (m : Model.t) =
  Option.map fst (active_memory_content_rect m)

let active_diagram (m : Model.t) =
  match active_memory_content_rect m, m.knowledge.memory_diagram with
  | Some (keeper, _), Some d
    when Knowledge_store.memory_diagram_matches_scope ~keeper_opt:(Some keeper)
           d ->
      Some d
  | (Some _ | None), (Some _ | None) -> None

let can_render_png_in_rect ~(content_rect : Rect.t)
    (d : Knowledge_store.memory_diagram_state) =
  if not (Knowledge_store.equal_memory_diagram_mode d.mode Diagram_mode_auto)
  then false
  else
    match Observed.to_option d.payload with
    | Some (Knowledge_store.Diagram_pele_png _) ->
        let _, after_hdr = Rect.split_v content_rect ~top_h:1 in
        after_hdr.w >= min_graphic_cols && after_hdr.h >= min_graphic_rows
    | Some (Knowledge_store.Diagram_text _) | None -> false

let diagram_body_rect ~(content_rect : Rect.t)
    (d : Knowledge_store.memory_diagram_state) =
  if Rect.is_empty content_rect then (Rect.empty, false)
  else
    let _, after_hdr = Rect.split_v content_rect ~top_h:1 in
    if Rect.is_empty after_hdr then (Rect.empty, false)
    else
      let has_note =
        match Observed.to_option d.payload with
        | Some (Knowledge_store.Diagram_text { note = Some n; _ })
          when not (String.equal (String.trim n) "") ->
            after_hdr.h >= 2
        | Some (Knowledge_store.Diagram_text _) -> false
        | Some (Knowledge_store.Diagram_pele_png _) ->
            (not (can_render_png_in_rect ~content_rect d)) && after_hdr.h >= 2
        | None -> false
      in
      if has_note then
        let _, body = Rect.split_v after_hdr ~top_h:1 in
        (body, true)
      else (after_hdr, false)

let active_diagram_body_rect (m : Model.t) =
  match active_memory_content_rect m, m.knowledge.memory_diagram with
  | Some (keeper, content_rect), Some d
    when Knowledge_store.memory_diagram_matches_scope ~keeper_opt:(Some keeper)
           d ->
      let body, _ = diagram_body_rect ~content_rect d in
      if Rect.is_empty body then None else Some body
  | (Some _ | None), (Some _ | None) -> None
