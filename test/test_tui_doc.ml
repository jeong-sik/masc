(* Pure decision and safety tests for [Masc_tui_doc] and numbered [tab_strip].
   Checks structural invariants -- width bounds down to zero on CJK/ASCII text,
   mixed Korean/ASCII key-value column alignment and narrow stacking,
   numbered-paragraph splitting fidelity without double blank rails, terminal
   control-byte sanitisation (including footer_keys), fixed-height bottom
   sheets, and plain/colour-stripped structure parity. *)

open Alcotest
module Doc = Masc_tui_doc
module Layout = Masc_tui_message_layout
module Theme = Masc_tui_theme
module Card = Masc_tui_card

let display_cells s = Layout.display_width (Theme.strip_sgr s)

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i =
    i + n <= h && (String.sub haystack i n = needle || loop (i + 1))
  in
  n = 0 || loop 0

let strip_all_whitespace s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (function
      | ' ' | '\t' | '\n' | '\r' -> ()
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let assert_no_control_bytes ~label rows =
  List.iter
    (fun row ->
       let plain = Theme.strip_sgr row in
       check bool (label ^ ": no C0/DEL byte") true
         (String.for_all (fun c -> Char.code c >= 0x20 && c <> '\x7f') plain))
    rows

let test_section_rule_bounds () =
  List.iter
    (fun width ->
       let with_badge = Doc.section_rule ~width ~badge:"검증 통과" "목표와 성공 조건" in
       check bool
         (Printf.sprintf "section_rule fits width %d" width)
         true
         (display_cells with_badge <= width);
       let plain = Doc.section_rule ~width "Details" in
       check bool
         (Printf.sprintf "plain section_rule fits width %d" width)
         true
         (display_cells plain <= width))
    [ 0; 1; 2; 3; 4; 5; 8; 20; 40; 80; 120 ];
  check string "zero width returns empty" "" (Doc.section_rule ~width:0 "목표")

let test_kv_rows_align_stack_and_fit () =
  let fields =
    [ Doc.kv "제목" "MASC TUI 전면 UI/UX 고도화 작업입니다"
    ; Doc.kv "목표값" "6 stacked PRs"
    ; Doc.kv "" "라벨 없는 부가 설명 한 줄"
    ; Doc.kv "Metric" "completion rate over 24 hours across active keepers"
    ]
  in
  List.iter
    (fun width ->
       let rows = Doc.kv_rows ~width fields in
       if width <= 0 then check int "zero width returns empty" 0 (List.length rows)
       else begin
         check bool (Printf.sprintf "non-empty kv at %d" width) true (rows <> []);
         List.iter
           (fun row ->
              check bool
                (Printf.sprintf "kv row fits width %d: %S" width (Theme.strip_sgr row))
                true
                (display_cells row <= width))
           rows
       end)
    [ 0; 1; 2; 3; 5; 10; 20; 36; 60; 100 ];
  (* In 2-column mode, mixed CJK and ASCII labels align their value start column. *)
  let rows =
    Doc.kv_rows ~width:80
      [ Doc.kv "a" "alpha"; Doc.kv "목표" "beta"; Doc.kv "Measure" "gamma" ]
  in
  check int "3 rows" 3 (List.length rows);
  let value_col word row =
    let plain = Theme.strip_sgr row in
    let n = String.length word and h = String.length plain in
    let rec find i =
      if i + n > h then -1
      else if String.sub plain i n = word then Layout.display_width (String.sub plain 0 i)
      else find (i + 1)
    in
    find 0
  in
  let col_a = value_col "alpha" (List.nth rows 0) in
  let col_b = value_col "beta" (List.nth rows 1) in
  let col_c = value_col "gamma" (List.nth rows 2) in
  check int "CJK and ASCII labels share value column" col_a col_b;
  check int "wider ASCII label sets shared column" col_a col_c;
  (* Below 2-column threshold, labels stack cleanly above indented values. *)
  let stacked = Doc.kv_rows ~width:24 ~indent:2 [ Doc.kv "Long Label" "short value" ] in
  check bool "stacked mode produces >= 2 rows" true (List.length stacked >= 2)
  (* A width with room for two columns but not for the whole label stacks it
     rather than cutting it: at every width the label is drawn whole. *)
  List.iter
    (fun width ->
       let rows = Doc.kv_rows ~width ~indent:2 [ Doc.kv "Long Label" "short value" ] in
       check bool (Printf.sprintf "the label is whole at %d" width) true
         (List.exists (fun row -> contains ~needle:"Long Label" (Theme.strip_sgr row)) rows))
    (List.init 40 (fun step -> 20 + step))

let test_split_numbered_paragraphs_preserves_text () =
  let sample =
    "직접 확인됐다. (1) board 증거 게시물 #53291 확인. (2) GitHub PR(#53292) 승인. (10) 목표 달성."
  in
  let split = Doc.split_numbered_paragraphs sample in
  check int "splits into intro + 3 numbered clauses incl double digit" 4 (List.length split);
  check string "all non-whitespace characters preserved verbatim"
    (strip_all_whitespace sample)
    (strip_all_whitespace (String.concat "" split));
  let start_with_num = Doc.split_numbered_paragraphs "(1) first (2) second" in
  check int "starts with (1) -> 2 clauses" 2 (List.length start_with_num);
  let unsplit = Doc.split_numbered_paragraphs "call foo(1) and check #53292(2) inline" in
  check int "does not split mid-identifier parens" 1 (List.length unsplit)

let test_prose_block_sanitization_and_paragraphs () =
  let payload = "hello \027[31mred\027[0m world\n(1) first \007bell\n\r\t(2) second" in
  List.iter
    (fun width ->
       let rows = Doc.prose_block ~width ~break_numbered:true payload in
       assert_no_control_bytes ~label:(Printf.sprintf "prose %d" width) rows;
       List.iter
         (fun row ->
            check bool (Printf.sprintf "prose fits width %d" width) true
              (display_cells row <= width);
            check bool "escaped ESC" false (contains ~needle:"\027[31mred" row))
         rows)
    [ 0; 1; 2; 3; 5; 20; 48 ];
  (* Standalone tab and CR are escaped rather than trimmed away silently. *)
  let ctrl_rows = Doc.prose_block ~width:40 "a\n\t\nb" in
  assert_no_control_bytes ~label:"tab preserved as escape" ctrl_rows;
  check bool "tab escaped cleanly" true
    (List.exists (fun r -> contains ~needle:"\\x09" (Theme.strip_sgr r)) ctrl_rows);
  (* Explicit blank line before (1) must not emit two consecutive blank guide lines. *)
  let spaced = Doc.prose_block ~width:60 ~break_numbered:true "intro\n\n(1) one (2) two" in
  let is_blank_guide r =
    let p = String.trim (Theme.strip_sgr r) in
    String.equal p Masc_tui_theme.Box.v
  in
  let rec has_adjacent_blanks = function
    | a :: b :: rest -> (is_blank_guide a && is_blank_guide b) || has_adjacent_blanks (b :: rest)
    | [ _ ] | [] -> false
  in
  check bool "no consecutive blank guide rails" false (has_adjacent_blanks spaced)

let test_callout_and_bottom_sheet_geometry_and_sanitization () =
  let status =
    { Card.symbol = Card.Mark Masc_tui_value.Mark.Yours
    ; word = "최종 확인\027[2J"
    ; tone = ""
    }
  in
  List.iter
    (fun width ->
       let callout =
         Doc.action_callout_card ~ko:true ~width ~role:Theme.Panel_attention
           ~title:"다음 행동\007" ~status ~next_step:"a를 눌러 확인\n둘째 줄"
           ~summary_clauses:[ "실제값 6/6" ]
           ~footer_keys:[ { Card.key = "a\007"; label = "근거\027]0;x\007확인" } ]
       in
       assert_no_control_bytes ~label:(Printf.sprintf "callout %d" width) callout;
       List.iter
         (fun row ->
            if width <= 0 then check int "empty at 0" 0 (List.length callout)
            else check bool (Printf.sprintf "callout <= width %d" width) true
              (display_cells row <= width))
         callout)
    [ 0; 1; 2; 6; 12; 64 ];
  let sb = { Card.offset = 1; visible = 3; total = 8 } in
  let sheet =
    Doc.bottom_sheet ~ko:true ~width:70 ~height:7 ~role:Theme.Panel_memory
      ~title:"선택한 사실" ~status ~count:(Card.Whole 12) ~scrollbar:sb
      ~footer_keys:[ { Card.key = "Enter"; label = "전체\n읽기" } ]
      ~body:(fun ~cells ->
        List.init 8 (fun i -> Printf.sprintf "%d row within %d" i cells))
      ()
  in
  check int "bottom_sheet exact height 7" 7 (List.length sheet);
  assert_no_control_bytes ~label:"bottom_sheet" sheet;
  List.iter
    (fun row -> check int "bottom_sheet row exact width 70" 70 (display_cells row))
    sheet;
  let joined = String.concat "\n" (List.map Theme.strip_sgr sheet) in
  check bool "structure survives SGR stripping (NO_COLOR parity): title & scrollbar & overflow" true
    (contains ~needle:"선택한 사실" joined
     && contains ~needle:"외 3" joined
     && contains ~needle:Masc_tui_theme.Box.scroll_up joined)

let test_numbered_tab_strip_and_default () =
  let tabs =
    [ ("목표", true, 1); ("작업 검토", false, 2); ("작업 판정", false, 3) ]
  in
  let unnumbered =
    Theme.strip_sgr
      (Masc_tui_ansi.tab_strip ~width:80 ~press:(fun _ s -> s) tabs)
  in
  check bool "default numbered=false omits superscripts" false (contains ~needle:"¹" unnumbered);
  let numbered =
    Theme.strip_sgr
      (Masc_tui_ansi.tab_strip ~numbered:true ~width:80 ~press:(fun _ s -> s) tabs)
  in
  check bool "numbered=true includes superscripts" true
    (contains ~needle:"¹목표" numbered && contains ~needle:"²작업 검토" numbered);
  let min_unnumbered = Masc_tui_ansi.tab_strip_min_width tabs in
  let min_numbered = Masc_tui_ansi.tab_strip_min_width ~numbered:true tabs in
  check bool "numbered min_width accounts for superscript" true (min_numbered = min_unnumbered + 1);
  for width = 0 to 60 do
    let rendered =
      Theme.strip_sgr
        (Masc_tui_ansi.tab_strip ~numbered:true ~width ~press:(fun _ s -> s) tabs)
    in
    check bool (Printf.sprintf "numbered strip fits width %d" width) true
      (Layout.display_width rendered <= width)
  done;
  let unpadded_active_end = contains ~needle:" ▸목표 " unnumbered in
  check bool "active tab draws padded pill" true unpadded_active_end

let test_v2_chrome_primitives_bounds_and_sanitization () =
  List.iter
    (fun width ->
       let hr = Doc.hairline ~width ~indent:2 () in
       check bool (Printf.sprintf "hairline fits %d" width) true
         (display_cells hr <= width);
       let hdr =
         Doc.section_header ~width ~indent:2 ~subtitle:"3 members, 1 waiting"
           ~right:"all on glm" "Roster"
       in
       assert_no_control_bytes ~label:(Printf.sprintf "header %d" width) [ hdr ];
       check bool (Printf.sprintf "section_header fits %d" width) true
         (display_cells hdr <= width);
       let hints =
         Doc.preview_footer_hints ~width ~indent:2
           [ { Card.key = "Enter\007"; label = "열기\n상세" }
           ; { Card.key = "Space"; label = "펼치기" }
           ; { Card.key = "Esc"; label = "닫기\027[2J" }
           ]
       in
       assert_no_control_bytes ~label:(Printf.sprintf "hints %d" width) [ hints ];
       check bool (Printf.sprintf "hints fit %d" width) true
         (display_cells hints <= width))
    [ 0; 1; 2; 3; 6; 15; 40; 80; 120 ];
  List.iter
    (fun height ->
       let rows =
         Doc.docked_preview ~width:64 ~height ~indent:2 ~eyebrow:"선택한 목표"
           ~title:"MASC TUI V2" ~meta:"검토 대기 · 3/3"
           ~footer_hints:
             [ { Card.key = "Space"; label = "더 보기" }
             ; { Card.key = "Enter"; label = "상세 열기" }
             ]
           [ "첫째 줄 요약"; "둘째 줄\007 제어문자"; "셋째 줄 본문" ]
       in
       check int (Printf.sprintf "docked_preview exact height %d" height)
         (max 0 height) (List.length rows);
       assert_no_control_bytes ~label:(Printf.sprintf "docked %d" height) rows;
       List.iter
         (fun r ->
            check bool (Printf.sprintf "docked row fits at h=%d" height) true
              (display_cells r <= 64))
         rows)
    [ 0; 1; 2; 3; 6; 12 ];
  check string "footer_key_style NO_COLOR returns empty" ""
    (Theme.For_testing.footer_key_style ~colors_enabled:false);
  check string "active_tab_pill NO_COLOR returns empty" ""
    (Theme.For_testing.active_tab_pill ~colors_enabled:false
       ~project:(fun _ -> None) ~surface:Theme.Page None);
  check string "section_heading NO_COLOR returns empty" ""
    (Theme.For_testing.section_heading ~colors_enabled:false
       ~project:(fun _ -> None) ~surface:Theme.Page None)

let test_docked_preview_chrome_matches_rendered_budget () =
  let hints = [ { Card.key = "Enter"; label = "open" } ] in
  let blank_hints = [ { Card.key = "  "; label = " " } ] in
  check int "eyebrow + footer hints -> 3 chrome rows" 3
    (Doc.docked_preview_chrome ~eyebrow:"Selected" ~footer_hints:hints ());
  check int "eyebrow only -> 2 chrome rows" 2
    (Doc.docked_preview_chrome ~eyebrow:"Selected" ~footer_hints:[] ());
  check int "footer hints only -> 2 chrome rows" 2
    (Doc.docked_preview_chrome ~footer_hints:hints ());
  check int "blank eyebrow + blank hints -> 1 chrome row (hairline only)" 1
    (Doc.docked_preview_chrome ~eyebrow:"   " ~footer_hints:blank_hints ());
  let body = [ "body-row-1"; "body-row-2"; "body-row-3"; "body-row-4" ] in
  let chrome = Doc.docked_preview_chrome ~eyebrow:"Header" ~footer_hints:hints () in
  let rendered =
    Doc.docked_preview ~width:64 ~height:(chrome + List.length body) ~indent:1
      ~eyebrow:"Header" ~footer_hints:hints body
    |> List.map Theme.strip_sgr
  in
  check int "rendered height matches chrome + body" (chrome + List.length body)
    (List.length rendered);
  check bool "final body row is never clipped at height = chrome + body" true
    (List.exists (fun line -> String.trim line = "body-row-4") rendered)

let () =
  run "tui_doc"
    [ ( "doc"
      , [ test_case "section_rule bounds across zero/narrow/wide" `Quick test_section_rule_bounds
        ; test_case "kv_rows align CJK/ASCII, stack narrow, fit widths" `Quick
            test_kv_rows_align_stack_and_fit
        ; test_case "split_numbered_paragraphs preserves content verbatim" `Quick
            test_split_numbered_paragraphs_preserves_text
        ; test_case "prose_block escapes control bytes without double blank rails" `Quick
            test_prose_block_sanitization_and_paragraphs
        ; test_case "callout card and bottom sheet sanitize keys & keep geometry" `Quick
            test_callout_and_bottom_sheet_geometry_and_sanitization
        ; test_case "numbered tab_strip default and width bounds" `Quick
            test_numbered_tab_strip_and_default
        ; test_case "v2 hairline, section_header, footer_hints, docked_preview & theme NO_COLOR" `Quick
            test_v2_chrome_primitives_bounds_and_sanitization
        ; test_case "docked_preview_chrome matches rendered body budget" `Quick
            test_docked_preview_chrome_matches_rendered_budget
        ] )
    ]
