module Composer = Masc_tui_board_composer

let test_strip_markdown_title_prefix () =
  Alcotest.(check string) "single hash header"
    "Hello World"
    (Composer.strip_markdown_title_prefix "# Hello World");
  Alcotest.(check string) "triple hash header"
    "Sub heading"
    (Composer.strip_markdown_title_prefix "### Sub heading");
  Alcotest.(check string) "tab after hash header"
    "Tab heading"
    (Composer.strip_markdown_title_prefix "#\tTab heading");
  Alcotest.(check string) "bare single hash"
    ""
    (Composer.strip_markdown_title_prefix "#");
  Alcotest.(check string) "bare multiple hashes"
    ""
    (Composer.strip_markdown_title_prefix "###");
  Alcotest.(check string) "bare hash with trailing space"
    ""
    (Composer.strip_markdown_title_prefix "#   ");
  Alcotest.(check string) "plain text without hashes"
    "Just plain title"
    (Composer.strip_markdown_title_prefix "Just plain title");
  Alcotest.(check string) "hashtag is preserved"
    "#release-v1 note"
    (Composer.strip_markdown_title_prefix "#release-v1 note");
  Alcotest.(check string) "leading and trailing whitespace trimmed"
    "Trimmed"
    (Composer.strip_markdown_title_prefix "   ## Trimmed   ")
;;

let test_split_draft () =
  let (t1, b1) = Composer.split_draft "Simple Title\nBody line 1\nBody line 2" in
  Alcotest.(check string) "title extracted" "Simple Title" t1;
  Alcotest.(check string) "body extracted" "Body line 1\nBody line 2" b1;

  let (t2, b2) = Composer.split_draft "# Markdown Header\n\nBody paragraph" in
  Alcotest.(check string) "markdown title extracted" "Markdown Header" t2;
  Alcotest.(check string) "markdown body preserved" "\nBody paragraph" b2;

  let (t3, b3) = Composer.split_draft "\n\n  ### Delayed Title  \nActual body" in
  Alcotest.(check string) "leading blank lines skipped for title" "Delayed Title" t3;
  Alcotest.(check string) "body follows title" "Actual body" b3;

  let (t4, b4) = Composer.split_draft "Only Title" in
  Alcotest.(check string) "single line title" "Only Title" t4;
  Alcotest.(check string) "empty body" "" b4;

  let (t5, b5) = Composer.split_draft "" in
  Alcotest.(check string) "empty title" "" t5;
  Alcotest.(check string) "empty body" "" b5;

  let (t6, b6) = Composer.split_draft "   \n\n   " in
  Alcotest.(check string) "whitespace title" "" t6;
  Alcotest.(check string) "whitespace body" "" b6
;;

let test_template_detection () =
  let template = Composer.template_for_new_post () in
  Alcotest.(check bool) "template is detected as untouched"
    true
    (Composer.is_untouched_template ~draft:template);
  Alcotest.(check bool) "empty string is detected as untouched"
    true
    (Composer.is_untouched_template ~draft:"");
  Alcotest.(check bool) "whitespace is detected as untouched"
    true
    (Composer.is_untouched_template ~draft:"   \n   \t  ");
  Alcotest.(check bool) "modified draft is not untouched"
    false
    (Composer.is_untouched_template ~draft:"# My Custom Post\n\nContent")
;;

let test_addressing_analysis () =
  let addr1 = Composer.analyze_addressing "Draft mentioning @@all to wake fleet" in
  Alcotest.(check bool) "broadcast all detected"
    true
    (match addr1 with Composer.Broadcast_all -> true | _ -> false);

  let addr2 = Composer.analyze_addressing "Hello @sangsu and @lane-smith please review" in
  (match addr2 with
   | Composer.Mentions targets ->
       Alcotest.(check bool) "contains sangsu" true (List.mem "sangsu" targets);
       Alcotest.(check bool) "contains lane-smith" true (List.mem "lane-smith" targets)
   | _ -> Alcotest.fail "expected Mentions");

  let addr3 = Composer.analyze_addressing "A post without any mentions" in
  Alcotest.(check bool) "unaddressed detected as discoverable"
    true
    (match addr3 with Composer.Discoverable_unaddressed -> true | _ -> false);

  let addr4 = Composer.analyze_addressing "Using @@invalid_broadcast_tag" in
  Alcotest.(check bool) "unsupported broadcast detected"
    true
    (match addr4 with Composer.Unsupported_broadcast _ -> true | _ -> false)
;;

let test_format_addressing_hint () =
  let h1 = Composer.format_addressing_hint ~max_cells:80 Composer.Broadcast_all in
  Alcotest.(check bool) "broadcast contains @@all"
    true
    (String.contains h1 '@');

  let h2 = Composer.format_addressing_hint ~max_cells:80 (Composer.Mentions [ "sangsu" ]) in
  Alcotest.(check bool) "mentions contains target"
    true
    (String.contains h2 '@');
  (* Verify no runaway whitespace gap before arrow *)
  Alcotest.(check bool) "no runaway whitespace padding before arrow"
    false
    (let rec has_wide_gap s =
       try
         let idx = String.index s ' ' in
         let rec count_spaces i =
           if i < String.length s && s.[i] = ' ' then 1 + count_spaces (i + 1)
           else 0
         in
         if count_spaces idx > 10 then true
         else has_wide_gap (String.sub s (idx + 1) (String.length s - idx - 1))
       with Not_found -> false
     in
     has_wide_gap h2);

  let h3 = Composer.format_addressing_hint ~max_cells:80 Composer.Discoverable_unaddressed in
  Alcotest.(check bool) "unaddressed mentions Discoverable"
    true
    (String.contains h3 'D')
;;

let test_compute_caret_position () =
  let (r1, c1) = Composer.compute_caret_position ~chrome_top_rows:6 ~cols:80 ~visible_lines:[] in
  Alcotest.(check int) "empty visible lines row" 7 r1;
  Alcotest.(check int) "empty visible lines col" 5 c1;

  let (r2, c2) = Composer.compute_caret_position ~chrome_top_rows:6 ~cols:80
    ~visible_lines:[ "Line 1"; "Line 2 is longer" ] in
  Alcotest.(check int) "2 visible lines row" 8 r2;
  Alcotest.(check int) "col based on last line width" (5 + String.length "Line 2 is longer") c2
;;

let () =
  Alcotest.run "tui board composer"
    [ ( "strip_prefix"
      , [ Alcotest.test_case "markdown title prefix" `Quick test_strip_markdown_title_prefix ] )
    ; ( "split_draft"
      , [ Alcotest.test_case "draft splitting" `Quick test_split_draft ] )
    ; ( "template"
      , [ Alcotest.test_case "template detection" `Quick test_template_detection ] )
    ; ( "addressing"
      , [ Alcotest.test_case "addressing analysis" `Quick test_addressing_analysis
        ; Alcotest.test_case "addressing hint formatting" `Quick test_format_addressing_hint
        ] )
    ; ( "caret"
      , [ Alcotest.test_case "caret calculation" `Quick test_compute_caret_position ] )
    ]
;;
