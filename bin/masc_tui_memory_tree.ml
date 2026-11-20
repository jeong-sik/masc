(** Hierarchical Memory UI components: mode strip, semantic category badges,
    World -> Shared -> Keeper summary card, and Memory category tree sidebar. *)

open Masc_tui_ansi
module Cat = Masc.Keeper_memory_os_types
module Card = Masc_tui_card
module Doc = Masc_tui_doc
module Layout = Masc_tui_message_layout
module Mem_health = Masc.Tui_decode_memory_health
module Mem_usage = Masc_tui_memory_usage
module Scroll = Masc_tui_scroll
module Terminal_text = Masc.Tui_terminal_text
module Types = Masc_tui_types
module World = Masc_tui_memory_world

let mem_tint () = Theme.series_tint Masc_tui_theme.Memory 0.8

let memory_mode_strip ?(lead = "  ") ~ko ~cols ~active () =
  let say korean english = if ko then korean else english in
  let tabs =
    [ (say "최근" "Recent", active = `Recent, `Recent)
    ; (say "조회" "Retrieved", active = `Retrieved, `Retrieved)
    ; (say "변화" "Changes", active = `Changes, `Changes)
    ; (say "저장" "Storage", active = `Storage, `Storage)
    ]
  in
  lead
  ^ tab_strip ~numbered:true
      ~width:(tab_strip_width ~cols ~before:lead ~after:"")
      ~press:(fun _ text -> text)
      tabs
;;

let category_badge ~ko = function
  | Cat.Code_change ->
      (if ko then "코드변경" else "code"), Theme.series_tint Masc_tui_theme.Calls 0.8
  | Cat.Fact ->
      (if ko then "사실" else "fact"), Theme.series_tint Masc_tui_theme.Memory 0.75
  | Cat.Preference ->
      (if ko then "선호" else "pref"), Theme.recede ()
  | Cat.Goal ->
      (if ko then "목표" else "goal"), Theme.series_tint Masc_tui_theme.Completion 0.8
  | Cat.Constraint ->
      (if ko then "제약" else "rule"), Theme.warn ()
  | Cat.Validated_approach ->
      (if ko then "검증방법" else "valid"), Theme.ok ()
  | Cat.Lesson ->
      (if ko then "교훈" else "lesson"), Theme.series_tint Masc_tui_theme.Latency 0.8
  | Cat.Blocker ->
      (if ko then "막힘" else "blocker"), Theme.bad ()
  | Cat.Custom s ->
      let clean =
        String.trim (Terminal_text.sanitize_terminal_text (s :> string))
      in
      let label = if String.equal clean "" then (if ko then "기타" else "custom") else clean in
      label, Theme.recede ()
;;

let filter_badge ~ko = function
  | Types.Category_all -> (if ko then "전체" else "All"), Ansi.bold
  | Types.Category_ordinary cat -> category_badge ~ko cat
  | Types.Category_source ->
      (if ko then "원본" else "source"), Theme.series_tint Masc_tui_theme.Calls 0.75
  | Types.Category_dropped -> (if ko then "무효화" else "dropped"), Theme.bad ()
;;

let format_storage ~unit bytes =
  match unit with
  | Mem_usage.Tokens ->
      Masc_tui_token_scale.format_estimate Masc_tui_token_scale.fleet bytes ^ " tok"
  | Mem_usage.Bytes ->
      if bytes >= 1024 * 1024 then Printf.sprintf "%.1f MiB" (float bytes /. 1048576.)
      else if bytes >= 1024 then Printf.sprintf "%.1f KiB" (float bytes /. 1024.)
      else Printf.sprintf "%d B" bytes
;;

let world_hierarchy_card ~ko ~width ~world ~health ~unit =
  if width < Card.min_width then []
  else
    let say korean english = if ko then korean else english in
    let status : Card.status =
      match world with
      | World.Not_read ->
          { symbol = Card.Unknown Masc_tui_value.Unknown.Unread
          ; word = say "미조회" "unread"
          ; tone = Theme.recede ()
          }
      | World.Reading ->
          { symbol = Card.Mark Masc_tui_value.Mark.Under_way
          ; word = say "조회 중" "reading"
          ; tone = Theme.info ()
          }
      | World.Read_failed _ ->
          { symbol = Card.Mark Masc_tui_value.Mark.Failed
          ; word = say "월드 오류" "world failed"
          ; tone = Theme.warn ()
          }
      | World.Loaded { refresh_failure = Some _; _ } ->
          { symbol = Card.Mark Masc_tui_value.Mark.Caution
          ; word = say "이전 관측" "stale"
          ; tone = Theme.warn ()
          }
      | World.Loaded { refresh_failure = None; _ } ->
          { symbol = Card.Mark Masc_tui_value.Mark.Settled
          ; word = say "연결됨" "linked"
          ; tone = Theme.ok ()
          }
    in
    let body ~cells =
      let world_prefix =
        mem_tint () ^ "◆ " ^ Ansi.reset
        ^ Ansi.bold ^ say "월드·공유" "World/Shared" ^ Ansi.reset ^ "  "
      in
      let prefix_w = Layout.display_width (Masc_tui_theme.strip_sgr world_prefix) in
      let clause_room = max 8 (cells - prefix_w) in
      let world_line =
        world_prefix
        ^ Layout.truncate_end clause_room
            (String.concat " · " (World.clauses ~ko ~room:clause_room world))
      in
      let keeper_line =
        let branch = Theme.border_muted () ^ "└─ " ^ Ansi.reset in
        let summary =
          match health with
          | None ->
              Theme.recede ()
              ^ say "키퍼 기억 저장소 · 관측 대기" "Keeper memory · awaiting snapshot"
              ^ Ansi.reset
          | Some snap ->
              let bytes_total =
                snap.Mem_health.mhs_total_snapshot_bytes
                + snap.mhs_total_source_snapshot_bytes
              in
              let lag_clause =
                match snap.mhs_total_librarian_unread_turns with
                | Some turns when turns > 0 ->
                    " · " ^ Theme.warn ()
                    ^ Printf.sprintf
                        (if ko then "미읽은 턴 %d" else "%d unread turns")
                        turns
                    ^ Ansi.reset
                | Some _ | None -> ""
              in
              Printf.sprintf
                (if ko then "키퍼 기억 (%d명) · 일반 %d + 원본 %d · %s"
                 else "Keeper memory (%d) · %d ordinary + %d source · %s")
                (List.length snap.mhs_keepers) snap.mhs_total_facts
                snap.mhs_total_source_facts
                (format_storage ~unit bytes_total)
              ^ lag_clause
        in
        Layout.truncate_end (max 1 cells) (branch ^ summary) ^ Ansi.reset
      in
      [ world_line; keeper_line ]
    in
    let edge : Card.edge =
      { name = say "기억 계층 · 월드 → 공유 → 키퍼" "Memory Hierarchy · World → Shared → Keepers"
      ; key = None
      ; status = Some status
      ; count = None
      ; focus = Card.Unfocused
      ; border_accent = Doc.panel_border_accent Masc_tui_theme.Panel_memory
      ; footer_keys = []
      }
    in
    Card.render ~ko ~style:(Doc.card_style ()) ~width ~height:4 { edge; body }
;;

let sidebar_tree_rows ~ko ~width ~height ~world ~selected ~entries =
  let width = max 1 width in
  let hline =
    Theme.border_muted ()
    ^ String.concat "" (List.init width (fun _ -> Ansi.box_h))
    ^ Ansi.reset
  in
  let world_summary =
    let room = max 1 (width - 2) in
    Layout.truncate_end room
      (String.concat " · " (World.clauses ~ko ~room world))
  in
  let header =
    [ ( None
      , Layout.fit_width
          (Ansi.bold ^ (if ko then "기억 계층" else "Memory tree") ^ Ansi.reset
           ^ Theme.recede () ^ (if ko then "  d:접기" else "  d:hide") ^ Ansi.reset)
          width )
    ; ( None
      , Layout.fit_width
          (mem_tint () ^ "◆ " ^ Ansi.reset
           ^ Ansi.bold ^ (if ko then "월드·공유" else "World/Shared") ^ Ansi.reset)
          width )
    ; ( None
      , Layout.fit_width
          (Theme.border_muted () ^ Masc_tui_theme.Box.v ^ " " ^ Ansi.reset
           ^ Theme.recede () ^ world_summary ^ Ansi.reset)
          width )
    ; None, hline
    ]
    |> List.filteri (fun i _ -> i < max 0 height)
  in
  let body_height = max 0 (height - List.length header) in
  let total = List.length entries in
  let selected_index =
    List.find_index (fun (filt, _) -> filt = selected) entries
    |> Option.value ~default:0
  in
  let scroll =
    Scroll.ensure_visible ~cursor:selected_index ~height:(max 1 body_height) 0
  in
  let visible =
    entries
    |> List.filteri (fun i _ -> i >= scroll && i < scroll + body_height)
    |> List.mapi (fun i (filt, count_opt) ->
         let orig_idx = scroll + i in
         let is_last = orig_idx = total - 1 in
         let branch = if is_last then "└─ " else "├─ " in
         let is_selected = filt = selected in
         let lead = if is_selected then "› " else "  " in
         let label, badge_style = filter_badge ~ko filt in
         let count_str =
           match count_opt with
           | None -> "?"
           | Some n -> string_of_int n
         in
         let right_str = " " ^ count_str in
         let right_w = Layout.display_width right_str in
         let lead_w = Layout.display_width lead in
         let branch_w = Layout.display_width branch in
         let name_room = max 0 (width - lead_w - branch_w - right_w) in
         let fitted_label = Layout.truncate_end name_room label in
         let pad_cells =
           max 0 (width - lead_w - branch_w - Layout.display_width fitted_label - right_w)
         in
         let line =
           if is_selected then
             Theme.selection_style ()
             ^ Layout.fit_width
                 (lead ^ branch ^ fitted_label ^ String.make pad_cells ' ' ^ right_str)
                 width
             ^ Ansi.reset
           else
             Layout.fit_width
               (lead
                ^ Theme.border_muted () ^ branch ^ Ansi.reset
                ^ badge_style ^ fitted_label ^ Ansi.reset
                ^ String.make pad_cells ' '
                ^ Theme.recede () ^ right_str ^ Ansi.reset)
               width
         in
         Some filt, line)
  in
  header @ visible
;;
