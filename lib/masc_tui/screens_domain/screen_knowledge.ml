open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

module H = Domain_helpers

(* --- 1. Board Helpers --- *)

let unique_strings xs =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun s ->
      if Hashtbl.mem seen s then false
      else begin
        Hashtbl.add seen s ();
        true
      end)
    xs

let post_visibility_label ~lang = function
  | None -> ""
  | Some Wire_knowledge.Vis_public ->
      Say.resolve lang (Say.make ~ko:"공개" ~en:"Public")
  | Some Wire_knowledge.Vis_unlisted ->
      Say.resolve lang (Say.make ~ko:"미등재" ~en:"Unlisted")
  | Some Wire_knowledge.Vis_internal ->
      Say.resolve lang (Say.make ~ko:"내부" ~en:"Internal")
  | Some Wire_knowledge.Vis_direct ->
      Say.resolve lang (Say.make ~ko:"직접" ~en:"Direct")

let format_karma_badge ~lang (p : Wire_knowledge.board_post) =
  let score_part =
    Printf.sprintf "%s+%d" (Glyph.to_utf8 Glyph.Delta_up) p.score
  in
  let karma_part =
    match p.author_karma with
    | Observed.Value { data; stale; observed_at = _ } ->
        let prefix =
          if stale then Glyph.to_utf8 Glyph.Transport_stale ^ " " else ""
        in
        Printf.sprintf "%sKarma %s%d" prefix (if data >= 0 then "+" else "") data
    | Observed.Loading _ -> "Karma " ^ Glyph.to_utf8 Glyph.Ellipsis
    | Observed.Absent -> ""
    | Observed.Unreported ->
        Say.resolve lang
          (Say.make ~ko:"Karma ? 미보고" ~en:"Karma ? Unreported")
    | Observed.Failed _ ->
        Say.resolve lang (Say.make ~ko:"Karma ✕" ~en:"Karma ✕")
  in
  if String.equal karma_part "" then score_part
  else score_part ^ Typography.sep_dot ^ karma_part

let draw_board_preview ~grid ~cache ~(rect : Rect.t) ~(theme : Theme.t) ~bp
    ~lang ~now_unix ~(k : Knowledge_store.t)
    (post_opt : Wire_knowledge.board_post option) ~focused =
  let title, subtitle, badge =
    match post_opt with
    | None ->
        ( Say.resolve lang (Say.make ~ko:"타래 미리보기" ~en:"Thread Preview")
        , None
        , None )
    | Some p ->
        let hearth_s =
          match p.hearth with Some h -> "#" ^ h | None -> "#general"
        in
        let chain_s =
          match p.chain_depth with
          | Some d when d > 1 -> Printf.sprintf "[x%d] %s" d hearth_s
          | Some _ | None -> hearth_s
        in
        let karma_b =
          H.make_badge ~glyph:Glyph.Delta_up ~tone:Theme.Status_ok
            (format_karma_badge ~lang p)
        in
        ( Say.resolve lang (Say.make ~ko:"타래 미리보기" ~en:"Thread Preview")
        , Some chain_s
        , Some karma_b )
  in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ?subtitle ?badge
         ~hotkey:(Say.resolve lang (Say.make ~ko:"[Enter] 상세" ~en:"[Enter] Dive"))
         ~focused title)
  in
  if Rect.is_empty inner then ()
  else
    match post_opt with
    | None ->
        H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp inner) ~theme
          ~lang k.board
    | Some p ->
        let pad_x = Layout.card_pad_x bp in
        let age = H.format_age ~now_unix p.created_at_unix in
        let vis = post_visibility_label ~lang p.visibility in
        let vis_part =
          if String.equal vis "" then "" else Typography.sep_dot ^ vis
        in
        let meta =
          Printf.sprintf "@%s%s%s%s%d %s%s" p.author Typography.sep_dot age
            Typography.sep_dot p.comment_count
            (Say.resolve lang (Say.make ~ko:"댓글" ~en:"comments"))
            vis_part
        in
        let band_h = if inner.h >= 7 then 2 else 1 in
        Card.draw_section_band ~pad_x grid
          ~rect:(Rect.make ~x:inner.x ~y:inner.y ~w:inner.w ~h:band_h)
          ~theme ~left_title:p.title ~right_meta:age
          ?subtitle:(if band_h >= 2 then Some meta else None)
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
          (* Succession chain strip when post belongs to a chain *)
          (match p.succession_chain_root_id, p.chain_depth with
           | Some _, Some d when d > 1 && !y < bottom ->
               let strip =
                 Printf.sprintf "%s %s #%d %s #%d · [Enter]"
                   (Glyph.to_utf8 Glyph.Flow_down)
                   (Say.resolve lang (Say.make ~ko:"계승 체인" ~en:"Chain"))
                   (Int.max 1 (d - 1))
                   "→" d
               in
               ignore
                 (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                    ~max_w:content.w ~style:(H.accent_style ~theme ()) strip);
               incr y;
               if !y < bottom then begin
                 H.draw_divider ~grid ~rect:content ~y:!y ~theme ();
                 incr y
               end
           | _ ->
               if bottom - !y >= 6 then incr y);
          let comments =
            match Observed.to_option k.active_thread with
            | Some (tp, cs) when String.equal tp.id p.id -> cs
            | Some _ | None -> []
          in
          let comment_rows =
            if comments = [] || bottom - !y < 6 then 0
            else Int.min 5 (1 + List.length comments)
          in
          let md_h = Int.max 0 (bottom - !y - comment_rows) in
          if md_h > 0 then begin
            let md_rect = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:md_h in
            ignore (Markdown.draw grid ~rect:md_rect ~theme ~osc8:true p.body);
            y := !y + md_h
          end;
          if comment_rows > 0 && !y < bottom then begin
            H.draw_divider ~grid ~rect:content ~y:!y ~theme
              ~label:
                (Printf.sprintf "%s (%d)"
                   (Say.resolve lang (Say.make ~ko:"댓글" ~en:"Comments"))
                   (List.length comments))
              ();
            incr y;
            List.iter
              (fun (c : Wire_knowledge.board_comment) ->
                if !y < bottom then begin
                  Card.draw_left_rail ~color:theme.border_inactive grid
                    ~x:content.x ~y:!y ~h:1 ~theme;
                  let c_age = H.format_age ~now_unix c.created_at_unix in
                  let aw = Grapheme.display_width c_age in
                  let body_s =
                    Printf.sprintf "@%s  %s" c.author
                      (H.sanitize_single_line c.body)
                  in
                  ignore
                    (H.put_clipped ~grid ~clip:content ~x:(content.x + 2) ~y:!y
                       ~max_w:(Int.max 6 (content.w - aw - 4))
                       ~style:(H.secondary_style ~theme ()) body_s);
                  ignore
                    (H.put_right ~grid ~clip:content
                       ~right_x:(Rect.right content) ~y:!y ~max_w:aw
                       ~style:(H.whisper_style ~theme ()) c_age);
                  incr y
                end)
              (H.safe_take (bottom - !y) comments)
          end

let draw_quarantine_strip ~grid ~(rect : Rect.t) ~(theme : Theme.t) ~bp ~lang
    ~now_unix (quarantines : Wire_knowledge.quarantine_candidate list) =
  if Rect.is_empty rect then ()
  else
    let pad_x = Layout.card_pad_x bp in
    let n = List.length quarantines in
    if n = 0 then begin
      let y = rect.y in
      let line =
        Printf.sprintf "%s %s"
          (Glyph.to_utf8 Glyph.Live_healthy)
          (Say.resolve lang
             (Say.make ~ko:"보드 주목 격리: 0건 (정상)"
                ~en:"Board Attention Quarantine: 0 (healthy)"))
      in
      ignore
        (H.put_clipped ~grid ~clip:rect ~x:(rect.x + pad_x) ~y
           ~max_w:(Int.max 0 (rect.w - (2 * pad_x)))
           ~style:(H.status_style ~theme Theme.Status_ok)
           line)
    end
    else begin
      let y = ref rect.y in
      let bottom = Rect.bottom rect in
      H.draw_divider ~grid ~rect ~y:!y ~theme ~pad_x
        ~label:
          (Printf.sprintf "%s %s (%d)"
             (Glyph.to_utf8 Glyph.Action_required)
             (Say.resolve lang
                (Say.make ~ko:"격리 큐 · CAS 재큐"
                   ~en:"Quarantined · CAS Requeue"))
             n)
        ();
      incr y;
      let tx = rect.x + pad_x in
      let tw = Int.max 0 (rect.w - (2 * pad_x)) in
      if !y < bottom then begin
        let counts : (string, int) Hashtbl.t = Hashtbl.create 16 in
        let order = ref [] in
        List.iter
          (fun (q : Wire_knowledge.quarantine_candidate) ->
            match Hashtbl.find_opt counts q.keeper with
            | None ->
                order := q.keeper :: !order;
                Hashtbl.add counts q.keeper 1
            | Some c -> Hashtbl.replace counts q.keeper (c + 1))
          quarantines;
        let summary =
          List.rev !order |> H.safe_take 5
          |> List.map (fun kp ->
                 let c = Option.value ~default:0 (Hashtbl.find_opt counts kp) in
                 Printf.sprintf "%s(%d)" kp c)
          |> String.concat ", "
        in
        Card.draw_left_rail ~tone:Theme.Status_attention grid ~x:tx ~y:!y ~h:1
          ~theme;
        let line =
          Printf.sprintf "%s %s · [R] %s"
            (Glyph.to_utf8 Glyph.Action_required)
            summary
            (Say.resolve lang (Say.make ~ko:"선택 재큐" ~en:"CAS Requeue"))
        in
        ignore
          (H.put_clipped ~grid ~clip:rect ~x:(tx + 2) ~y:!y
             ~max_w:(Int.max 0 (tw - 2))
             ~style:
               (H.status_style ~theme ~attrs:Attr.bold Theme.Status_attention)
             line);
        incr y
      end;
      match quarantines with
      | q :: _ when !y < bottom ->
          let age =
            match q.quarantined_at_unix with
            | Some ts -> H.format_age ~now_unix ts
            | None -> Glyph.to_utf8 Glyph.Missing_absent
          in
          Card.draw_left_rail ~tone:Theme.Status_attention grid ~x:tx ~y:!y ~h:1
            ~theme;
          let evidence =
            Printf.sprintf "%s [%s] %s · q=%s · %s (%s)" q.keeper q.status
              q.failure_reason
              (H.short_hash ~len:8 q.quarantine_id)
              (H.short_hash ~len:10 q.post_id)
              age
          in
          ignore
            (H.put_clipped ~grid ~clip:rect ~x:(tx + 2) ~y:!y
               ~max_w:(Int.max 0 (tw - 2)) ~style:(H.whisper_style ~theme ())
               evidence)
      | _ -> ()
    end

let render_board ~(model : Model.t) ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp grid =
  let lang = model.lang in
  let k = model.knowledge in
  let now_unix = model.freshness.last_wall_unix in
  let all_posts =
    match Observed.to_option k.board with Some f -> f.posts | None -> []
  in
  let filtered = Knowledge_store.filtered_posts k in
  let hidden_verify = Int.max 0 (List.length all_posts - List.length filtered) in
  let verify_count =
    List.fold_left
      (fun acc (p : Wire_knowledge.board_post) ->
        let is_verify =
          (not p.is_signal)
          ||
          match p.post_kind with
          | Some Wire_knowledge.System_post -> true
          | Some (Wire_knowledge.Human_post | Wire_knowledge.Automation_post)
          | None ->
              false
        in
        if is_verify then acc + 1 else acc)
      0 all_posts
  in
  let direct_count =
    List.fold_left
      (fun acc (p : Wire_knowledge.board_post) ->
        match p.visibility with
        | Some Wire_knowledge.Vis_direct -> acc + 1
        | Some
            ( Wire_knowledge.Vis_public
            | Wire_knowledge.Vis_unlisted
            | Wire_knowledge.Vis_internal )
        | None ->
            acc)
      0 all_posts
  in
  let quarantines = Knowledge_store.quarantines_list k in
  let q_count = List.length quarantines in
  let filter_rect, body_rect =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ f; b ] -> (f, b)
    | _ -> (Rect.empty, rect)
  in
  let signal_lbl =
    if k.board_signal_only && hidden_verify > 0 then
      Say.resolve lang
        (Say.make
           ~ko:(Printf.sprintf "신호만 (-%d Verify)" hidden_verify)
           ~en:(Printf.sprintf "Signal Only (-%d Verify)" hidden_verify))
    else Say.resolve lang (Say.make ~ko:"신호만" ~en:"Signal Only")
  in
  let pills =
    [
      {
        H.label = signal_lbl;
        active = k.board_signal_only;
        tone = Some Theme.Status_ok;
        glyph = Some Glyph.Live_healthy;
      };
      {
        H.label =
          Printf.sprintf "%s (%d)"
            (Say.resolve lang (Say.make ~ko:"전체" ~en:"All"))
            (List.length all_posts);
        active = not k.board_signal_only;
        tone = None;
        glyph = None;
      };
      {
        H.label = Printf.sprintf "Verify/Sys (%d)" verify_count;
        active = false;
        tone = Some Theme.Status_historical;
        glyph = None;
      };
      {
        H.label =
          Printf.sprintf "%s (%d)"
            (Say.resolve lang (Say.make ~ko:"직접" ~en:"Direct"))
            direct_count;
        active = false;
        tone = Some Theme.Status_active;
        glyph = None;
      };
      {
        H.label =
          Printf.sprintf "%s %d"
            (Say.resolve lang (Say.make ~ko:"격리" ~en:"Quar"))
            q_count;
        active = q_count > 0;
        tone =
          Some
            (if q_count > 0 then Theme.Status_attention else Theme.Status_ok);
        glyph = Some Glyph.Action_required;
      };
    ]
    @
    if String.equal (String.trim k.filter_query) "" then []
    else
      [
        {
          H.label = "/" ^ k.filter_query;
          active = true;
          tone = Some Theme.Status_active;
          glyph = None;
        };
      ]
  in
  ignore (H.draw_pills ~grid ~rect:filter_rect ~theme pills);
  let selected_post = Knowledge_store.selected_post k in
  if model.nav.zoomed then
    draw_board_preview ~grid ~cache ~rect:body_rect ~theme ~bp ~lang ~now_unix ~k
      selected_post ~focused:true
  else
    let list_rect, preview_rect =
      Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.48
        ~top_ratio:0.54 bp body_rect
    in
    let list_title =
      if k.board_signal_only then
        Say.resolve lang
          (Say.make
             ~ko:(Printf.sprintf "신호 타래 · %d건" (List.length filtered))
             ~en:(Printf.sprintf "Signal Threads · %d" (List.length filtered)))
      else
        Say.resolve lang
          (Say.make
             ~ko:(Printf.sprintf "전체 보드 · %d건" (List.length filtered))
             ~en:(Printf.sprintf "All Board · %d" (List.length filtered)))
    in
    let list_inner =
      Card.draw ~cache grid ~rect:list_rect ~theme
        (H.card_spec ~focused:(model.nav.pane_index = 0)
           ~hotkey:(Say.resolve lang (Say.make ~ko:"[Space] 계승" ~en:"[Space] Chain"))
           list_title)
    in
    if not (Rect.is_empty list_inner) then begin
      let pad_x = Layout.card_pad_x bp in
      let hearths =
        all_posts
        |> List.filter_map (fun (p : Wire_knowledge.board_post) -> p.hearth)
        |> unique_strings |> H.safe_take 8
      in
      let hearth_rows =
        if list_inner.h >= 6 then 2 else if list_inner.h >= 4 then 1 else 0
      in
      let quar_rows =
        if list_inner.h >= 8 then if q_count > 0 then 3 else 1
        else if list_inner.h >= 6 && q_count > 0 then 2
        else 0
      in
      let feed_h = Int.max 0 (list_inner.h - hearth_rows - quar_rows) in
      let cur_y = ref list_inner.y in
      if hearth_rows >= 1 then begin
        let h_rect =
          Rect.make ~x:(list_inner.x + pad_x) ~y:!cur_y
            ~w:(Int.max 0 (list_inner.w - (2 * pad_x)))
            ~h:1
        in
        let h_pills =
          {
            H.label = Say.resolve lang (Say.make ~ko:"전체" ~en:"All");
            active = Option.is_none k.board_hearth;
            tone = None;
            glyph = None;
          }
          :: List.map
               (fun h ->
                 let is_sel =
                   match k.board_hearth with
                   | Some cur -> String.equal cur h
                   | None -> false
                 in
                 {
                   H.label = "#" ^ h;
                   active = is_sel;
                   tone = None;
                   glyph = None;
                 })
               hearths
        in
        ignore
          (H.draw_pills ~grid ~rect:h_rect ~theme ~bg:theme.surface_1 h_pills);
        incr cur_y;
        if hearth_rows >= 2 then begin
          H.draw_divider ~grid ~rect:list_inner ~y:!cur_y ~theme ();
          incr cur_y
        end
      end;
      let feed_rect =
        Rect.make ~x:list_inner.x ~y:!cur_y ~w:list_inner.w ~h:feed_h
      in
      cur_y := !cur_y + feed_h;
      let pad_r = if list_inner.w >= 24 then 2 else 1 in
      (match k.board with
       | Observed.Value _ when filtered <> [] ->
           let groups = Knowledge_store.group_succession_chains filtered in
           let sel_id =
             match selected_post with Some p -> Some p.id | None -> None
           in
           let visual_rows = ref [] in
           List.iter
             (fun (grp : Knowledge_store.succession_group) ->
               let is_expanded =
                 match grp.chain_root_id with
                 | Some root_id ->
                     Knowledge_store.is_succession_chain_expanded ~root_id k
                 | None -> false
               in
               let group_has_sel =
                 match sel_id with
                 | None -> false
                 | Some sid ->
                     List.exists
                       (fun (m : Wire_knowledge.board_post) ->
                         String.equal m.id sid)
                       grp.members
               in
               visual_rows :=
                 (`Group (grp, is_expanded, group_has_sel)) :: !visual_rows;
               if is_expanded && List.length grp.members > 1 then
                 let total_m = List.length grp.members in
                 List.iteri
                   (fun idx (m : Wire_knowledge.board_post) ->
                     let is_last = Int.equal idx (total_m - 1) in
                     let is_sel =
                       match sel_id with
                       | Some sid -> String.equal m.id sid
                       | None -> false
                     in
                     visual_rows :=
                       (`Member (m, is_last, is_sel)) :: !visual_rows)
                   grp.members)
             groups;
           let v_arr = Array.of_list (List.rev !visual_rows) in
           let total_v = Array.length v_arr in
           let sel_v_idx =
             let found = ref None in
             for i = 0 to total_v - 1 do
               match v_arr.(i) with
               | `Member (_, _, true) -> found := Some i
               | `Group (_, false, true) ->
                   if Option.is_none !found then found := Some i
               | `Group (_, true, true) ->
                   if Option.is_none !found then found := Some i
               | `Group (_, _, false) | `Member (_, _, false) -> ()
             done;
             !found
           in
           let start_v, _ =
             Table.compute_viewport ~total_rows:total_v
               ~viewport_rows:feed_rect.h ~scroll:k.scroll_offset
               ~selected:sel_v_idx
           in
           for row_i = 0 to feed_rect.h - 1 do
             let idx = start_v + row_i in
             if idx < total_v then begin
               let py = feed_rect.y + row_i in
               let r_rect =
                 Rect.make ~x:feed_rect.x ~y:py ~w:feed_rect.w ~h:1
               in
               let tx = feed_rect.x + 2 in
               let right_edge = Rect.right feed_rect - pad_r in
               match v_arr.(idx) with
               | `Group (grp, is_expanded, is_sel) ->
                   let p = grp.lead in
                   let row_bg =
                     if is_sel then theme.selection_bg else theme.surface_1
                   in
                   if is_sel then
                     H.paint_selected_row_bg ~grid ~clip:feed_rect
                       ~row_rect:r_rect ~theme ();
                   let age = H.format_age ~now_unix p.created_at_unix in
                   let replies_s = Printf.sprintf "%dc" p.comment_count in
                   let age_w = Grapheme.display_width age in
                   let rep_w = Grapheme.display_width replies_s in
                   let right_total = rep_w + 2 + age_w in
                   ignore
                     (H.put_right ~grid ~clip:r_rect ~right_x:right_edge ~y:py
                        ~max_w:age_w
                        ~style:(H.whisper_style ~theme ~bg:row_bg ())
                        age);
                   ignore
                     (H.put_right ~grid ~clip:r_rect
                        ~right_x:(right_edge - age_w - 2) ~y:py ~max_w:rep_w
                        ~style:(H.secondary_style ~theme ~bg:row_bg ())
                        replies_s);
                   let left_limit = right_edge - right_total - 2 in
                   let cx = ref tx in
                   if grp.chain_count > 1 then begin
                     let caret =
                       if is_expanded then Glyph.Expand_open
                       else Glyph.Expand_closed
                     in
                     let tag =
                       if grp.unique_keepers > 1 then
                         Printf.sprintf "%s [x%d] %dk " (Glyph.to_utf8 caret)
                           grp.chain_count grp.unique_keepers
                       else
                         Printf.sprintf "%s [x%d] " (Glyph.to_utf8 caret)
                           grp.chain_count
                     in
                     let adv =
                       H.put_clipped ~grid ~clip:r_rect ~x:!cx ~y:py
                         ~max_w:(Int.max 0 (left_limit - !cx))
                         ~style:
                           (H.accent_style ~theme ~bg:row_bg ~attrs:Attr.bold ())
                         tag
                     in
                     cx := !cx + adv
                   end
                   else begin
                     match p.hearth with
                     | Some h when left_limit - !cx > 18 ->
                         let h_s =
                           Grapheme.truncate_to_width ~max_width:10 ("#" ^ h)
                         in
                         let adv =
                           H.put_clipped ~grid ~clip:r_rect ~x:!cx ~y:py
                             ~max_w:10
                             ~style:(H.secondary_style ~theme ~bg:row_bg ())
                             h_s
                         in
                         cx := !cx + adv + 2
                     | Some _ | None -> ()
                   end;
                   let title_style =
                     if is_sel then H.anchor_style ~theme ~bg:row_bg ()
                     else H.text_style ~theme ~bg:row_bg ()
                   in
                   ignore
                     (H.put_clipped ~grid ~clip:r_rect ~x:!cx ~y:py
                        ~max_w:(Int.max 0 (left_limit - !cx))
                        ~style:title_style p.title)
               | `Member (m, is_last, is_sel) ->
                   let row_bg =
                     if is_sel then theme.selection_bg else theme.surface_1
                   in
                   if is_sel then
                     H.paint_selected_row_bg ~grid ~clip:feed_rect
                       ~row_rect:r_rect ~theme ();
                   let branch =
                     if is_last then Glyph.Tree_corner else Glyph.Tree_tee
                   in
                   let age = H.format_age ~now_unix m.created_at_unix in
                   let aw = Grapheme.display_width age in
                   let left_s =
                     Printf.sprintf "  %s @%s  %s" (Glyph.to_utf8 branch)
                       m.author m.title
                   in
                   ignore
                     (H.put_clipped ~grid ~clip:r_rect ~x:tx ~y:py
                        ~max_w:(Int.max 0 (right_edge - tx - aw - 2))
                        ~style:
                          (if is_sel then H.anchor_style ~theme ~bg:row_bg ()
                           else H.secondary_style ~theme ~bg:row_bg ())
                        left_s);
                   ignore
                     (H.put_right ~grid ~clip:r_rect ~right_x:right_edge ~y:py
                        ~max_w:aw ~style:(H.whisper_style ~theme ~bg:row_bg ())
                        age)
             end
           done
       | Observed.Value _ ->
           H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp feed_rect) ~theme
             (Say.resolve lang
                (Say.make ~ko:"조건에 맞는 보드 글이 없습니다"
                   ~en:"No board posts match the current filter"))
       | ( Observed.Loading _
         | Observed.Absent
         | Observed.Unreported
         | Observed.Failed _ ) as obs ->
           H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp feed_rect)
             ~theme ~lang obs);
      if quar_rows > 0 then begin
        let q_rect =
          Rect.make ~x:list_inner.x ~y:!cur_y ~w:list_inner.w ~h:quar_rows
        in
        draw_quarantine_strip ~grid ~rect:q_rect ~theme ~bp ~lang ~now_unix
          quarantines
      end
    end;
    draw_board_preview ~grid ~cache ~rect:preview_rect ~theme ~bp ~lang
      ~now_unix ~k selected_post ~focused:(model.nav.pane_index = 1)

(* --- 2. Wiki & Artifacts Sub-Tab (38/62 Split + Wide TOC Rail) --- *)

let wiki_source_badge ~lang = function
  | Wire_knowledge.Source_direct_experience ->
      Say.resolve lang (Say.make ~ko:"직접경험" ~en:"Direct")
  | Wire_knowledge.Source_research ->
      Say.resolve lang (Say.make ~ko:"리서치" ~en:"Research")
  | Wire_knowledge.Source_experiment ->
      Say.resolve lang (Say.make ~ko:"실험" ~en:"Experiment")
  | Wire_knowledge.Source_observation ->
      Say.resolve lang (Say.make ~ko:"관측" ~en:"Observation")

let extract_markdown_headings (md : string) : (int * string) list =
  String.split_on_char '\n' md
  |> List.filter_map (fun raw ->
         let s = String.trim raw in
         if String.starts_with ~prefix:"### " s then
           Some (3, String.trim (String.sub s 4 (String.length s - 4)))
         else if String.starts_with ~prefix:"## " s then
           Some (2, String.trim (String.sub s 3 (String.length s - 3)))
         else if String.starts_with ~prefix:"# " s then
           Some (1, String.trim (String.sub s 2 (String.length s - 2)))
         else None)

let draw_wiki_preview ~target_slug ~grid ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp ~lang ~(k : Knowledge_store.t) ~focused =
  let sel_summary =
    match target_slug with
    | Some want -> (
        match Observed.to_option k.wiki_index with
        | Some idx ->
            List.find_opt
              (fun (p : Wire_knowledge.wiki_page_summary) ->
                String.equal p.slug want)
              idx.pages
        | None -> None)
    | None -> Knowledge_store.selected_wiki_page k
  in
  let page_detail =
    match target_slug with
    | Some want -> (
        match Observed.to_option k.wiki_page with
        | Some d when String.equal d.slug want -> Some d
        | Some _ | None -> None)
    | None -> (
        match Observed.to_option k.wiki_page, sel_summary with
        | Some d, Some s when String.equal d.slug s.slug -> Some d
        | Some d, None -> Some d
        | Some _, Some _ | None, _ -> None)
  in
  let draft_active =
    match k.wiki_edit_draft, target_slug with
    | Some d, Some want -> if String.equal d.slug want then Some d else None
    | d_opt, None -> d_opt
    | None, Some _ -> None
  in
  let title, badge =
    match draft_active with
    | Some d ->
        let state_txt =
          if d.saving then Say.resolve lang (Say.make ~ko:"저장 중" ~en:"Saving")
          else if d.dirty then
            Say.resolve lang (Say.make ~ko:"편집 중*" ~en:"Editing*")
          else Say.resolve lang (Say.make ~ko:"인라인 편집" ~en:"Inline Edit")
        in
        ( Printf.sprintf "%s %s" (Glyph.to_utf8 Glyph.Spark_mark) d.slug
        , Some
            (H.make_badge ~glyph:Glyph.Spark_mark ~tone:Theme.Status_attention
               state_txt) )
    | None -> (
        match page_detail, sel_summary with
        | Some d, _ ->
            ( d.frontmatter.title
            , Some
                (H.make_badge ~glyph:Glyph.Live_healthy ~tone:Theme.Status_active
                   (Printf.sprintf "r%d · %s" d.frontmatter.revision
                      (wiki_source_badge ~lang d.frontmatter.source))) )
        | None, Some s ->
            ( s.title
            , Some
                (H.make_badge ~tone:Theme.Status_active
                   (Printf.sprintf "r%d · %s" s.revision
                      (wiki_source_badge ~lang s.source))) )
        | None, None ->
            let fallback_title =
              match target_slug with
              | Some want -> want
              | None -> Say.resolve lang (Say.make ~ko:"위키 페이지" ~en:"Wiki Page")
            in
            (fallback_title, None))
  in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ?badge ~focused
         ~hotkey:
           (Say.resolve lang
              (match target_slug with
               | Some _ ->
                   Say.make ~ko:"[e] 편집 · [Ctrl+E] $EDITOR · [Esc] 뒤로"
                     ~en:"[e] Edit · [Ctrl+E] $EDITOR · [Esc] Back"
               | None ->
                   Say.make ~ko:"[Enter] 전체보기 · [e] 편집"
                     ~en:"[Enter] Dive · [e] Edit"))
         title)
  in
  if Rect.is_empty inner then ()
  else
    let pad_x = Layout.card_pad_x bp in
    match draft_active with
    | Some d ->
        let cas =
          match d.expected_revision with
          | Some r -> Printf.sprintf "CAS r%d" r
          | None -> "CAS new"
        in
        Card.draw_section_band ~pad_x grid
          ~rect:(Rect.make ~x:inner.x ~y:inner.y ~w:inner.w ~h:1)
          ~theme
          ~left_title:
            (Printf.sprintf "%s %s"
               (Glyph.to_utf8 Glyph.Spark_mark)
               (Say.resolve lang
                  (Say.make ~ko:"인라인 위키 편집 활성화"
                     ~en:"Inline Wiki Edit Active")))
          ~right_meta:
            (Printf.sprintf "%s · %s" cas
               (if String.equal d.note "" then "(no note)" else d.note))
          ();
        let md_rect =
          Rect.make ~x:inner.x ~y:(inner.y + 1) ~w:inner.w
            ~h:(Int.max 0 (inner.h - 1))
          |> H.pad_content ~bp
        in
        if not (Rect.is_empty md_rect) then
          ignore (Markdown.draw grid ~rect:md_rect ~theme ~osc8:true d.body)
    | None -> (
        match page_detail with
        | Some d ->
            let tags =
              match d.frontmatter.tags with
              | [] -> ""
              | ts -> " · #" ^ String.concat " #" ts
            in
            let sub =
              Printf.sprintf "%s · @%s%s" d.slug d.frontmatter.author tags
            in
            let right_meta =
              Printf.sprintf "%s · r%d" d.frontmatter.updated
                d.frontmatter.revision
            in
            let band_h = if inner.h >= 7 then 2 else 1 in
            Card.draw_section_band ~pad_x grid
              ~rect:(Rect.make ~x:inner.x ~y:inner.y ~w:inner.w ~h:band_h)
              ~theme ~left_title:d.frontmatter.title ~right_meta
              ?subtitle:(if band_h >= 2 then Some sub else None)
              ();
            let below =
              Rect.make ~x:inner.x ~y:(inner.y + band_h) ~w:inner.w
                ~h:(Int.max 0 (inner.h - band_h))
            in
            if not (Rect.is_empty below) then begin
              let show_toc_rail =
                Layout.equal_breakpoint bp Layout.Wide
                && below.w >= 68
                && below.h >= 8
              in
              if show_toc_rail then begin
                let toc_w = 22 in
                let prose_w = Int.max 20 (below.w - toc_w - 1) in
                let prose_rect =
                  Rect.make ~x:below.x ~y:below.y ~w:prose_w ~h:below.h
                  |> H.pad_content ~bp ~pad_y:1
                in
                let vline_x = below.x + prose_w in
                Card.draw_v_hairline grid ~x:vline_x ~y:below.y ~h:below.h ~theme;
                let rail_rect =
                  Rect.make ~x:(vline_x + 1) ~y:below.y ~w:toc_w ~h:below.h
                  |> Card.pad_inner ~pad_x:1 ~pad_y:0
                in
                if not (Rect.is_empty prose_rect) then
                  ignore
                    (Markdown.draw grid ~rect:prose_rect ~theme ~osc8:true
                       d.body_markdown);
                if not (Rect.is_empty rail_rect) then begin
                  let ry = ref rail_rect.y and rbot = Rect.bottom rail_rect in
                  let headings = extract_markdown_headings d.body_markdown in
                  if !ry < rbot then begin
                    ignore
                      (H.put_clipped ~grid ~clip:rail_rect ~x:rail_rect.x ~y:!ry
                         ~max_w:rail_rect.w
                         ~style:(H.secondary_style ~theme ~attrs:Attr.bold ())
                         (Say.resolve lang (Say.make ~ko:"목차" ~en:"TOC")));
                    incr ry
                  end;
                  if headings = [] then begin
                    if !ry < rbot then begin
                      ignore
                        (H.put_clipped ~grid ~clip:rail_rect ~x:rail_rect.x
                           ~y:!ry ~max_w:rail_rect.w
                           ~style:(H.whisper_style ~theme ())
                           (Glyph.to_utf8 Glyph.Missing_absent));
                      incr ry
                    end
                  end
                  else
                    List.iter
                      (fun (lvl, htxt) ->
                        if !ry < rbot then begin
                          let indent = if lvl >= 3 then "  " else if lvl = 2 then " " else "" in
                          ignore
                            (H.put_clipped ~grid ~clip:rail_rect ~x:rail_rect.x
                               ~y:!ry ~max_w:rail_rect.w
                               ~style:(H.whisper_style ~theme ~italic:false ())
                               (indent ^ htxt));
                          incr ry
                        end)
                      (H.safe_take 6 headings);
                  if !ry < rbot then begin
                    H.draw_divider ~grid ~rect:rail_rect ~y:!ry ~theme ();
                    incr ry
                  end;
                  if !ry < rbot then begin
                    ignore
                      (H.put_clipped ~grid ~clip:rail_rect ~x:rail_rect.x ~y:!ry
                         ~max_w:rail_rect.w
                         ~style:(H.secondary_style ~theme ~attrs:Attr.bold ())
                         (Printf.sprintf "%s (%d)"
                            (Say.resolve lang
                               (Say.make ~ko:"역링크" ~en:"Backlinks"))
                            (List.length d.backlinks)));
                    incr ry
                  end;
                  (match d.backlinks with
                   | [] when !ry < rbot ->
                       ignore
                         (H.put_clipped ~grid ~clip:rail_rect ~x:rail_rect.x
                            ~y:!ry ~max_w:rail_rect.w
                            ~style:(H.whisper_style ~theme ())
                            (Say.resolve lang
                               (Say.make ~ko:"없음 (고아)" ~en:"none (orphan)")));
                       incr ry
                   | bls ->
                       List.iter
                         (fun bl ->
                           if !ry < rbot then begin
                             ignore
                               (H.put_link ~grid ~clip:rail_rect ~x:rail_rect.x
                                  ~y:!ry ~max_w:rail_rect.w
                                  ~style:(H.accent_style ~theme ())
                                  ~uri:("masc://wiki/" ^ bl)
                                  (Glyph.to_utf8 Glyph.External_arrow ^ " " ^ bl));
                             incr ry
                           end)
                         (H.safe_take 6 bls));
                  if d.lint_findings <> [] && !ry + 1 < rbot then begin
                    H.draw_divider ~grid ~rect:rail_rect ~y:!ry ~theme ();
                    incr ry;
                    ignore
                      (H.put_clipped ~grid ~clip:rail_rect ~x:rail_rect.x ~y:!ry
                         ~max_w:rail_rect.w
                         ~style:(H.status_style ~theme Theme.Status_attention)
                         (Printf.sprintf "%s Lint %d"
                            (Glyph.to_utf8 Glyph.Warning_triangle)
                            (List.length d.lint_findings)))
                  end
                end
              end
              else begin
                let content = H.pad_content ~bp below in
                let y = ref content.y and bottom = Rect.bottom content in
                if !y < bottom then begin
                  let bl_lbl =
                    Printf.sprintf "%s (%d): "
                      (Say.resolve lang (Say.make ~ko:"역링크" ~en:"Backlinks"))
                      (List.length d.backlinks)
                  in
                  let x = ref content.x in
                  let adv =
                    H.put_clipped ~grid ~clip:content ~x:!x ~y:!y
                      ~max_w:content.w
                      ~style:(H.secondary_style ~theme ~attrs:Attr.bold ())
                      bl_lbl
                  in
                  x := !x + adv;
                  (match d.backlinks with
                   | [] ->
                       ignore
                         (H.put_clipped ~grid ~clip:content ~x:!x ~y:!y
                            ~max_w:(Rect.right content - !x)
                            ~style:(H.whisper_style ~theme ())
                            (Say.resolve lang
                               (Say.make ~ko:"없음 (고아 후보)"
                                  ~en:"none (orphan)")))
                   | bls ->
                       List.iter
                         (fun bl ->
                           let rem = Rect.right content - !x in
                           if rem >= 4 then begin
                             let w =
                               H.put_link ~grid ~clip:content ~x:!x ~y:!y
                                 ~max_w:rem ~style:(H.accent_style ~theme ())
                                 ~uri:("masc://wiki/" ^ bl)
                                 ("[[" ^ bl ^ "]]")
                             in
                             x := !x + w + 1
                           end)
                         (H.safe_take 5 bls));
                  incr y
                end;
                if !y < bottom then begin
                  H.draw_divider ~grid ~rect:content ~y:!y ~theme ();
                  incr y
                end;
                let md_h = Int.max 0 (bottom - !y) in
                if md_h > 0 then
                  let md_rect =
                    Rect.make ~x:content.x ~y:!y ~w:content.w ~h:md_h
                  in
                  ignore
                    (Markdown.draw grid ~rect:md_rect ~theme ~osc8:true
                       d.body_markdown)
              end
            end
        | None -> (
            match sel_summary with
            | Some s ->
                let content = H.pad_content ~bp inner in
                let y = ref content.y and bottom = Rect.bottom content in
                if !y < bottom then begin
                  let uri = "masc://wiki/" ^ s.slug in
                  let adv =
                    H.put_link ~grid ~clip:content ~x:content.x ~y:!y
                      ~max_w:content.w
                      ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                      ~uri s.slug
                  in
                  let rem = content.w - adv - 2 in
                  if rem > 4 then
                    ignore
                      (H.put_clipped ~grid ~clip:content
                         ~x:(content.x + adv + 2) ~y:!y ~max_w:rem
                         ~style:(H.whisper_style ~theme ())
                         (Printf.sprintf "@%s · %s" s.author s.updated));
                  incr y
                end;
                if !y < bottom then begin
                  H.put_kv ~grid ~clip:content ~x:content.x ~y:!y
                    ~max_w:content.w ~theme
                    ~key:(Say.resolve lang (Say.make ~ko:"링크" ~en:"Links"))
                    (Printf.sprintf "%s%d back · %d out · %d src · %d hearsay"
                       (Glyph.to_utf8 Glyph.External_arrow)
                       s.backlink_count s.outgoing_link_count s.sources_count
                       s.hearsay_count);
                  incr y
                end;
                if !y < bottom then begin
                  H.draw_divider ~grid ~rect:content ~y:!y ~theme ();
                  incr y
                end;
                let md_h = Int.max 0 (bottom - !y) in
                if md_h > 0 then
                  let md_rect =
                    Rect.make ~x:content.x ~y:!y ~w:content.w ~h:md_h
                  in
                  ignore
                    (Markdown.draw grid ~rect:md_rect ~theme ~osc8:true s.summary)
            | None -> (
                let content = H.pad_content ~bp inner in
                match target_slug with
                | Some want -> (
                    match k.wiki_page with
                    | Observed.Value _ ->
                        H.draw_empty_notice ~grid ~rect:content ~theme
                          (Printf.sprintf "%s %s: %s"
                             (Glyph.to_utf8 Glyph.Transport_reconnecting)
                             (Say.resolve lang
                                (Say.make ~ko:"위키 페이지 불러오는 중"
                                   ~en:"Loading wiki page"))
                             want)
                    | Observed.Loading _
                    | Observed.Absent
                    | Observed.Unreported
                    | Observed.Failed _ ->
                        H.draw_observed_placeholder ~grid ~rect:content ~theme
                          ~lang k.wiki_page)
                | None ->
                    H.draw_observed_placeholder ~grid ~rect:content ~theme ~lang
                      k.wiki_index)))

let render_wiki_artifacts ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let k = model.knowledge in
  let now_unix = model.freshness.last_wall_unix in
  let wiki_n =
    match Observed.to_option k.wiki_index with
    | Some idx -> idx.pages_total
    | None -> 0
  in
  let art_n =
    match Observed.to_option k.artifacts with Some xs -> List.length xs | None -> 0
  in
  let lint_summary =
    match Observed.to_option k.wiki_lint with
    | Some rep ->
        let finding_orphans =
          List.filter_map
            (fun (f : Wire_knowledge.wiki_lint_finding) ->
              match f.kind with
              | Wire_knowledge.Orphan_page | Wire_knowledge.Orphan_unconfirmed -> (
                  match f.page with
                  | Some p when not (String.equal (String.trim p) "") -> Some p
                  | Some _ | None -> Some f.subject)
              | Wire_knowledge.Broken_link
              | Wire_knowledge.Unsupported_link
              | Wire_knowledge.Missing_sources
              | Wire_knowledge.Hearsay_only
              | Wire_knowledge.Unreadable_page
              | Wire_knowledge.Revision_log_gap
              | Wire_knowledge.Revision_log_hole
              | Wire_knowledge.Duplicate_title_candidate
              | Wire_knowledge.Other_lint _ ->
                  None)
            rep.findings
          |> unique_strings
        in
        let orphans =
          if finding_orphans <> [] then finding_orphans
          else
            match Observed.to_option k.wiki_index with
            | Some idx -> idx.lint.orphans
            | None -> []
        in
        Some
          ( rep.counts.duplicate_title_candidates
          , rep.counts.orphan
          , rep.counts.broken_link
          , rep.pages_unreadable
          , rep.duplicate_title_candidates
          , orphans )
    | None -> (
        match Observed.to_option k.wiki_index with
        | Some idx ->
            Some
              ( idx.lint.counts.duplicate_title_candidates
              , idx.lint.counts.orphan
              , idx.lint.counts.broken_link
              , idx.pages_unreadable
              , idx.lint.duplicate_title_candidates
              , idx.lint.orphans )
        | None -> None)
  in
  let bar_rect, body_rect =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ a; b ] -> (a, b)
    | _ -> (Rect.empty, rect)
  in
  let is_wiki =
    match k.wiki_artifacts_submode with `Wiki -> true | `Artifacts -> false
  in
  let lint_hint_str =
    match lint_summary with
    | None ->
        Say.resolve lang
          (Say.make ~ko:"wiki-lint: 미보고" ~en:"wiki-lint: Unreported")
    | Some (dup, orph, broken, unread, _, _) ->
        if dup + orph + broken + unread = 0 then
          Printf.sprintf "%s %s"
            (Glyph.to_utf8 Glyph.Check_mark)
            (Say.resolve lang
               (Say.make ~ko:"wiki-lint 정상 (중복 0 · 고아 0)"
                  ~en:"wiki-lint clean (0 dup · 0 orphans)"))
        else
          Printf.sprintf "%s lint: %s %d · %s %d · %s %d"
            (Glyph.to_utf8 Glyph.Warning_triangle)
            (Say.resolve lang (Say.make ~ko:"중복" ~en:"dup"))
            dup
            (Say.resolve lang (Say.make ~ko:"고아" ~en:"orphan"))
            orph
            (Say.resolve lang (Say.make ~ko:"깨짐" ~en:"broken"))
            (broken + unread)
  in
  let mode_pills =
    [
      {
        H.label =
          Printf.sprintf "%s (%d)"
            (Say.resolve lang (Say.make ~ko:"위키" ~en:"Wiki"))
            wiki_n;
        active = is_wiki;
        tone = Some Theme.Status_active;
        glyph = Some Glyph.Live_healthy;
      };
      {
        H.label =
          Printf.sprintf "%s (%d)"
            (Say.resolve lang (Say.make ~ko:"아티팩트" ~en:"Artifacts"))
            art_n;
        active = not is_wiki;
        tone = Some Theme.Status_ok;
        glyph = Some Glyph.Tool_square;
      };
      {
        H.label =
          Say.resolve lang (Say.make ~ko:"[Space] 전환" ~en:"[Space] Switch");
        active = false;
        tone = Some Theme.Status_historical;
        glyph = None;
      };
    ]
  in
  ignore
    (H.draw_pills ~grid ~rect:bar_rect ~theme ~right_hint:lint_hint_str
       mode_pills);
  match k.wiki_artifacts_submode with
  | `Wiki ->
      if model.nav.zoomed then
        draw_wiki_preview ~target_slug:None ~grid ~cache ~rect:body_rect ~theme
          ~bp ~lang ~k ~focused:true
      else
        let left_rect, right_rect =
          Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.38
            ~top_ratio:0.48 bp body_rect
        in
        let left_inner =
          Card.draw ~cache grid ~rect:left_rect ~theme
            (H.card_spec ~focused:(model.nav.pane_index = 0)
               (Say.resolve lang
                  (Say.make ~ko:"위키 주제 트리 · log.md"
                     ~en:"Wiki Topic Tree · log.md")))
        in
        if not (Rect.is_empty left_inner) then begin
          let pad_x = Layout.card_pad_x bp in
          let log_entries =
            match Observed.to_option k.wiki_log with
            | Some log -> log.entries
            | None -> []
          in
          let lint_rows =
            match lint_summary with
            | Some (dup, orph, _, _, dups, orphs)
              when (dup > 0 || orph > 0) && left_inner.h >= 10 ->
                Int.min 3 (1 + List.length dups + if orphs <> [] then 1 else 0)
            | Some _ | None -> 0
          in
          let log_rows =
            if log_entries <> [] && left_inner.h >= 8 then
              Int.min 4 (1 + List.length log_entries)
            else 0
          in
          let list_h = Int.max 0 (left_inner.h - lint_rows - log_rows) in
          let cur_y = ref left_inner.y in
          let list_area =
            Rect.make ~x:left_inner.x ~y:!cur_y ~w:left_inner.w ~h:list_h
          in
          cur_y := !cur_y + list_h;
          let pad_r = if left_inner.w >= 24 then 2 else 1 in
          (match k.wiki_index with
           | Observed.Value _ ->
               let q = String.trim k.filter_query in
               let visible_pages = Knowledge_store.wiki_pages_filtered k in
               if visible_pages = [] then
                 H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp list_area)
                   ~theme
                   (Say.resolve lang
                      (if String.equal q "" then
                         Say.make ~ko:"위키 페이지가 없습니다" ~en:"No wiki pages"
                       else
                         Say.make ~ko:"필터에 일치하는 위키 페이지 없음"
                           ~en:"No wiki pages match filter"))
               else
                 let clusters = Knowledge_store.cluster_wiki_pages visible_pages in
                 let sel_slug =
                   match Knowledge_store.selected_wiki_page k with
                   | Some s -> Some s.slug
                   | None -> None
                 in
                 let draft_slug =
                   match k.wiki_edit_draft with
                   | Some d -> Some d.slug
                   | None -> None
                 in
                 let rows_acc = ref [] in
                 List.iter
                   (fun (topic_opt, ps) ->
                     let topic =
                       match topic_opt with
                       | Some t -> t
                       | None ->
                           Say.resolve lang (Say.make ~ko:"일반" ~en:"General")
                     in
                     rows_acc := (`Topic (topic, List.length ps)) :: !rows_acc;
                     List.iter
                       (fun (p : Wire_knowledge.wiki_page_summary) ->
                         let is_sel =
                           match sel_slug with
                           | Some sl -> String.equal sl p.slug
                           | None -> false
                         in
                         let is_editing =
                           match draft_slug with
                           | Some sl -> String.equal sl p.slug
                           | None -> false
                         in
                         rows_acc := (`Page (p, is_sel, is_editing)) :: !rows_acc)
                       ps)
                   clusters;
                 let arr = Array.of_list (List.rev !rows_acc) in
                 let total = Array.length arr in
                 let sel_row =
                   let found = ref None in
                   for i = 0 to total - 1 do
                     match arr.(i) with
                     | `Page (_, true, _) -> found := Some i
                     | `Page (_, false, _) | `Topic _ -> ()
                   done;
                   !found
                 in
                 let start, _ =
                   Table.compute_viewport ~total_rows:total
                     ~viewport_rows:list_area.h ~scroll:k.scroll_offset
                     ~selected:sel_row
                 in
                 for i = 0 to list_area.h - 1 do
                   let idx_row = start + i in
                   if idx_row < total then begin
                     let py = list_area.y + i in
                     let r_rect =
                       Rect.make ~x:list_area.x ~y:py ~w:list_area.w ~h:1
                     in
                     let right_edge = Rect.right list_area - pad_r in
                     match arr.(idx_row) with
                     | `Topic (topic, cnt) ->
                         let hdr =
                           Printf.sprintf "%s #%s"
                             (Glyph.to_utf8 Glyph.Expand_open)
                             topic
                         in
                         let cnt_s = Printf.sprintf "(%d)" cnt in
                         ignore
                           (H.put_clipped ~grid ~clip:r_rect
                              ~x:(list_area.x + 2) ~y:py
                              ~max_w:(Int.max 6 (right_edge - list_area.x - 8))
                              ~style:(H.secondary_style ~theme ~attrs:Attr.bold ())
                              hdr);
                         ignore
                           (H.put_right ~grid ~clip:r_rect ~right_x:right_edge
                              ~y:py ~max_w:6 ~style:(H.whisper_style ~theme ())
                              cnt_s)
                     | `Page (p, is_sel, is_editing) ->
                         let row_bg =
                           if is_sel then theme.selection_bg else theme.surface_1
                         in
                         if is_sel then
                           H.paint_selected_row_bg ~grid ~clip:list_area
                             ~row_rect:r_rect ~theme ();
                         let meta =
                           let edit_t =
                             if is_editing then
                               " " ^ Glyph.to_utf8 Glyph.Spark_mark
                             else ""
                           in
                           Printf.sprintf "%s%d r%d%s"
                             (Glyph.to_utf8 Glyph.External_arrow)
                             p.backlink_count p.revision edit_t
                         in
                         let mw = Grapheme.display_width meta in
                         let tx = list_area.x + 4 in
                         let title_style =
                           if is_sel then H.anchor_style ~theme ~bg:row_bg ()
                           else H.text_style ~theme ~bg:row_bg ()
                         in
                         ignore
                           (H.put_clipped ~grid ~clip:r_rect ~x:tx ~y:py
                              ~max_w:(Int.max 4 (right_edge - tx - mw - 2))
                              ~style:title_style p.title);
                         ignore
                           (H.put_right ~grid ~clip:r_rect ~right_x:right_edge
                              ~y:py ~max_w:mw
                              ~style:(H.whisper_style ~theme ~bg:row_bg ())
                              meta)
                   end
                 done
           | ( Observed.Loading _
             | Observed.Absent
             | Observed.Unreported
             | Observed.Failed _ ) as obs ->
               H.draw_observed_placeholder ~grid
                 ~rect:(H.pad_content ~bp list_area) ~theme ~lang obs);
          if lint_rows > 0 then begin
            let l_rect =
              Rect.make ~x:left_inner.x ~y:!cur_y ~w:left_inner.w ~h:lint_rows
            in
            cur_y := !cur_y + lint_rows;
            let ly = ref l_rect.y and l_bot = Rect.bottom l_rect in
            H.draw_divider ~grid ~rect:l_rect ~y:!ly ~theme ~pad_x
              ~label:"wiki-lint" ();
            incr ly;
            let tx = l_rect.x + pad_x in
            let tw = Int.max 0 (l_rect.w - (2 * pad_x)) in
            match lint_summary with
            | Some (_, _, _, _, dups, orphs) ->
                List.iter
                  (fun (d : Wire_knowledge.wiki_duplicate_candidate) ->
                    if !ly < l_bot then begin
                      Card.draw_left_rail ~tone:Theme.Status_attention grid
                        ~x:tx ~y:!ly ~h:1 ~theme;
                      let txt =
                        Printf.sprintf "dup: %s / %s" d.page_a d.page_b
                      in
                      ignore
                        (H.put_clipped ~grid ~clip:l_rect ~x:(tx + 2) ~y:!ly
                           ~max_w:(Int.max 0 (tw - 2))
                           ~style:(H.status_style ~theme Theme.Status_attention)
                           txt);
                      incr ly
                    end)
                  dups;
                if orphs <> [] && !ly < l_bot then begin
                  Card.draw_left_rail ~tone:Theme.Status_attention grid ~x:tx
                    ~y:!ly ~h:1 ~theme;
                  let txt =
                    Printf.sprintf "orphan: %s"
                      (String.concat ", " (H.safe_take 4 orphs))
                  in
                  ignore
                    (H.put_clipped ~grid ~clip:l_rect ~x:(tx + 2) ~y:!ly
                       ~max_w:(Int.max 0 (tw - 2))
                       ~style:(H.status_style ~theme Theme.Status_attention)
                       txt)
                end
            | None -> ()
          end;
          if log_rows > 0 then begin
            let log_rect =
              Rect.make ~x:left_inner.x ~y:!cur_y ~w:left_inner.w ~h:log_rows
            in
            let ly = ref log_rect.y and l_bot = Rect.bottom log_rect in
            H.draw_divider ~grid ~rect:log_rect ~y:!ly ~theme ~pad_x
              ~label:"log.md" ();
            incr ly;
            let tx = log_rect.x + pad_x in
            let right_e = Rect.right log_rect - pad_x in
            List.iter
              (fun (e : Wire_knowledge.wiki_log_entry) ->
                if !ly < l_bot then begin
                  let age = H.format_age ~now_unix e.written_at_unix in
                  let aw = Grapheme.display_width age in
                  let line =
                    Printf.sprintf "r%d %s %s" e.revision e.action e.page
                  in
                  ignore
                    (H.put_clipped ~grid ~clip:log_rect ~x:tx ~y:!ly
                       ~max_w:(Int.max 4 (right_e - tx - aw - 2))
                       ~style:(H.secondary_style ~theme ()) line);
                  ignore
                    (H.put_right ~grid ~clip:log_rect ~right_x:right_e ~y:!ly
                       ~max_w:aw ~style:(H.whisper_style ~theme ()) age);
                  incr ly
                end)
              (H.safe_take (log_rows - 1) log_entries)
          end
        end;
        draw_wiki_preview ~target_slug:None ~grid ~cache ~rect:right_rect ~theme
          ~bp ~lang ~k ~focused:(model.nav.pane_index = 1)
  | `Artifacts ->
      let left_rect, right_rect =
        Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.56
          ~top_ratio:0.54 bp body_rect
      in
      let left_inner =
        Card.draw ~cache grid ~rect:left_rect ~theme
          (H.card_spec ~focused:(model.nav.pane_index = 0)
             (Say.resolve lang
                (Say.make ~ko:"발행 아티팩트 / 보고서"
                   ~en:"Published Artifacts & Reports")))
      in
      if not (Rect.is_empty left_inner) then begin
        match k.artifacts with
        | Observed.Value { data = items; _ } ->
            let q = String.trim k.filter_query in
            let visible_items =
              if String.equal q "" then items
              else
                List.filter
                  (fun (a : Wire_knowledge.artifact_entry) ->
                    H.contains_ci ~needle:q a.name
                    || H.contains_ci ~needle:q a.sha256)
                  items
            in
            if visible_items = [] then
              H.draw_empty_notice ~grid ~rect:(H.pad_content ~bp left_inner)
                ~theme
                (Say.resolve lang
                   (if String.equal q "" then
                      Say.make ~ko:"발행된 아티팩트가 없습니다"
                        ~en:"No published artifacts"
                    else
                      Say.make ~ko:"필터에 일치하는 아티팩트 없음"
                        ~en:"No artifacts match filter"))
            else
              let columns : Table.column list =
                [
                  {
                    id = "name";
                    header = Say.make ~ko:"이름" ~en:"Name";
                    priority = 0;
                    min_width = 16;
                    max_width = None;
                    weight = 3;
                    align = Table.Left;
                  };
                  {
                    id = "mime";
                    header = Say.make ~ko:"형식" ~en:"MIME";
                    priority = 2;
                    min_width = 10;
                    max_width = Some 18;
                    weight = 1;
                    align = Table.Left;
                  };
                  {
                    id = "size";
                    header = Say.make ~ko:"크기" ~en:"Size";
                    priority = 1;
                    min_width = 8;
                    max_width = Some 12;
                    weight = 1;
                    align = Table.Right;
                  };
                  {
                    id = "producer";
                    header = Say.make ~ko:"생성자" ~en:"Producer";
                    priority = 3;
                    min_width = 10;
                    max_width = Some 18;
                    weight = 1;
                    align = Table.Left;
                  };
                ]
              in
              let rows =
                List.map
                  (fun (a : Wire_knowledge.artifact_entry) ->
                    let display =
                      match a.title with
                      | Some t when not (String.equal (String.trim t) "") -> t
                      | Some _ | None -> a.name
                    in
                    let prod =
                      match a.producer with
                      | Some p -> p
                      | None -> Glyph.to_utf8 Glyph.Missing_absent
                    in
                    {
                      Table.id = a.sha256;
                      cells =
                        [
                          ("name", Table.text_cell display);
                          ( "mime"
                          , Table.text_cell
                              ~fg:(Color.of_rgb theme.text_secondary)
                              a.mime_type );
                          ( "size"
                          , Table.text_cell
                              (Format_val.format_value Format_val.Bytes
                                 (float_of_int a.bytes)) );
                          ("producer", Table.text_cell prod);
                        ];
                    })
                  visible_items
              in
              let sel =
                H.clamp_index (List.length visible_items) k.selected_index
              in
              ignore
                (Table.draw grid ~rect:left_inner ~theme ~caps:H.default_caps
                   ~lang ~col_gap:(Layout.table_col_gap bp)
                   ~scroll:k.scroll_offset ~selected:sel ~columns rows)
        | ( Observed.Loading _
          | Observed.Absent
          | Observed.Unreported
          | Observed.Failed _ ) as obs ->
            H.draw_observed_placeholder ~grid
              ~rect:(H.pad_content ~bp left_inner) ~theme ~lang obs
      end;
      let right_inner =
        Card.draw ~cache grid ~rect:right_rect ~theme
          (H.card_spec ~focused:(model.nav.pane_index = 1)
             ~hotkey:(Say.resolve lang (Say.make ~ko:"[Enter] 상세" ~en:"[Enter] Dive"))
             (Say.resolve lang (Say.make ~ko:"아티팩트 상세" ~en:"Artifact Detail")))
      in
      if not (Rect.is_empty right_inner) then begin
        match Knowledge_store.selected_artifact k with
        | None ->
            H.draw_observed_placeholder ~grid
              ~rect:(H.pad_content ~bp right_inner) ~theme ~lang k.artifacts
        | Some a ->
            let pad_x = Layout.card_pad_x bp in
            let title_s = Option.value ~default:a.name a.title in
            let band_h = if right_inner.h >= 7 then 2 else 1 in
            Card.draw_section_band ~pad_x grid
              ~rect:(Rect.make ~x:right_inner.x ~y:right_inner.y
                       ~w:right_inner.w ~h:band_h)
              ~theme ~left_title:title_s
              ~right_meta:
                (Format_val.format_value Format_val.Bytes (float_of_int a.bytes))
              ?subtitle:(if band_h >= 2 then Some a.mime_type else None)
              ();
            let content =
              Rect.make ~x:right_inner.x ~y:(right_inner.y + band_h)
                ~w:right_inner.w ~h:(Int.max 0 (right_inner.h - band_h))
              |> H.pad_content ~bp
            in
            let y = ref content.y and bottom = Rect.bottom content in
            let add_kv key value =
              if !y < bottom then begin
                H.put_kv ~grid ~clip:content ~x:content.x ~y:!y ~max_w:content.w
                  ~theme ~key_w:9 ~key value;
                incr y
              end
            in
            add_kv (Say.resolve lang (Say.make ~ko:"파일" ~en:"File")) a.name;
            add_kv "SHA-256" a.sha256;
            (match a.producer with
             | Some p ->
                 add_kv
                   (Say.resolve lang (Say.make ~ko:"생성자" ~en:"Producer"))
                   p
             | None -> ());
            (match a.created_at_unix with
             | Some ts ->
                 add_kv
                   (Say.resolve lang (Say.make ~ko:"생성" ~en:"Created"))
                   (Wire_common.format_unix_rfc3339 ts)
             | None -> ());
            if !y < bottom then begin
              let uri = "masc://artifact/" ^ a.sha256 in
              ignore
                (H.put_link ~grid ~clip:content ~x:content.x ~y:!y
                   ~max_w:content.w ~style:(H.accent_style ~theme ()) ~uri
                   (Printf.sprintf "[o] %s (%s)"
                      (Say.resolve lang (Say.make ~ko:"뷰어 열기" ~en:"Open Viewer"))
                      (H.short_hash ~len:12 a.sha256)))
            end
      end

(* --- 3. Memory (World MVCC Conflicts with Violet/Amber Rails + Stacked_bar Heat) --- *)

let writer_state_display ~lang = function
  | Wire_knowledge.Writer_open ->
      (Glyph.Live_working, Theme.Status_active, Say.make ~ko:"열림" ~en:"Open")
  | Wire_knowledge.Writer_idle ->
      (Glyph.Live_healthy, Theme.Status_ok, Say.make ~ko:"유휴" ~en:"Idle")
  | Wire_knowledge.Writer_asking ->
      ( Glyph.Action_required
      , Theme.Status_attention
      , Say.make ~ko:"질문 대기" ~en:"Asking" )
  | Wire_knowledge.Writer_resting ->
      ( Glyph.Live_paused
      , Theme.Status_attention
      , Say.make ~ko:"휴식 중" ~en:"Resting" )
  | Wire_knowledge.Writer_refused_at_bottom ->
      ( Glyph.Live_failing
      , Theme.Status_critical
      , Say.make ~ko:"하단 거부" ~en:"Refused at bottom" )
  | Wire_knowledge.Writer_booting ->
      ( Glyph.Transport_reconnecting
      , Theme.Status_active
      , Say.make ~ko:"기동 중" ~en:"Booting" )
  | Wire_knowledge.Writer_retired ->
      ( Glyph.Live_idle
      , Theme.Status_historical
      , Say.make ~ko:"은퇴" ~en:"Retired" )
  | Wire_knowledge.Writer_stopped reason ->
      ( Glyph.Live_paused
      , Theme.Status_critical
      , Say.make ~ko:("중지: " ^ reason) ~en:("Stopped: " ^ reason) )
  | Wire_knowledge.Writer_no_writer ->
      ( Glyph.Live_idle
      , Theme.Status_historical
      , Say.make ~ko:"라이터 없음" ~en:"No writer" )

let briefing_status_display ~lang = function
  | Wire_knowledge.Briefing_current ->
      ( Glyph.Live_healthy
      , Theme.Status_ok
      , Say.resolve lang (Say.make ~ko:"최신" ~en:"Current") )
  | Wire_knowledge.Briefing_stale ->
      ( Glyph.Transport_stale
      , Theme.Status_attention
      , Say.resolve lang (Say.make ~ko:"오래됨" ~en:"Stale") )
  | Wire_knowledge.Briefing_missing ->
      ( Glyph.Live_idle
      , Theme.Status_historical
      , Say.resolve lang (Say.make ~ko:"미생성" ~en:"Missing") )
  | Wire_knowledge.Briefing_unavailable ->
      ( Glyph.Live_failing
      , Theme.Status_critical
      , Say.resolve lang (Say.make ~ko:"조회 불가" ~en:"Unavailable") )

let heat_pill_spec ~count = function
  | Wire_knowledge.Heat_hot ->
      (Printf.sprintf "HOT %dx" count, Theme.Status_attention)
  | Wire_knowledge.Heat_warm ->
      (Printf.sprintf "WARM %dx" count, Theme.Status_active)
  | Wire_knowledge.Heat_cold ->
      (Printf.sprintf "COLD %dx" count, Theme.Status_historical)
  | Wire_knowledge.Heat_never_retrieved ->
      ("COLD 0x", Theme.Status_historical)

let relation_label = function
  | Wire_knowledge.Revision -> "rev"
  | Wire_knowledge.Program_revision -> "prog-rev"
  | Wire_knowledge.Program_absorption -> "absorb"

let draw_world_and_librarian ~grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp ~lang ~(k : Knowledge_store.t) ~focused =
  let wm_opt = Observed.to_option k.world_memory in
  let conflicts_n = match wm_opt with Some w -> w.conflicts_count | None -> 0 in
  let badge =
    if conflicts_n > 0 then
      Some
        (H.make_badge ~glyph:Glyph.Action_required ~tone:Theme.Status_attention
           (Say.resolve lang
              (Say.make
                 ~ko:(Printf.sprintf "%d 실시간 충돌" conflicts_n)
                 ~en:(Printf.sprintf "%d LIVE CONFLICTS" conflicts_n))))
    else
      Some
        (H.make_badge ~glyph:Glyph.Live_healthy ~tone:Theme.Status_ok
           (Say.resolve lang (Say.make ~ko:"충돌 0" ~en:"0 conflicts")))
  in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ?badge ~focused
         ~hotkey:(Say.resolve lang (Say.make ~ko:"[a] 사서 복구 · [A] 상세" ~en:"[a] Recover · [A] Act"))
         (Say.resolve lang
            (Say.make ~ko:"월드 MVCC 메모리 · 경합 충돌"
               ~en:"World MVCC Memory & Conflicts")))
  in
  let content = H.pad_content ~bp inner in
  if Rect.is_empty content then ()
  else
    let y = ref content.y in
    let bottom = Rect.bottom content in
    match k.world_memory with
    | Observed.Value { data = wm; _ } ->
        (* Row 1: Claims / Facts / Conflicts KPI strip *)
        if !y < bottom then begin
          let cx = ref content.x in
          let right_e = Rect.right content in
          let put_seg style txt =
            let adv =
              H.put_clipped ~grid ~clip:content ~x:!cx ~y:!y
                ~max_w:(Int.max 0 (right_e - !cx)) ~style txt
            in
            cx := !cx + adv
          in
          let dot_s = H.whisper_style ~theme ~italic:false () in
          put_seg (H.anchor_style ~theme ()) (string_of_int wm.claims_count);
          put_seg (H.secondary_style ~theme ())
            (" " ^ Say.resolve lang (Say.make ~ko:"주장" ~en:"claims"));
          put_seg dot_s Typography.sep_dot;
          put_seg (H.anchor_style ~theme ()) (string_of_int wm.facts_count);
          put_seg (H.secondary_style ~theme ())
            (" " ^ Say.resolve lang (Say.make ~ko:"사실" ~en:"facts"));
          put_seg dot_s Typography.sep_dot;
          let conf_tone =
            if wm.conflicts_count > 0 then Theme.Status_attention
            else Theme.Status_ok
          in
          put_seg
            (H.status_style ~theme ~attrs:Attr.bold conf_tone)
            (Printf.sprintf "%s %d %s"
               (Glyph.to_utf8
                  (if wm.conflicts_count > 0 then Glyph.Action_required
                   else Glyph.Live_healthy))
               wm.conflicts_count
               (Say.resolve lang (Say.make ~ko:"충돌" ~en:"conflicts")));
          incr y
        end;
        (* Row 2: Briefing freshness *)
        if !y < bottom then begin
          let bg_g, bt, bl = briefing_status_display ~lang wm.briefing.status in
          let pass_s =
            match wm.briefing.building_pass with
            | Some (cur, tot) -> Printf.sprintf " (%d/%d)" cur tot
            | None -> ""
          in
          let text_s =
            match wm.briefing.text with
            | Some t -> Typography.sep_dot ^ H.sanitize_single_line t
            | None -> (
                match wm.briefing.error with
                | Some e -> Typography.sep_dot ^ e
                | None -> "")
          in
          let prefix =
            Printf.sprintf "%s %s: %s (%d src%s)" (Glyph.to_utf8 bg_g)
              (Say.resolve lang (Say.make ~ko:"브리핑" ~en:"Briefing"))
              bl wm.briefing.source_ids_count pass_s
          in
          let pw =
            H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
              ~max_w:content.w ~style:(H.status_style ~theme bt) prefix
          in
          if content.w - pw > 4 && not (String.equal text_s "") then
            ignore
              (H.put_clipped ~grid ~clip:content ~x:(content.x + pw) ~y:!y
                 ~max_w:(content.w - pw) ~style:(H.whisper_style ~theme ())
                 text_s);
          incr y
        end;
        (* MVCC Conflict A/B Comparison using Violet & Amber Left Rails (ZERO nested boxes!) *)
        let writer_reserve = if bottom - !y >= 6 then 4 else 2 in
        if wm.active_conflicts <> [] && !y + writer_reserve < bottom then begin
          H.draw_divider ~grid ~rect:content ~y:!y ~theme
            ~label:
              (Printf.sprintf "%s %s (%d)"
                 (Glyph.to_utf8 Glyph.Action_required)
                 (Say.resolve lang
                    (Say.make ~ko:"경합 주장 비교" ~en:"Competing Claims"))
                 (List.length wm.active_conflicts))
            ();
          incr y;
          let conflict_budget = Int.max 0 (bottom - !y - writer_reserve) in
          let two_line_claims = conflict_budget >= 5 in
          let max_conflicts = if conflict_budget >= 11 then 2 else 1 in
          List.iter
            (fun (c : Wire_knowledge.memory_conflict) ->
              if !y + writer_reserve < bottom then begin
                let hdr =
                  Printf.sprintf "%s #%s (%d) %s"
                    (Glyph.to_utf8 Glyph.Action_required)
                    (H.short_hash ~len:8 c.conflict_id)
                    c.member_count c.description
                in
                ignore
                  (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                     ~max_w:content.w
                     ~style:
                       (H.status_style ~theme ~attrs:Attr.bold
                          Theme.Status_attention)
                     hdr);
                incr y;
                let draw_claim_rail ~tag ~tone
                    (cl : Wire_knowledge.competing_claim) =
                  if !y + writer_reserve < bottom then begin
                    let rows_used =
                      if two_line_claims && !y + 1 + writer_reserve < bottom
                      then 2
                      else 1
                    in
                    Card.draw_left_rail ~tone grid ~x:content.x ~y:!y
                      ~h:rows_used ~theme;
                    let orig =
                      match cl.origin with Some o -> o | None -> cl.store_kind
                    in
                    let txt =
                      match cl.claim with
                      | Some s -> s
                      | None -> Glyph.to_utf8 Glyph.Missing_absent
                    in
                    let tx = content.x + 2 in
                    let tw = Int.max 0 (content.w - 2) in
                    if rows_used >= 2 then begin
                      let head_left =
                        Printf.sprintf "%s · @%s" tag cl.keeper_id
                      in
                      let head_meta =
                        Printf.sprintf "%s · %s" orig
                          (H.short_hash ~len:6 cl.claim_sha256)
                      in
                      let adv =
                        H.put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                          ~style:(H.status_style ~theme ~attrs:Attr.bold tone)
                          head_left
                      in
                      if tw - adv > 6 then
                        ignore
                          (H.put_right ~grid ~clip:content
                             ~right_x:(Rect.right content) ~y:!y
                             ~max_w:(tw - adv - 2)
                             ~style:(H.whisper_style ~theme ()) head_meta);
                      incr y;
                      if !y < bottom then begin
                        ignore
                          (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y
                             ~max_w:tw ~style:(H.text_style ~theme ()) txt);
                        incr y
                      end
                    end
                    else begin
                      let prefix =
                        Printf.sprintf "%s · @%s: " tag cl.keeper_id
                      in
                      let adv =
                        H.put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                          ~style:(H.status_style ~theme ~attrs:Attr.bold tone)
                          prefix
                      in
                      if tw - adv > 2 then
                        ignore
                          (H.put_clipped ~grid ~clip:content ~x:(tx + adv) ~y:!y
                             ~max_w:(tw - adv) ~style:(H.text_style ~theme ())
                             txt);
                      incr y
                    end
                  end
                in
                match c.competing_claims with
                | a :: b :: _ ->
                    draw_claim_rail ~tag:"A" ~tone:Theme.Status_ai a;
                    draw_claim_rail ~tag:"B" ~tone:Theme.Status_attention b
                | [ a ] -> draw_claim_rail ~tag:"A" ~tone:Theme.Status_ai a
                | [] -> ()
              end)
            (H.safe_take max_conflicts wm.active_conflicts)
        end;
        (* Librarian Writer Health & Real Server /memory/act Recovery Acts *)
        if !y < bottom then begin
          H.draw_divider ~grid ~rect:content ~y:!y ~theme
            ~label:
              (Say.resolve lang
                 (Say.make ~ko:"사서 라이터 · /memory/act 복구"
                    ~en:"Librarian Writers & /memory/act"))
            ();
          incr y
        end;
        let available_tokens =
          match wm.librarian_writers with
          | Wire_knowledge.Writers_none_in_process ->
              if !y < bottom then begin
                ignore
                  (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                     ~max_w:content.w ~style:(H.whisper_style ~theme ())
                     (Say.resolve lang
                        (Say.make ~ko:"○ 프로세스 내 활성 사서 라이터 없음"
                           ~en:"○ No in-process Librarian writers")));
                incr y
              end;
              []
          | Wire_knowledge.Writers_running { error_count; warn_count; keepers } ->
              if !y < bottom then begin
                let tone =
                  if error_count > 0 then Theme.Status_critical
                  else if warn_count > 0 then Theme.Status_attention
                  else Theme.Status_ok
                in
                let hdr =
                  Printf.sprintf "%s %s: %d · err %d · warn %d"
                    (Glyph.to_utf8 Glyph.Live_healthy)
                    (Say.resolve lang (Say.make ~ko:"라이터" ~en:"Writers"))
                    (List.length keepers) error_count warn_count
                in
                ignore
                  (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                     ~max_w:content.w
                     ~style:(H.status_style ~theme ~attrs:Attr.bold tone)
                     hdr);
                incr y
              end;
              let reserve_acts = 2 in
              let max_w = Int.max 0 (bottom - !y - reserve_acts) in
              List.iter
                (fun (w : Wire_knowledge.librarian_writer_row) ->
                  if !y < bottom - reserve_acts then begin
                    let g, tone, lbl = writer_state_display ~lang w.state in
                    let snap_s =
                      match w.snapshot_file with
                      | Some (Wire_knowledge.Snapshot_file_present { sha; _ }) ->
                          let short =
                            if String.length sha > 8 then String.sub sha 0 8
                            else sha
                          in
                          " · snap:" ^ short
                      | Some (Wire_knowledge.Snapshot_file_fault f) ->
                          " · snap:" ^ f
                      | None -> ""
                    in
                    let acts_s =
                      match w.available_act_tokens with
                      | [] -> ""
                      | xs -> String.concat ", " xs
                    in
                    let left_s =
                      Printf.sprintf "  %s %s · %s%s" (Glyph.to_utf8 g) w.keeper
                        (Say.resolve lang lbl) snap_s
                    in
                    let aw = Grapheme.display_width acts_s in
                    ignore
                      (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                         ~max_w:
                           (if aw > 0 then Int.max 10 (content.w - aw - 2)
                            else content.w)
                         ~style:(H.status_style ~theme tone) left_s);
                    if aw > 0 then
                      ignore
                        (H.put_right ~grid ~clip:content
                           ~right_x:(Rect.right content) ~y:!y ~max_w:aw
                           ~style:(H.whisper_style ~theme ()) acts_s);
                    incr y
                  end)
                (H.safe_take max_w keepers);
              List.concat_map
                (fun (w : Wire_knowledge.librarian_writer_row) ->
                  w.available_act_tokens)
                keepers
              |> unique_strings
        in
        let keeper_diff_tokens =
          match Observed.to_option k.memory_diff with
          | None -> []
          | Some { body = Wire_knowledge.World_diff _; _ } -> []
          | Some { body = Wire_knowledge.Keeper_diff { writer_status; _ }; _ } -> (
              match writer_status with
              | Some
                  (Wire_knowledge.Keeper_writer_active
                     { state = _; available_act_tokens; snapshot_file = _ }) ->
                  available_act_tokens
              | Some
                  ( Wire_knowledge.Keeper_writer_none_in_process
                  | Wire_knowledge.Keeper_writer_none )
              | None ->
                  [])
        in
        let available_tokens =
          unique_strings (available_tokens @ keeper_diff_tokens)
        in
        if !y < bottom then begin
          let act_specs =
            [
              ("resume", Say.make ~ko:"재개" ~en:"Resume");
              ("adopt", Say.make ~ko:"수용" ~en:"Adopt");
              ("restart_reading", Say.make ~ko:"다시 읽기" ~en:"Restart Reading");
              ("skip_item", Say.make ~ko:"항목 건너뛰기" ~en:"Skip Item");
              ("skip_line", Say.make ~ko:"줄 건너뛰기" ~en:"Skip Line");
            ]
          in
          if available_tokens = [] then
            ignore
              (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                 ~max_w:content.w ~style:(H.whisper_style ~theme ())
                 (Say.resolve lang
                    (Say.make
                       ~ko:"복구 액션: 대기 중인 복구 없음 (재개 · 수용 · 다시 읽기 · 건너뛰기)"
                       ~en:"Recovery: no actions needed (Resume · Adopt · Restart · Skip)")))
          else begin
            let act_pills =
              List.map
                (fun (tok, label_say) ->
                  let avail =
                    List.exists
                      (fun t -> String.equal (String.lowercase_ascii t) tok)
                      available_tokens
                  in
                  {
                    H.label = Say.resolve lang label_say;
                    active = avail;
                    tone =
                      Some
                        (if avail then Theme.Status_active
                         else Theme.Status_historical);
                    glyph = None;
                  })
                act_specs
            in
            let act_rect = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:1 in
            ignore
              (H.draw_pills ~grid ~rect:act_rect ~theme ~bg:theme.surface_1
                 act_pills)
          end;
          incr y
        end;
        (match k.last_memory_act_answer with
         | Some (kp, ans) when !y < bottom ->
             let tone, summary =
               match ans with
               | Wire_knowledge.Memory_act_done st ->
                   let _, t, l = writer_state_display ~lang st in
                   (t, Printf.sprintf "%s -> %s" kp (Say.resolve lang l))
               | Wire_knowledge.Memory_act_refused { code; detail } ->
                   let d = match detail with Some s -> " · " ^ s | None -> "" in
                   ( Theme.Status_attention
                   , Printf.sprintf "%s refused: %s%s" kp code d )
               | Wire_knowledge.Memory_act_invalid msg ->
                   (Theme.Status_critical, Printf.sprintf "%s invalid: %s" kp msg)
               | Wire_knowledge.Memory_act_no_writer ->
                   (Theme.Status_historical, Printf.sprintf "%s no writer" kp)
             in
             ignore
               (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                  ~max_w:content.w ~style:(H.status_style ~theme tone) summary)
         | Some _ | None -> ())
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        H.draw_observed_placeholder ~grid ~rect:content ~theme ~lang obs

let draw_temporal_memory_diff ~grid ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp ~lang ~now_unix ~(k : Knowledge_store.t) ~focused =
  let scope_str =
    match k.memory_diff_keeper with
    | None -> Say.resolve lang (Say.make ~ko:"월드 메모리" ~en:"World Memory")
    | Some kp -> kp
  in
  let win_str =
    match k.memory_diff_window with
    | Knowledge_store.Window_24h -> "24h"
    | Knowledge_store.Window_7d -> "7d"
    | Knowledge_store.Window_30d -> "30d"
    | Knowledge_store.Window_revs { from_rev; to_rev } ->
        Printf.sprintf "rev %d->%d" from_rev to_rev
  in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ~focused
         ~subtitle:(Printf.sprintf "%s · %s" scope_str win_str)
         ~hotkey:(Say.resolve lang (Say.make ~ko:"[Space] 창 전환" ~en:"[Space] Window"))
         (Say.resolve lang
            (Say.make ~ko:"시간축 메모리 Diff 스크러버"
               ~en:"Temporal Memory Diff Scrubber")))
  in
  let content = H.pad_content ~bp inner in
  if Rect.is_empty content then ()
  else
    match k.memory_diff with
    | Observed.Value { data = diff; _ } ->
        let y = ref content.y in
        let bottom = Rect.bottom content in
        (* Row 1: Revision range + semantic diff counts *)
        if !y < bottom then begin
          let rev_range =
            match diff.range.from_rev, diff.range.to_rev with
            | Some a, Some b -> Printf.sprintf "rev %d → %d" a b
            | Some a, None -> Printf.sprintf "rev %d+" a
            | None, Some b -> Printf.sprintf "..rev %d" b
            | None, None -> win_str
          in
          let cx = ref content.x and right_e = Rect.right content in
          let put_s style s =
            let adv =
              H.put_clipped ~grid ~clip:content ~x:!cx ~y:!y
                ~max_w:(Int.max 0 (right_e - !cx)) ~style s
            in
            cx := !cx + adv
          in
          put_s (H.anchor_style ~theme ()) rev_range;
          put_s (H.whisper_style ~theme ~italic:false ()) Typography.sep_dot;
          (match diff.body with
           | Wire_knowledge.Keeper_diff { counts; _ } ->
               put_s (H.secondary_style ~theme ())
                 (Printf.sprintf "%d %s" counts.total_facts_now
                    (Say.resolve lang (Say.make ~ko:"사실" ~en:"facts")));
               put_s (H.whisper_style ~theme ~italic:false ()) Typography.sep_dot;
               put_s (H.status_style ~theme Theme.Status_ok)
                 (Printf.sprintf "+%d " counts.added);
               put_s (H.status_style ~theme Theme.Status_active)
                 (Printf.sprintf "~%d " counts.updated);
               put_s (H.status_style ~theme Theme.Status_critical)
                 (Printf.sprintf "-%d " counts.retracted);
               put_s (H.status_style ~theme Theme.Status_attention)
                 (Printf.sprintf "!%d" counts.invalidated)
           | Wire_knowledge.World_diff { counts; _ } ->
               put_s (H.secondary_style ~theme ())
                 (Printf.sprintf "%d %s" counts.total_claims_now
                    (Say.resolve lang (Say.make ~ko:"주장" ~en:"claims")));
               put_s (H.whisper_style ~theme ~italic:false ()) Typography.sep_dot;
               put_s (H.status_style ~theme Theme.Status_ok)
                 (Printf.sprintf "+%d " counts.added);
               put_s (H.status_style ~theme Theme.Status_active)
                 (Printf.sprintf "~%d " counts.updated);
               put_s (H.status_style ~theme Theme.Status_critical)
                 (Printf.sprintf "-%d" counts.retracted));
          incr y
        end;
        (* Row 2-3: HOT / WARM / COLD Tier Distribution Stacked_bar with colored ● legend *)
        if !y + 1 < bottom then begin
          let h = diff.retrieval_heat in
          let bar_rect = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:2 in
          let heat_spec : Chart.Spec.t =
            {
              title = Say.make ~ko:"기억 계층" ~en:"Memory Tiers";
              hotkey_hint = None;
              kind =
                Chart.Spec.Stacked_bar
                  {
                    segments =
                      [
                        (Say.literal "HOT", float_of_int h.hot, Theme.Status_attention);
                        (Say.literal "WARM", float_of_int h.warm, Theme.Status_active);
                        ( Say.literal "COLD"
                        , float_of_int (h.cold + h.never_retrieved)
                        , Theme.Status_historical );
                      ];
                    total_label =
                      Say.literal (Printf.sprintf "%d hits" h.total_events);
                    unit = Format_val.Count;
                  };
            }
          in
          ignore
            (Chart.draw grid ~rect:bar_rect ~theme ~caps:H.default_caps ~lang
               ~show_title:false heat_spec);
          y := !y + 2
        end;
        (* Memory OS Internals compact telemetry line (Compaction · Canonical · Digest · Molt) *)
        (match k.memory_diff_keeper, Observed.to_option k.memory_os_internals with
        | Some kp, Some intr when String.equal intr.keeper kp && !y < bottom ->
            let comp_s =
              if intr.compaction.present then
                Printf.sprintf "cmp:%dep/%dt/%dB" intr.compaction.epoch_count
                  intr.compaction.archived_turns_count intr.compaction.anchor_bytes
              else "cmp:none"
            in
            let ct_s =
              if intr.canonical_turns.present then
                let rk =
                  Option.value intr.canonical_turns.latest_runtime_kind
                    ~default:"?"
                in
                Printf.sprintf "turns:%d(%s,rst:%d)"
                  intr.canonical_turns.turn_count rk
                  intr.canonical_turns.history_resets_count
              else "turns:none"
            in
            let dig_s =
              if intr.memory_digest.present then
                let rev_s =
                  match intr.memory_digest.revision with
                  | Some r -> Printf.sprintf "r%d" r
                  | None -> "r?"
                in
                Printf.sprintf "dig:%s/%df/%dB" rev_s
                  intr.memory_digest.fact_count intr.memory_digest.bytes
              else "dig:none"
            in
            let molt_s =
              match intr.librarian_molt.pending_molt_kind with
              | Some mk ->
                  let cats =
                    if intr.librarian_molt.pending_molt_categories = [] then ""
                    else
                      "("
                      ^ String.concat ","
                          intr.librarian_molt.pending_molt_categories
                      ^ ")"
                  in
                  "molt:" ^ mk ^ cats
              | None -> "molt:clear"
            in
            let line =
              Printf.sprintf "OS %s · %s · %s · %s" comp_s ct_s dig_s molt_s
            in
            ignore
              (H.put_clipped ~grid ~clip:content ~x:content.x ~y:!y
                 ~max_w:content.w ~style:(H.secondary_style ~theme ()) line);
            incr y
        | _ -> ());
        if !y < bottom then begin
          H.draw_divider ~grid ~rect:content ~y:!y ~theme ();
          incr y
        end;
        (* Temporal Diff Entries with semantic Left Rails & Tier-4 Italic timestamps *)
        (match diff.body with
         | Wire_knowledge.Keeper_diff { added; updated; retracted; invalidated; _ }
           ->
             List.iter
               (fun (f : Wire_knowledge.memory_fact_entry) ->
                 if !y < bottom then begin
                   let rows_n = if !y + 1 < bottom then 2 else 1 in
                   Card.draw_left_rail ~tone:Theme.Status_ok grid ~x:content.x
                     ~y:!y ~h:rows_n ~theme;
                   let heat_lbl, heat_tone =
                     heat_pill_spec ~count:f.retrieval_count f.heat
                   in
                   let age = H.format_age ~now_unix f.first_seen_unix in
                   let tx = content.x + 2 and tw = Int.max 0 (content.w - 2) in
                   let hw = Grapheme.display_width heat_lbl in
                   let aw = Grapheme.display_width age in
                   let left_txt =
                     Printf.sprintf "+ [%s] %s" f.category f.origin
                   in
                   ignore
                     (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y
                        ~max_w:(Int.max 6 (tw - hw - aw - 4))
                        ~style:
                          (H.status_style ~theme ~attrs:Attr.bold
                             Theme.Status_ok)
                        left_txt);
                   ignore
                     (H.put_right ~grid ~clip:content
                        ~right_x:(Rect.right content - aw - 2) ~y:!y ~max_w:hw
                        ~style:(H.status_style ~theme heat_tone) heat_lbl);
                   ignore
                     (H.put_right ~grid ~clip:content
                        ~right_x:(Rect.right content) ~y:!y ~max_w:aw
                        ~style:(H.whisper_style ~theme ()) age);
                   incr y;
                   if !y < bottom && rows_n >= 2 then begin
                     ignore
                       (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                          ~style:(H.text_style ~theme ()) f.text);
                     incr y
                   end
                 end)
               added;
             List.iter
               (fun (u : Wire_knowledge.memory_updated_fact) ->
                 if !y < bottom then begin
                   let rows_n = Int.min 3 (bottom - !y) in
                   Card.draw_left_rail ~tone:Theme.Status_active grid
                     ~x:content.x ~y:!y ~h:rows_n ~theme;
                   let heat_lbl, heat_tone =
                     heat_pill_spec ~count:u.after.retrieval_count u.after.heat
                   in
                   let tx = content.x + 2 and tw = Int.max 0 (content.w - 2) in
                   let hw = Grapheme.display_width heat_lbl in
                   let hdr =
                     Printf.sprintf "~ [%s] %s @r%d" u.after.category
                       (relation_label u.relation)
                       u.at_rev
                   in
                   ignore
                     (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y
                        ~max_w:(Int.max 6 (tw - hw - 2))
                        ~style:
                          (H.status_style ~theme ~attrs:Attr.bold
                             Theme.Status_active)
                        hdr);
                   ignore
                     (H.put_right ~grid ~clip:content
                        ~right_x:(Rect.right content) ~y:!y ~max_w:hw
                        ~style:(H.status_style ~theme heat_tone) heat_lbl);
                   incr y;
                   if !y < bottom then begin
                     ignore
                       (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                          ~style:(H.status_style ~theme Theme.Status_critical)
                          ("- " ^ u.before.text));
                     incr y
                   end;
                   if !y < bottom then begin
                     ignore
                       (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                          ~style:(H.status_style ~theme Theme.Status_ok)
                          ("+ " ^ u.after.text));
                     incr y
                   end
                 end)
               updated;
             List.iter
               (fun (r : Wire_knowledge.memory_retracted_fact) ->
                 if !y < bottom then begin
                   let rows_n = if !y + 1 < bottom then 2 else 1 in
                   Card.draw_left_rail ~tone:Theme.Status_critical grid
                     ~x:content.x ~y:!y ~h:rows_n ~theme;
                   let tx = content.x + 2 and tw = Int.max 0 (content.w - 2) in
                   let why =
                     match r.drop_reason with Some s -> " · " ^ s | None -> ""
                   in
                   let hdr =
                     Printf.sprintf "- [%s] %s @r%d · %s%s" r.category
                       (Say.resolve lang (Say.make ~ko:"대체/철회" ~en:"retracted"))
                       r.removed_at_rev r.removed_by why
                   in
                   ignore
                     (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                        ~style:(H.status_style ~theme Theme.Status_critical) hdr);
                   incr y;
                   if !y < bottom && rows_n >= 2 then begin
                     ignore
                       (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                          ~style:(H.whisper_style ~theme ()) ("- " ^ r.text));
                     incr y
                   end
                 end)
               retracted;
             List.iter
               (fun (inv : Wire_knowledge.memory_invalidated_fact) ->
                 if !y < bottom then begin
                   let rows_n = if !y + 1 < bottom then 2 else 1 in
                   Card.draw_left_rail ~tone:Theme.Status_attention grid
                     ~x:content.x ~y:!y ~h:rows_n ~theme;
                   let tx = content.x + 2 and tw = Int.max 0 (content.w - 2) in
                   let prems = String.concat ", " inv.missing_premise_ids in
                   let hdr =
                     Printf.sprintf "! [invalidated] @r%d missing: %s"
                       inv.at_rev prems
                   in
                   ignore
                     (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                        ~style:(H.status_style ~theme Theme.Status_attention)
                        hdr);
                   incr y;
                   if !y < bottom && rows_n >= 2 then begin
                     ignore
                       (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                          ~style:(H.whisper_style ~theme ()) ("- " ^ inv.text));
                     incr y
                   end
                 end)
               invalidated;
             if
               added = [] && updated = [] && retracted = [] && invalidated = []
               && !y < bottom
             then
               H.draw_empty_notice ~grid
                 ~rect:
                   (Rect.make ~x:content.x ~y:!y ~w:content.w
                      ~h:(Int.max 1 (bottom - !y)))
                 ~theme
                 ~hint:
                   (Say.resolve lang
                      (Say.make ~ko:"[Space] 시간 범위를 7d로 확장"
                         ~en:"[Space] Expand window to 7d"))
                 (Say.resolve lang
                    (Say.make ~ko:"이 기간 내 메모리 변동 없음"
                       ~en:"No memory changes in this window"))
         | Wire_knowledge.World_diff { added; updated; retracted; _ } ->
             List.iter
               (fun (e : Wire_knowledge.world_change_entry) ->
                 if !y < bottom then begin
                   Card.draw_left_rail ~tone:Theme.Status_ok grid ~x:content.x
                     ~y:!y ~h:1 ~theme;
                   let tx = content.x + 2 and tw = Int.max 0 (content.w - 2) in
                   let ts = H.extract_hhmmss e.recorded_at in
                   let tw_ts = Grapheme.display_width ts in
                   let line =
                     Printf.sprintf "+ #%d [%s] %s" e.seq
                       (H.short_hash ~len:8 e.fact_id)
                       e.summary
                   in
                   ignore
                     (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y
                        ~max_w:(Int.max 6 (tw - tw_ts - 2))
                        ~style:(H.status_style ~theme Theme.Status_ok) line);
                   ignore
                     (H.put_right ~grid ~clip:content
                        ~right_x:(Rect.right content) ~y:!y ~max_w:tw_ts
                        ~style:(H.whisper_style ~theme ()) ts);
                   incr y
                 end)
               added;
             List.iter
               (fun (u : Wire_knowledge.world_updated_entry) ->
                 if !y < bottom then begin
                   let rows_n = Int.min 3 (bottom - !y) in
                   Card.draw_left_rail ~tone:Theme.Status_active grid
                     ~x:content.x ~y:!y ~h:rows_n ~theme;
                   let tx = content.x + 2 and tw = Int.max 0 (content.w - 2) in
                   let ts = H.extract_hhmmss u.recorded_at in
                   let tw_ts = Grapheme.display_width ts in
                   let hdr =
                     Printf.sprintf "~ #%d [%s] %s" u.seq
                       (H.short_hash ~len:8 u.fact_id)
                       u.summary
                   in
                   ignore
                     (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y
                        ~max_w:(Int.max 6 (tw - tw_ts - 2))
                        ~style:
                          (H.status_style ~theme ~attrs:Attr.bold
                             Theme.Status_active)
                        hdr);
                   ignore
                     (H.put_right ~grid ~clip:content
                        ~right_x:(Rect.right content) ~y:!y ~max_w:tw_ts
                        ~style:(H.whisper_style ~theme ()) ts);
                   incr y;
                   let b_s =
                     H.json_kv_summary u.before |> H.safe_take 3
                     |> List.map (fun (k, v) -> k ^ "=" ^ v)
                     |> String.concat " · "
                   in
                   let a_s =
                     H.json_kv_summary u.after |> H.safe_take 3
                     |> List.map (fun (k, v) -> k ^ "=" ^ v)
                     |> String.concat " · "
                   in
                   if !y < bottom && not (String.equal b_s "") then begin
                     ignore
                       (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                          ~style:(H.status_style ~theme Theme.Status_critical)
                          ("- " ^ b_s));
                     incr y
                   end;
                   if !y < bottom && not (String.equal a_s "") then begin
                     ignore
                       (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                          ~style:(H.status_style ~theme Theme.Status_ok)
                          ("+ " ^ a_s));
                     incr y
                   end
                 end)
               updated;
             List.iter
               (fun (r : Wire_knowledge.world_change_entry) ->
                 if !y < bottom then begin
                   Card.draw_left_rail ~tone:Theme.Status_critical grid
                     ~x:content.x ~y:!y ~h:1 ~theme;
                   let tx = content.x + 2 and tw = Int.max 0 (content.w - 2) in
                   let ts = H.extract_hhmmss r.recorded_at in
                   let tw_ts = Grapheme.display_width ts in
                   let line =
                     Printf.sprintf "- #%d [%s] %s" r.seq
                       (H.short_hash ~len:8 r.fact_id)
                       r.summary
                   in
                   ignore
                     (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y
                        ~max_w:(Int.max 6 (tw - tw_ts - 2))
                        ~style:(H.status_style ~theme Theme.Status_critical) line);
                   ignore
                     (H.put_right ~grid ~clip:content
                        ~right_x:(Rect.right content) ~y:!y ~max_w:tw_ts
                        ~style:(H.whisper_style ~theme ()) ts);
                   incr y
                 end)
               retracted;
             if added = [] && updated = [] && retracted = [] && !y < bottom then
               H.draw_empty_notice ~grid
                 ~rect:
                   (Rect.make ~x:content.x ~y:!y ~w:content.w
                      ~h:(Int.max 1 (bottom - !y)))
                 ~theme
                 ~hint:
                   (Say.resolve lang
                      (Say.make ~ko:"[Space] 시간 범위를 7d로 확장"
                         ~en:"[Space] Expand window to 7d"))
                 (Say.resolve lang
                    (Say.make ~ko:"이 기간 내 월드 메모리 변동 없음"
                       ~en:"No world memory changes in this window")))
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        H.draw_observed_placeholder ~grid ~rect:content ~theme ~lang obs

let render_memory ~(model : Model.t) ~cache ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp grid =
  let lang = model.lang in
  let k = model.knowledge in
  let now_unix = model.freshness.last_wall_unix in
  let top_rect, body_rect =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ a; b ] -> (a, b)
    | _ -> (Rect.empty, rect)
  in
  let scope_label =
    match k.memory_diff_keeper with
    | None -> Say.resolve lang (Say.make ~ko:"범위: 월드" ~en:"Scope: World")
    | Some kp ->
        Say.resolve lang
          (Say.make ~ko:("범위: " ^ kp) ~en:("Scope: " ^ kp))
  in
  let rev_pill_label, rev_active =
    match k.memory_diff_window with
    | Knowledge_store.Window_revs { from_rev; to_rev } ->
        (Printf.sprintf "rev %d → %d" from_rev to_rev, true)
    | Knowledge_store.Window_24h
    | Knowledge_store.Window_7d
    | Knowledge_store.Window_30d ->
        ("rev A→B", false)
  in
  let pills =
    [
      {
        H.label = scope_label;
        active = true;
        tone = Some Theme.Status_active;
        glyph = Some Glyph.Live_healthy;
      };
      {
        H.label = "24h";
        active =
          Knowledge_store.equal_memory_diff_window k.memory_diff_window
            Knowledge_store.Window_24h;
        tone = None;
        glyph = None;
      };
      {
        H.label = "7d";
        active =
          Knowledge_store.equal_memory_diff_window k.memory_diff_window
            Knowledge_store.Window_7d;
        tone = None;
        glyph = None;
      };
      {
        H.label = "30d";
        active =
          Knowledge_store.equal_memory_diff_window k.memory_diff_window
            Knowledge_store.Window_30d;
        tone = None;
        glyph = None;
      };
      {
        H.label = rev_pill_label;
        active = rev_active;
        tone = None;
        glyph = None;
      };
    ]
  in
  ignore (H.draw_pills ~grid ~rect:top_rect ~theme pills);
  if model.nav.zoomed then
    draw_temporal_memory_diff ~grid ~cache ~rect:body_rect ~theme ~bp ~lang
      ~now_unix ~k ~focused:true
  else
    let left_rect, right_rect =
      Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.48
        ~top_ratio:0.48 bp body_rect
    in
    draw_world_and_librarian ~grid ~cache ~rect:left_rect ~theme ~bp ~lang ~k
      ~focused:(model.nav.pane_index = 0);
    draw_temporal_memory_diff ~grid ~cache ~rect:right_rect ~theme ~bp ~lang
      ~now_unix ~k ~focused:(model.nav.pane_index = 1)

(* --- 4. Top-Level Workspace Render & Dive Render --- *)

let render ~(model : Model.t) ~cache ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Theme.of_preset model.theme_preset in
    let bp = H.layout_bp ~model ~rect in
    let body = H.body_rect ~bp rect in
    match model.knowledge.active_tab with
    | Nav.Knowledge_board ->
        render_board ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Knowledge_wiki_artifacts ->
        render_wiki_artifacts ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Knowledge_memory ->
        render_memory ~model ~cache ~rect:body ~theme ~bp grid

let render_dive_thread ~post_id ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let k = model.knowledge in
  let now_unix = model.freshness.last_wall_unix in
  let post_and_comments =
    match Observed.to_option k.active_thread with
    | Some (p, cs) when String.equal p.id post_id -> Some (p, cs)
    | Some (p, cs) -> (
        match Observed.to_option k.board with
        | Some f -> (
            match
              List.find_opt
                (fun (bp : Wire_knowledge.board_post) ->
                  String.equal bp.id post_id)
                f.posts
            with
            | Some bp -> Some (bp, [])
            | None -> Some (p, cs))
        | None -> Some (p, cs))
    | None -> (
        match Observed.to_option k.board with
        | Some f -> (
            match
              List.find_opt
                (fun (bp : Wire_knowledge.board_post) ->
                  String.equal bp.id post_id)
                f.posts
            with
            | Some bp -> Some (bp, [])
            | None -> None)
        | None -> None)
  in
  let bar_rect, body_rect =
    match Layout.split_v rect [ Layout.Fixed 1; Layout.Flex 1 ] with
    | [ a; b ] -> (a, b)
    | _ -> (Rect.empty, rect)
  in
  let chain_pills =
    let depth_info =
      match post_and_comments with
      | Some (p, _) -> (
          let all_posts =
            match Observed.to_option k.board with Some f -> f.posts | None -> []
          in
          match p.succession_chain_root_id with
          | Some root ->
              let chain =
                List.filter
                  (fun (bp : Wire_knowledge.board_post) ->
                    match bp.succession_chain_root_id with
                    | Some r -> String.equal r root
                    | None -> false)
                  all_posts
              in
              let n =
                Int.max (List.length chain)
                  (match p.chain_depth with Some d -> d | None -> 1)
              in
              let cur = match p.chain_depth with Some d -> d | None -> n in
              Printf.sprintf "Chain #%d/%d" cur n
          | None -> "Standalone")
      | None -> H.short_hash ~len:10 post_id
    in
    [
      {
        H.label = Say.resolve lang (Say.make ~ko:"이전" ~en:"Prev");
        active = false;
        tone = Some Theme.Status_active;
        glyph = Some Glyph.External_arrow;
      };
      {
        H.label = depth_info;
        active = true;
        tone = Some Theme.Status_ok;
        glyph = None;
      };
      {
        H.label = Say.resolve lang (Say.make ~ko:"다음" ~en:"Next");
        active = false;
        tone = Some Theme.Status_active;
        glyph = Some Glyph.Focus_caret;
      };
      {
        H.label = "[+] Karma";
        active = false;
        tone = Some Theme.Status_ok;
        glyph = Some Glyph.Delta_up;
      };
    ]
  in
  ignore (H.draw_pills ~grid ~rect:bar_rect ~theme chain_pills);
  let title, badge =
    match post_and_comments with
    | Some (p, _) ->
        ( Printf.sprintf "%s > %s"
            (Say.resolve lang (Say.make ~ko:"지식 · 타래" ~en:"Knowledge > Thread"))
            p.title
        , Some
            (H.make_badge ~glyph:Glyph.Delta_up ~tone:Theme.Status_ok
               (format_karma_badge ~lang p)) )
    | None ->
        ( Printf.sprintf "%s > %s"
            (Say.resolve lang (Say.make ~ko:"지식 · 타래" ~en:"Knowledge > Thread"))
            post_id
        , None )
  in
  let inner =
    Card.draw ~cache grid ~rect:body_rect ~theme
      (H.card_spec ?badge ~focused:true
         ~hotkey:(Say.resolve lang (Say.make ~ko:"[Esc] 뒤로" ~en:"[Esc] Back"))
         title)
  in
  if Rect.is_empty inner then ()
  else
    match post_and_comments with
    | None ->
        H.draw_observed_placeholder ~grid ~rect:(H.pad_content ~bp inner) ~theme
          ~lang k.active_thread
    | Some (p, comments) ->
        let pad_x = Layout.card_pad_x bp in
        let hearth = match p.hearth with Some h -> "#" ^ h | None -> "#general" in
        let age = H.format_age ~now_unix p.created_at_unix in
        let meta =
          Printf.sprintf "@%s · %s · %d %s" p.author hearth
            (Int.max p.comment_count (List.length comments))
            (Say.resolve lang (Say.make ~ko:"댓글" ~en:"comments"))
        in
        let band_h = if inner.h >= 7 then 2 else 1 in
        Card.draw_section_band ~pad_x grid
          ~rect:(Rect.make ~x:inner.x ~y:inner.y ~w:inner.w ~h:band_h)
          ~theme ~left_title:p.title ~right_meta:age
          ?subtitle:(if band_h >= 2 then Some meta else None)
          ();
        let content =
          Rect.make ~x:inner.x ~y:(inner.y + band_h) ~w:inner.w
            ~h:(Int.max 0 (inner.h - band_h))
          |> H.pad_content ~bp
        in
        if not (Rect.is_empty content) then begin
          let y = ref content.y and bottom = Rect.bottom content in
          let comments_h =
            if comments = [] then 0
            else
              Int.min
                (Int.max 3 ((bottom - !y) / 3))
                (2 + (List.length comments * 2))
          in
          let body_h = Int.max 0 (bottom - !y - comments_h) in
          if body_h > 0 then begin
            let md_rect = Rect.make ~x:content.x ~y:!y ~w:content.w ~h:body_h in
            ignore (Markdown.draw grid ~rect:md_rect ~theme ~osc8:true p.body);
            y := !y + body_h
          end;
          if comments_h > 0 && !y < bottom then begin
            H.draw_divider ~grid ~rect:content ~y:!y ~theme
              ~label:
                (Printf.sprintf "%s (%d)"
                   (Say.resolve lang (Say.make ~ko:"댓글" ~en:"Comments"))
                   (List.length comments))
              ();
            incr y;
            List.iter
              (fun (c : Wire_knowledge.board_comment) ->
                if !y < bottom then begin
                  let c_rows = if !y + 1 < bottom then 2 else 1 in
                  Card.draw_left_rail ~color:theme.border_inactive grid
                    ~x:content.x ~y:!y ~h:c_rows ~theme;
                  let tx = content.x + 2 and tw = Int.max 0 (content.w - 2) in
                  let c_age = H.format_age ~now_unix c.created_at_unix in
                  let aw = Grapheme.display_width c_age in
                  let hdr =
                    Printf.sprintf "@%s · %s+%d" c.author
                      (Glyph.to_utf8 Glyph.Delta_up)
                      c.score
                  in
                  ignore
                    (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y
                       ~max_w:(Int.max 6 (tw - aw - 2))
                       ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                       hdr);
                  ignore
                    (H.put_right ~grid ~clip:content
                       ~right_x:(Rect.right content) ~y:!y ~max_w:aw
                       ~style:(H.whisper_style ~theme ()) c_age);
                  incr y;
                  if !y < bottom && c_rows >= 2 then begin
                    ignore
                      (H.put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                         ~style:(H.text_style ~theme ()) c.body);
                    incr y
                  end
                end)
              comments
          end
        end

let render_dive_wiki ~slug ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let k = model.knowledge in
  let main_rect, side_rect =
    Layout.adaptive_split_2 ~stack_on_compact:true ~left_ratio:0.66
      ~top_ratio:0.68 bp rect
  in
  draw_wiki_preview ~target_slug:(Some slug) ~grid ~cache ~rect:main_rect ~theme
    ~bp ~lang ~k ~focused:true;
  let side_inner =
    Card.draw ~cache grid ~rect:side_rect ~theme
      (H.card_spec ~subtitle:slug
         (Say.resolve lang
            (Say.make ~ko:"역링크 · 외부 링크 · 린트"
               ~en:"Backlinks · Links · Lint")))
    |> H.pad_content ~bp
  in
  if not (Rect.is_empty side_inner) then begin
    let y = ref side_inner.y and bottom = Rect.bottom side_inner in
    match Observed.to_option k.wiki_page with
    | Some d when String.equal d.slug slug ->
        if !y < bottom then begin
          H.draw_divider ~grid ~rect:side_inner ~y:!y ~theme
            ~label:
              (Printf.sprintf "%s (%d)"
                 (Say.resolve lang (Say.make ~ko:"역링크" ~en:"Backlinks"))
                 (List.length d.backlinks))
            ();
          incr y
        end;
        List.iter
          (fun bl ->
            if !y < bottom then begin
              ignore
                (H.put_link ~grid ~clip:side_inner ~x:side_inner.x ~y:!y
                   ~max_w:side_inner.w ~style:(H.accent_style ~theme ())
                   ~uri:("masc://wiki/" ^ bl)
                   (Glyph.to_utf8 Glyph.External_arrow ^ " " ^ bl));
              incr y
            end)
          (H.safe_take 6 d.backlinks);
        if !y < bottom then begin
          H.draw_divider ~grid ~rect:side_inner ~y:!y ~theme
            ~label:
              (Printf.sprintf "%s (%d)"
                 (Say.resolve lang (Say.make ~ko:"나가는 링크" ~en:"Outgoing"))
                 (List.length d.outgoing_links))
            ();
          incr y
        end;
        List.iter
          (fun (ol : Wire_knowledge.wiki_outgoing_link) ->
            if !y < bottom then begin
              let tone, g =
                match ol.exists with
                | Some false -> (Theme.Status_critical, Glyph.Live_failing)
                | Some true -> (Theme.Status_ok, Glyph.Check_mark)
                | None -> (Theme.Status_active, Glyph.Focus_caret)
              in
              let lbl =
                Printf.sprintf "%s %s -> %s" (Glyph.to_utf8 g) ol.text ol.target
              in
              ignore
                (H.put_link ~grid ~clip:side_inner ~x:side_inner.x ~y:!y
                   ~max_w:side_inner.w ~style:(H.status_style ~theme tone)
                   ~uri:ol.target lbl);
              incr y
            end)
          (H.safe_take 6 d.outgoing_links);
        if d.lint_findings <> [] && !y < bottom then begin
          H.draw_divider ~grid ~rect:side_inner ~y:!y ~theme ~label:"Lint" ();
          incr y;
          List.iter
            (fun (lf : Wire_knowledge.wiki_lint_finding) ->
              if !y < bottom then begin
                Card.draw_left_rail ~tone:Theme.Status_attention grid
                  ~x:side_inner.x ~y:!y ~h:1 ~theme;
                let txt =
                  Printf.sprintf "%s %s"
                    (Glyph.to_utf8 Glyph.Warning_triangle)
                    lf.subject
                in
                ignore
                  (H.put_clipped ~grid ~clip:side_inner ~x:(side_inner.x + 2)
                     ~y:!y ~max_w:(Int.max 0 (side_inner.w - 2))
                     ~style:(H.status_style ~theme Theme.Status_attention) txt);
                incr y
              end)
            (H.safe_take 4 d.lint_findings)
        end
    | Some _ ->
        H.draw_empty_notice ~grid ~rect:side_inner ~theme
          (Printf.sprintf "%s %s: %s"
             (Glyph.to_utf8 Glyph.Transport_reconnecting)
             (Say.resolve lang
                (Say.make ~ko:"페이지 링크 불러오는 중" ~en:"Loading page links"))
             slug)
    | None ->
        H.draw_observed_placeholder ~grid ~rect:side_inner ~theme ~lang
          k.wiki_page
  end

let render_dive_artifact ~sha256 ~(model : Model.t) ~cache ~(rect : Rect.t)
    ~(theme : Theme.t) ~bp grid =
  let lang = model.lang in
  let k = model.knowledge in
  let artifacts =
    match Observed.to_option k.artifacts with Some xs -> xs | None -> []
  in
  let target =
    List.find_opt
      (fun (a : Wire_knowledge.artifact_entry) -> String.equal a.sha256 sha256)
      artifacts
  in
  let inner =
    Card.draw ~cache grid ~rect ~theme
      (H.card_spec ~focused:true
         ~subtitle:(H.short_hash ~len:12 sha256)
         ~hotkey:(Say.resolve lang (Say.make ~ko:"[Esc] 뒤로" ~en:"[Esc] Back"))
         (Say.resolve lang
            (Say.make ~ko:"지식 > 아티팩트 뷰어" ~en:"Knowledge > Artifact Viewer")))
  in
  let content = H.pad_content ~bp inner in
  if Rect.is_empty content then ()
  else
    let y = ref content.y and bottom = Rect.bottom content in
    (match target with
     | None ->
         H.draw_observed_placeholder ~grid ~rect:content ~theme ~lang k.artifacts
     | Some a ->
         let put_row key v =
           if !y < bottom then begin
             H.put_kv ~grid ~clip:content ~x:content.x ~y:!y ~max_w:content.w
               ~theme ~key_w:9 ~key v;
             incr y
           end
         in
         put_row (Say.resolve lang (Say.make ~ko:"이름" ~en:"Name")) a.name;
         (match a.title with
          | Some t ->
              put_row (Say.resolve lang (Say.make ~ko:"제목" ~en:"Title")) t
          | None -> ());
         put_row "MIME" a.mime_type;
         put_row
           (Say.resolve lang (Say.make ~ko:"크기" ~en:"Size"))
           (Format_val.format_value Format_val.Bytes (float_of_int a.bytes));
         put_row "SHA-256" a.sha256;
         (match a.producer with
          | Some p ->
              put_row (Say.resolve lang (Say.make ~ko:"생성자" ~en:"Producer")) p
          | None -> ());
         if !y < bottom then begin
           ignore
             (H.put_link ~grid ~clip:content ~x:content.x ~y:!y ~max_w:content.w
                ~style:(H.accent_style ~theme ~attrs:Attr.bold ())
                ~uri:("masc://artifact/" ^ a.sha256)
                (Say.resolve lang
                   (Say.make ~ko:"[o] 아티팩트 뷰어 열기"
                      ~en:"[o] Open artifact viewer")));
           incr y
         end);
    if artifacts <> [] && !y + 1 < bottom then begin
      H.draw_divider ~grid ~rect:content ~y:!y ~theme
        ~label:
          (Say.resolve lang
             (Say.make ~ko:"아티팩트 리비전 목록" ~en:"Artifact Revisions"))
        ();
      incr y;
      List.iter
        (fun (a : Wire_knowledge.artifact_entry) ->
          if !y < bottom then begin
            let is_cur = String.equal a.sha256 sha256 in
            let row_rect =
              Rect.make ~x:content.x ~y:!y ~w:content.w ~h:1
            in
            let row_bg =
              if is_cur then theme.selection_bg else theme.surface_1
            in
            if is_cur then
              H.paint_selected_row_bg ~grid ~clip:content ~row_rect ~theme ();
            let style =
              if is_cur then H.anchor_style ~theme ~bg:row_bg ()
              else H.secondary_style ~theme ~bg:row_bg ()
            in
            let line =
              Printf.sprintf "%s · %s · %s"
                (H.short_hash ~len:10 a.sha256)
                a.name
                (Format_val.format_value Format_val.Bytes (float_of_int a.bytes))
            in
            ignore
              (H.put_clipped ~grid ~clip:content ~x:(content.x + 2) ~y:!y
                 ~max_w:(Int.max 0 (content.w - 2)) ~style line);
            incr y
          end)
        artifacts
    end

let render_dive_memory ~keeper ~from_rev ~to_rev ~(model : Model.t) ~cache
    ~(rect : Rect.t) ~(theme : Theme.t) ~bp grid =
  let k_scoped =
    {
      model.knowledge with
      memory_diff_keeper = keeper;
      memory_diff_window = Knowledge_store.Window_revs { from_rev; to_rev };
    }
  in
  let scoped_model = { model with knowledge = k_scoped } in
  render_memory ~model:scoped_model ~cache ~rect ~theme ~bp grid

let render_dive ~(target : Nav.knowledge_dive_target) ~(model : Model.t) ~cache
    ~(rect : Rect.t) grid =
  if Rect.is_empty rect then ()
  else
    let theme = Theme.of_preset model.theme_preset in
    let bp = H.layout_bp ~model ~rect in
    let body = H.body_rect ~bp rect in
    match target with
    | Nav.Thread_dive post_id ->
        render_dive_thread ~post_id ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Wiki_dive slug ->
        render_dive_wiki ~slug ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Artifact_dive sha256 ->
        render_dive_artifact ~sha256 ~model ~cache ~rect:body ~theme ~bp grid
    | Nav.Memory_diff_dive { keeper; from_rev; to_rev } ->
        render_dive_memory ~keeper ~from_rev ~to_rev ~model ~cache ~rect:body
          ~theme ~bp grid
