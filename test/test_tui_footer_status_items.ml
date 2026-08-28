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

let check_one_line label text =
  let newlines =
    String.fold_left
      (fun count char -> if Char.equal char '\n' then count + 1 else count)
      0 text
  in
  Alcotest.(check int) label 1 newlines

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

let test_base_path_reads_between_build_and_port () =
  check_string "base path follows the build and precedes the endpoint"
    "<dim>  q:quit  | v0.24.0 030fa90 | Base: /Users/dancer/me | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Server_build
             { version = "0.24.0"; commit = "030fa9043aafc" }
         ; Masc_tui_footer.Server_base_path "/Users/dancer/me"
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  check_string "path characters are not trimmed into another authority"
    "<dim>  q:quit  | Base:  /work/masc | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Server_base_path " /work/masc" ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:80 ~port:8935
       ~hints:"q:quit" ())

let test_width_omits_whole_status_items () =
  let status =
    [ Masc_tui_footer.Refresh_interval 5.0
    ; Masc_tui_footer.Server_build
        { version = "0.24.0"; commit = "030fa9043aafc5c2003f830c86720afff8e8e2ff" }
    ; Masc_tui_footer.Server_base_path "/work/masc"
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
  check_bool "wide keeps base path" true
    (contains ~needle:"Base: /work/masc" wide);
  check_bool "wide keeps port" true (contains ~needle:"Port: 8935" wide);
  let medium = render 80 in
  check_at_most_cells "80 cells" 80 medium;
  check_bool "medium omits the whole refresh item" false
    (contains ~needle:"Refresh:" medium);
  check_bool "medium omits build before workspace" false
    (contains ~needle:"v0.24.0 030fa90" medium);
  check_bool "medium keeps the whole base-path item" true
    (contains ~needle:"Base: /work/masc" medium);
  check_bool "medium keeps the whole port item" true
    (contains ~needle:"Port: 8935" medium);
  let compact = render 60 in
  check_at_most_cells "60 cells" 60 compact;
  check_bool "compact omits refresh" false
    (contains ~needle:"Refresh:" compact);
  check_bool "compact omits build before endpoint" false
    (contains ~needle:"v0.24.0" compact);
  check_bool "compact omits workspace before endpoint" false
    (contains ~needle:"Base:" compact);
  check_bool "compact retains endpoint last" true
    (contains ~needle:"Port: 8935" compact);
  let narrow = render 40 in
  check_at_most_cells "40 cells" 40 narrow;
  check_bool "narrow never leaves a partial status item" false
    (contains ~needle:"Refresh:" narrow || contains ~needle:"v0.24" narrow
     || contains ~needle:"Base:" narrow || contains ~needle:"Port:" narrow)

let test_chat_hint_widths_keep_one_row_and_whole_items () =
  let status =
    [ Masc_tui_footer.Server_build
        { version = "0.24.0"; commit = "030fa9043aafc" }
    ; Masc_tui_footer.Server_base_path "/Users/dancer/me"
    ]
  in
  let idle_hints =
    "Enter:send  Ctrl-J:newline  Ctrl-R:reasoning  Ctrl-D:tools  \
     PgUp:scroll back  Esc:list  Ctrl-U:clear"
  in
  let render hints max_cells =
    Masc_tui_footer.line ~status ~dim:"\x1b[2m" ~reset:"\x1b[0m"
      ~max_cells ~port:8935 ~hints ()
  in
  List.iter
    (fun width ->
      let line = render idle_hints width in
      check_at_most_cells (Printf.sprintf "idle footer fits %d cells" width)
        width line;
      check_one_line (Printf.sprintf "idle footer stays one row at %d" width)
        line)
    [ 240; 200; 160; 120; 80 ];
  let wide = render idle_hints 200 in
  check_bool "ordinary wide chat keeps its base path" true
    (contains ~needle:"Base: /Users/dancer/me" wide);
  check_bool "ordinary wide chat keeps one endpoint" true
    (contains ~needle:"Port: 8935" wide);
  let narrow = render idle_hints 120 in
  check_bool "narrow chat never shows a partial base-path item" false
    (contains ~needle:"Base:" narrow || contains ~needle:"/Users/dancer" narrow);
  (* This is the real active-chat shape: queue controls, transcript paging,
     Keeper switching, and interrupt status can all be present together. Its
     hints exceed 200 cells; #30465 deliberately keeps hints before facts. *)
  let active_hints =
    "Enter:queue (12 waiting)  Ctrl-K:cancel last  Ctrl-P:edit last  \
     Ctrl-J:newline  Ctrl-R:reasoning  Ctrl-D:tools  \
     \226\134\145/\226\134\147:line  PgUp/PgDn:page  Ctrl-E:newest  (999 back)  \
     Ctrl-G:next Keeper  Esc:interrupt turn  Ctrl-U:clear"
  in
  let active = render active_hints 240 in
  check_at_most_cells "worst-case active footer fits 240 cells" 240 active;
  check_one_line "worst-case active footer stays one row" active;
  check_bool "worst-case active footer omits the whole path" false
    (contains ~needle:"Base:" active || contains ~needle:"/Users/dancer" active)

let test_korean_base_path_is_measured_by_cells () =
  let render max_cells =
    Masc_tui_footer.line
      ~status:[ Masc_tui_footer.Server_base_path "/작업/마스" ]
      ~dim:"" ~reset:"" ~max_cells ~port:8935 ~hints:"q" ()
  in
  let exact = render 36 in
  check_at_most_cells "Korean path fits its exact cell width" 36 exact;
  check_bool "cell measurement retains the whole Korean path" true
    (contains ~needle:"Base: /작업/마스" exact);
  let compact = render 35 in
  check_at_most_cells "compact Korean footer stays in bounds" 35 compact;
  check_bool "one fewer cell omits the whole Korean path" false
    (contains ~needle:"Base:" compact || contains ~needle:"/작업" compact);
  check_bool "endpoint survives Korean path omission" true
    (contains ~needle:"Port: 8935" compact)

let test_unavailable_status_is_omitted () =
  check_string "zero and unread facts are absent"
    "<dim>  q:quit<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Refresh_interval 0.
         ; Masc_tui_footer.Server_build { version = ""; commit = "" }
         ; Masc_tui_footer.Server_base_path ""
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

(* A workspace disagreement used to replace the whole screen and swallow every
   key but r. The reads it protects are refused where they happen, so the
   notice rides the footer instead -- and it is the last fact a narrow footer
   gives up, after the port. *)
let test_a_workspace_mismatch_outlives_the_port () =
  check_string "the local path reads beside the server's own"
    "<dim>  q:quit  | Base: /me | MISMATCH local /work/masc (r:retry) | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Server_base_path "/me"
         ; Masc_tui_footer.Workspace_mismatch "/work/masc"
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  let narrow =
    Masc_tui_footer.line
      ~status:
        [ Masc_tui_footer.Refresh_interval 5.0
        ; Masc_tui_footer.Server_build { version = "0.24.0"; commit = "030fa90" }
        ; Masc_tui_footer.Server_base_path "/Users/dancer/me"
        ; Masc_tui_footer.Workspace_mismatch "/work/masc"
        ]
      ~dim:"<dim>" ~reset:"<reset>" ~max_cells:48 ~port:8935 ~hints:"q:quit" ()
  in
  check_bool "the notice outlives the port" true
    (contains ~needle:"MISMATCH local /work/masc" narrow);
  check_bool "the port went first" false (contains ~needle:"Port:" narrow);
  check_string "a workspace that agrees says nothing"
    "<dim>  q:quit  | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Workspace_mismatch "" ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_answering_names_the_first_keeper () =
  check_string "one keeper answering reads by name"
    "<dim>  q:quit  | \xe2\x97\x8c answering kidsnote | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Keeper_answering [ "kidsnote" ] ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  check_string "more keepers ride as a count behind the first"
    "<dim>  q:quit  | \xe2\x97\x8c answering kidsnote +2 | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Keeper_answering [ "kidsnote"; "analyst"; "rondo" ] ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  check_string "nobody answering says nothing"
    "<dim>  q:quit  | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:[ Masc_tui_footer.Keeper_answering [] ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_answered_glow_reads_by_name () =
  check_string "one finish reads by name with its age"
    "<dim>  q:quit  | \xe2\x9c\x93 kidsnote answered 12s ago | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Keeper_answered
             { name = "kidsnote"; seconds_ago = 12; more = 0 }
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ());
  check_string "older finishes fold behind the newest"
    "<dim>  q:quit  | \xe2\x9c\x93 kidsnote answered 3m ago +2 | Port: 8935<reset>\n"
    (Masc_tui_footer.line
       ~status:
         [ Masc_tui_footer.Keeper_answered
             { name = "kidsnote"; seconds_ago = 200; more = 2 }
         ]
       ~dim:"<dim>" ~reset:"<reset>" ~max_cells:120 ~port:8935
       ~hints:"q:quit" ())

let test_answering_outlives_the_build_fact () =
  (* At a width with no room for everything, the live-activity fact stays on
     the row after refresh and build have been dropped. *)
  let narrow =
    Masc_tui_footer.line
      ~status:
        [ Masc_tui_footer.Refresh_interval 2.0
        ; Masc_tui_footer.Server_build
            { version = "9.9.9"; commit = "abcdef0123456" }
        ; Masc_tui_footer.Keeper_answering [ "kidsnote" ]
        ]
      ~dim:"" ~reset:"" ~max_cells:46 ~port:8935 ~hints:"q:quit" ()
  in
  check_at_most_cells "narrow footer fits" 46 narrow;
  check_bool "the build fact went first" false (contains ~needle:"9.9.9" narrow);
  check_bool "answering stayed" true (contains ~needle:"answering" narrow)

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
      ; Alcotest.test_case "base path reads between build and port" `Quick
          test_base_path_reads_between_build_and_port
      ; Alcotest.test_case "hints do not change the tail" `Quick
          test_hints_do_not_change_the_tail
      ; Alcotest.test_case "40/80/120 omit whole status items" `Quick
          test_width_omits_whole_status_items
      ; Alcotest.test_case "chat widths keep one row and whole items" `Quick
          test_chat_hint_widths_keep_one_row_and_whole_items
      ; Alcotest.test_case "Korean base path is measured by cells" `Quick
          test_korean_base_path_is_measured_by_cells
      ; Alcotest.test_case "unavailable status is omitted" `Quick
          test_unavailable_status_is_omitted
      ; Alcotest.test_case "ANSI Korean hint truncates by cells" `Quick
          test_ansi_korean_hint_truncates_by_cells
      ; Alcotest.test_case "a workspace mismatch outlives the port" `Quick
          test_a_workspace_mismatch_outlives_the_port
      ; Alcotest.test_case "answering names the first keeper" `Quick
          test_answering_names_the_first_keeper
      ; Alcotest.test_case "answered glow reads by name" `Quick
          test_answered_glow_reads_by_name
      ; Alcotest.test_case "answering outlives the build fact" `Quick
          test_answering_outlives_the_build_fact
      ] )
  ]


let () = Alcotest.run "tui_footer_status_items" tests
