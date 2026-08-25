(** Every surface footer ends with the same status facts.

    Before Masc_tui_footer each of the 21 footers spelled [Port: %d] into its
    own format string, so a screen could carry a different spelling, a
    different separator, or no port at all and nothing would say so. These
    tests pin the shared tail. *)

let check_string = Alcotest.(check string)
let check_bool = Alcotest.(check bool)

let contains ~needle text =
  try
    ignore (Str.search_forward (Str.regexp_string needle) text 0);
    true
  with Not_found -> false

let check_at_most_cells label max_cells text =
  Alcotest.(check bool) label true
    (Masc_tui_message_layout.display_width text <= max_cells)

let test_port_closes_every_footer () =
  check_string "port closes a plain footer"
    "<dim>  j/k:move  Tab:next  | Port: 8935<reset>\n"
    (Masc_tui_footer.line ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120
       ~port:8935 ~hints:"j/k:move  Tab:next" ())

let test_extra_facts_precede_port () =
  check_string "a surface's own fact reads before the port"
    "<dim>  q:quit  | Refresh: 5s | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Refresh_interval 5.0 ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_hints_do_not_change_the_tail () =
  (* Two surfaces with nothing in common still end identically. *)
  let tail line =
    let marker = "  | " in
    let index = Str.search_forward (Str.regexp_string marker) line 0 in
    String.sub line index (String.length line - index)
  in
  let overview =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:120 ~port:8935
      ~hints:"j/k:events  t:tasks  q:quit" ()
  in
  let help =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:120 ~port:8935
      ~hints:"j/k:scroll  Esc:close" ()
  in
  check_string "same tail" (tail overview) (tail help)

(* The tail said [Port: 8935] and nothing else, so two checkouts serving that
   port read identically from the screen -- and a binary older than the tree
   it was built from looked exactly like a current one. *)
let test_build_reads_before_the_port () =
  check_string "version and commit precede the port"
    "<dim>  q:quit  | v0.24.0 030fa90 | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Server_build
             { version = "0.24.0"; commit = "030fa9043aafc5c2003f830c86720afff8e8e2ff" }
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_a_short_commit_is_not_padded () =
  check_string "a commit shorter than the prefix reads whole"
    "<dim>  q:quit  | v0.24.0 abc | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Server_build { version = "0.24.0"; commit = "abc" } ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_a_half_read_build_still_says_what_it_knows () =
  check_string "a version with no commit still reads"
    "<dim>  q:quit  | v0.24.0 | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Server_build { version = "0.24.0"; commit = "" } ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  check_string "neither half read is omitted rather than invented"
    "<dim>  q:quit  | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Server_build { version = ""; commit = "" } ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_width_omits_whole_status_items () =
  let status =
    [ Masc_tui_footer.Refresh_interval 5.0
    ; Masc_tui_footer.Server_build
        { version = "0.24.0"; commit = "030fa9043aafc5c2003f830c86720afff8e8e2ff" }
    ]
  in
  let hints = "j/k:move  Enter:detail  r:refresh  Tab:next" in
  let render max_cells =
    Masc_tui_footer.line ~status ~dim:"\x1b[2m" ~reset:"\x1b[0m"
      ~max_cells ~port:8935 ~hints ()
  in
  let wide = render 120 in
  check_at_most_cells "120 cells" 120 wide;
  check_bool "wide keeps refresh" true (contains ~needle:"Refresh: 5s" wide);
  check_bool "wide keeps build" true (contains ~needle:"v0.24.0 030fa90" wide);
  check_bool "wide keeps port" true (contains ~needle:"Port: 8935" wide);
  let medium = render 80 in
  check_at_most_cells "80 cells" 80 medium;
  check_bool "medium omits the whole refresh item" false
    (contains ~needle:"Refresh:" medium);
  check_bool "medium keeps the whole build item" true
    (contains ~needle:"v0.24.0 030fa90" medium);
  check_bool "medium keeps the whole port item" true
    (contains ~needle:"Port: 8935" medium);
  let compact = render 60 in
  check_at_most_cells "60 cells" 60 compact;
  check_bool "compact omits refresh" false
    (contains ~needle:"Refresh:" compact);
  check_bool "compact omits build before endpoint" false
    (contains ~needle:"v0.24.0" compact);
  check_bool "compact retains endpoint last" true
    (contains ~needle:"Port: 8935" compact);
  let narrow = render 40 in
  check_at_most_cells "40 cells" 40 narrow;
  check_bool "narrow never leaves a partial status item" false
    (contains ~needle:"Refresh:" narrow || contains ~needle:"v0.24" narrow
     || contains ~needle:"Port:" narrow)

let test_unavailable_status_is_omitted () =
  check_string "zero and unread facts are absent"
    "<dim>  q:quit<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Refresh_interval 0.
         ; Masc_tui_footer.Server_build { version = ""; commit = "" }
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:80 ~port:0 ~hints:"q:quit"
       ())

let test_ansi_korean_hint_truncates_by_cells () =
  let line =
    Masc_tui_footer.line ~dim:"\x1b[2m" ~reset:"\x1b[0m" ~max_cells:10
      ~port:8935 ~hints:"\x1b[1m확인\x1b[0m  Tab:다음" ()
  in
  check_at_most_cells "ANSI and Korean stay within ten cells" 10 line;
  check_bool "cell-safe truncation is explicit" true (contains ~needle:"~" line)

let tests =
  [ ( "tui-footer-status-items"
    , [ Alcotest.test_case "port closes every footer" `Quick
          test_port_closes_every_footer
      ; Alcotest.test_case "extra facts precede port" `Quick
          test_extra_facts_precede_port
      ; Alcotest.test_case "build reads before the port" `Quick
          test_build_reads_before_the_port
      ; Alcotest.test_case "a short commit is not padded" `Quick
          test_a_short_commit_is_not_padded
      ; Alcotest.test_case "a half-read build still says what it knows" `Quick
          test_a_half_read_build_still_says_what_it_knows
      ; Alcotest.test_case "hints do not change the tail" `Quick
          test_hints_do_not_change_the_tail
      ; Alcotest.test_case "40/80/120 omit whole status items" `Quick
          test_width_omits_whole_status_items
      ; Alcotest.test_case "unavailable status is omitted" `Quick
          test_unavailable_status_is_omitted
      ; Alcotest.test_case "ANSI Korean hint truncates by cells" `Quick
          test_ansi_korean_hint_truncates_by_cells
      ] )
  ]


let () = Alcotest.run "tui_footer_status_items" tests
