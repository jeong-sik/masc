open Masc_tui_core
open Masc_tui_term
open Masc_tui_ui
open Masc_tui_protocol
open Masc_tui_store

let default_caps = Presenter.default_capabilities

let say (lang : Say.lang) ~ko ~en = Say.resolve lang (Say.make ~ko ~en)

let sanitize_single_line s =
  let buf = Buffer.create (String.length s) in
  let prev_space = ref false in
  String.iter
    (fun c ->
      let code = Char.code c in
      if c = '\n' || c = '\r' || c = '\t' then begin
        if not !prev_space then Buffer.add_char buf ' ';
        prev_space := true
      end
      else if code >= 32 then begin
        Buffer.add_char buf c;
        prev_space := c = ' '
      end)
    s;
  String.trim (Buffer.contents buf)

let short_hash ?(len = 8) s =
  if String.length s <= len then s else String.sub s 0 len

let format_age ~now_unix ts_unix =
  if
    (not (Float.is_finite now_unix))
    || (not (Float.is_finite ts_unix))
    || now_unix <= 0.0
    || ts_unix <= 0.0
  then Glyph.to_utf8 Glyph.Missing_absent
  else
    let delta = Float.max 0.0 (now_unix -. ts_unix) in
    if delta < 5.0 then "now" else Format_val.format_duration_s delta

let wrap_single_paragraph ~max_width text =
  let max_w = Int.max 4 max_width in
  if String.equal text "" then [ "" ]
  else
    let clusters = Grapheme.split_clusters text in
    let lines = ref [] in
    let cur = Buffer.create 64 in
    let cur_w = ref 0 in
    let flush () =
      lines := Buffer.contents cur :: !lines;
      Buffer.clear cur;
      cur_w := 0
    in
    List.iter
      (fun (bytes, width) ->
        let gw = Int.max 1 width in
        if !cur_w + gw > max_w && !cur_w > 0 then flush ();
        Buffer.add_string cur bytes;
        cur_w := !cur_w + gw)
      clusters;
    if !cur_w > 0 || !lines = [] then flush ();
    List.rev !lines

let wrap_lines ~max_width text =
  let max_w = Int.max 4 max_width in
  let paragraphs = String.split_on_char '\n' text in
  List.concat_map (wrap_single_paragraph ~max_width:max_w) paragraphs

let put_clipped ~grid ~clip ~x ~y ~max_w ~style s =
  if max_w <= 0 then 0
  else
    let clipped = Grapheme.truncate_to_width ~max_width:max_w s in
    Cell_grid.put_text ~clip grid ~x ~y ~style clipped

let put_right ~grid ~clip ~right_x ~y ~max_w ~style s =
  if max_w <= 0 then 0
  else
    let clipped = Grapheme.truncate_to_width ~max_width:max_w s in
    let w = Grapheme.display_width clipped in
    let x = Int.max clip.Rect.x (right_x - w) in
    Cell_grid.put_text ~clip grid ~x ~y ~style clipped

let paint_selected_row ~grid ~clip ~(row_rect : Rect.t) ~(theme : Theme.t)
    ?tone () =
  let bg = Color.of_rgb theme.selection_bg in
  Cell_grid.fill_rect ~clip grid ~rect:row_rect
    ~style:(Style.make ~bg ())
    ();
  let rail_fg =
    match tone with
    | Some tok -> Color.of_rgb (Theme.status_color theme tok)
    | None -> Color.of_rgb theme.accent
  in
  Cell_grid.put_glyph ~clip grid ~x:row_rect.x ~y:row_rect.y
    ~style:(Style.make ~fg:rail_fg ~bg ~attrs:Attr.bold ())
    Glyph.Left_rail

let draw_observed_notice ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~bg (obs : 'a Observed.t) =
  if Rect.is_empty rect then ()
  else
    let cy = rect.y + Int.min 1 (Int.max 0 (rect.h / 2)) in
    match obs with
    | Observed.Loading _ ->
        let txt =
          Glyph.to_utf8 Glyph.Transport_reconnecting ^ " "
          ^ say lang ~ko:"불러오는 중..." ~en:"Loading..."
        in
        ignore
          (put_clipped ~grid ~clip:rect ~x:rect.x ~y:cy ~max_w:rect.w
             ~style:(Typography.whisper ~bg theme) txt)
    | Observed.Absent ->
        let txt =
          Glyph.to_utf8 Glyph.Missing_absent ^ " "
          ^ say lang ~ko:"표시할 항목 없음" ~en:"No data available"
        in
        ignore
          (put_clipped ~grid ~clip:rect ~x:rect.x ~y:cy ~max_w:rect.w
             ~style:(Typography.whisper ~bg theme) txt)
    | Observed.Unreported ->
        let txt =
          Glyph.to_utf8 Glyph.Missing_unreported ^ " "
          ^ say lang ~ko:"서버 미보고" ~en:"Unreported by server"
        in
        ignore
          (put_clipped ~grid ~clip:rect ~x:rect.x ~y:cy ~max_w:rect.w
             ~style:(Typography.whisper ~bg theme) txt)
    | Observed.Failed { reason; retryable; _ } ->
        let suffix =
          if retryable then say lang ~ko:" (재시도 가능 · [r])" ~en:" (retryable · [r])"
          else ""
        in
        Card.draw_left_rail ~bg ~tone:Theme.Status_critical grid ~x:rect.x ~y:cy
          ~h:1 ~theme;
        let txt =
          Glyph.to_utf8 Glyph.Live_failing ^ " "
          ^ say lang
              ~ko:("조회 실패: " ^ reason ^ suffix)
              ~en:("Fetch failed: " ^ reason ^ suffix)
        in
        ignore
          (put_clipped ~grid ~clip:rect ~x:(rect.x + 2) ~y:cy
             ~max_w:(Int.max 0 (rect.w - 2))
             ~style:(Typography.status ~bg ~bold:true theme Theme.Status_critical)
             txt)
    | Observed.Value _ -> ()

let activity_kind_spec ~lang = function
  | Wire_knowledge.Activity_created ->
      ("+", say lang ~ko:"생성" ~en:"Created", Theme.Status_ok)
  | Wire_knowledge.Activity_reobserved ->
      ("↻", say lang ~ko:"재관측" ~en:"Reobserved", Theme.Status_active)
  | Wire_knowledge.Activity_revised ->
      ("~", say lang ~ko:"수정" ~en:"Revised", Theme.Status_active)
  | Wire_knowledge.Activity_absorbed ->
      ("⊕", say lang ~ko:"흡수" ~en:"Absorbed", Theme.Status_ai)
  | Wire_knowledge.Activity_retracted ->
      ("-", say lang ~ko:"철회" ~en:"Retracted", Theme.Status_critical)
  | Wire_knowledge.Activity_removed ->
      ("✕", say lang ~ko:"삭제" ~en:"Removed", Theme.Status_critical)
  | Wire_knowledge.Activity_invalidated ->
      ("!", say lang ~ko:"무효화" ~en:"Invalidated", Theme.Status_attention)
  | Wire_knowledge.Activity_relation_unavailable ->
      ("?", say lang ~ko:"관계 미확인" ~en:"Relation N/A", Theme.Status_attention)

let relation_label ~lang = function
  | Wire_knowledge.Revision -> say lang ~ko:"개정" ~en:"rev"
  | Wire_knowledge.Program_revision -> say lang ~ko:"규칙 개정" ~en:"prog-rev"
  | Wire_knowledge.Program_absorption -> say lang ~ko:"흡수" ~en:"absorb"

let heat_badge = function
  | Wire_knowledge.Heat_hot -> ("HOT", Theme.Status_attention)
  | Wire_knowledge.Heat_warm -> ("WARM", Theme.Status_active)
  | Wire_knowledge.Heat_cold -> ("COLD", Theme.Status_historical)
  | Wire_knowledge.Heat_never_retrieved -> ("0x", Theme.Status_historical)

let json_kv_summary = function
  | `Assoc fields ->
      List.filter_map
        (fun (k, v) ->
          match v with
          | `String s -> Some (k, sanitize_single_line s)
          | `Int n -> Some (k, string_of_int n)
          | `Float f -> Some (k, Printf.sprintf "%.2f" f)
          | `Bool b -> Some (k, string_of_bool b)
          | `Null | `List _ | `Assoc _ | `Intlit _ -> None)
        fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> []

let format_basis_lines ~lang = function
  | Wire_knowledge.Basis_observed ->
      [ say lang ~ko:"관측 (Observed)" ~en:"Observed" ]
  | Wire_knowledge.Basis_observed_board { post_id; comment_id } ->
      let c_part =
        match comment_id with Some c -> " / comment:" ^ c | None -> ""
      in
      [
        Printf.sprintf "%s (board post:%s%s)"
          (say lang ~ko:"관측 · 보드" ~en:"Observed · Board")
          post_id c_part;
      ]
  | Wire_knowledge.Basis_derived derivs ->
      List.map
        (fun (d : Wire_knowledge.memory_derivation_ref) ->
          Printf.sprintf "%s %s ← [%s]"
            (say lang ~ko:"유도 규칙" ~en:"Derived rule")
            d.rule_id
            (String.concat ", " d.premise_ids))
        derivs

(* --- Full Reading Renderer (scrollable word-wrapped detail) --- *)

type reading_line = {
  rail : Theme.status_token option;
  style : Style.t;
  text : string;
}

let build_reading_lines ~theme ~bg ~width ~lang ~now_unix
    (entry : Knowledge_store.memory_reading_entry) : reading_line list =
  let text_w = Int.max 12 (width - 2) in
  let acc = ref [] in
  let push ?rail ~style text = acc := { rail; style; text } :: !acc in
  let push_wrapped ?rail ~style text =
    List.iter (fun ln -> push ?rail ~style ln) (wrap_lines ~max_width:text_w text)
  in
  let push_blank () = push ~style:(Typography.primary ~bg theme) "" in
  let push_section ?rail label =
    push ?rail ~style:(Typography.structure ~bg ~bold:true theme) label
  in
  let push_kv key value =
    push_wrapped
      ~style:(Typography.primary ~bg theme)
      (Printf.sprintf "%s: %s" key value)
  in
  (match entry with
  | Knowledge_store.Reading_activity { keeper; event; notes } ->
      let g, lbl, tone = activity_kind_spec ~lang event.kind in
      push ~rail:tone
        ~style:(Typography.status ~bg ~bold:true theme tone)
        (Printf.sprintf "%s %s  ·  @%s  ·  r%d  ·  %s (%s)" g lbl keeper
           event.revision
           (Wire_common.format_unix_rfc3339 event.recorded_at_unix)
           (format_age ~now_unix event.recorded_at_unix));
      push ~style:(Typography.whisper ~bg theme) ("ID: " ^ event.identity);
      push_blank ();
      (match event.reason with
      | Some r when not (String.equal (String.trim r) "") ->
          push_section ~rail:Theme.Status_attention
            (say lang ~ko:"사유 (Reason)" ~en:"Reason");
          push_wrapped ~rail:Theme.Status_attention
            ~style:(Typography.primary ~bg theme) r;
          push_blank ()
      | Some _ | None -> ());
      push_section ~rail:Theme.Status_critical
        (Printf.sprintf "%s (%d)"
           (say lang ~ko:"이전 기억 (Before)" ~en:"Before")
           (List.length event.before));
      if event.before = [] then
        push ~style:(Typography.whisper ~bg theme)
          (say lang ~ko:"(없음 — 신규 생성)" ~en:"(none — newly created)")
      else
        List.iteri
          (fun idx (f : Wire_knowledge.memory_activity_fact) ->
            push ~rail:Theme.Status_critical
              ~style:(Typography.whisper ~bg ~italic:false theme)
              (Printf.sprintf "#%d  %s" (idx + 1) f.memory_id);
            let claim_s =
              Option.value f.claim
                ~default:
                  (say lang ~ko:"(본문 미기록)" ~en:"(claim unavailable)")
            in
            push_wrapped ~rail:Theme.Status_critical
              ~style:(Typography.primary ~bg theme) claim_s)
          event.before;
      push_blank ();
      push_section ~rail:Theme.Status_ok
        (Printf.sprintf "%s (%d)"
           (say lang ~ko:"이후 기억 (After)" ~en:"After")
           (List.length event.after));
      if event.after = [] then
        push ~style:(Typography.whisper ~bg theme)
          (say lang ~ko:"(없음 — 철회/삭제/무효화)" ~en:"(none — retracted/removed/invalidated)")
      else
        List.iteri
          (fun idx (f : Wire_knowledge.memory_activity_fact) ->
            push ~rail:Theme.Status_ok
              ~style:(Typography.whisper ~bg ~italic:false theme)
              (Printf.sprintf "#%d  %s" (idx + 1) f.memory_id);
            let claim_s =
              Option.value f.claim
                ~default:
                  (say lang ~ko:"(본문 미기록)" ~en:"(claim unavailable)")
            in
            push_wrapped ~rail:Theme.Status_ok
              ~style:(Typography.primary ~bg theme) claim_s)
          event.after;
      if notes <> [] then begin
        push_blank ();
        push_section (say lang ~ko:"저널 노트 (Notes)" ~en:"Journal Notes");
        List.iter
          (fun n ->
            push_wrapped ~style:(Typography.whisper ~bg theme) ("· " ^ n))
          notes
      end
  | Knowledge_store.Reading_ordinary_fact { keeper; revision; fact } ->
      let cat_s = Wire_knowledge.memory_fact_category_to_string fact.category in
      let orig_s = Wire_knowledge.memory_fact_origin_to_string fact.origin in
      push ~rail:Theme.Status_active
        ~style:(Typography.anchor ~bg theme)
        (Printf.sprintf "@%s  ·  [%s]  ·  %s  ·  r%d" keeper cat_s orig_s
           revision);
      push ~style:(Typography.whisper ~bg theme) ("ID: " ^ fact.memory_id);
      push_blank ();
      push_section ~rail:Theme.Status_ok
        (say lang ~ko:"전체 기억 내용 (Claim)" ~en:"Full Claim");
      push_wrapped ~rail:Theme.Status_ok
        ~style:(Typography.primary ~bg theme) fact.claim;
      push_blank ();
      push_section (say lang ~ko:"메타데이터 · 조회 이력" ~en:"Metadata & Retrieval");
      push_kv
        (say lang ~ko:"최초 관측" ~en:"First seen")
        (Printf.sprintf "%s (%s)"
           (Wire_common.format_unix_rfc3339 fact.first_seen_unix)
           (format_age ~now_unix fact.first_seen_unix));
      push_kv
        (say lang ~ko:"최근 관측" ~en:"Last seen")
        (Printf.sprintf "%s (%s)"
           (Wire_common.format_unix_rfc3339 fact.last_seen_unix)
           (format_age ~now_unix fact.last_seen_unix));
      let ret_str =
        match fact.events.retrieval with
        | Wire_knowledge.Never_retrieved ->
            say lang ~ko:"미조회 (0회)" ~en:"Never retrieved (0x)"
        | Wire_knowledge.Retrieved { count; distinct_days; last_at_unix } ->
            Printf.sprintf "%dx · %dd · %s (%s)" count distinct_days
              (Wire_common.format_unix_rfc3339 last_at_unix)
              (format_age ~now_unix last_at_unix)
      in
      push_kv (say lang ~ko:"조회 기록" ~en:"Retrieval") ret_str;
      if fact.events.retracted_count > 0 then
        push_kv
          (say lang ~ko:"철회 횟수" ~en:"Retracted count")
          (string_of_int fact.events.retracted_count);
      push_blank ();
      push_section ~rail:Theme.Status_ai
        (say lang ~ko:"근거 (Basis)" ~en:"Basis");
      List.iter
        (fun ln ->
          push_wrapped ~rail:Theme.Status_ai
            ~style:(Typography.primary ~bg theme) ln)
        (format_basis_lines ~lang fact.basis);
      if fact.events.revised_from <> [] then begin
        push_blank ();
        push_section ~rail:Theme.Status_active
          (say lang ~ko:"개정 계보 (Supersedes / Revised From)"
             ~en:"Lineage (Revised From)");
        List.iter
          (fun prev_id ->
            push ~rail:Theme.Status_active
              ~style:(Typography.structure ~bg theme)
              ("← " ^ prev_id))
          fact.events.revised_from
      end
  | Knowledge_store.Reading_source_fact { keeper; fact } ->
      push ~rail:Theme.Status_ai
        ~style:(Typography.anchor ~bg theme)
        (Printf.sprintf "@%s  ·  [source-bound]" keeper);
      push_kv (say lang ~ko:"소스 경로" ~en:"Source path") fact.path;
      push_kv "SHA-256" fact.sha256;
      push_kv
        (say lang ~ko:"최초 관측" ~en:"First seen")
        (Wire_common.format_unix_rfc3339 fact.first_seen_unix);
      push_blank ();
      push_section ~rail:Theme.Status_ai
        (say lang ~ko:"전체 기억 내용 (Claim)" ~en:"Full Claim");
      push_wrapped ~rail:Theme.Status_ai
        ~style:(Typography.primary ~bg theme) fact.claim
  | Knowledge_store.Reading_source_invalidation { keeper; invalidation } ->
      push ~rail:Theme.Status_attention
        ~style:(Typography.status ~bg ~bold:true theme Theme.Status_attention)
        (Printf.sprintf "! @%s  ·  %s" keeper
           (say lang ~ko:"소스 기반 기억 무효화" ~en:"Source-bound Invalidation"));
      push_blank ();
      push_kv
        (say lang ~ko:"소스 경로" ~en:"Source path")
        invalidation.source_path;
      push_kv
        (say lang ~ko:"사유" ~en:"Reason")
        (Wire_knowledge.source_invalidation_reason_to_string invalidation.reason);
      push_kv
        (say lang ~ko:"무효화 시각" ~en:"Invalidated at")
        (Wire_common.format_unix_rfc3339 invalidation.invalidated_at_unix)
  | Knowledge_store.Reading_diff_item { keeper; item } -> (
      let scope_s =
        match keeper with
        | Some kp -> "@" ^ kp
        | None -> say lang ~ko:"월드 메모리" ~en:"World Memory"
      in
      match item with
      | Knowledge_store.Keeper_added f ->
          let h_lbl, _ = heat_badge f.heat in
          push ~rail:Theme.Status_ok
            ~style:(Typography.status ~bg ~bold:true theme Theme.Status_ok)
            (Printf.sprintf "+ %s  ·  [%s] %s  ·  %s %dx" scope_s f.category
               f.origin h_lbl f.retrieval_count);
          push ~style:(Typography.whisper ~bg theme) ("ID: " ^ f.memory_id);
          push_blank ();
          push_wrapped ~rail:Theme.Status_ok
            ~style:(Typography.primary ~bg theme) f.text
      | Knowledge_store.Keeper_updated u ->
          push ~rail:Theme.Status_active
            ~style:(Typography.status ~bg ~bold:true theme Theme.Status_active)
            (Printf.sprintf "~ %s  ·  [%s] %s @r%d" scope_s u.after.category
               (relation_label ~lang u.relation)
               u.at_rev);
          push_blank ();
          push_section ~rail:Theme.Status_critical
            (say lang ~ko:"이전 (Before)" ~en:"Before");
          push_wrapped ~rail:Theme.Status_critical
            ~style:(Typography.primary ~bg theme) u.before.text;
          push_blank ();
          push_section ~rail:Theme.Status_ok
            (say lang ~ko:"이후 (After)" ~en:"After");
          push_wrapped ~rail:Theme.Status_ok
            ~style:(Typography.primary ~bg theme) u.after.text
      | Knowledge_store.Keeper_retracted r ->
          push ~rail:Theme.Status_critical
            ~style:(Typography.status ~bg ~bold:true theme Theme.Status_critical)
            (Printf.sprintf "- %s  ·  [%s] @r%d  ·  %s" scope_s r.category
               r.removed_at_rev r.removed_by);
          (match r.drop_reason with
          | Some rs ->
              push_kv (say lang ~ko:"사유" ~en:"Reason") rs
          | None -> ());
          push_blank ();
          push_wrapped ~rail:Theme.Status_critical
            ~style:(Typography.primary ~bg theme) r.text
      | Knowledge_store.Keeper_invalidated inv ->
          push ~rail:Theme.Status_attention
            ~style:(Typography.status ~bg ~bold:true theme Theme.Status_attention)
            (Printf.sprintf "! %s  ·  @r%d" scope_s inv.at_rev);
          push_kv
            (say lang ~ko:"유실된 전제" ~en:"Missing premises")
            (String.concat ", " inv.missing_premise_ids);
          push_blank ();
          push_wrapped ~rail:Theme.Status_attention
            ~style:(Typography.primary ~bg theme) inv.text
      | Knowledge_store.World_added e ->
          let tone = Theme.Status_ok in
          push ~rail:tone
            ~style:(Typography.status ~bg ~bold:true theme tone)
            (Printf.sprintf "+ %s  ·  #%d [%s]" scope_s e.seq e.fact_id);
          push_kv (say lang ~ko:"시각" ~en:"Recorded at") e.recorded_at;
          push_blank ();
          push_wrapped ~rail:tone ~style:(Typography.primary ~bg theme) e.summary;
          let kvs = json_kv_summary e.payload in
          if kvs <> [] then begin
            push_blank ();
            List.iter (fun (k, v) -> push_kv k v) kvs
          end
      | Knowledge_store.World_retracted e ->
          let tone = Theme.Status_critical in
          push ~rail:tone
            ~style:(Typography.status ~bg ~bold:true theme tone)
            (Printf.sprintf "- %s  ·  #%d [%s]" scope_s e.seq e.fact_id);
          push_kv (say lang ~ko:"시각" ~en:"Recorded at") e.recorded_at;
          push_blank ();
          push_wrapped ~rail:tone ~style:(Typography.primary ~bg theme) e.summary;
          let kvs = json_kv_summary e.payload in
          if kvs <> [] then begin
            push_blank ();
            List.iter (fun (k, v) -> push_kv k v) kvs
          end
      | Knowledge_store.World_updated u ->
          push ~rail:Theme.Status_active
            ~style:(Typography.status ~bg ~bold:true theme Theme.Status_active)
            (Printf.sprintf "~ %s  ·  #%d [%s]" scope_s u.seq u.fact_id);
          push_kv (say lang ~ko:"시각" ~en:"Recorded at") u.recorded_at;
          push_blank ();
          push_wrapped ~rail:Theme.Status_active
            ~style:(Typography.primary ~bg theme) u.summary;
          let b_kvs = json_kv_summary u.before in
          if b_kvs <> [] then begin
            push_blank ();
            push_section ~rail:Theme.Status_critical
              (say lang ~ko:"이전 (Before)" ~en:"Before");
            List.iter (fun (k, v) -> push_kv k v) b_kvs
          end;
          let a_kvs = json_kv_summary u.after in
          if a_kvs <> [] then begin
            push_blank ();
            push_section ~rail:Theme.Status_ok
              (say lang ~ko:"이후 (After)" ~en:"After");
            List.iter (fun (k, v) -> push_kv k v) a_kvs
          end));
  List.rev !acc

let render_full_reading ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~now_unix ~entry ~scroll =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    let hdr_rect, body_rect = Rect.split_v rect ~top_h:1 in
    let hdr_bg = Color.of_rgb theme.surface_2 in
    Cell_grid.fill_rect ~clip:hdr_rect grid ~rect:hdr_rect
      ~style:(Style.make ~bg:hdr_bg ())
      ();
    let title =
      say lang ~ko:"전문 읽기 (Full Reading)" ~en:"Full Reading"
    in
    let hint =
      say lang ~ko:"[j/k] 스크롤 · [y] 복사 · [Esc] 닫기"
        ~en:"[j/k] Scroll · [y] Copy · [Esc] Close"
    in
    let hw = Grapheme.display_width hint in
    ignore
      (put_clipped ~grid ~clip:hdr_rect ~x:(hdr_rect.x + 1) ~y:hdr_rect.y
         ~max_w:(Int.max 6 (hdr_rect.w - hw - 3))
         ~style:(Typography.anchor ~bg:hdr_bg theme)
         title);
    if hdr_rect.w > hw + 10 then
      ignore
        (put_right ~grid ~clip:hdr_rect ~right_x:(Rect.right hdr_rect - 1)
           ~y:hdr_rect.y ~max_w:hw
           ~style:(Typography.whisper ~bg:hdr_bg ~italic:false theme)
           hint);
    if not (Rect.is_empty body_rect) then begin
      let lines =
        build_reading_lines ~theme ~bg ~width:body_rect.w ~lang ~now_unix entry
      in
      let vis_h = Int.max 1 body_rect.h in
      let max_scroll = Int.max 0 (List.length lines - vis_h) in
      let skip = Int.min max_scroll (Int.max 0 scroll) in
      let y = ref body_rect.y in
      let bottom = Rect.bottom body_rect in
      List.iter
        (fun (ln : reading_line) ->
          if !y < bottom then begin
            let tx =
              match ln.rail with
              | Some tone ->
                  Card.draw_left_rail ~bg ~tone grid ~x:body_rect.x ~y:!y ~h:1
                    ~theme;
                  body_rect.x + 2
              | None -> body_rect.x
            in
            ignore
              (put_clipped ~grid ~clip:body_rect ~x:tx ~y:!y
                 ~max_w:(Int.max 0 (Rect.right body_rect - tx))
                 ~style:ln.style ln.text);
            incr y
          end)
        (Store_scroll.drop skip lines)
    end

(* --- Mode Switch Pills Bar --- *)

let draw_mode_pills ~grid ~(rect : Rect.t) ~(theme : Theme.t) ~(lang : Say.lang)
    ~bg ~(k : Knowledge_store.t) ~keeper =
  if Rect.is_empty rect then ()
  else
    let ev_cnt =
      match Observed.to_option k.keeper_memory_activity with
      | Some act when String.equal act.keeper keeper ->
          Printf.sprintf " (%d)" (List.length act.events)
      | Some _ | None -> ""
    in
    let fact_cnt =
      match Observed.to_option k.keeper_memory_facts with
      | Some mf when String.equal mf.keeper keeper ->
          let n = List.length (Knowledge_store.filtered_memory_fact_rows ~keeper k) in
          Printf.sprintf " (%d)" n
      | Some _ | None -> ""
    in
    let win_s =
      match k.memory_diff_window with
      | Knowledge_store.Window_24h -> "24h"
      | Knowledge_store.Window_7d -> "7d"
      | Knowledge_store.Window_30d -> "30d"
      | Knowledge_store.Window_revs { from_rev; to_rev } ->
          Printf.sprintf "r%d..%d" from_rev to_rev
    in
    let pills =
      [
        ( Printf.sprintf "[e] %s%s"
            (say lang ~ko:"변천 과정" ~en:"Evolution")
            ev_cnt
        , Knowledge_store.equal_memory_view_mode k.memory_view_mode
            Knowledge_store.View_evolution
        , Theme.Status_active );
        ( Printf.sprintf "[f] %s%s"
            (say lang ~ko:"전체 기억" ~en:"Facts")
            fact_cnt
        , Knowledge_store.equal_memory_view_mode k.memory_view_mode
            Knowledge_store.View_facts
        , Theme.Status_ok );
        ( Printf.sprintf "[d] %s (%s)"
            (say lang ~ko:"기간 Diff" ~en:"Diff")
            win_s
        , Knowledge_store.equal_memory_view_mode k.memory_view_mode
            Knowledge_store.View_diff
        , Theme.Status_ai );
      ]
    in
    let right_hint =
      match k.memory_view_mode with
      | Knowledge_store.View_evolution ->
          say lang ~ko:"[t] 전환 · [Enter] 전문" ~en:"[t] Mode · [Enter] Read"
      | Knowledge_store.View_facts ->
          let sort_lbl =
            match k.memory_facts_sort with
            | Knowledge_store.Sort_recency ->
                say lang ~ko:"최근순" ~en:"Recency"
            | Knowledge_store.Sort_retrieved ->
                say lang ~ko:"조회순" ~en:"Retrieved"
          in
          Printf.sprintf "[s] %s · [Enter] %s" sort_lbl
            (say lang ~ko:"전문" ~en:"Read")
      | Knowledge_store.View_diff ->
          say lang ~ko:"[Space] 기간 · [Enter] 전문" ~en:"[Space] Win · [Enter] Read"
    in
    let rh_w = Grapheme.display_width right_hint in
    let pills_limit =
      if rect.w > rh_w + 24 then Rect.right rect - rh_w - 2 else Rect.right rect
    in
    let cx = ref rect.x in
    List.iter
      (fun (label, active, tone) ->
        if !cx < pills_limit then begin
          let avail = pills_limit - !cx in
          if active then begin
            let pbg = Color.of_rgb theme.surface_2 in
            Cell_grid.put_glyph ~clip:rect grid ~x:!cx ~y:rect.y
              ~style:
                (Style.make
                   ~fg:(Color.of_rgb (Theme.status_color theme tone))
                   ~bg:pbg ~attrs:Attr.bold ())
              Glyph.Left_rail;
            let adv =
              put_clipped ~grid ~clip:rect ~x:(!cx + 1) ~y:rect.y
                ~max_w:(Int.max 0 (avail - 1))
                ~style:(Typography.anchor ~bg:pbg ~underline:true theme)
                (" " ^ label ^ " ")
            in
            cx := !cx + 1 + adv + 1
          end
          else begin
            let adv =
              put_clipped ~grid ~clip:rect ~x:!cx ~y:rect.y ~max_w:avail
                ~style:(Typography.structure ~bg theme)
                label
            in
            cx := !cx + adv + 2
          end
        end)
      pills;
    if rect.w > rh_w + 24 then
      ignore
        (put_right ~grid ~clip:rect ~right_x:(Rect.right rect) ~y:rect.y
           ~max_w:rh_w ~style:(Typography.whisper ~bg ~italic:false theme)
           right_hint)

(* --- Responsive Chart Strip (24-bin Age Ladder + facts_by_hour Braille + OS Internals) --- *)

let draw_os_internals_line ~grid ~clip ~x ~y ~max_w ~theme ~bg ~keeper
    (k : Knowledge_store.t) =
  match Observed.to_option k.memory_os_internals with
  | Some intr when String.equal intr.keeper keeper ->
      let comp_s =
        if intr.compaction.present then
          Printf.sprintf "cmp:%dep/%dt/%dB" intr.compaction.epoch_count
            intr.compaction.archived_turns_count intr.compaction.anchor_bytes
        else "cmp:none"
      in
      let ct_s =
        if intr.canonical_turns.present then
          let rk =
            Option.value intr.canonical_turns.latest_runtime_kind ~default:"?"
          in
          Printf.sprintf "turns:%d(%s,rst:%d)" intr.canonical_turns.turn_count rk
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
          Printf.sprintf "dig:%s/%df/%dB" rev_s intr.memory_digest.fact_count
            intr.memory_digest.bytes
        else "dig:none"
      in
      let molt_s =
        match intr.librarian_molt.pending_molt_kind with
        | Some mk ->
            let cats =
              if intr.librarian_molt.pending_molt_categories = [] then ""
              else
                "("
                ^ String.concat "," intr.librarian_molt.pending_molt_categories
                ^ ")"
            in
            "molt:" ^ mk ^ cats
        | None -> "molt:clear"
      in
      let line =
        Printf.sprintf "OS %s · %s · %s · %s" comp_s ct_s dig_s molt_s
      in
      ignore
        (put_clipped ~grid ~clip ~x ~y ~max_w
           ~style:(Typography.structure ~bg theme)
           line);
      true
  | Some _ | None -> false

let draw_keeper_chart_strip ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~bg ~keeper ~(k : Knowledge_store.t) : int =
  if Rect.is_empty rect then 0
  else
    let y = ref rect.y in
    let bottom = Rect.bottom rect in
    let health_opt = Knowledge_store.health_row_for_keeper ~keeper k in
    (match health_opt with
    | Some row when bottom - !y >= 8 ->
        let chart_h = if bottom - !y >= 14 then 5 else 4 in
        let chart_r = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:chart_h in
        let obs_drv = (row.observed_facts, row.derived_facts) in
        if rect.w >= 62 then begin
          match
            Layout.split_h ~gap:2 chart_r [ Layout.Fixed 30; Layout.Flex 1 ]
          with
          | [ left_r; right_r ] ->
              ignore
                (Memory_charts.draw_age_ladder grid ~rect:left_r ~theme
                   ~caps:default_caps ~lang ~bg ~observed_derived:obs_drv
                   row.age_bins);
              Card.draw_v_hairline ~bg grid ~x:(right_r.x - 1) ~y:chart_r.y
                ~h:chart_r.h ~theme;
              ignore
                (Memory_charts.draw_facts_trend grid ~rect:right_r ~theme
                   ~caps:default_caps ~lang ~bg ~observed_derived:obs_drv
                   row.facts_by_hour)
          | _ ->
              ignore
                (Memory_charts.draw_age_ladder grid ~rect:chart_r ~theme
                   ~caps:default_caps ~lang ~bg ~observed_derived:obs_drv
                   row.age_bins)
        end
        else
          ignore
            (Memory_charts.draw_age_ladder grid ~rect:chart_r ~theme
               ~caps:default_caps ~lang ~bg ~observed_derived:obs_drv
               row.age_bins);
        y := !y + chart_h;
        if !y < bottom then begin
          let bytes_s =
            Format_val.format_value Format_val.Bytes
              (float_of_int row.snapshot_bytes)
          in
          let alerts_s =
            match row.alerts with
            | [] -> ""
            | xs -> Printf.sprintf " · %s %d" (Glyph.to_utf8 Glyph.Warning_triangle) (List.length xs)
          in
          let fail_s =
            if row.librarian_failures > 0 then
              Printf.sprintf " · fail:%d" row.librarian_failures
            else ""
          in
          let stat =
            Printf.sprintf "r%d · %d %s (%s %d · %s %d) · +%d -%d · %s%s%s"
              row.revision row.facts
              (say lang ~ko:"사실" ~en:"facts")
              (say lang ~ko:"관측" ~en:"obs")
              row.observed_facts
              (say lang ~ko:"유도" ~en:"drv")
              row.derived_facts row.added row.removed bytes_s fail_s alerts_s
          in
          let st =
            if row.librarian_failures > 0 || row.alerts <> [] then
              Typography.status ~bg theme Theme.Status_attention
            else Typography.whisper ~bg ~italic:false theme
          in
          ignore
            (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w ~style:st
               stat);
          incr y
        end
    | Some row when bottom - !y >= 5 ->
        let compact_r = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:3 in
        let used =
          Memory_charts.draw_age_ladder grid ~rect:compact_r ~theme
            ~caps:default_caps ~lang ~bg
            ~observed_derived:(row.observed_facts, row.derived_facts)
            row.age_bins
        in
        y := !y + used
    | Some _ | None -> ());
    if !y < bottom then begin
      if
        draw_os_internals_line ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
          ~theme ~bg ~keeper k
      then incr y
    end;
    let consumed = !y - rect.y in
    if consumed > 0 && !y < bottom then begin
      Card.draw_hairline ~pad_x:0 ~bg grid ~rect ~y:!y ~theme;
      incr y
    end;
    !y - rect.y

(* --- Evolution (Activity) Table View --- *)

let render_evolution_view ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~now_unix ~bg ~keeper ~(k : Knowledge_store.t) ~focused =
  if Rect.is_empty rect then ()
  else
    match k.keeper_memory_activity with
    | Observed.Value { data = act; stale; _ } ->
        if not (String.equal act.keeper keeper) then
          let msg =
            say lang
              ~ko:(Printf.sprintf "%s 기억 변천 이력 대기 중..." keeper)
              ~en:(Printf.sprintf "Awaiting memory evolution for %s..." keeper)
          in
          ignore
            (put_clipped ~grid ~clip:rect ~x:rect.x ~y:rect.y ~max_w:rect.w
               ~style:(Typography.whisper ~bg theme)
               (Glyph.to_utf8 Glyph.Transport_reconnecting ^ " " ^ msg))
        else begin
          let y = ref rect.y in
          let bottom = Rect.bottom rect in
          let events = Knowledge_store.filtered_memory_activity_events ~keeper k in
          (* Summary line *)
          if !y < bottom then begin
            let stale_s =
              if stale then " " ^ Glyph.to_utf8 Glyph.Transport_stale else ""
            in
            let undec_s =
              if act.undecodable_lines > 0 then
                Printf.sprintf " · %s %d undecodable"
                  (Glyph.to_utf8 Glyph.Warning_triangle)
                  act.undecodable_lines
              else ""
            in
            let hdr =
              Printf.sprintf "%d %s · %d/%d %s%s%s"
                (List.length events)
                (say lang ~ko:"변천 이벤트" ~en:"events")
                act.journal_lines act.limit
                (say lang ~ko:"저널 줄" ~en:"journal lines")
                undec_s stale_s
            in
            ignore
              (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                 ~style:(Typography.structure ~bg theme)
                 hdr);
            incr y
          end;
          if events = [] then begin
            if !y < bottom then
              let empty_msg =
                match act.notes with
                | first :: _ -> first
                | [] ->
                    if String.equal (String.trim k.filter_query) "" then
                      say lang ~ko:"기록된 기억 변천 이벤트가 없습니다."
                        ~en:"No memory evolution events recorded yet."
                    else
                      say lang ~ko:"필터에 일치하는 변천 이벤트가 없습니다."
                        ~en:"No evolution events match filter."
              in
              ignore
                (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                   ~style:(Typography.whisper ~bg theme)
                   empty_msg)
          end
          else begin
            let avail_rows = Int.max 1 (bottom - !y) in
            let rows_per_entry = if avail_rows >= 8 then 2 else 1 in
            let visible_entries = Int.max 1 (avail_rows / rows_per_entry) in
            let total = List.length events in
            let sel = Store_scroll.clamp_index total k.selected_activity_index in
            let start, _ =
              Table.compute_viewport ~total_rows:total
                ~viewport_rows:visible_entries ~scroll:k.activity_scroll_offset
                ~selected:(Some sel)
            in
            List.iteri
              (fun local_i (ev : Wire_knowledge.memory_activity_event) ->
                let abs_i = start + local_i in
                if !y < bottom then begin
                  let is_sel = Int.equal abs_i sel in
                  let row_bg =
                    if is_sel && focused then Color.of_rgb theme.selection_bg
                    else bg
                  in
                  let g, lbl, tone = activity_kind_spec ~lang ev.kind in
                  let row_h =
                    if rows_per_entry >= 2 && !y + 1 < bottom then 2 else 1
                  in
                  if is_sel && focused then
                    paint_selected_row ~grid ~clip:rect
                      ~row_rect:
                        (Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:row_h)
                      ~theme ~tone ()
                  else
                    Card.draw_left_rail ~bg:row_bg ~tone grid ~x:rect.x ~y:!y
                      ~h:row_h ~theme;
                  let tx = rect.x + 2 in
                  let tw = Int.max 0 (rect.w - 2) in
                  let age_s = format_age ~now_unix ev.recorded_at_unix in
                  let counts_s =
                    Printf.sprintf "%d→%d" (List.length ev.before)
                      (List.length ev.after)
                  in
                  let meta_right = Printf.sprintf "%s · %s" counts_s age_s in
                  let mw = Grapheme.display_width meta_right in
                  let left_head =
                    Printf.sprintf "%s %s · r%d" g lbl ev.revision
                  in
                  let primary_preview =
                    let first_claim xs =
                      List.find_map
                        (fun (f : Wire_knowledge.memory_activity_fact) ->
                          match f.claim with
                          | Some c when not (String.equal (String.trim c) "") ->
                              Some (sanitize_single_line c)
                          | Some _ | None -> None)
                        xs
                    in
                    match first_claim ev.after with
                    | Some c -> c
                    | None -> (
                        match first_claim ev.before with
                        | Some c -> c
                        | None -> (
                            match ev.reason with
                            | Some r -> sanitize_single_line r
                            | None -> ev.identity))
                  in
                  if row_h >= 2 then begin
                    ignore
                      (put_clipped ~grid ~clip:rect ~x:tx ~y:!y
                         ~max_w:(Int.max 6 (tw - mw - 2))
                         ~style:
                           (Typography.status ~bg:row_bg ~bold:true theme tone)
                         left_head);
                    ignore
                      (put_right ~grid ~clip:rect ~right_x:(Rect.right rect)
                         ~y:!y ~max_w:mw
                         ~style:(Typography.whisper ~bg:row_bg ~italic:false theme)
                         meta_right);
                    incr y;
                    let preview_txt =
                      match ev.reason with
                      | Some r when not (String.equal (String.trim r) "") ->
                          Printf.sprintf "%s  (%s)" primary_preview
                            (sanitize_single_line r)
                      | Some _ | None -> primary_preview
                    in
                    ignore
                      (put_clipped ~grid ~clip:rect ~x:tx ~y:!y ~max_w:tw
                         ~style:
                           (if is_sel && focused then
                              Typography.anchor ~bg:row_bg theme
                            else Typography.primary ~bg:row_bg theme)
                         preview_txt);
                    incr y
                  end
                  else begin
                    let head_adv =
                      put_clipped ~grid ~clip:rect ~x:tx ~y:!y
                        ~max_w:(Int.max 6 (tw - mw - 2))
                        ~style:
                          (Typography.status ~bg:row_bg ~bold:true theme tone)
                        (left_head ^ "  ")
                    in
                    let rem_w = tw - head_adv - mw - 2 in
                    if rem_w > 4 then
                      ignore
                        (put_clipped ~grid ~clip:rect ~x:(tx + head_adv) ~y:!y
                           ~max_w:rem_w
                           ~style:(Typography.primary ~bg:row_bg theme)
                           primary_preview);
                    ignore
                      (put_right ~grid ~clip:rect ~right_x:(Rect.right rect)
                         ~y:!y ~max_w:mw
                         ~style:(Typography.whisper ~bg:row_bg ~italic:false theme)
                         meta_right);
                    incr y
                  end
                end)
              (Store_scroll.drop start events |> fun xs ->
               let rec take n acc = function
                 | _ when n <= 0 -> List.rev acc
                 | [] -> List.rev acc
                 | hd :: tl -> take (n - 1) (hd :: acc) tl
               in
               take visible_entries [] xs)
          end
        end
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        draw_observed_notice ~grid ~rect ~theme ~lang ~bg obs

(* --- Full Facts Explorer View --- *)

let render_facts_view ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~now_unix ~bg ~keeper ~(k : Knowledge_store.t) ~focused =
  if Rect.is_empty rect then ()
  else
    match k.keeper_memory_facts with
    | Observed.Value { data = mf; stale; _ } ->
        if not (String.equal mf.keeper keeper) then
          let msg =
            say lang
              ~ko:(Printf.sprintf "%s 전체 기억 불러오는 중..." keeper)
              ~en:(Printf.sprintf "Awaiting memory facts for %s..." keeper)
          in
          ignore
            (put_clipped ~grid ~clip:rect ~x:rect.x ~y:rect.y ~max_w:rect.w
               ~style:(Typography.whisper ~bg theme)
               (Glyph.to_utf8 Glyph.Transport_reconnecting ^ " " ^ msg))
        else begin
          let y = ref rect.y in
          let bottom = Rect.bottom rect in
          (* Status header + partial error disclosure *)
          if !y < bottom then begin
            let ord_summary =
              match mf.ordinary with
              | Wire_knowledge.Memory_store_present o ->
                  Printf.sprintf "r%d · %d %s" o.revision (List.length o.facts)
                    (say lang ~ko:"일반" ~en:"ord")
              | Wire_knowledge.Memory_store_absent ->
                  say lang ~ko:"일반 없음" ~en:"ord absent"
              | Wire_knowledge.Memory_store_read_error e -> "ord err: " ^ e
            in
            let src_summary =
              match mf.source_bound with
              | Wire_knowledge.Memory_store_present s ->
                  Printf.sprintf "%d %s" (List.length s.facts)
                    (say lang ~ko:"소스" ~en:"src")
              | Wire_knowledge.Memory_store_absent ->
                  say lang ~ko:"소스 0" ~en:"src 0"
              | Wire_knowledge.Memory_store_read_error e -> "src err: " ^ e
            in
            let sort_s =
              match k.memory_facts_sort with
              | Knowledge_store.Sort_recency ->
                  say lang ~ko:"정렬: 최근순 [s]" ~en:"Sort: Recency [s]"
              | Knowledge_store.Sort_retrieved ->
                  say lang ~ko:"정렬: 조회순 [s]" ~en:"Sort: Retrieved [s]"
            in
            let stale_s =
              if stale then " " ^ Glyph.to_utf8 Glyph.Transport_stale else ""
            in
            let hdr =
              Printf.sprintf "%s · %s · %s%s" ord_summary src_summary sort_s
                stale_s
            in
            ignore
              (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                 ~style:(Typography.structure ~bg theme)
                 hdr);
            incr y
          end;
          (match mf.events_read_error with
          | Some err when !y < bottom ->
              ignore
                (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                   ~style:(Typography.status ~bg theme Theme.Status_attention)
                   (Glyph.to_utf8 Glyph.Warning_triangle ^ " events: " ^ err));
              incr y
          | Some _ | None -> ());
          let rows = Knowledge_store.filtered_memory_fact_rows ~keeper k in
          if rows = [] then begin
            if !y < bottom then
              let msg =
                if String.equal (String.trim k.filter_query) "" then
                  say lang ~ko:"저장된 기억 사실이 없습니다."
                    ~en:"No memory facts stored."
                else
                  say lang ~ko:"필터에 일치하는 기억 사실이 없습니다."
                    ~en:"No memory facts match filter."
              in
              ignore
                (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                   ~style:(Typography.whisper ~bg theme)
                   msg)
          end
          else begin
            let avail_rows = Int.max 1 (bottom - !y) in
            let rows_per_entry = if avail_rows >= 8 then 2 else 1 in
            let visible_entries = Int.max 1 (avail_rows / rows_per_entry) in
            let total = List.length rows in
            let sel = Store_scroll.clamp_index total k.selected_fact_index in
            let start, _ =
              Table.compute_viewport ~total_rows:total
                ~viewport_rows:visible_entries ~scroll:k.facts_scroll_offset
                ~selected:(Some sel)
            in
            List.iteri
              (fun local_i (row : Knowledge_store.memory_fact_row) ->
                let abs_i = start + local_i in
                if !y < bottom then begin
                  let is_sel = Int.equal abs_i sel in
                  let row_bg =
                    if is_sel && focused then Color.of_rgb theme.selection_bg
                    else bg
                  in
                  let tone, left_meta, right_meta, claim_txt =
                    match row with
                    | Knowledge_store.Fact_ordinary { fact; _ } ->
                        let cat_s =
                          Wire_knowledge.memory_fact_category_to_string
                            fact.category
                        in
                        let basis_tag =
                          match fact.basis with
                          | Wire_knowledge.Basis_observed -> "obs"
                          | Wire_knowledge.Basis_observed_board _ -> "board"
                          | Wire_knowledge.Basis_derived _ -> "drv"
                        in
                        let ret_s, ret_tone =
                          match fact.events.retrieval with
                          | Wire_knowledge.Never_retrieved ->
                              ("0x", Theme.Status_historical)
                          | Wire_knowledge.Retrieved { count; _ } ->
                              let t =
                                if count >= 5 then Theme.Status_attention
                                else Theme.Status_ok
                              in
                              (Printf.sprintf "%dx" count, t)
                        in
                        let age_s = format_age ~now_unix fact.last_seen_unix in
                        ( ret_tone
                        , Printf.sprintf "[%s] %s" cat_s basis_tag
                        , Printf.sprintf "%s · %s" ret_s age_s
                        , sanitize_single_line fact.claim )
                    | Knowledge_store.Fact_source sf ->
                        let age_s = format_age ~now_unix sf.first_seen_unix in
                        ( Theme.Status_ai
                        , "[source] " ^ sf.path
                        , age_s
                        , sanitize_single_line sf.claim )
                    | Knowledge_store.Fact_source_invalidation inv ->
                        let age_s = format_age ~now_unix inv.invalidated_at_unix in
                        ( Theme.Status_attention
                        , "! [source-inv] "
                          ^ Wire_knowledge.source_invalidation_reason_to_string
                              inv.reason
                        , age_s
                        , inv.source_path )
                  in
                  let row_h =
                    if rows_per_entry >= 2 && !y + 1 < bottom then 2 else 1
                  in
                  if is_sel && focused then
                    paint_selected_row ~grid ~clip:rect
                      ~row_rect:
                        (Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:row_h)
                      ~theme ~tone ()
                  else
                    Card.draw_left_rail ~bg:row_bg ~tone grid ~x:rect.x ~y:!y
                      ~h:row_h ~theme;
                  let tx = rect.x + 2 in
                  let tw = Int.max 0 (rect.w - 2) in
                  let mw = Grapheme.display_width right_meta in
                  if row_h >= 2 then begin
                    ignore
                      (put_clipped ~grid ~clip:rect ~x:tx ~y:!y
                         ~max_w:(Int.max 6 (tw - mw - 2))
                         ~style:
                           (Typography.status ~bg:row_bg ~bold:true theme tone)
                         left_meta);
                    ignore
                      (put_right ~grid ~clip:rect ~right_x:(Rect.right rect)
                         ~y:!y ~max_w:mw
                         ~style:(Typography.whisper ~bg:row_bg ~italic:false theme)
                         right_meta);
                    incr y;
                    ignore
                      (put_clipped ~grid ~clip:rect ~x:tx ~y:!y ~max_w:tw
                         ~style:
                           (if is_sel && focused then
                              Typography.anchor ~bg:row_bg theme
                            else Typography.primary ~bg:row_bg theme)
                         claim_txt);
                    incr y
                  end
                  else begin
                    let adv =
                      put_clipped ~grid ~clip:rect ~x:tx ~y:!y
                        ~max_w:(Int.max 6 (tw - mw - 2))
                        ~style:
                          (Typography.status ~bg:row_bg ~bold:true theme tone)
                        (left_meta ^ "  ")
                    in
                    let rem_w = tw - adv - mw - 2 in
                    if rem_w > 4 then
                      ignore
                        (put_clipped ~grid ~clip:rect ~x:(tx + adv) ~y:!y
                           ~max_w:rem_w
                           ~style:(Typography.primary ~bg:row_bg theme)
                           claim_txt);
                    ignore
                      (put_right ~grid ~clip:rect ~right_x:(Rect.right rect)
                         ~y:!y ~max_w:mw
                         ~style:(Typography.whisper ~bg:row_bg ~italic:false theme)
                         right_meta);
                    incr y
                  end
                end)
              (Store_scroll.drop start rows |> fun xs ->
               let rec take n acc = function
                 | _ when n <= 0 -> List.rev acc
                 | [] -> List.rev acc
                 | hd :: tl -> take (n - 1) (hd :: acc) tl
               in
               take visible_entries [] xs)
          end
        end
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        draw_observed_notice ~grid ~rect ~theme ~lang ~bg obs

(* --- Word-Wrapped Temporal Memory Diff View (Keeper & World) --- *)

type diff_visual_row =
  | Diff_header_heat_age of {
      rail : Theme.status_token;
      style : Style.t;
      left_txt : string;
      heat_lbl : string;
      heat_tone : Theme.status_token;
      age : string;
      selected : bool;
    }
  | Diff_header_right of {
      rail : Theme.status_token;
      style : Style.t;
      left_txt : string;
      right_txt : string;
      right_style : Style.t;
      selected : bool;
    }
  | Diff_plain of {
      rail : Theme.status_token;
      style : Style.t;
      text : string;
      selected : bool;
    }

let build_diff_visual_rows ~theme ~bg ~lang ~now_unix ~wrap_w ~selected_idx
    (items : Knowledge_store.memory_diff_item list) : diff_visual_row list =
  let acc = ref [] in
  let push r = acc := r :: !acc in
  let push_wrapped ~rail ~style ~selected ~prefix text =
    let avail = Int.max 8 (wrap_w - Grapheme.display_width prefix) in
    let wrapped = wrap_lines ~max_width:avail text in
    let indent = String.make (Grapheme.display_width prefix) ' ' in
    List.iteri
      (fun i ln ->
        let p = if i = 0 then prefix else indent in
        push (Diff_plain { rail; style; text = p ^ ln; selected }))
      wrapped
  in
  List.iteri
    (fun idx item ->
      let selected = Int.equal idx selected_idx in
      match item with
      | Knowledge_store.Keeper_added f ->
          let heat_lbl, heat_tone = heat_badge f.heat in
          let age = format_age ~now_unix f.first_seen_unix in
          let left_txt = Printf.sprintf "+ [%s] %s" f.category f.origin in
          push
            (Diff_header_heat_age
               {
                 rail = Theme.Status_ok;
                 style = Typography.status ~bg ~bold:true theme Theme.Status_ok;
                 left_txt;
                 heat_lbl = Printf.sprintf "%s %dx" heat_lbl f.retrieval_count;
                 heat_tone;
                 age;
                 selected;
               });
          push_wrapped ~rail:Theme.Status_ok
            ~style:(Typography.primary ~bg theme) ~selected ~prefix:"" f.text
      | Knowledge_store.Keeper_updated u ->
          let heat_lbl, heat_tone = heat_badge u.after.heat in
          let hdr =
            Printf.sprintf "~ [%s] %s @r%d" u.after.category
              (relation_label ~lang u.relation)
              u.at_rev
          in
          push
            (Diff_header_right
               {
                 rail = Theme.Status_active;
                 style =
                   Typography.status ~bg ~bold:true theme Theme.Status_active;
                 left_txt = hdr;
                 right_txt =
                   Printf.sprintf "%s %dx" heat_lbl u.after.retrieval_count;
                 right_style = Typography.status ~bg theme heat_tone;
                 selected;
               });
          push_wrapped ~rail:Theme.Status_active
            ~style:(Typography.status ~bg theme Theme.Status_critical)
            ~selected ~prefix:"- " u.before.text;
          push_wrapped ~rail:Theme.Status_active
            ~style:(Typography.status ~bg theme Theme.Status_ok) ~selected
            ~prefix:"+ " u.after.text
      | Knowledge_store.Keeper_retracted r ->
          let why =
            match r.drop_reason with Some s -> " · " ^ s | None -> ""
          in
          let hdr =
            Printf.sprintf "- [%s] %s @r%d · %s%s" r.category
              (say lang ~ko:"대체/철회" ~en:"retracted")
              r.removed_at_rev r.removed_by why
          in
          push
            (Diff_plain
               {
                 rail = Theme.Status_critical;
                 style = Typography.status ~bg theme Theme.Status_critical;
                 text = hdr;
                 selected;
               });
          push_wrapped ~rail:Theme.Status_critical
            ~style:(Typography.whisper ~bg theme) ~selected ~prefix:"- " r.text
      | Knowledge_store.Keeper_invalidated inv ->
          let prems = String.concat ", " inv.missing_premise_ids in
          let hdr =
            Printf.sprintf "! [invalidated] @r%d missing: %s" inv.at_rev prems
          in
          push
            (Diff_plain
               {
                 rail = Theme.Status_attention;
                 style = Typography.status ~bg theme Theme.Status_attention;
                 text = hdr;
                 selected;
               });
          push_wrapped ~rail:Theme.Status_attention
            ~style:(Typography.whisper ~bg theme) ~selected ~prefix:"- " inv.text
      | Knowledge_store.World_added e ->
          let ts =
            match String.index_opt e.recorded_at 'T' with
            | Some i when i + 9 <= String.length e.recorded_at ->
                String.sub e.recorded_at (i + 1) 8
            | Some _ | None -> e.recorded_at
          in
          let line =
            Printf.sprintf "+ #%d [%s] %s" e.seq (short_hash ~len:8 e.fact_id)
              e.summary
          in
          push
            (Diff_header_right
               {
                 rail = Theme.Status_ok;
                 style = Typography.status ~bg theme Theme.Status_ok;
                 left_txt = line;
                 right_txt = ts;
                 right_style = Typography.whisper ~bg theme;
                 selected;
               })
      | Knowledge_store.World_updated u ->
          let ts =
            match String.index_opt u.recorded_at 'T' with
            | Some i when i + 9 <= String.length u.recorded_at ->
                String.sub u.recorded_at (i + 1) 8
            | Some _ | None -> u.recorded_at
          in
          let hdr =
            Printf.sprintf "~ #%d [%s] %s" u.seq (short_hash ~len:8 u.fact_id)
              u.summary
          in
          push
            (Diff_header_right
               {
                 rail = Theme.Status_active;
                 style =
                   Typography.status ~bg ~bold:true theme Theme.Status_active;
                 left_txt = hdr;
                 right_txt = ts;
                 right_style = Typography.whisper ~bg theme;
                 selected;
               });
          let fmt_kvs j =
            json_kv_summary j
            |> (fun xs ->
                 let rec take n acc = function
                   | _ when n <= 0 -> List.rev acc
                   | [] -> List.rev acc
                   | hd :: tl -> take (n - 1) (hd :: acc) tl
                 in
                 take 3 [] xs)
            |> List.map (fun (k, v) -> k ^ "=" ^ v)
            |> String.concat " · "
          in
          let b_s = fmt_kvs u.before in
          if not (String.equal b_s "") then
            push_wrapped ~rail:Theme.Status_active
              ~style:(Typography.status ~bg theme Theme.Status_critical)
              ~selected ~prefix:"- " b_s;
          let a_s = fmt_kvs u.after in
          if not (String.equal a_s "") then
            push_wrapped ~rail:Theme.Status_active
              ~style:(Typography.status ~bg theme Theme.Status_ok) ~selected
              ~prefix:"+ " a_s
      | Knowledge_store.World_retracted r ->
          let ts =
            match String.index_opt r.recorded_at 'T' with
            | Some i when i + 9 <= String.length r.recorded_at ->
                String.sub r.recorded_at (i + 1) 8
            | Some _ | None -> r.recorded_at
          in
          let line =
            Printf.sprintf "- #%d [%s] %s" r.seq (short_hash ~len:8 r.fact_id)
              r.summary
          in
          push
            (Diff_header_right
               {
                 rail = Theme.Status_critical;
                 style = Typography.status ~bg theme Theme.Status_critical;
                 left_txt = line;
                 right_txt = ts;
                 right_style = Typography.whisper ~bg theme;
                 selected;
               }))
    items;
  List.rev !acc

let draw_diff_rows ~grid ~content ~y ~bottom ~(theme : Theme.t) ~bg ~scroll
    ~focused rows =
  let avail_h = Int.max 1 (bottom - !y) in
  let max_skip = Int.max 0 (List.length rows - avail_h) in
  let skip = Int.min max_skip (Int.max 0 scroll) in
  let tx = content.Rect.x + 2 in
  let tw = Int.max 0 (content.Rect.w - 2) in
  List.iter
    (fun row ->
      if !y < bottom then begin
        let sel =
          focused
          &&
          match row with
          | Diff_header_heat_age { selected; _ }
          | Diff_header_right { selected; _ }
          | Diff_plain { selected; _ } ->
              selected
        in
        let row_bg = if sel then Color.of_rgb theme.selection_bg else bg in
        if sel then
          Cell_grid.fill_rect ~clip:content grid
            ~rect:(Rect.make ~x:content.x ~y:!y ~w:content.w ~h:1)
            ~style:(Style.make ~bg:row_bg ())
            ();
        (match row with
        | Diff_header_heat_age
            { rail; style; left_txt; heat_lbl; heat_tone; age; _ } ->
            Card.draw_left_rail ~bg:row_bg ~tone:rail grid ~x:content.x ~y:!y
              ~h:1 ~theme;
            let hw = Grapheme.display_width heat_lbl in
            let aw = Grapheme.display_width age in
            let st = { style with bg = row_bg } in
            ignore
              (put_clipped ~grid ~clip:content ~x:tx ~y:!y
                 ~max_w:(Int.max 6 (tw - hw - aw - 4))
                 ~style:st left_txt);
            ignore
              (put_right ~grid ~clip:content
                 ~right_x:(Rect.right content - aw - 2) ~y:!y ~max_w:hw
                 ~style:(Typography.status ~bg:row_bg theme heat_tone)
                 heat_lbl);
            ignore
              (put_right ~grid ~clip:content ~right_x:(Rect.right content)
                 ~y:!y ~max_w:aw ~style:(Typography.whisper ~bg:row_bg theme)
                 age)
        | Diff_header_right { rail; style; left_txt; right_txt; right_style; _ }
          ->
            Card.draw_left_rail ~bg:row_bg ~tone:rail grid ~x:content.x ~y:!y
              ~h:1 ~theme;
            let rw = Grapheme.display_width right_txt in
            ignore
              (put_clipped ~grid ~clip:content ~x:tx ~y:!y
                 ~max_w:(Int.max 6 (tw - rw - 2))
                 ~style:{ style with bg = row_bg } left_txt);
            ignore
              (put_right ~grid ~clip:content ~right_x:(Rect.right content)
                 ~y:!y ~max_w:rw
                 ~style:{ right_style with bg = row_bg } right_txt)
        | Diff_plain { rail; style; text; _ } ->
            Card.draw_left_rail ~bg:row_bg ~tone:rail grid ~x:content.x ~y:!y
              ~h:1 ~theme;
            ignore
              (put_clipped ~grid ~clip:content ~x:tx ~y:!y ~max_w:tw
                 ~style:{ style with bg = row_bg } text));
        incr y
      end)
    (Store_scroll.drop skip rows)

let render_keeper_diff_view ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~now_unix ~bg ~keeper ~(k : Knowledge_store.t) ~focused
    ~diff_scroll =
  if Rect.is_empty rect then ()
  else
    match k.memory_diff with
    | Observed.Value { data = diff; _ } -> (
        match diff.scope, diff.body with
        | Wire_knowledge.Scope_keeper kp, Wire_knowledge.Keeper_diff { counts; _ }
          when String.equal kp keeper ->
            let y = ref rect.y in
            let bottom = Rect.bottom rect in
            let win_str =
              match k.memory_diff_window with
              | Knowledge_store.Window_24h -> "24h"
              | Knowledge_store.Window_7d -> "7d"
              | Knowledge_store.Window_30d -> "30d"
              | Knowledge_store.Window_revs { from_rev; to_rev } ->
                  Printf.sprintf "rev %d→%d" from_rev to_rev
            in
            let rev_range =
              match diff.range.from_rev, diff.range.to_rev with
              | Some a, Some b -> Printf.sprintf "rev %d → %d" a b
              | Some a, None -> Printf.sprintf "rev %d+" a
              | None, Some b -> Printf.sprintf "..rev %d" b
              | None, None -> win_str
            in
            if !y < bottom then begin
              let h = diff.retrieval_heat in
              let summary =
                Printf.sprintf "%s · %d %s · +%d ~%d -%d !%d · HOT:%d WARM:%d COLD:%d"
                  rev_range counts.total_facts_now
                  (say lang ~ko:"사실" ~en:"facts")
                  counts.added counts.updated counts.retracted counts.invalidated
                  h.hot h.warm h.cold
              in
              ignore
                (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                   ~style:(Typography.structure ~bg ~bold:true theme)
                   summary);
              incr y
            end;
            let h = diff.retrieval_heat in
            let heat_total = h.hot + h.warm + h.cold + h.never_retrieved in
            if heat_total > 0 && bottom - !y >= 4 then begin
              let bar_r = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:2 in
              let segments =
                [
                  (Say.literal "HOT", float_of_int h.hot, Theme.Status_attention);
                  (Say.literal "WARM", float_of_int h.warm, Theme.Status_active);
                  ( Say.literal "COLD"
                  , float_of_int (h.cold + h.never_retrieved)
                  , Theme.Status_historical );
                ]
                |> List.filter (fun (_, v, _) -> v > 0.0)
              in
              ignore
                (Chart.draw grid ~rect:bar_r ~theme ~caps:default_caps ~lang
                   ~show_title:false
                   {
                     Chart.Spec.title = Say.make ~ko:"기억 계층" ~en:"Heat";
                     hotkey_hint = None;
                     kind =
                       Chart.Spec.Stacked_bar
                         {
                           segments;
                           total_label =
                             Say.literal (Printf.sprintf "%d hits" h.total_events);
                           unit = Format_val.Count;
                         };
                   });
              y := !y + 2;
              if !y < bottom then begin
                Card.draw_hairline ~pad_x:0 ~bg grid ~rect ~y:!y ~theme;
                incr y
              end
            end;
            let items = Knowledge_store.filtered_memory_diff_items k in
            if items = [] then begin
              if !y < bottom then
                ignore
                  (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                     ~style:(Typography.whisper ~bg theme)
                     (say lang ~ko:"선택한 기간 내 기억 변경 사항이 없습니다."
                        ~en:"No memory changes recorded in this window."))
            end
            else
              let sel_idx =
                Store_scroll.clamp_index (List.length items) k.selected_diff_index
              in
              let rows =
                build_diff_visual_rows ~theme ~bg ~lang ~now_unix
                  ~wrap_w:(Int.max 10 (rect.w - 2)) ~selected_idx:sel_idx items
              in
              draw_diff_rows ~grid ~content:rect ~y ~bottom ~theme ~bg
                ~scroll:diff_scroll ~focused rows
        | ( (Wire_knowledge.Scope_keeper _ | Wire_knowledge.Scope_world)
          , (Wire_knowledge.Keeper_diff _ | Wire_knowledge.World_diff _) ) ->
            let msg =
              say lang
                ~ko:
                  (Printf.sprintf
                     "%s 기억 Diff 불러오기 대기 중 · [r] 키로 새로고침" keeper)
                ~en:
                  (Printf.sprintf
                     "Awaiting scoped memory diff for %s · press [r] to refresh"
                     keeper)
            in
            ignore
              (put_clipped ~grid ~clip:rect ~x:rect.x ~y:rect.y ~max_w:rect.w
                 ~style:(Typography.whisper ~bg theme)
                 (Glyph.to_utf8 Glyph.Transport_reconnecting ^ " " ^ msg)))
    | ( Observed.Loading _
      | Observed.Absent
      | Observed.Unreported
      | Observed.Failed _ ) as obs ->
        draw_observed_notice ~grid ~rect ~theme ~lang ~bg obs

(* --- Public Entrypoints --- *)

let render_keeper_memory ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~bp:_ ~(model : Model.t) ~keeper ~focused ~diff_scroll =
  if Rect.is_empty rect then ()
  else
    let lang = model.lang in
    let now_unix = model.freshness.last_wall_unix in
    let k = model.knowledge in
    let bg = Color.of_rgb theme.surface_1 in
    match k.memory_reading with
    | Some entry ->
        render_full_reading ~grid ~rect ~theme ~lang ~now_unix ~entry
          ~scroll:k.memory_reading_scroll
    | None ->
        let bar_rect, body_rect = Rect.split_v rect ~top_h:1 in
        draw_mode_pills ~grid ~rect:bar_rect ~theme ~lang ~bg ~k ~keeper;
        if not (Rect.is_empty body_rect) then begin
          let chart_used =
            draw_keeper_chart_strip ~grid ~rect:body_rect ~theme ~lang ~bg
              ~keeper ~k
          in
          let list_rect =
            Rect.make ~x:body_rect.x ~y:(body_rect.y + chart_used)
              ~w:body_rect.w ~h:(Int.max 0 (body_rect.h - chart_used))
          in
          match k.memory_view_mode with
          | Knowledge_store.View_evolution ->
              render_evolution_view ~grid ~rect:list_rect ~theme ~lang ~now_unix
                ~bg ~keeper ~k ~focused
          | Knowledge_store.View_facts ->
              render_facts_view ~grid ~rect:list_rect ~theme ~lang ~now_unix ~bg
                ~keeper ~k ~focused
          | Knowledge_store.View_diff ->
              render_keeper_diff_view ~grid ~rect:list_rect ~theme ~lang
                ~now_unix ~bg ~keeper ~k ~focused ~diff_scroll
        end

let render_world_diff_body ~grid ~(rect : Rect.t) ~(theme : Theme.t)
    ~(lang : Say.lang) ~now_unix ~(k : Knowledge_store.t) ~diff_scroll =
  if Rect.is_empty rect then ()
  else
    let bg = Color.of_rgb theme.surface_1 in
    match k.memory_reading with
    | Some entry ->
        render_full_reading ~grid ~rect ~theme ~lang ~now_unix ~entry
          ~scroll:k.memory_reading_scroll
    | None -> (
        match k.memory_diff with
        | Observed.Value { data = diff; _ } ->
            let y = ref rect.y in
            let bottom = Rect.bottom rect in
            let win_str =
              match k.memory_diff_window with
              | Knowledge_store.Window_24h -> "24h"
              | Knowledge_store.Window_7d -> "7d"
              | Knowledge_store.Window_30d -> "30d"
              | Knowledge_store.Window_revs { from_rev; to_rev } ->
                  Printf.sprintf "rev %d→%d" from_rev to_rev
            in
            if !y < bottom then begin
              let rev_range =
                match diff.range.from_rev, diff.range.to_rev with
                | Some a, Some b -> Printf.sprintf "rev %d → %d" a b
                | Some a, None -> Printf.sprintf "rev %d+" a
                | None, Some b -> Printf.sprintf "..rev %d" b
                | None, None -> win_str
              in
              let line =
                match diff.body with
                | Wire_knowledge.World_diff { counts; _ } ->
                    Printf.sprintf "%s · %d %s · +%d ~%d -%d" rev_range
                      counts.total_claims_now
                      (say lang ~ko:"주장" ~en:"claims")
                      counts.added counts.updated counts.retracted
                | Wire_knowledge.Keeper_diff { counts; _ } ->
                    Printf.sprintf "%s · %d %s · +%d ~%d -%d !%d" rev_range
                      counts.total_facts_now
                      (say lang ~ko:"사실" ~en:"facts")
                      counts.added counts.updated counts.retracted
                      counts.invalidated
              in
              ignore
                (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                   ~style:(Typography.anchor ~bg theme)
                   line);
              incr y
            end;
            if !y + 1 < bottom then begin
              let h = diff.retrieval_heat in
              let bar_rect = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:2 in
              let heat_spec : Chart.Spec.t =
                {
                  title = Say.make ~ko:"기억 계층" ~en:"Memory Tiers";
                  hotkey_hint = None;
                  kind =
                    Chart.Spec.Stacked_bar
                      {
                        segments =
                          [
                            ( Say.literal "HOT"
                            , float_of_int h.hot
                            , Theme.Status_attention );
                            ( Say.literal "WARM"
                            , float_of_int h.warm
                            , Theme.Status_active );
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
                (Chart.draw grid ~rect:bar_rect ~theme ~caps:default_caps ~lang
                   ~show_title:false heat_spec);
              y := !y + 2
            end;
            (* Fleet-aggregated 24-bin Age Ladder when fleet health is loaded *)
            (match Observed.to_option k.keeper_memory_health with
            | Some fleet when bottom - !y >= 10 ->
                let fleet_bins =
                  List.filter_map
                    (fun (r : Wire_knowledge.keeper_memory_health_row) ->
                      r.age_bins)
                    fleet.keepers
                  |> Memory_charts.aggregate_fleet_age_bins
                in
                (match fleet_bins with
                | Some _ ->
                    let obs_tot =
                      List.fold_left
                        (fun acc (r : Wire_knowledge.keeper_memory_health_row) ->
                          acc + r.observed_facts)
                        0 fleet.keepers
                    in
                    let drv_tot =
                      List.fold_left
                        (fun acc (r : Wire_knowledge.keeper_memory_health_row) ->
                          acc + r.derived_facts)
                        0 fleet.keepers
                    in
                    let ladder_r = Rect.make ~x:rect.x ~y:!y ~w:rect.w ~h:4 in
                    let used =
                      Memory_charts.draw_age_ladder grid ~rect:ladder_r ~theme
                        ~caps:default_caps ~lang ~bg
                        ~title:
                          (say lang ~ko:"함대 기억 연령 분포 (24-bin)"
                             ~en:"Fleet Fact Age Ladder (24-bin)")
                        ~observed_derived:(obs_tot, drv_tot) fleet_bins
                    in
                    y := !y + used
                | None -> ())
            | Some _ | None -> ());
            if !y < bottom then begin
              Card.draw_hairline ~pad_x:0 ~bg grid ~rect ~y:!y ~theme;
              incr y
            end;
            let items = Knowledge_store.filtered_memory_diff_items k in
            if items = [] then begin
              if !y < bottom then
                let q = String.trim k.filter_query in
                let msg =
                  if String.equal q "" then
                    say lang ~ko:"이 기간 내 월드 메모리 변동 없음"
                      ~en:"No world memory changes in this window"
                  else
                    say lang ~ko:"필터에 일치하는 월드 메모리 변동 없음"
                      ~en:"No world memory changes match filter"
                in
                ignore
                  (put_clipped ~grid ~clip:rect ~x:rect.x ~y:!y ~max_w:rect.w
                     ~style:(Typography.whisper ~bg theme)
                     msg)
            end
            else
              let sel_idx =
                Store_scroll.clamp_index (List.length items) k.selected_diff_index
              in
              let rows =
                build_diff_visual_rows ~theme ~bg ~lang ~now_unix
                  ~wrap_w:(Int.max 10 (rect.w - 2)) ~selected_idx:sel_idx items
              in
              draw_diff_rows ~grid ~content:rect ~y ~bottom ~theme ~bg
                ~scroll:diff_scroll ~focused:false rows
        | ( Observed.Loading _
          | Observed.Absent
          | Observed.Unreported
          | Observed.Failed _ ) as obs ->
            draw_observed_notice ~grid ~rect ~theme ~lang ~bg obs)
